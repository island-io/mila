import Foundation
import os

/// Unified-log destination for every LLM invocation. Same subsystem as the
/// rest of the app so `log stream --predicate 'subsystem == "…"'` catches
/// runner lines alongside the callers' own lifecycle lines
/// (`PostRecordingCoordinator`, `RecordingSummarizer`).
///
/// File-level rather than a member of `LLMRunner` so `ProcessHandle` and the
/// error types can reach it too, matching `PostRecordingCoordinator`'s
/// `postRecordingLog`.
private let llmRunnerLog = os.Logger(subsystem: "io.island.whisper.IslandWhisper",
                                     category: "LLMRunner")

/// Which product surface an LLM invocation belongs to.
///
/// Exists purely for observability: without it every line in the log reads
/// "some CLI ran", and the question users actually ask — "did the *title*
/// generation fire for this recording?" — stays unanswerable. `LLMRunner`
/// itself behaves identically for every case.
///
/// `rawValue`s are the log tokens, so they are deliberately short, lowercase,
/// and stable — grep-ability is the whole point, and renaming one silently
/// breaks anyone's saved log predicate.
enum LLMFeature: String {
    /// Recording title suggestion (rename sheet's "Suggest", and the
    /// hands-off auto-title in `PostRecordingCoordinator`).
    case name
    /// The automatic post-transcription summary (`RecordingSummarizer`).
    case summary
    /// The user-triggered "Send to <tool>" post-recording action.
    case action
    /// Live AI's periodic in-meeting tick.
    case liveAI = "live-ai"
    /// Settings → AI Provider's "Test" button (the `diagnose` path).
    case settingsTest = "settings-test"
    /// Caller didn't say. Present so adding the parameter couldn't break any
    /// existing call site — a line tagged this way means a caller wasn't
    /// updated, which is itself worth seeing in the log.
    case unspecified
}

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
            return "No LLM is configured in Settings → AI Provider."
        case .executableNotFound(let name):
            return "Could not find \(name) on PATH. Install it or set the full path in Settings → AI Provider."
        case .launchFailed(let err):
            return "Could not launch the LLM CLI: \(err.localizedDescription)"
        case .nonZeroExit(let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "LLM CLI exited with status \(code). \(trimmed)"
        case .timedOut(let seconds):
            return "LLM CLI did not respond within \(seconds)s. If it's running an agentic task (e.g. calendar lookup), raise the timeout in Settings → AI Provider."
        case .emptyOutput:
            return "LLM CLI returned no output. Check the prompt or your CLI's auth."
        case .cancelled:
            return "LLM call was cancelled."
        }
    }
}

/// Everything the Settings → AI Provider test panel needs to explain a run to
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

/// The on-disk artifacts a recording already has, for the *reference*
/// transcript delivery (issue #179). Nothing here is produced for the LLM's
/// benefit: these are the `.srt` / `.txt` / audio files `TranscriptionService`
/// and `RecordingStore` write next to every completed recording anyway, so
/// referencing them puts no new copy of the user's content on disk.
///
/// Every field is optional because none of them is guaranteed to exist at the
/// moment a run starts: the `.srt` is written after the transcription pass and
/// is skipped entirely for a recording with no segments, and the `.txt` is
/// removed when the transcript comes up empty. Use `existing(...)` rather than
/// the memberwise init so a path that is not actually on disk can never reach a
/// prompt — a reference the CLI can't open is worse than no reference at all,
/// because the model then answers from the prompt's framing instead of from
/// anything that was said.
struct TranscriptFiles: Equatable {
    /// The `.srt` sidecar: SubRip cues carrying `00:00:07,000 --> 00:00:14,000`
    /// timings and, when diarization ran, a `SPEAKER_00: ` prefix per cue. The
    /// only artifact Mila writes that has timestamps at all.
    var subtitles: URL?
    /// The `.txt` sidecar. This is `Recording.fullText` — the plain join, with
    /// **no** speaker labels (unlike the inlined body, which goes through
    /// `TranscriptFormatter.plainText`). Offered as the easy-to-read whole-file
    /// option, and it is the only reference available for a recording that has
    /// no segments; `subtitles` is the richer one whenever it exists.
    var plainText: URL?
    /// The recording's audio. Referenced, never suggested for reading — an LLM
    /// CLI can't decode it, but an agentic action ("file this recording in
    /// $SYSTEM") needs to know where it is.
    var audio: URL?

    /// True when there is nothing to point the model at, which is the signal
    /// for `LLMRunner.effectiveDelivery` to fall back to inlining.
    var isEmpty: Bool { subtitles == nil && plainText == nil && audio == nil }

    /// Which references survived, as a stable `+`-joined log token
    /// (`srt+txt+audio`). Extensions only — a *filename* is derived from the
    /// recording's title, which Mila generates from the meeting, so it is
    /// content and does not belong in the unified log. See `redactedCommand`.
    var logToken: String {
        var parts: [String] = []
        if subtitles != nil { parts.append("srt") }
        if plainText != nil { parts.append("txt") }
        if audio != nil { parts.append("audio") }
        return parts.isEmpty ? "none" : parts.joined(separator: "+")
    }

    /// Keep only the paths that exist on disk *and* have bytes in them. The
    /// zero-length check matters: `RecordingStore` deletes an emptied sidecar,
    /// but an interrupted atomic write can still leave a 0-byte file behind,
    /// and "read this empty file" reads to a model as "nothing was said".
    static func existing(subtitles: URL? = nil,
                         plainText: URL? = nil,
                         audio: URL? = nil,
                         fileManager: FileManager = .default) -> TranscriptFiles {
        func usable(_ url: URL?) -> URL? {
            guard let url else { return nil }
            guard let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
                  size.int64Value > 0 else { return nil }
            return url
        }
        return TranscriptFiles(subtitles: usable(subtitles),
                               plainText: usable(plainText),
                               audio: usable(audio))
    }
}

/// How the transcript reaches the model (issue #179).
///
/// `inline` is the historical behaviour and stays the default everywhere: the
/// transcript body is pasted into the prompt argument. It is the only shape
/// that works for a provider with no filesystem — notably the
/// OpenAI-compatible HTTP endpoint.
///
/// `reference` swaps the body for the paths of files Mila already wrote. It
/// exists because inlining is lossy in a way that is invisible from inside the
/// prompt: `TranscriptFormatter.plainText` keeps speaker labels but drops every
/// timestamp, while the `.srt` sitting next to the audio has both. It also
/// turns a one-shot paste into something an agent can re-read, seek within and
/// quote exact times out of — which is the point of the Send-to-LLM action.
///
/// A caller only ever *requests* a delivery; what actually happens is decided
/// by `LLMRunner.effectiveDelivery(_:tool:)`, which downgrades to `inline` for
/// a tool that cannot read files and for an empty reference set.
enum TranscriptDelivery: Equatable {
    case inline
    case reference(TranscriptFiles)

    /// `delivery=` log token.
    var logToken: String {
        switch self {
        case .inline:    return "inline"
        case .reference: return "reference"
        }
    }

    /// `refs=` log token. `none` for inline, so the pair always reads
    /// consistently.
    var refsToken: String {
        switch self {
        case .inline:               return "none"
        case .reference(let files): return files.logToken
        }
    }
}

/// Spawns the configured `claude` or `cursor-agent` binary with the user's
/// prompt + transcript and returns whatever the CLI prints to stdout.
///
/// Why the transcript is appended to the *prompt argument* rather than
/// piped on stdin: `claude -p` happens to read both stdin and argv, but
/// `cursor-agent -p` only looks at argv and silently asks "what transcript?"
/// when stdin is closed. Putting the transcript in the prompt is the
/// portable shape that works for both CLIs without the user having to know.
/// (`TranscriptDelivery.reference` narrows *what* travels in that argument —
/// paths instead of the body — but not the mechanism: it is still argv.)
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
    ///
    /// `delivery` selects between pasting the transcript body in (the default,
    /// unchanged) and naming the on-disk sidecars instead (issue #179). Pass the
    /// value `effectiveDelivery(_:tool:)` returned, not the caller's raw request
    /// — this function trusts that the paths it is handed exist and that the
    /// tool can open them. It stays the ONE place either wire format is built,
    /// so the format tests cover both modes.
    static func composedPrompt(_ userPrompt: String,
                               transcript: String,
                               summary: String = "",
                               delivery: TranscriptDelivery = .inline) -> String {
        let prompt = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let gist = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .reference(let files) = delivery, !files.isEmpty {
            // Reference mode: the body is deliberately dropped. The summary is
            // NOT — it is a few hundred characters, it is the gist the model
            // should read before deciding which file to open, and it may exist
            // for a recording whose sidecars don't (a Send fired mid-meeting).
            // Same envelope as inline mode — one `---` under the user's prompt,
            // blank-line-separated sections after it — so a user who switches
            // modes doesn't have to re-tune a prompt that says "below".
            var sections: [String] = []
            if !gist.isEmpty { sections.append("Summary:\n\(gist)") }
            sections.append(referenceBlock(files))
            return "\(prompt)\n\n---\n" + sections.joined(separator: "\n\n")
        }
        let body = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty && gist.isEmpty { return prompt }
        if gist.isEmpty {
            return "\(prompt)\n\n---\nTranscript:\n\(body)"
        }
        if body.isEmpty {
            return "\(prompt)\n\n---\nSummary:\n\(gist)"
        }
        return "\(prompt)\n\n---\nSummary:\n\(gist)\n\nFull transcript:\n\(body)"
    }

    /// The path-list half of the reference wire format.
    ///
    /// Labels describe the **format**, not the content: "with timestamps" is
    /// true of every `.srt` Mila writes, whereas "diarized" would be a lie for
    /// a recording transcribed with diarization off, and the URL alone can't
    /// tell us which happened. `.srt` is listed first because it is a superset
    /// of the `.txt` whenever both exist.
    ///
    /// The read instruction covers only the transcripts. The audio line sits
    /// below it, unmentioned, so an agent doesn't spend a tool call trying to
    /// read an `.m4a` it cannot decode — but an action that has to attach or
    /// move the recording still knows where it is.
    static func referenceBlock(_ files: TranscriptFiles) -> String {
        var lines: [String] = []
        if let srt = files.subtitles {
            lines.append("Transcript (SubRip subtitles, with timestamps): \(srt.path)")
        }
        if let txt = files.plainText {
            lines.append("Transcript (plain text): \(txt.path)")
        }
        if !lines.isEmpty {
            lines.append("Read the transcript file(s) above before answering.")
        }
        if let audio = files.audio {
            lines.append("Audio: \(audio.path)")
        }
        return lines.joined(separator: "\n")
    }

    /// What `delivery` will actually do for `tool`, applied once in `run` so
    /// the prompt builder and the log line can never disagree about it.
    ///
    /// Two downgrades to `inline`, both of them "the reference would be a lie":
    ///
    /// 1. **A tool with no filesystem.** `.openaiCompatible` is a remote HTTP
    ///    endpoint; handing it `/Users/…/Foo.srt` sends a path it cannot open
    ///    and gets back an answer about a meeting it never saw. The Settings UI
    ///    doesn't offer the mode for that provider — this is the defence in
    ///    depth behind it, exactly like `run`'s own re-check of the base URL.
    /// 2. **No usable references.** `TranscriptFiles.existing` filtered every
    ///    candidate out (transcription hasn't finished, or produced no
    ///    segments and no text). Inlining whatever body we do have beats
    ///    sending a prompt that points nowhere.
    ///
    /// Both degrade rather than throw: a Send that silently loses timestamps is
    /// a worse answer, but a Send that fails outright is a lost one.
    static func effectiveDelivery(_ delivery: TranscriptDelivery,
                                 tool: LLMTool) -> TranscriptDelivery {
        guard case .reference(let files) = delivery else { return .inline }
        guard tool.readsLocalFiles, !files.isEmpty else { return .inline }
        return delivery
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
    /// `delivery` chooses whether the transcript body is inlined into the
    /// prompt argument (the default, and the historical behaviour) or replaced
    /// by the paths of the recording's own sidecars (issue #179). Always pass
    /// the transcript text as well, even in `.reference` mode: it is what
    /// `effectiveDelivery`'s fallback inlines when the tool can't read files or
    /// no sidecar turned out to exist.
    ///
    /// `extraArgs` are appended verbatim after the tool's standard arguments
    /// — the user's persisted "Extra args" from Settings → AI Provider (e.g.
    /// `--model …`, a permission flag). Empty for callers that manage their
    /// own args (Live AI pins its own model).
    ///
    /// `timeout` defaults to 5 minutes. Pass a smaller value for foreground
    /// callers that block UI (e.g. the Suggest button).
    ///
    /// `feature` only tags the unified-log lines this call emits — it changes
    /// no behaviour. It is the LAST parameter (rather than the first, where it
    /// would read better) because Swift requires arguments in declaration
    /// order: appending it keeps every existing call site compiling untouched.
    static func run(tool: LLMTool,
                    prompt: String,
                    transcript: String,
                    summary: String = "",
                    delivery: TranscriptDelivery = .inline,
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
                    transport: OpenAITransport? = nil,
                    feature: LLMFeature = .unspecified) async throws -> String {
        guard tool != .none else {
            logSetupFailure(feature: feature, tool: tool,
                            error: LLMRunnerError.toolDisabled)
            throw LLMRunnerError.toolDisabled
        }

        // OpenAI-compatible HTTP path — handled before any CLI resolution, so
        // `executablePathOverride` / `session` / `extraArgs` (CLI-only) are
        // irrelevant here. `delivery` is deliberately NOT forwarded either: a
        // remote endpoint cannot open `/Users/…/Foo.srt`, so this path always
        // sends the transcript inline (issue #179). `effectiveDelivery` encodes
        // the same rule for anyone composing a prompt without going through
        // here. Defense in depth: `run` has no `LLMSettings`, so it
        // re-checks the base-URL readiness gate the Settings UI also enforces
        // via `isConfigured` — a nil/empty base URL can't send anything.
        if tool == .openaiCompatible {
            guard let baseURL = openAIBaseURL,
                  !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                logSetupFailure(feature: feature, tool: tool,
                                error: LLMRunnerError.toolDisabled)
                throw LLMRunnerError.toolDisabled
            }
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
                                                 transport: t,
                                                 feature: feature)
        }

        let executable: URL
        do {
            executable = try resolveExecutable(tool: tool,
                                               override: executablePathOverride)
        } catch {
            // A stale or missing executable path is the single most common
            // real-world failure, and it never reaches `executeProcess` — so
            // without this it produced no log line whatsoever.
            logSetupFailure(feature: feature, tool: tool, error: error)
            throw error
        }
        // Resolve the delivery ONCE, here: the prompt below and the log line
        // after it must describe the same run, and the downgrade rules live in
        // `effectiveDelivery` rather than being re-derived at each use.
        let resolvedDelivery = effectiveDelivery(delivery, tool: tool)
        let fullPrompt = composedPrompt(prompt,
                                        transcript: transcript,
                                        summary: summary,
                                        delivery: resolvedDelivery)
        let arguments = tool.arguments(prompt: fullPrompt,
                                       model: model,
                                       session: session) + extraArgs
        let command = redactedCommand(executable: executable,
                                      arguments: arguments,
                                      prompt: fullPrompt,
                                      extraArgsCount: extraArgs.count)
        let started = Date()
        logRunStart(feature: feature,
                    tool: tool,
                    executable: executable,
                    model: model,
                    session: session,
                    extraArgsCount: extraArgs.count,
                    promptChars: prompt.count,
                    summaryChars: summary.count,
                    transcriptChars: transcript.count,
                    composedChars: fullPrompt.count,
                    delivery: resolvedDelivery,
                    timeout: timeout,
                    command: command)
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
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let outcome = try executeProcess(executable: executable,
                                                         arguments: arguments,
                                                         timeout: timeout,
                                                         handle: handle)
                        // Log the FULL outcome — exit code, stderr tail, byte
                        // counts — before the throw below collapses it into a
                        // single localized sentence. This is the "route real
                        // runs through the capture `diagnose` uses" half of
                        // issue #175: `run`'s contract still throws, but the
                        // exit code and stderr no longer vanish with it.
                        logRunEnd(feature: feature,
                                  tool: tool,
                                  outcome: outcome,
                                  duration: Date().timeIntervalSince(started),
                                  timeout: timeout,
                                  command: command)
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
                        // Only `launchFailed` reaches here (the executable
                        // resolved but `Process.run()` refused).
                        logLaunchFailure(feature: feature,
                                         tool: tool,
                                         duration: Date().timeIntervalSince(started),
                                         command: command,
                                         error: error)
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
                                    transport: OpenAITransport,
                                    feature: LLMFeature = .unspecified) async throws -> String {
        // Log metadata FIRST, before anything that can throw. Request
        // construction itself fails on a malformed base URL, and computing
        // `host`/`started` afterwards meant that failure had neither a start
        // line nor a failure line — invisible, which is the exact defect #175
        // is about.
        //
        // Host only, never the full URL: a user's endpoint can carry a token
        // in its query string, and the privacy rule is "no secrets in logged
        // URLs". The host is enough to tell "wrong endpoint" from "endpoint
        // rejected us".
        let host = URL(string: baseURL)?.host ?? "(unparsed)"
        let started = Date()
        llmRunnerLog.notice("""
            llm http start feature=\(feature.rawValue, privacy: .public) \
            host=\(host, privacy: .public) \
            model=\(modelTag(model), privacy: .public) \
            prompt=\(prompt.count, privacy: .public)c \
            summary=\(summary.count, privacy: .public)c \
            transcript=\(transcript.count, privacy: .public)c \
            jsonMode=\(jsonMode, privacy: .public) \
            timeout=\(Int(timeout.rounded(.up)), privacy: .public)s
            """)

        // `makeRequest` throws `OpenAIRequestError.invalidEndpoint` for a
        // malformed base URL (issue celarent7/mila#1). It's an
        // `OpenAIRequestError`, so the rethrow surfaces it to the caller as a
        // readable LocalizedError — not a crash — and it is now recorded on
        // the way past instead of vanishing.
        var request: URLRequest
        do {
            request = try OpenAIClient.makeRequest(baseURL: baseURL,
                                                   model: model ?? "",
                                                   prompt: prompt,
                                                   transcript: transcript,
                                                   summary: summary,
                                                   apiKey: apiKey,
                                                   jsonMode: jsonMode,
                                                   temperature: temperature)
        } catch {
            logHTTPFailure(feature: feature, host: host,
                           duration: Date().timeIntervalSince(started), error: error)
            throw error
        }
        if timeout > 0 { request.timeoutInterval = timeout }

        do {
            // Already cancelled before we even dispatch (e.g. the rename sheet
            // closed while the transcript was still being assembled)? Don't
            // spend the round trip — or the tokens. (CodeRabbit #2.)
            try Task.checkCancellation()
            let (http, data) = try await transport.send(request)
            // A cooperative cancellation (Task.cancel, or a custom/test
            // transport that throws CancellationError) would otherwise fall
            // through to `.launchFailed`; surface it as a cancellation so the
            // banner/auto-suggest callers drop it quietly. (CodeRabbit #2.)
            try Task.checkCancellation()
            switch OpenAIClient.parse(data: data, response: http) {
            case .success(let content):
                // Re-check after the (possibly slow) transport returned: a
                // late response to a cancelled task shouldn't be delivered.
                try Task.checkCancellation()
                llmRunnerLog.notice("""
                    llm http end feature=\(feature.rawValue, privacy: .public) \
                    host=\(host, privacy: .public) \
                    status=\(http.statusCode, privacy: .public) \
                    duration=\(durationTag(Date().timeIntervalSince(started)), privacy: .public)s \
                    response=\(content.count, privacy: .public)c
                    """)
                return content
            case .failure(let error):
                throw error
            }
        } catch let error as OpenAIRequestError {
            logHTTPFailure(feature: feature, host: host,
                           duration: Date().timeIntervalSince(started), error: error)
            throw error
        } catch is CancellationError {
            logHTTPCancelled(feature: feature, host: host,
                             duration: Date().timeIntervalSince(started))
            throw LLMRunnerError.cancelled
        } catch let urlError as URLError {
            switch urlError.code {
            case .cancelled:
                // Same event as `CancellationError` above, just delivered by
                // URLSession instead of the task. It went unlogged, so a
                // cancel was recorded on the process path but silently
                // dropped here.
                logHTTPCancelled(feature: feature, host: host,
                                 duration: Date().timeIntervalSince(started))
                throw LLMRunnerError.cancelled
            case .timedOut:
                logHTTPFailure(feature: feature, host: host,
                               duration: Date().timeIntervalSince(started),
                               error: LLMRunnerError.timedOut(seconds: Int(timeout.rounded(.up))))
                throw LLMRunnerError.timedOut(seconds: Int(timeout.rounded(.up)))
            default:
                logHTTPFailure(feature: feature, host: host,
                               duration: Date().timeIntervalSince(started), error: urlError)
                throw LLMRunnerError.launchFailed(urlError)
            }
        } catch {
            logHTTPFailure(feature: feature, host: host,
                           duration: Date().timeIntervalSince(started), error: error)
            throw LLMRunnerError.launchFailed(error)
        }
    }

    /// Run the configured CLI like `run` does, but never throw — capture the
    /// exact command line, exit code, stdout, and stderr and hand them all
    /// back so the Settings → AI Provider test panel can show precisely what
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
                         transport: OpenAITransport? = nil,
                         feature: LLMFeature = .settingsTest) async -> LLMTestResult {
        guard tool != .none else {
            logSetupFailure(feature: feature, tool: tool,
                            error: LLMRunnerError.toolDisabled)
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
            logSetupFailure(feature: feature, tool: tool, error: error)
            return LLMTestResult(setupError: msg)
        }
        let fullPrompt = composedPrompt(prompt, transcript: transcript, summary: summary)
        let args = tool.arguments(prompt: fullPrompt, model: model) + extraArgs
        // The panel's copy-pasteable command keeps the real prompt — it is
        // shown only to the user who owns the transcript, in their own UI. The
        // *logged* command is the redacted twin below; the two must not be
        // confused.
        let command = ([executable.path] + args).map(shellQuote).joined(separator: " ")
        let loggedCommand = redactedCommand(executable: executable,
                                            arguments: args,
                                            prompt: fullPrompt,
                                            extraArgsCount: extraArgs.count)
        let start = Date()
        logRunStart(feature: feature,
                    tool: tool,
                    executable: executable,
                    model: model,
                    session: .none,
                    extraArgsCount: extraArgs.count,
                    promptChars: prompt.count,
                    summaryChars: summary.count,
                    transcriptChars: transcript.count,
                    composedChars: fullPrompt.count,
                    // The Settings test panel runs against its own editable
                    // sample transcript, not a recording, so there are no
                    // sidecars to reference — this path is inline by
                    // construction rather than by choice.
                    delivery: .inline,
                    timeout: timeout,
                    command: loggedCommand)
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
                                                         handle: handle)
                        logRunEnd(feature: feature,
                                  tool: tool,
                                  outcome: outcome,
                                  duration: elapsed(),
                                  timeout: timeout,
                                  command: loggedCommand)
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
                        logLaunchFailure(feature: feature,
                                         tool: tool,
                                         duration: elapsed(),
                                         command: loggedCommand,
                                         error: error)
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
    /// "test" path the Settings → AI Provider panel uses to explain an endpoint
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
                    ?? "No OpenAI endpoint is configured in Settings → AI Provider.")
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

    // MARK: - Observability (issue #175)
    //
    // Everything below exists so a failed title / summary / Send leaves an
    // artifact behind. The hard constraint is that a transcript must NEVER
    // reach the unified log: it is meeting content, the log is world-readable
    // to anything with the right entitlement, and it persists for days. So the
    // rule enforced here is *shape*, not annotation discipline: the only
    // strings that reach a `Logger` call are ones these pure helpers built out
    // of metadata. Prompt, summary and transcript appear as `.count` and
    // nothing else.
    //
    // Every interpolation is `privacy: .public` on purpose. `.private` would
    // render as `<private>` for the very person reading their own log with
    // `/usr/bin/log show`, which is the entire audience — so a field is either
    // safe to be public or it is not logged at all.

    /// Cap on the stderr excerpt copied into a failure log line. Generous
    /// enough for a stack-trace-ish CLI error, small enough that a CLI which
    /// dumps megabytes to stderr can't flood the log.
    static let stderrLogLimit = 512

    /// `model=` token. Distinguishes "the CLI picked its own default" from
    /// "we pinned one", which matters because a wrong pinned model is a
    /// common cause of a non-zero exit.
    static func modelTag(_ model: String?) -> String {
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "(default)" : trimmed
    }

    /// `session=` token. Only the first 8 characters of the UUID: enough to
    /// correlate a `--resume` chain across lines (and with the jsonl filename
    /// under `~/.claude/projects/`) without making the line unreadable.
    static func sessionTag(_ session: LLMSession) -> String {
        switch session {
        case .none: return "none"
        case .new(let id): return "new:\(id.uuidString.prefix(8))"
        case .resume(let id): return "resume:\(id.uuidString.prefix(8))"
        }
    }

    /// Fixed 2-decimal seconds, so durations line up when scanning a log and
    /// a sub-second run doesn't print as `0.0009999999`.
    static func durationTag(_ seconds: TimeInterval) -> String {
        String(format: "%.2f", seconds)
    }

    /// The argv we launched, shell-quoted for readability, with everything
    /// that could carry a secret or meeting content replaced by a
    /// `<kind:Nc>` placeholder.
    ///
    /// This is the log-safe twin of `diagnose`'s `command`. A command line is
    /// *mostly* metadata a user needs — which binary, which flags, which
    /// `--session-id` — so redacting the few positions that can hold a
    /// payload keeps the shape diagnosable without publishing the payload.
    /// Two things get redacted:
    ///
    /// 1. **The composed prompt.** Under the default `inline` delivery this is
    ///    the meeting transcript, verbatim. Under `reference` delivery (issue
    ///    #179) the body is gone — but the argument is *not* thereby neutral,
    ///    which is the trap: it still carries the Live-AI summary, and it
    ///    carries the sidecar paths, whose filenames Mila derives from the
    ///    recording's title, which the LLM generated from the meeting. A run
    ///    log full of `…/Q3 layoffs — legal review.srt` leaks the same thing
    ///    the transcript would, one line at a time. So the placeholder holds in
    ///    both modes, and the thing the reference mode actually made
    ///    un-diagnosable — "did it send paths or the body, and which files?" —
    ///    is answered by the `delivery=` / `refs=` tokens on the start line,
    ///    which name extensions and never filenames.
    /// 2. **The values of the user's own "Extra args"** (the trailing
    ///    `extraArgsCount` tokens). These are free text from Settings → AI
    ///    Provider and people do put credentials in them — `--api-key sk-…`,
    ///    a bearer token, an `--append-system-prompt` blob. Mila cannot know
    ///    which of a third-party CLI's flags take a secret, so the only safe
    ///    default is that no extra-argument *value* is ever logged.
    ///
    /// Flag *names* survive, including the `--flag=value` form (name kept,
    /// value redacted), because "which flags did it run with" is the
    /// diagnostic question and a flag name is not a secret. Mila's own
    /// generated arguments (`--model`, `--session-id`, `--resume`, `-f`,
    /// `--skip-trust`) stay visible: those values are ones Mila chose, not
    /// user input, and a wrong model name is a common cause of a non-zero
    /// exit.
    ///
    /// The result is deliberately NOT copy-pasteable — placeholders are
    /// unquoted so it can't be mistaken for a runnable command.
    static func redactedCommand(executable: URL,
                                arguments: [String],
                                prompt: String,
                                extraArgsCount: Int = 0) -> String {
        // argv is always `tool.arguments(...) + extraArgs`, so the
        // user-supplied tokens are exactly the trailing slice. Position beats
        // value-matching here: an extra arg that happened to equal one of
        // Mila's own values would otherwise be treated as trusted.
        let firstExtraArg = arguments.count - max(0, extraArgsCount)
        let redacted = arguments.enumerated().map { index, arg -> String in
            // Empty-prompt guard: without it an empty `prompt` would match
            // every empty argument in argv and redact unrelated tokens.
            if !prompt.isEmpty && arg == prompt {
                return "<prompt:\(prompt.count)c>"
            }
            guard index >= firstExtraArg else { return shellQuote(arg) }
            return redactedExtraArg(arg)
        }
        return ([shellQuote(executable.path)] + redacted).joined(separator: " ")
    }

    /// One token of the user's "Extra args", reduced to what is safe to log.
    ///
    ///     --verbose          -> --verbose            (a flag name, not a secret)
    ///     --api-key=sk-abc   -> --api-key=<value:6c> (glued form still splits)
    ///     sk-abc             -> <value:6c>           (bare value — could be anything)
    static func redactedExtraArg(_ arg: String) -> String {
        guard arg.hasPrefix("-") else { return "<value:\(arg.count)c>" }
        // `--flag=value`: keep the name, redact the payload. Split on the
        // FIRST `=` only — a value may legitimately contain more of them.
        guard let eq = arg.firstIndex(of: "=") else { return shellQuote(arg) }
        let name = String(arg[arg.startIndex..<eq])
        let value = String(arg[arg.index(after: eq)...])
        return "\(shellQuote(name))=<value:\(value.count)c>"
    }

    /// One-line, bounded excerpt of a CLI's stderr for a failure log line.
    ///
    /// Keeps the **tail**: CLIs print the fatal error last, after any
    /// progress/warning chatter. Newlines are folded to ` | ` because a
    /// multi-line unified-log entry is painful to read and impossible to grep.
    ///
    /// Logged **`privacy: .private`**, unlike every other field here.
    ///
    /// A CLI run verbosely can echo the prompt — i.e. the transcript — back
    /// on stderr, and the non-zero-exit path falls back to stdout, which is
    /// the model's answer *about* the meeting. Neither is CLI chatter; both
    /// are the content this file reduces to character counts everywhere else.
    /// Mila's whole premise is that recordings stay on the machine, and the
    /// unified log is a plaintext store other processes can read, so a
    /// structured always-on excerpt of that content is not something to
    /// enable by default.
    ///
    /// The precedent that `LLMRunnerError.nonZeroExit` already embeds stderr
    /// verbatim in `errorDescription` — which `PostRecordingCoordinator` logs
    /// `.public` — argues that the *existing* line is too loose, not that a
    /// new and broader one is fine. (Worth tightening separately.)
    ///
    /// What stays `.public` is the part that answers the question at a
    /// glance: exit code, stderr/stdout byte counts, duration, and the
    /// redacted command. "exit 1, 4 KB of stderr" is the triage signal; the
    /// bytes themselves are available to the user who asks for them, via
    /// Settings → AI Provider's test panel (which shows full stderr in the
    /// UI, at the user's request) or by enabling private-data logging.
    static func stderrTail(_ stderr: String, limit: Int = stderrLogLimit) -> String {
        let flattened = stderr
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
        guard flattened.count > limit else { return flattened }
        return "…" + String(flattened.suffix(limit))
    }

    /// "A run is starting, and here is everything about it that isn't user
    /// content." `notice` (not `debug`) because the question this answers —
    /// "is a title being generated right now, and with what?" — has to be
    /// answerable from a plain `log show` without `--info --debug`. One line
    /// per invocation, and invocations are user-paced, so the volume is fine.
    ///
    /// `exe=` is the fully resolved path and is public: "Mila is running a
    /// different binary than my shell is" is one of the failures this is meant
    /// to catch, and the path is useless when redacted. It can contain the
    /// account's short name — the same exposure the pre-existing sandbox-path
    /// line already accepts.
    ///
    /// `delivery=` / `refs=` are the counterpart for issue #179. The
    /// transcript's *path* can't be logged (it embeds the recording title — see
    /// `redactedCommand`), so these say the shape instead: `delivery=reference
    /// refs=srt+txt+audio` versus `delivery=inline refs=none`. That is enough
    /// to tell the two failures apart — "the mode is on but silently fell back
    /// to inlining because the `.srt` wasn't written yet" reads as
    /// `delivery=inline` with a non-zero `transcript=`, while a genuine
    /// reference run shows `transcript=` bytes that never left the machine.
    static func logRunStart(feature: LLMFeature,
                            tool: LLMTool,
                            executable: URL,
                            model: String?,
                            session: LLMSession,
                            extraArgsCount: Int,
                            promptChars: Int,
                            summaryChars: Int,
                            transcriptChars: Int,
                            composedChars: Int,
                            delivery: TranscriptDelivery,
                            timeout: TimeInterval,
                            command: String) {
        llmRunnerLog.notice("""
            llm run start feature=\(feature.rawValue, privacy: .public) \
            tool=\(tool.rawValue, privacy: .public) \
            exe=\(executable.path, privacy: .public) \
            model=\(modelTag(model), privacy: .public) \
            session=\(sessionTag(session), privacy: .public) \
            extraArgs=\(extraArgsCount, privacy: .public) \
            prompt=\(promptChars, privacy: .public)c \
            summary=\(summaryChars, privacy: .public)c \
            transcript=\(transcriptChars, privacy: .public)c \
            composed=\(composedChars, privacy: .public)c \
            delivery=\(delivery.logToken, privacy: .public) \
            refs=\(delivery.refsToken, privacy: .public) \
            timeout=\(Int(timeout.rounded(.up)), privacy: .public)s
            """)
        // The redacted argv is `debug`: it repeats what the start line already
        // says for a healthy run, and duplicating it at notice level would
        // double the log volume for no gain. The failure lines below carry it
        // at their own level, so it is never missing when it matters.
        llmRunnerLog.debug("llm run cmd feature=\(feature.rawValue, privacy: .public) \(command, privacy: .public)")
    }

    /// The end of a run that actually reached the process. Level is chosen by
    /// outcome, because "invisible by default" is exactly the bug:
    ///  - success → `notice`
    ///  - cancelled → `debug` (deliberate; the user discarded or re-ran)
    ///  - timeout / non-zero exit → `error`, with the redacted argv and the
    ///    stderr tail, so a failed summary is diagnosable from the log alone.
    ///
    /// Every field is `.public` except `stderr-tail`, which is `.private`
    /// because it can echo transcript or answer text — see `stderrTail`. The
    /// triage signal (exit code, byte counts, duration, redacted argv) is
    /// public, so a failure is still legible without private-data logging;
    /// only the payload is held back.
    static func logRunEnd(feature: LLMFeature,
                          tool: LLMTool,
                          outcome: ProcessOutcome,
                          duration: TimeInterval,
                          timeout: TimeInterval,
                          command: String) {
        let common = """
            feature=\(feature.rawValue) tool=\(tool.rawValue) \
            exit=\(outcome.exitCode) duration=\(durationTag(duration))s \
            stdout=\(outcome.stdout.utf8.count)B stderr=\(outcome.stderr.utf8.count)B
            """
        if outcome.cancelled {
            llmRunnerLog.debug("llm run cancelled \(common, privacy: .public)")
        } else if outcome.timedOut {
            llmRunnerLog.error("""
                llm run timed out \(common, privacy: .public) \
                limit=\(Int(timeout.rounded(.up)), privacy: .public)s \
                cmd=\(command, privacy: .public) \
                stderr-tail=\(stderrTail(outcome.stderr), privacy: .private)
                """)
        } else if outcome.exitCode != 0 {
            llmRunnerLog.error("""
                llm run failed \(common, privacy: .public) \
                cmd=\(command, privacy: .public) \
                stderr-tail=\(stderrTail(outcome.stderr.isEmpty ? outcome.stdout : outcome.stderr), privacy: .private)
                """)
        } else {
            llmRunnerLog.notice("llm run end \(common, privacy: .public)")
        }
    }

    /// A run that never got as far as a process: no tool configured, no
    /// executable found, or (for the HTTP path) no base URL. `error` because
    /// the user asked for something and got nothing, and the message is
    /// `errorDescription` — the same sentence the UI shows, which contains
    /// only the tool/path the user typed.
    static func logSetupFailure(feature: LLMFeature, tool: LLMTool, error: Error) {
        let message = (error as? LLMRunnerError)?.errorDescription ?? error.localizedDescription
        llmRunnerLog.error("""
            llm run setup failed feature=\(feature.rawValue, privacy: .public) \
            tool=\(tool.rawValue, privacy: .public): \(message, privacy: .public)
            """)
    }

    /// `Process.run()` itself refused (bad architecture, permissions, a shim
    /// that isn't really executable). Distinct from a setup failure because
    /// the path resolved — knowing that changes where the user looks next.
    static func logLaunchFailure(feature: LLMFeature,
                                 tool: LLMTool,
                                 duration: TimeInterval,
                                 command: String,
                                 error: Error) {
        let message = (error as? LLMRunnerError)?.errorDescription ?? error.localizedDescription
        llmRunnerLog.error("""
            llm run launch failed feature=\(feature.rawValue, privacy: .public) \
            tool=\(tool.rawValue, privacy: .public) \
            duration=\(durationTag(duration), privacy: .public)s \
            cmd=\(command, privacy: .public): \(message, privacy: .public)
            """)
    }

    /// A cancelled HTTP call. Not a failure — the user closed the sheet or
    /// discarded the recording — so `debug`, matching how the process path
    /// records `outcome.cancelled`. Both delivery shapes (`CancellationError`
    /// and `URLError.cancelled`) route here so neither can go unrecorded.
    static func logHTTPCancelled(feature: LLMFeature,
                                 host: String,
                                 duration: TimeInterval) {
        llmRunnerLog.debug("""
            llm http cancelled feature=\(feature.rawValue, privacy: .public) \
            host=\(host, privacy: .public) \
            duration=\(durationTag(duration), privacy: .public)s
            """)
    }

    /// Failure on the OpenAI-compatible HTTP path. `host` rather than the full
    /// URL — see the call site for why.
    static func logHTTPFailure(feature: LLMFeature,
                               host: String,
                               duration: TimeInterval,
                               error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        llmRunnerLog.error("""
            llm http failed feature=\(feature.rawValue, privacy: .public) \
            host=\(host, privacy: .public) \
            duration=\(durationTag(duration), privacy: .public)s: \
            \(message, privacy: .public)
            """)
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
                                       handle: ProcessHandle) throws -> ProcessOutcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        // Inherit `$PATH` etc. so the CLI can find any helpers it shells out
        // to, but AUGMENT PATH so node-shebang CLIs find their interpreter.
        // Spawning a Process from a sandboxed-style minimal environment
        // surprises users whose claude/cursor wrappers source nvm/asdf/etc.
        process.environment = childEnvironment(for: executable)

        // CRITICAL: spawn in an empty directory Mila owns — never $HOME, `/`,
        // or a user folder. macOS attributes any file access by the child
        // process to *our* bundle ID, so if claude / cursor-agent walks the
        // cwd looking for project files (which both do — particularly
        // cursor-agent in `-f` mode), the user sees scary TCC prompts saying
        // "Mila would like to access Desktop / Downloads". Launching from an
        // isolated, empty directory guarantees there's nothing for the LLM
        // CLI to discover and reach for, so no permission prompts fire.
        //
        // The directory is SHARED and STABLE across every invocation — see
        // `sandboxDirectory()` for why (issue #181: claude derives its
        // `~/.claude/projects/<slug-of-cwd>` project directory from the cwd,
        // so a per-run cwd leaked a per-run project directory forever).
        process.currentDirectoryURL = sandboxDirectory()

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
                    // `error`: a child that outlives SIGKILL is a genuine
                    // anomaly (see the comment above), and it explains a
                    // truncated result — it must not need `--debug` to see.
                    llmRunnerLog.error("llm reap abandoned pid=\(process.processIdentifier, privacy: .public) — waitUntilExit didn't return after SIGKILL")
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
                // `notice`, not `error`: on the kill path the output is being
                // discarded anyway (the caller sees .timedOut / .cancelled),
                // so this is expected bookkeeping rather than a fault.
                llmRunnerLog.notice("llm pipe drain timed out after kill — an orphaned grandchild is still holding stdout/stderr; returning partial output")
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
                // `error`: unlike the kill path, this output IS returned to
                // the caller and may be truncated mid-stream — a silently
                // short summary is exactly the kind of thing that needs a
                // default-visible breadcrumb.
                llmRunnerLog.error("llm pipe drain timed out after normal exit — a helper process is still holding stdout/stderr; returning buffered output")
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

    /// The ONE working directory every LLM CLI invocation is chdir'd into.
    ///
    /// Two requirements meet here, and a single stable directory is the only
    /// shape that satisfies both:
    ///
    /// 1. **TCC isolation.** The child must start in an empty directory Mila
    ///    owns, so a CLI that scans its cwd for project context finds nothing
    ///    and no "Mila would like to access Desktop" prompts fire.
    /// 2. **One Claude Code project, not one per run** (issue #181). claude
    ///    stores its conversation transcripts in
    ///    `~/.claude/projects/<slug-of-cwd>/<session-uuid>.jsonl` — the
    ///    *project* comes from the cwd, the *session* from the UUID we pass in
    ///    `--session-id` / `--resume`. The old code handed every invocation
    ///    its own cwd (`$TMPDIR/island-mila-llm-<UUID>` for one-shots,
    ///    `$TMPDIR/island-mila-llm-session-<UUID>` for Live AI ticks), so
    ///    every invocation minted a new project directory under
    ///    `~/.claude/projects/` — named after a temp path Mila then deleted,
    ///    never cleaned up, burying the user's real projects in claude's own
    ///    resume/project pickers. One reporter had 175 of them, 46 MB.
    ///    A shared cwd collapses all of that into a single project holding
    ///    one jsonl per run.
    ///
    /// Session isolation is unaffected: sessions are keyed by the UUID in
    /// `--session-id` / `--resume`, not by the cwd, so Live AI's `--resume`
    /// continuity still works — and the conversations are now actually
    /// *resumable by hand* (`cd` here, `claude --resume <uuid>`), which the
    /// old delete-the-cwd design made impossible.
    ///
    /// Application Support rather than `$TMPDIR` on purpose: the project slug
    /// must stay stable across reboots, and macOS both rotates the per-user
    /// temp directory and periodically purges it — either would fragment the
    /// project directory again over time.
    ///
    /// The directory is created on demand and never removed: `Process.run()`
    /// fails outright if `currentDirectoryURL` doesn't exist.
    static func sandboxDirectory() -> URL {
        let url = sandboxDirectory(appSupportRoot: applicationSupportRoot())
        do {
            try FileManager.default.createDirectory(at: url,
                                                    withIntermediateDirectories: true)
            return url
        } catch {
            // `applicationSupportRoot()` only falls back when the *lookup*
            // fails. If the directory resolves but can't be created -- a
            // read-only or permission-broken Application Support -- swallowing
            // the error and returning the path anyway breaks every subsequent
            // CLI launch, because `Process.run()` fails outright when
            // `currentDirectoryURL` does not exist. Degrade to a temp directory
            // instead: the Claude project slug stops being stable, which costs
            // resumability, but LLM calls keep working.
            llmRunnerLog.error("llm sandbox unavailable at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public) -- falling back to a temp directory")
            let fallback = sandboxDirectory(appSupportRoot: FileManager.default.temporaryDirectory)
            try? FileManager.default.createDirectory(at: fallback,
                                                     withIntermediateDirectories: true)
            // Say where we landed as well as what broke: the fallback costs
            // Claude Code project-slug stability (#187), so "why did my
            // resumable conversations scatter?" is answerable from the log.
            llmRunnerLog.notice("llm sandbox fallback in use at \(fallback.path, privacy: .public) — claude project slugs will not be stable across reboots")
            return fallback
        }
    }

    /// Pure path composition, split out so tests can assert the layout
    /// without touching the real Application Support directory.
    static func sandboxDirectory(appSupportRoot: URL) -> URL {
        appSupportRoot
            .appendingPathComponent("Mila", isDirectory: true)
            .appendingPathComponent("llm-sandbox", isDirectory: true)
    }

    /// `~/Library/Application Support`, with a temp-directory fallback so a
    /// pathological environment degrades to "LLM calls still work" rather than
    /// "LLM calls throw". Mila is not app-sandboxed, so this is the real
    /// user-domain path (the same one `RecordingStore` uses).
    private static func applicationSupportRoot() -> URL {
        if let url = FileManager.default.urls(for: .applicationSupportDirectory,
                                              in: .userDomainMask).first {
            return url
        }
        return FileManager.default.temporaryDirectory
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
    /// a stripped-down PATH from launchd, so claude/cursor/gemini installed by
    /// Homebrew or a node version manager are typically *not* on the
    /// inherited PATH — falling back to the well-known directories prevents
    /// the "works in Terminal, not in Mila" footgun.
    private static func lookupOnPath(_ name: String) -> URL? {
        let fm = FileManager.default
        for dir in searchDirectories() {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// Environment for the spawned CLI. We inherit Mila's environment (so the
    /// CLI still sees HOME, npm config, API-key vars, etc.) but *augment* PATH
    /// so a node-shebang CLI can find its interpreter. `gemini`'s shebang is
    /// `#!/usr/bin/env node`; a Finder-launched app gets a stripped PATH from
    /// launchd, so without this it dies with `env: node: No such file or
    /// directory`. We prepend the resolved executable's own directory (its
    /// sibling `node` lives there for nvm/npm installs) plus the well-known
    /// version-manager bins, then the inherited PATH — de-duped, order kept.
    static func childEnvironment(
        for executable: URL,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = base
        let inherited = base["PATH"]?.split(separator: ":").map(String.init) ?? []
        var ordered: [String] = [executable.deletingLastPathComponent().path]
        ordered += searchDirectories(pathEnv: nil)
        ordered += inherited
        var seen = Set<String>()
        let merged = ordered.filter { !$0.isEmpty && seen.insert($0).inserted }
        env["PATH"] = merged.joined(separator: ":")
        return env
    }

    /// Ordered candidate directories for `lookupOnPath`: the inherited `$PATH`
    /// first, then the `bin` of whatever prefix npm is *configured* with, then
    /// well-known shell/version-manager `bin` dirs. Node-based CLIs (claude,
    /// cursor-agent, gemini) are commonly installed as global npm packages
    /// under a version manager, so those roots are enumerated too.
    /// Exposed (internal) so the enumeration is unit-testable.
    static func searchDirectories(
        home: String = NSHomeDirectory(),
        pathEnv: String? = ProcessInfo.processInfo.environment["PATH"],
        fileManager: FileManager = .default
    ) -> [String] {
        var dirs: [String] = []
        if let pathEnv {
            dirs += pathEnv.split(separator: ":").map(String.init)
        }
        // Everything past the PATH entries is a *guess* at where a global npm
        // install landed — except the configured prefix, which comes from the
        // user's own npm config, so it leads the fallbacks.
        var fallbacks: [String] = []
        if let prefixBin = npmPrefixBin(home: home, fileManager: fileManager) {
            fallbacks.append(prefixBin)
        }
        fallbacks += [
            "\(home)/.local/bin",
            "\(home)/bin",
            "\(home)/.cargo/bin",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",        // Volta
            "\(home)/.asdf/shims",       // asdf
            "\(home)/.npm-global/bin",   // the ~/.npm-global convention
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
        // nvm installs each Node version under
        // ~/.nvm/versions/node/<version>/bin. A global npm package (claude,
        // cursor-agent, gemini) lands in whichever version was active at
        // install time, so search every installed version, newest first.
        let nvmRoot = "\(home)/.nvm/versions/node"
        if let versions = try? fileManager.contentsOfDirectory(atPath: nvmRoot) {
            fallbacks += versions
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { "\(nvmRoot)/\($0)/bin" }
        }
        // De-dupe, order kept: npm's *default* prefix on a node that isn't
        // Homebrew's is /usr/local, so a configured value routinely collides
        // with an entry already in the list (or already on PATH), and probing
        // the same directory twice per lookup buys nothing.
        // De-dupe the inherited PATH too, not just the fallbacks: a PATH with
        // the same directory twice would otherwise be probed twice.
        var seen = Set<String>()
        dirs = dirs.filter { seen.insert($0).inserted }
        dirs += fallbacks.filter { seen.insert($0).inserted }
        return dirs
    }

    /// `bin` directory of the npm prefix the user actually configured, or
    /// `nil` when `~/.npmrc` has no usable `prefix` value.
    ///
    /// Parsing the file rather than shelling out to `npm config get prefix` is
    /// deliberate: that needs `npm` on `PATH`, which is exactly what a
    /// launchd-launched Mila does not have, and it would cost a process spawn
    /// on every executable lookup.
    ///
    /// **Only the user config is read.** npm's other prefix sources cannot
    /// help in the situation this exists for:
    /// - `NPM_CONFIG_PREFIX` / `npm_config_prefix` and `NPM_CONFIG_USERCONFIG`
    ///   live in the environment. A Finder- or launchd-launched Mila does not
    ///   get the user's exported shell variables — the same stripping that
    ///   loses `PATH` — and when Mila *is* started from a shell, that prefix's
    ///   `bin` is already on the inherited `PATH` searched first. Honouring
    ///   them would be dead code in the broken case and redundant in the
    ///   working one.
    /// - the global `$PREFIX/etc/npmrc` can only be located once the prefix is
    ///   known, which is circular; the two prefixes it realistically names on
    ///   macOS (`/opt/homebrew`, `/usr/local`) are in the list above already.
    /// - a project-level `./.npmrc` is meaningless for a GUI app whose working
    ///   directory the user never chose.
    static func npmPrefixBin(home: String = NSHomeDirectory(),
                             fileManager: FileManager = .default) -> String? {
        let npmrc = (home as NSString).appendingPathComponent(".npmrc")
        guard let data = fileManager.contents(atPath: npmrc),
              let text = String(data: data, encoding: .utf8),
              let value = npmrcPrefixValue(in: text) else { return nil }
        let expanded = expandingHome(value, home: home)
        // Blank, relative, commented-out or otherwise unusable values degrade
        // to "no extra directory" rather than a nonsense path to probe.
        guard expanded.hasPrefix("/") else {
            if !expanded.isEmpty {
                llmRunnerLog.debug("""
                    llm npm prefix ignored (not an absolute path) \
                    npmrc=\(npmrc, privacy: .public)
                    """)
            }
            return nil
        }
        return (expanded as NSString).appendingPathComponent("bin")
    }

    /// The effective `prefix` value in an npmrc body, following the `ini`
    /// parser npm itself uses: `;` and `#` start a comment, a double-quoted
    /// value is JSON-decoded and a single-quoted one is literal, an unquoted
    /// one ends at an inline comment, and a later assignment overwrites an
    /// earlier one — *including* a later one npm cannot parse, which lands as
    /// its own raw text and so leaves no usable prefix. `nil` when the key is absent —
    /// an empty string when it is present but blank, which the caller rejects
    /// along with every other unusable value.
    private static func npmrcPrefixValue(in text: String) -> String? {
        var found: String?
        var inSection = false
        // `isNewline` rather than splitting on "\n": Swift treats CRLF as a
        // single Character, so a file saved with Windows line endings would
        // otherwise parse as one giant line.
        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            // `[section]` scopes everything under it. npm does not use a
            // section-scoped `prefix` as the global prefix, so neither may we --
            // probing its `bin` would add a directory npm never installs into.
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inSection = true
                continue
            }
            guard !inSection else { continue }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<equals]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            guard key == "prefix" else { continue }
            var value = line[line.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               let quote = value.first, quote == "\"" || quote == "'",
               value.last == quote {
                let inner = String(value.dropFirst().dropLast())
                // npm's ini reader JSON-parses a double-quoted value, so every
                // JSON escape applies -- not just `\\\\` and `\\"` but `\\u006e` too.
                // Hand-rolling that decoding got it wrong twice on this branch,
                // so delegate to a real JSON parser rather than enumerating the
                // escapes. Single-quoted values are literal in npm; no decoding.
                //
                // A double-quoted value that isn't valid JSON is kept **raw,
                // quotes and all** -- which is precisely what `npm/ini` does:
                // its `JSON.parse` sits inside a `try/catch` whose handler
                // leaves the value untouched, and the parse loop then assigns
                // it like any other. That buys two things at once. The leading
                // `"` fails `npmPrefixBin`'s absolute-path check, so a value
                // npm cannot read still yields no directory to probe -- unlike
                // dropping the quotes, which would turn `"/opt/bad\\q"` into
                // the absolute-looking `/opt/bad\\q` and probe a directory npm
                // would never install into. And because the line is *assigned*
                // rather than skipped, it overwrites an earlier `prefix`,
                // keeping last-assignment-wins true even when the last
                // assignment is malformed. Skipping it would leave a stale
                // earlier value in force and send Mila hunting for a CLI in a
                // directory npm no longer points at -- a wrong answer where
                // npm gives none.
                if quote == "\"" {
                    value = jsonDecodedString(value) ?? value
                } else {
                    value = inner
                }
            } else {
                value = truncatingAtUnescapedComment(value)
            }
            found = value
        }
        return found
    }

    /// Decodes a JSON string literal (quotes included), or nil when the text
    /// isn't valid JSON. `npm/ini` uses JSON parsing for double-quoted values,
    /// so this matches it exactly instead of approximating a subset of the
    /// escapes by hand.
    private static func jsonDecodedString(_ quoted: String) -> String? {
        guard let data = quoted.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }

    /// Cuts an unquoted value at its first *unescaped* `;` or `#`.
    ///
    /// npm keeps `\\#` and `\\;` as literal characters in an unquoted value, so
    /// a naive scan for the bare delimiter turns `prefix=/opt/npm\\#tools` into
    /// `/opt/npm\\` and probes a directory that does not exist. Verified
    /// against `npm config get prefix --userconfig`.
    ///
    /// The backslash is dropped as it is consumed, which is what npm does with
    /// it -- it is an escape, not part of the path.
    private static func truncatingAtUnescapedComment(_ value: String) -> String {
        var out = ""
        var pendingBackslash = false
        for character in value {
            if pendingBackslash {
                // npm escapes only these three. Before anything else the
                // backslash is an ordinary character and both survive --
                // `prefix=/opt/npm\\tools` is a path with a backslash in it, not
                // `/opt/npmtools`.
                if character == "\\" || character == ";" || character == "#" {
                    out.append(character)
                } else {
                    out.append("\\")
                    out.append(character)
                }
                pendingBackslash = false
                continue
            }
            if character == "\\" {
                pendingBackslash = true
                continue
            }
            if character == ";" || character == "#" { break }
            out.append(character)
        }
        // A trailing lone backslash escaped nothing; npm keeps it as a literal.
        if pendingBackslash { out.append("\\") }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Expands a leading `~`, `$HOME` or `${HOME}` against the given home.
    /// Anything else (`~someoneelse`, `$OTHER`) is returned untouched so it
    /// fails `npmPrefixBin`'s absolute-path check instead of being
    /// half-expanded into a directory that cannot exist.
    private static func expandingHome(_ value: String, home: String) -> String {
        for token in ["${HOME}", "$HOME", "~"] {
            if value == token { return home }
            if value.hasPrefix(token + "/") {
                let rest = String(value.dropFirst(token.count + 1))
                return (home as NSString).appendingPathComponent(rest)
            }
        }
        return value
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
