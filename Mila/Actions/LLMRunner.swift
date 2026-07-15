import Foundation
import os

/// Errors surfaced from the CLI invocation. The Settings UI / rename sheet
/// renders `errorDescription` directly so users can self-diagnose path /
/// permission issues without reading logs.
enum LLMRunnerError: LocalizedError {
    case toolDisabled
    case executableNotFound(String)
    case launchFailed(Error)
    case nonZeroExit(code: Int32, stderr: String)
    case timedOut(seconds: Int)
    case emptyOutput
    case cancelled

    var errorDescription: String? {
        switch self {
        case .toolDisabled:
            return "No LLM is configured in Settings → LLM."
        case .executableNotFound(let name):
            return "Could not find \(name) on PATH. Install it or set the full path in Settings → LLM."
        case .launchFailed(let err):
            return "Could not launch the LLM CLI: \(err.localizedDescription)"
        case .nonZeroExit(let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "LLM CLI exited with status \(code). \(trimmed)"
        case .timedOut(let seconds):
            return "LLM CLI did not respond within \(seconds)s. If it's running an agentic task (e.g. calendar lookup), raise the timeout in Settings → LLM."
        case .emptyOutput:
            return "LLM CLI returned no output. Check the prompt or your CLI's auth."
        case .cancelled:
            return "LLM call was cancelled."
        }
    }
}

/// Everything the Settings → LLM test panel needs to explain a run to the
/// user. Produced by `LLMRunner.diagnose`. Unlike `LLMRunner.run`, nothing is
/// thrown away on failure: the user sees the exact command, the exit code, and
/// both streams so they can self-diagnose (or re-run `command` in a terminal).
struct LLMTestResult: Equatable {
    /// The exact, shell-quoted command line that was launched (or would have
    /// been, if we got far enough to build it). Empty when no tool/executable
    /// was resolved. For the OpenAI HTTP path this is `POST <url>`.
    var command: String = ""
    /// True only when the CLI launched and exited 0, OR the HTTP endpoint
    /// returned 2xx with parseable content.
    var succeeded: Bool = false
    /// Process exit code, or nil when the CLI never launched (setup error).
    /// Always nil for the OpenAI HTTP path (there is no process).
    var exitCode: Int32? = nil
    var stdout: String = ""
    var stderr: String = ""
    var durationSeconds: TimeInterval = 0
    /// Set when something prevented the CLI from even running — no tool
    /// selected, executable not on PATH, launch failure — or when the OpenAI
    /// transport couldn't reach the endpoint (network/timeout failure).
    var setupError: String? = nil
    var timedOut: Bool = false
    // OpenAI HTTP diagnostics (Phase 7). Populated only by the
    // `.openaiCompatible` diagnose branch; empty/nil for the CLI path.
    /// The full request URL the POST was sent to.
    var url: String = ""
    /// HTTP status code of the response, or nil when the request never got a
    /// response (transport failure). This — not `exitCode` — is the "did the
    /// HTTP call actually run?" signal for the OpenAI path (AC-DIAG-04).
    var httpStatus: Int? = nil
    /// The JSON request body that was sent, for copy-paste / debugging.
    var requestBody: String = ""

    /// Whether anything actually ran. For the CLI path, "launched a process"
    /// (`exitCode != nil`); for the OpenAI path, "got an HTTP response"
    /// (`httpStatus != nil`). False for pure setup failures (no tool selected,
    /// executable not found, transport couldn't connect).
    var didLaunch: Bool { exitCode != nil || httpStatus != nil }
}

/// Spawns the configured `claude` or `cursor-agent` binary with the user's
/// prompt + transcript and returns whatever the CLI prints to stdout.
///
/// Why the transcript is appended to the *prompt argument* rather than
/// piped on stdin: `claude -p` happens to read both stdin and argv, but
/// `cursor-agent -p` only looks at argv and silently asks "what transcript?"
/// when stdin is closed. Putting the transcript in the prompt is the
/// portable shape that works for both CLIs without the user having to know.
///
/// We deliberately don't try to manage authentication, model selection, or
/// streaming — both CLIs handle that themselves. Our job is "give the user's
/// own LLM the transcript + their prompt, hand back the answer".
enum LLMRunner {
    /// Hard cap on how long we'll wait for a single invocation. Long enough
    /// that an agentic claude run that grinds for a few minutes still gets
    /// to finish — short enough that a truly stuck process doesn't pin the
    /// sheet forever. Foreground "Suggest" callers should pass a smaller
    /// value to keep the UI responsive; background "Send" callers can run
    /// long.
    static let defaultTimeout: TimeInterval = 300

    /// Format the prompt + optional Live-AI summary + transcript into the
    /// single arg-vector blob the CLI sees. Kept as a distinct function so
    /// tests can assert on the exact wire format.
    ///
    /// The summary lives **above** the transcript (and the transcript is
    /// labelled "Full transcript") so the LLM reads the gist before the
    /// raw text — that improves answer quality on long recordings where
    /// the model would otherwise lose the thread halfway through the
    /// transcript. Empty / whitespace-only `summary` is omitted entirely
    /// (we don't want "Summary: (empty)" confusing the model when Live AI
    /// wasn't configured for this recording).
    static func composedPrompt(_ userPrompt: String,
                               transcript: String,
                               summary: String = "") -> String {
        let prompt = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let gist = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty && gist.isEmpty { return prompt }
        if gist.isEmpty {
            return "\(prompt)\n\n---\nTranscript:\n\(body)"
        }
        if body.isEmpty {
            return "\(prompt)\n\n---\nSummary:\n\(gist)"
        }
        return "\(prompt)\n\n---\nSummary:\n\(gist)\n\nFull transcript:\n\(body)"
    }

    /// Run `tool` with `prompt` + `transcript`. Returns stdout, trimmed.
    /// Throws `LLMRunnerError` on any failure.
    ///
    /// `executablePathOverride` lets the user point at a binary in a
    /// non-PATH location (e.g. `/Users/foo/.local/bin/claude`).
    ///
    /// `summary` (optional) prepends a Live-AI summary section above the
    /// transcript so the LLM has the gist before it reads the raw text.
    /// Pass empty string when there is no summary (e.g. Live AI not
    /// configured) — the wire format collapses to the old transcript-only
    /// shape in that case.
    ///
    /// `extraArgs` are appended verbatim after the tool's standard arguments
    /// — the user's persisted "Extra CLI args" from Settings → LLM (e.g.
    /// `--model …`, a permission flag). Empty for callers that manage their
    /// own args (Live AI pins its own model).
    ///
    /// `timeout` defaults to 5 minutes. Pass a smaller value for foreground
    /// callers that block UI (e.g. the Suggest button).
    static func run(tool: LLMTool,
                    prompt: String,
                    transcript: String,
                    summary: String = "",
                    executablePathOverride: String?,
                    model: String? = nil,
                    session: LLMSession = .none,
                    extraArgs: [String] = [],
                    timeout: TimeInterval = LLMRunner.defaultTimeout,
                    // OpenAI-compatible endpoint config (Phase 6.0). Only
                    // `transport` is caller-transparent — it defaults to a real
                    // `URLSession` so CLI-only callers pass nothing and are
                    // unchanged. `baseURL`/`apiKey`/`jsonMode` default to
                    // nil/nil/false; callers that can land on
                    // `.openaiCompatible` MUST thread them (see the plan's
                    // 6.0.3 call-site audit). `model:` is reused for the
                    // OpenAI model name (`LLMSettings.openAIModelName`).
                    openAIBaseURL: String? = nil,
                    openAIAPIKey: String? = nil,
                    jsonMode: Bool = false,
                    temperature: Double? = nil,
                    transport: OpenAITransport? = nil) async throws -> String {
        guard tool != .none else { throw LLMRunnerError.toolDisabled }

        // OpenAI-compatible HTTP path — handled before any CLI resolution, so
        // `executablePathOverride` / `session` / `extraArgs` (CLI-only) are
        // irrelevant here. Defense in depth: `run` has no `LLMSettings`, so it
        // re-checks the base-URL readiness gate the Settings UI also enforces
        // via `isConfigured` — a nil/empty base URL can't send anything.
        if tool == .openaiCompatible {
            guard let baseURL = openAIBaseURL,
                  !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw LLMRunnerError.toolDisabled }
            let t = transport ?? URLSessionTransport(URLSession.shared)
            return try await runOpenAICompatible(prompt: prompt,
                                                 transcript: transcript,
                                                 summary: summary,
                                                 model: model,
                                                 timeout: timeout,
                                                 baseURL: baseURL,
                                                 apiKey: openAIAPIKey ?? "",
                                                 jsonMode: jsonMode,
                                                 temperature: temperature,
                                                 transport: t)
        }

        let executable = try resolveExecutable(tool: tool,
                                               override: executablePathOverride)
        let fullPrompt = composedPrompt(prompt, transcript: transcript, summary: summary)
        let modelTag = (model?.isEmpty ?? true) ? "(default)" : (model ?? "")
        let sessionTag: String = {
            switch session {
            case .none: return "none"
            case .new(let id): return "new:\(id.uuidString.prefix(8))"
            case .resume(let id): return "resume:\(id.uuidString.prefix(8))"
            }
        }()
        print("LLMRunner: \(executable.lastPathComponent) model=\(modelTag) session=\(sessionTag) prompt=\(fullPrompt.count)c timeout=\(Int(timeout))s")
        // ProcessHandle bridges Swift task cancellation to the underlying
        // `Process`. The continuation thread `attach`es the real Process
        // once it's spawned; if the Task was already cancelled by then
        // (e.g. user hit Cancel between `run(...)` and `Process().run()`),
        // attach immediately terminates the process. Otherwise an actual
        // cancel call on the Task fires `onCancel` below, which terminates
        // the live child.
        let handle = ProcessHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // For Live AI's session continuity to work, every tick
                // must share a CWD so claude's per-CWD session
                // storage stays addressable. We key the stable
                // sandbox off the session UUID.
                let sandboxKey: String? = {
                    switch session {
                    case .none: return nil
                    case .new(let id), .resume(let id): return id.uuidString
                    }
                }()
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let outcome = try executeProcess(executable: executable,
                                                         arguments: tool.arguments(prompt: fullPrompt, model: model, session: session) + extraArgs,
                                                         timeout: timeout,
                                                         handle: handle,
                                                         sandboxKey: sandboxKey)
                        // The Swift Task that drove us was cancelled mid-flight
                        // — `handle` SIGTERM'd the process, so the user-visible
                        // truth is "we cancelled it", not "the CLI crashed".
                        if outcome.cancelled {
                            continuation.resume(throwing: LLMRunnerError.cancelled)
                        } else if outcome.timedOut {
                            continuation.resume(throwing: LLMRunnerError.timedOut(seconds: Int(timeout.rounded(.up))))
                        } else if outcome.exitCode != 0 {
                            continuation.resume(throwing: LLMRunnerError.nonZeroExit(
                                code: outcome.exitCode,
                                stderr: outcome.stderr.isEmpty ? outcome.stdout : outcome.stderr))
                        } else {
                            continuation.resume(returning: outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            handle.terminate()
        }
    }

    /// HTTP path for `tool == .openaiCompatible`: build the
    /// `/chat/completions` request via the pure `OpenAIClient.makeRequest`,
    /// send it through the injectable transport, then decode via the pure
    /// `OpenAIClient.parse`. `timeout` is applied as the request's
    /// `timeoutInterval` (and `URLSession.data` surfaces the expiry as
    /// `URLError.timedOut`); Task cancellation surfaces as
    /// `URLError.cancelled`. Both are mapped back onto `LLMRunnerError` so
    /// callers see the same error vocabulary the CLI path produces.
    ///
    /// Error mapping:
    ///  - `OpenAIRequestError` (from `parse`) → rethrown as-is (typed,
    ///    `LocalizedError`, rendered by the Settings sheet / rename sheet).
    ///  - `URLError.cancelled` → `.cancelled` (mirrors the CLI's
    ///    `ProcessHandle`-driven cancellation).
    ///  - `URLError.timedOut` → `.timedOut(seconds:)`, rounded *up* to match
    ///    the CLI path's `Int(timeout.rounded(.up))` so AC-TIMEOUT-02's
    ///    "matches the CLI format" holds.
    ///  - any other transport failure → `.launchFailed` (the closest existing
    ///    bucket for "couldn't reach the endpoint").
    static func runOpenAICompatible(prompt: String,
                                    transcript: String,
                                    summary: String,
                                    model: String?,
                                    timeout: TimeInterval,
                                    baseURL: String,
                                    apiKey: String,
                                    jsonMode: Bool,
                                    temperature: Double?,
                                    transport: OpenAITransport) async throws -> String {
        // `makeRequest` throws `OpenAIRequestError.invalidEndpoint` for a
        // malformed base URL (issue celarent7/mila#1). It's an
        // `OpenAIRequestError`, so the typed-rethrow catch below surfaces it
        // to the caller as a readable LocalizedError — not a crash.
        var request = try OpenAIClient.makeRequest(baseURL: baseURL,
                                               model: model ?? "",
                                               prompt: prompt,
                                               transcript: transcript,
                                               summary: summary,
                                               apiKey: apiKey,
                                               jsonMode: jsonMode,
                                               temperature: temperature)
        if timeout > 0 { request.timeoutInterval = timeout }

        do {
            let (http, data) = try await transport.send(request)
            switch OpenAIClient.parse(data: data, response: http) {
            case .success(let content):
                return content
            case .failure(let error):
                throw error
            }
        } catch let error as OpenAIRequestError {
            throw error
        } catch let urlError as URLError {
            switch urlError.code {
            case .cancelled:
                throw LLMRunnerError.cancelled
            case .timedOut:
                throw LLMRunnerError.timedOut(seconds: Int(timeout.rounded(.up)))
            default:
                throw LLMRunnerError.launchFailed(urlError)
            }
        } catch {
            throw LLMRunnerError.launchFailed(error)
        }
    }

    /// Run the configured CLI like `run` does, but never throw — capture the
    /// exact command line, exit code, stdout, and stderr and hand them all
    /// back so the Settings → LLM test panel can show the user precisely what
    /// happened. This is the "why isn't my LLM working?" debugging path: the
    /// returned `command` is copy-pasteable into a terminal so the user can
    /// reproduce the run themselves.
    ///
    /// `extraArgs` are appended verbatim after the tool's standard arguments
    /// — the user types them in the test panel (e.g. `--model claude-sonnet-4-6`,
    /// `--debug`) so they can probe param changes without us hardcoding a
    /// model picker. Setup problems (no tool selected, executable not found)
    /// come back in `setupError` rather than as an exception.
    static func diagnose(tool: LLMTool,
                         prompt: String,
                         transcript: String,
                         summary: String = "",
                         extraArgs: [String] = [],
                         executablePathOverride: String?,
                         model: String? = nil,
                         timeout: TimeInterval = 120,
                         // OpenAI-compatible config (Phase 6.0/7). Same four
                         // defaulted params as `run`; only `transport` is
                         // caller-transparent. `diagnose` is non-throwing, so
                         // the base-URL guard and transport failures come back
                         // as `setupError` rather than exceptions.
                         openAIBaseURL: String? = nil,
                         openAIAPIKey: String? = nil,
                         jsonMode: Bool = false,
                         transport: OpenAITransport? = nil) async -> LLMTestResult {
        guard tool != .none else {
            return LLMTestResult(setupError: LLMRunnerError.toolDisabled.errorDescription ?? "No LLM configured.")
        }
        // OpenAI HTTP path — handled before CLI resolution, so no
        // `executablePath` is required (AC-DIAG-05).
        if tool == .openaiCompatible {
            return await diagnoseOpenAICompatible(prompt: prompt,
                                                  transcript: transcript,
                                                  summary: summary,
                                                  model: model,
                                                  timeout: timeout,
                                                  baseURL: openAIBaseURL ?? "",
                                                  apiKey: openAIAPIKey ?? "",
                                                  jsonMode: jsonMode,
                                                  transport: transport)
        }
        let executable: URL
        do {
            executable = try resolveExecutable(tool: tool, override: executablePathOverride)
        } catch {
            let msg = (error as? LLMRunnerError)?.errorDescription ?? error.localizedDescription
            return LLMTestResult(setupError: msg)
        }
        let fullPrompt = composedPrompt(prompt, transcript: transcript, summary: summary)
        let args = tool.arguments(prompt: fullPrompt, model: model) + extraArgs
        let command = ([executable.path] + args).map(shellQuote).joined(separator: " ")
        let start = Date()
        // Bridge Task cancellation to the child process, same as `run` — if
        // the test is cancelled (Settings closed, a newer run started), SIGTERM
        // the CLI instead of leaving it alive until the timeout.
        let handle = ProcessHandle()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let elapsed: () -> TimeInterval = { Date().timeIntervalSince(start) }
                    do {
                        let outcome = try executeProcess(executable: executable,
                                                         arguments: args,
                                                         timeout: timeout,
                                                         handle: handle,
                                                         sandboxKey: nil)
                        continuation.resume(returning: LLMTestResult(
                            command: command,
                            succeeded: !outcome.timedOut && outcome.exitCode == 0,
                            exitCode: outcome.exitCode,
                            stdout: outcome.stdout,
                            stderr: outcome.stderr,
                            durationSeconds: elapsed(),
                            timedOut: outcome.timedOut))
                    } catch {
                        // Only `launchFailed` reaches here now.
                        let msg = (error as? LLMRunnerError)?.errorDescription ?? error.localizedDescription
                        continuation.resume(returning: LLMTestResult(
                            command: command,
                            durationSeconds: elapsed(),
                            setupError: msg))
                    }
                }
            }
        } onCancel: {
            handle.terminate()
        }
    }

    /// Non-throwing HTTP diagnostic for `tool == .openaiCompatible` — the
    /// "test" path the Settings → LLM panel uses to explain an OpenAI endpoint
    /// to the user. Mirrors `runOpenAICompatible`'s request building but,
    /// because `diagnose` never throws, captures every outcome into the
    /// `LLMTestResult` fields: `url`/`requestBody`/`httpStatus` for the request
    /// + response, `succeeded` iff 2xx with parseable content, the response
    /// body in `stdout`, a typed error message in `stderr` for 4xx/5xx, and
    /// `setupError`/`timedOut` for transport failures (so the panel can tell
    /// "couldn't reach the endpoint" from "endpoint returned an error").
    static func diagnoseOpenAICompatible(prompt: String,
                                         transcript: String,
                                         summary: String,
                                         model: String?,
                                         timeout: TimeInterval,
                                         baseURL: String,
                                         apiKey: String,
                                         jsonMode: Bool,
                                         transport: OpenAITransport?) async -> LLMTestResult {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty else {
            return LLMTestResult(
                setupError: LLMRunnerError.toolDisabled.errorDescription
                    ?? "No OpenAI endpoint is configured in Settings → LLM.")
        }
        // `makeRequest` throws `invalidEndpoint` for a malformed base URL
        // (issue celarent7/mila#1). `diagnose` never throws, so surface it as
        // a setup problem the test panel can render — not a crash.
        var request: URLRequest
        do {
            request = try OpenAIClient.makeRequest(baseURL: trimmedBase,
                                                   model: model ?? "",
                                                   prompt: prompt,
                                                   transcript: transcript,
                                                   summary: summary,
                                                   apiKey: apiKey,
                                                   jsonMode: jsonMode,
                                                   temperature: nil)
        } catch let error as OpenAIRequestError {
            return LLMTestResult(
                setupError: error.errorDescription ?? "\(error)",
                url: "\(trimmedBase)/chat/completions")
        } catch {
            return LLMTestResult(setupError: error.localizedDescription)
        }
        if timeout > 0 { request.timeoutInterval = timeout }
        let url = request.url?.absoluteString ?? ""
        let requestBody = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        let command = "POST \(url)"
        let start = Date()
        let t = transport ?? URLSessionTransport(URLSession.shared)

        do {
            let (http, data) = try await t.send(request)
            let status = http.statusCode
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            switch OpenAIClient.parse(data: data, response: http) {
            case .success(let content):
                return LLMTestResult(
                    command: command,
                    succeeded: true,
                    stdout: content,
                    durationSeconds: Date().timeIntervalSince(start),
                    url: url,
                    httpStatus: status,
                    requestBody: requestBody)
            case .failure(let error):
                // 4xx/5xx: the endpoint ran (httpStatus set) but didn't
                // succeed. Surface the readable typed message in stderr and
                // the raw body in stdout so the user can self-diagnose.
                return LLMTestResult(
                    command: command,
                    succeeded: false,
                    stdout: bodyString,
                    stderr: (error as? LocalizedError)?.errorDescription ?? "\(error)",
                    durationSeconds: Date().timeIntervalSince(start),
                    url: url,
                    httpStatus: status,
                    requestBody: requestBody)
            }
        } catch let urlError as URLError {
            if urlError.code == .timedOut {
                return LLMTestResult(
                    command: command,
                    durationSeconds: Date().timeIntervalSince(start),
                    setupError: LLMRunnerError.timedOut(
                        seconds: Int(timeout.rounded(.up))).errorDescription,
                    timedOut: true,
                    url: url,
                    requestBody: requestBody)
            }
            return LLMTestResult(
                command: command,
                durationSeconds: Date().timeIntervalSince(start),
                setupError: urlError.localizedDescription,
                url: url,
                requestBody: requestBody)
        } catch {
            return LLMTestResult(
                command: command,
                durationSeconds: Date().timeIntervalSince(start),
                setupError: error.localizedDescription,
                url: url,
                requestBody: requestBody)
        }
    }

    /// Split a free-text "extra arguments" string into an argv array, honoring
    /// single quotes, double quotes, and backslash escapes the way a POSIX
    /// shell would — so a user can paste `--model "claude sonnet"` and get two
    /// tokens, not three. Deliberately small: it covers the quoting users
    /// actually type, not the full shell grammar.
    static func tokenizeArguments(_ input: String) -> [String] {
        var args: [String] = []
        var current = ""
        var hasToken = false
        var inSingle = false
        var inDouble = false
        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inSingle {
                if c == "'" { inSingle = false } else { current.append(c) }
            } else if inDouble {
                if c == "\"" {
                    inDouble = false
                } else if c == "\\", i + 1 < chars.count, chars[i + 1] == "\"" || chars[i + 1] == "\\" {
                    i += 1
                    current.append(chars[i])
                } else {
                    current.append(c)
                }
            } else if c == "'" {
                inSingle = true; hasToken = true
            } else if c == "\"" {
                inDouble = true; hasToken = true
            } else if c == "\\", i + 1 < chars.count {
                i += 1
                current.append(chars[i]); hasToken = true
            } else if c == " " || c == "\t" || c == "\n" {
                if hasToken { args.append(current); current = ""; hasToken = false }
            } else {
                current.append(c); hasToken = true
            }
            i += 1
        }
        if hasToken { args.append(current) }
        return args
    }

    /// Quote a single argv token for display so the rendered `command` can be
    /// pasted back into a shell and run as-is. Tokens made only of "safe"
    /// characters are left bare; everything else is single-quoted with any
    /// embedded single quotes escaped the classic `'\''` way.
    static func shellQuote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        let safe = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_./=:,@+")
        if s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Raw result of a single CLI invocation, before any success/failure
    /// interpretation. `run` maps this onto its throwing contract; `diagnose`
    /// surfaces every field verbatim so the Settings test panel can show the
    /// user exactly what happened (exit code, stdout, stderr) even on failure.
    struct ProcessOutcome {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        let timedOut: Bool
        let cancelled: Bool
    }

    private static func executeProcess(executable: URL,
                                       arguments: [String],
                                       timeout: TimeInterval,
                                       handle: ProcessHandle,
                                       sandboxKey: String? = nil) throws -> ProcessOutcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        // Inherit `$PATH` etc. so the CLI can find any helpers it shells out
        // to. Spawning a Process from a sandboxed-style minimal environment
        // surprises users whose claude/cursor wrappers source nvm/asdf/etc.
        process.environment = ProcessInfo.processInfo.environment

        // CRITICAL: spawn in a fresh, empty temp directory. macOS attributes
        // any file access by the child process to *our* bundle ID, so if
        // claude / cursor-agent walks the cwd looking for project files
        // (which both do — particularly cursor-agent in `-f` mode), the user
        // sees scary TCC prompts saying "Mila would like to access
        // Desktop / Downloads". Launching from an isolated, empty directory
        // guarantees there's nothing for the LLM CLI to discover and reach
        // for, so no permission prompts fire.
        //
        // When `sandboxKey` is non-nil we use a STABLE per-key sandbox
        // instead of a fresh one. claude stores its session jsonl
        // inside a hash of the CWD — if every tick spawns in a
        // different sandbox, `--resume <uuid>` errors with "No
        // conversation with ID …" because the storage lives in the
        // previous (already-deleted) sandbox. Live AI passes the
        // session UUID as the key so all ticks share one sandbox; the
        // caller is responsible for cleaning it up via
        // `cleanupStableSandbox(key:)` when the session ends.
        let sandbox: URL
        let ephemeral: Bool
        if let key = sandboxKey {
            sandbox = stableSandboxDirectory(key: key)
            ephemeral = false
        } else {
            sandbox = makeSandboxDirectory()
            ephemeral = true
        }
        process.currentDirectoryURL = sandbox

        // Close stdin immediately. Some CLIs (claude) read both stdin AND
        // argv; some (cursor-agent) ignore stdin entirely. We standardised
        // on "transcript lives in argv" — see `composedPrompt` — so giving
        // the child an empty stdin is the consistent behaviour.
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Only tear down the sandbox if it was ephemeral. Stable
        // session sandboxes are cleaned up by the caller when the
        // Live AI session ends.
        defer {
            if ephemeral {
                try? FileManager.default.removeItem(at: sandbox)
            }
        }

        do {
            try process.run()
        } catch {
            throw LLMRunnerError.launchFailed(error)
        }
        try? stdinPipe.fileHandleForWriting.close()

        // Hand the live process to the handle so a Task cancel can terminate
        // it. If cancellation already fired before we got here, `attach`
        // sends SIGTERM right now; the wait-loop below picks up the exit
        // and we throw `.cancelled` instead of resuming with a partial
        // result the user no longer cares about.
        handle.attach(process)

        // Read stdout/stderr eagerly on background queues so a chatty CLI
        // can't deadlock by filling the OS pipe buffer while we waitUntilExit.
        // Chunked reads into lock-guarded boxes (not one readDataToEndOfFile
        // into a captured var) so the bounded drain below can snapshot what
        // arrived so far without racing a still-blocked reader.
        let outBox = OSAllocatedUnfairLock(initialState: Data())
        let errBox = OSAllocatedUnfairLock(initialState: Data())
        let group = DispatchGroup()
        for (pipe, box) in [(stdoutPipe, outBox), (stderrPipe, errBox)] {
            group.enter()
            DispatchQueue.global().async {
                let handle = pipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData   // blocks until data or EOF
                    if chunk.isEmpty { break }
                    box.withLock { $0.append(chunk) }
                }
                group.leave()
            }
        }

        // Bounded wait — kill the process if it's still running at deadline.
        let runningGroup = DispatchGroup()
        runningGroup.enter()
        DispatchQueue.global().async {
            process.waitUntilExit()
            runningGroup.leave()
        }
        let deadline = DispatchTime.now() + .seconds(Int(timeout.rounded(.up)))
        let timedOut = runningGroup.wait(timeout: deadline) == .timedOut
        if timedOut {
            // SIGTERM first; if the CLI ignores it, hard-kill after a short
            // grace period so we don't read half-drained pipes or remove the
            // sandbox out from under a still-running child.
            process.terminate()
            if runningGroup.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                // BOUNDED: `waitUntilExit` has been observed never returning
                // even after a SIGKILL (macOS 26, sampled live — likely a
                // reaping race inside NSTask). The child is dead-or-dying
                // either way, and this is the timedOut path so its exit
                // status is already being discarded — don't hang the caller
                // (and its awaiting continuation) on the obituary.
                if runningGroup.wait(timeout: .now() + 5) == .timedOut {
                    print("LLMRunner: waitUntilExit didn't return after SIGKILL — abandoning the wait")
                }
            }
        }
        // Drain the pipe readers once the process is known to be gone.
        if timedOut || handle.wasTerminated {
            // Killed path: BOUNDED. A grandchild that inherited the pipes
            // and survived the kill (an MCP server or node helper the CLI
            // spawned) holds them open indefinitely, and an unbounded wait
            // here hung this method (and the awaiting continuation, and
            // the caller's in-flight slot) forever. The output is being
            // discarded anyway (the caller sees .timedOut / .cancelled),
            // so after the grace we move on; the leaked reader threads
            // exit when the pipes finally close.
            if group.wait(timeout: .now() + 3) == .timedOut {
                print("LLMRunner: pipe drain timed out after kill — an orphaned grandchild is still holding stdout/stderr; returning partial output")
            }
        } else {
            // Normal exit: bounded too, but with a GENEROUS grace. Two
            // opposing constraints meet here:
            //  * The child closed its write ends when it died, so the
            //    readers hit EOF as soon as they get CPU — on a loaded
            //    macos-26 CI VM that can be 10s+ of dispatch latency, and
            //    a tight 3s bound truncated perfectly good output
            //    mid-stream (test_runner_spawns_child_in_isolated_temp_
            //    directory went flaky on CI).
            //  * EOF is not GUARANTEED even after exit 0 — a helper the
            //    CLI spawned (MCP server, node daemon) can inherit the
            //    pipes and keep them open indefinitely; an unbounded wait
            //    hung the caller forever.
            // 30s clears any realistic dispatch latency while still
            // returning the (fully buffered by then) output if a
            // pipe-holding helper never lets EOF arrive.
            if group.wait(timeout: .now() + 30) == .timedOut {
                print("LLMRunner: pipe drain timed out after normal exit — a helper process is still holding stdout/stderr; returning buffered output")
            }
        }

        let stdout = String(data: outBox.withLock { $0 }, encoding: .utf8) ?? ""
        let stderr = String(data: errBox.withLock { $0 }, encoding: .utf8) ?? ""

        return ProcessOutcome(stdout: stdout,
                              stderr: stderr,
                              // After a timeout the process was terminated, so
                              // its status is meaningless — report the standard
                              // SIGTERM-ish code so callers don't treat it as a
                              // clean exit.
                              exitCode: timedOut ? -1 : process.terminationStatus,
                              timedOut: timedOut,
                              cancelled: handle.wasTerminated)
    }

    /// Create a brand-new empty directory inside the system temp area. The
    /// child LLM process is chdir'd here so anything it scans for context
    /// finds nothing — no popups for Desktop, Downloads, Documents, etc.
    private static func makeSandboxDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("island-mila-llm-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: url,
                                                  withIntermediateDirectories: true)
        return url
    }

    /// Stable sandbox directory for a Claude session keyed by `key`
    /// (the session UUID). Reused across every tick of a Live AI
    /// session so claude's per-CWD session storage stays put and
    /// `--resume <uuid>` keeps finding the conversation.
    static func stableSandboxDirectory(key: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("island-mila-llm-session-\(key)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: url,
                                                  withIntermediateDirectories: true)
        return url
    }

    /// Tear down a stable session sandbox. Safe to call when the
    /// directory doesn't exist. Should be called by the Live AI
    /// session when it cancels so /tmp doesn't accumulate stale
    /// session dirs across recordings.
    static func cleanupStableSandbox(key: String) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("island-mila-llm-session-\(key)",
                                    isDirectory: true)
        try? FileManager.default.removeItem(at: url)
    }

    private static func resolveExecutable(tool: LLMTool,
                                          override: String?) throws -> URL {
        // Absolute path override wins — handy for users with custom installs
        // or who want to point at a wrapper script (e.g. an asdf shim).
        if let override, !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw LLMRunnerError.executableNotFound(override)
            }
            return url
        }
        if let resolved = lookupOnPath(tool.executableName) {
            return resolved
        }
        throw LLMRunnerError.executableNotFound(tool.executableName)
    }

    /// Walk the user's `$PATH` plus a few common shell-managed locations
    /// (`~/.local/bin`, `/opt/homebrew/bin`, …). GUI apps on macOS inherit
    /// a stripped-down PATH from launchd, so claude/cursor installed by
    /// Homebrew or a node version manager are typically *not* on the
    /// inherited PATH — falling back to the well-known directories prevents
    /// the "works in Terminal, not in Mila" footgun.
    private static func lookupOnPath(_ name: String) -> URL? {
        var searchDirs: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            searchDirs += path.split(separator: ":").map(String.init)
        }
        let home = NSHomeDirectory()
        searchDirs += [
            "\(home)/.local/bin",
            "\(home)/bin",
            "\(home)/.cargo/bin",
            "\(home)/.bun/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
        let fm = FileManager.default
        for dir in searchDirs {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }
}

/// Bridges Swift `Task` cancellation to the underlying `Process`.
///
/// The Task that called `LLMRunner.run` runs on a Swift concurrency thread;
/// the actual `Process` runs as an external child. There's no direct way to
/// propagate a Task cancel into the child, so this small handle is the
/// shared mutable state: the runner `attach`es the live Process; the
/// `onCancel` arm of `withTaskCancellationHandler` calls `terminate()`,
/// which SIGTERMs the child. `wasTerminated` lets the wait-loop tell the
/// difference between "exited on its own with a non-zero status" and "we
/// killed it because the user cancelled".
final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var _wasTerminated = false

    /// Lock-protected read: `terminate()` sets the flag from whatever
    /// thread cancellation lands on while `executeProcess` reads it from
    /// its own context — an unlocked read is a data race (and could steer
    /// the drain-path choice wrong).
    var wasTerminated: Bool {
        lock.lock(); defer { lock.unlock() }
        return _wasTerminated
    }

    func attach(_ p: Process) {
        lock.lock(); defer { lock.unlock() }
        if _wasTerminated {
            // Cancel beat us to attach — the Task was already cancelled
            // before the Process even started. Reach out and SIGTERM right
            // now so the child doesn't even get a head start.
            p.terminate()
            return
        }
        process = p
    }

    func terminate() {
        lock.lock(); defer { lock.unlock() }
        _wasTerminated = true
        process?.terminate()
    }
}
