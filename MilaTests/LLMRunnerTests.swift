import XCTest
@testable import Mila

/// End-to-end-ish tests for `LLMRunner` — we use `/bin/cat` as a stand-in
/// for `claude -p` so we can verify the spawn + pipe behaviour without
/// depending on the user having a real LLM CLI installed.
final class LLMRunnerTests: XCTestCase {

    func test_runner_throws_when_tool_disabled() async {
        do {
            _ = try await LLMRunner.run(tool: .none,
                                        prompt: "anything",
                                        transcript: "hi",
                                        executablePathOverride: nil)
            XCTFail("Expected toolDisabled error")
        } catch let error as LLMRunnerError {
            if case .toolDisabled = error { /* ok */ } else {
                XCTFail("Wrong error: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func test_runner_throws_when_override_path_is_missing() async {
        do {
            _ = try await LLMRunner.run(tool: .claude,
                                        prompt: "anything",
                                        transcript: "hi",
                                        executablePathOverride: "/definitely/not/here/claude")
            XCTFail("Expected executableNotFound error")
        } catch let error as LLMRunnerError {
            if case .executableNotFound = error { /* ok */ } else {
                XCTFail("Wrong error: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    /// Regression guard for the "Mila is trying to access Desktop"
    /// TCC popups. The runner MUST chdir the child to an isolated empty
    /// directory — never the user's $HOME or `/` — because macOS attributes
    /// the child's file access to *our* bundle ID and the user would see
    /// scary prompts for any folder the LLM CLI happens to scan.
    func test_runner_spawns_child_in_isolated_empty_directory() async throws {
        // Script prints its cwd and counts the entries it sees there.
        // Deliberately `ls` and not `ls -A`: since #181 the sandbox is shared
        // and persistent, so an LLM CLI is free to leave its own dot-files
        // (`.claude/`) behind. What must stay true is that the child sees no
        // *user* content — which is what a visible-entry count proves, and it
        // still fails loudly if the cwd ever became $HOME or a user folder.
        let script = makeScript("""
            #!/bin/sh
            printf 'cwd=%s\\n' "$PWD"
            printf 'entries=%s\\n' "$(ls 2>/dev/null | wc -l | tr -d ' ')"
            """)
        defer { try? FileManager.default.removeItem(at: script) }
        let out = try await LLMRunner.run(
            tool: .claude,
            prompt: "x", transcript: "y",
            executablePathOverride: script.path,
            timeout: 30)  // macos-26 VM: subprocess spawn + pipe-drain dispatch adds ~10–15s of overhead
        // cwd must NOT be home or root — those would trigger TCC popups.
        XCTAssertFalse(out.contains("cwd=\(NSHomeDirectory())\n"),
                       "Child spawned in $HOME: \(out)")
        XCTAssertFalse(out.contains("cwd=/\n"),
                       "Child spawned in /: \(out)")
        // It SHOULD hold nothing visible — proving there's nothing for the
        // LLM to scan and reach for.
        XCTAssertTrue(out.contains("entries=0"),
                      "Sandbox directory is not empty: \(out)")
        // And it must be the one directory Mila owns for this.
        XCTAssertTrue(out.contains("cwd=\(LLMRunner.sandboxDirectory().path)\n"),
                      "Child cwd is not the shared LLM sandbox: \(out)")
    }

    /// The transcript travels in argv (via `composedPrompt`), not stdin —
    /// proven by spawning a script that echoes its last argument and
    /// asserting the transcript appears there. We also need to be confident
    /// stdin is closed (no hang).
    func test_runner_passes_prompt_in_argv_and_closes_stdin() async throws {
        let script = makeScript("""
            #!/bin/sh
            # Echo the last argument (= the composed prompt we passed in).
            printf '%s' "${@: -1}"
            # And read stdin to EOF to prove it's already closed (would hang otherwise).
            cat >/dev/null
            """)
        defer { try? FileManager.default.removeItem(at: script) }
        let result = try await LLMRunner.run(tool: .claude,
                                             prompt: "Title please",
                                             transcript: "the audio",
                                             executablePathOverride: script.path,
                                             timeout: 30)
        XCTAssertTrue(result.contains("Title please"),
                      "prompt missing from argv: \(result)")
        XCTAssertTrue(result.contains("the audio"),
                      "transcript missing from argv: \(result)")
    }

    private func makeScript(_ body: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("island-mila-llm-test-\(UUID().uuidString).sh")
        try? body.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
        return url
    }

    func test_runner_surfaces_nonzero_exit_code() async {
        // `/usr/bin/false` always exits 1.
        do {
            _ = try await LLMRunner.run(tool: .claude,
                                        prompt: "x",
                                        transcript: "y",
                                        executablePathOverride: "/usr/bin/false")
            XCTFail("Expected nonZeroExit error")
        } catch let error as LLMRunnerError {
            if case .nonZeroExit(let code, _) = error {
                XCTAssertEqual(code, 1)
            } else {
                XCTFail("Wrong error: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    /// The wire format MUST keep the transcript inside the prompt argument,
    /// not on stdin — `cursor-agent -p` ignores stdin so anything we expect
    /// it to read has to be in argv.
    func test_composed_prompt_appends_transcript_after_separator() {
        let composed = LLMRunner.composedPrompt(
            "Summarize this.",
            transcript: "Hello world.")
        XCTAssertEqual(composed,
                       "Summarize this.\n\n---\nTranscript:\nHello world.")
    }

    func test_composed_prompt_with_empty_transcript_is_just_the_prompt() {
        let composed = LLMRunner.composedPrompt("Say hi.", transcript: "   ")
        XCTAssertEqual(composed, "Say hi.")
    }

    /// When a Live-AI summary is provided, the wire format prepends a
    /// Summary section and labels the transcript "Full transcript:". The
    /// summary lives ABOVE the transcript so the model reads the gist
    /// first — that visibly improves the answer quality on long recordings
    /// (see PR notes on the post-record popup work).
    func test_composed_prompt_includes_summary_above_transcript() {
        let composed = LLMRunner.composedPrompt(
            "Make a tweet from this.",
            transcript: "Hello world.",
            summary: "We discussed the new schema.")
        XCTAssertEqual(composed,
                       "Make a tweet from this.\n\n---\nSummary:\nWe discussed the new schema.\n\nFull transcript:\nHello world.")
    }

    /// Empty / whitespace-only summary collapses back to the original
    /// transcript-only wire format — back-compat guarantee for callers that
    /// don't pass a summary (e.g. recordings that ran without Live AI).
    func test_composed_prompt_with_empty_summary_is_transcript_only() {
        let composed = LLMRunner.composedPrompt(
            "Summarize this.",
            transcript: "Hello world.",
            summary: "   ")
        XCTAssertEqual(composed,
                       "Summarize this.\n\n---\nTranscript:\nHello world.")
    }

    /// Summary-only (no transcript) is still valid — useful when the user
    /// hits Send before the transcript lands and we only have the rolling
    /// summary to ship.
    func test_composed_prompt_with_only_summary_uses_summary_section() {
        let composed = LLMRunner.composedPrompt(
            "Make a doc.",
            transcript: "",
            summary: "Migration is done.")
        XCTAssertEqual(composed,
                       "Make a doc.\n\n---\nSummary:\nMigration is done.")
    }

    func test_timeout_fires_when_process_exceeds_limit() async {
        // Script ignores its args and sleeps 5s. Runner times out at 1s.
        // The contract verified here is "the timeout error fires" — wall
        // time bounds were brittle on the macos-26 CI VM (subprocess
        // termination + pipe-drain dispatch varied between ~10s and
        // ~16s). The 5-minute xcodebuild step timeout already catches
        // "process never terminates" regressions.
        let script = makeScript("""
            #!/bin/sh
            sleep 5
            """)
        defer { try? FileManager.default.removeItem(at: script) }
        do {
            _ = try await LLMRunner.run(tool: .claude,
                                        prompt: "x",
                                        transcript: "y",
                                        executablePathOverride: script.path,
                                        timeout: 1)
            XCTFail("Expected timedOut error")
        } catch let error as LLMRunnerError {
            guard case .timedOut = error else {
                XCTFail("Wrong error: \(error)")
                return
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    /// Regression: after a timeout-kill, the pipe drain used to be an
    /// UNBOUNDED wait for EOF. A grandchild the CLI spawned (MCP server,
    /// node helper) that inherited stdout/stderr and survived the parent's
    /// SIGKILL kept the pipes open — `run` then never returned, leaving the
    /// caller's in-flight slot (summarizer spinner, Live AI tick) stuck
    /// permanently. The script models that: a background `sleep` inherits
    /// stdout and outlives its killed parent. `run` must still return
    /// `.timedOut` promptly instead of waiting out the grandchild.
    func test_timeout_returns_even_when_grandchild_holds_pipes_open() async {
        // The grandchild's PID is parked in a file so the test can reap it
        // on exit — otherwise every run leaves a stray `sleep 60` behind.
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("mila-grandchild-\(UUID().uuidString).pid")
        let script = makeScript("""
            #!/bin/sh
            sleep 60 &
            echo $! > "\(pidFile.path)"
            sleep 60
            """)
        defer {
            if let pidText = try? String(contentsOf: pidFile, encoding: .utf8),
               let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: pidFile)
            try? FileManager.default.removeItem(at: script)
        }

        let started = Date()
        do {
            _ = try await LLMRunner.run(tool: .claude,
                                        prompt: "x",
                                        transcript: "y",
                                        executablePathOverride: script.path,
                                        timeout: 1)
            XCTFail("Expected timedOut error")
        } catch let error as LLMRunnerError {
            guard case .timedOut = error else {
                XCTFail("Wrong error: \(error)")
                return
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
        let elapsed = Date().timeIntervalSince(started)
        // Generous CI bound (same flake class as the plain timeout test) —
        // the point is "returns in seconds, not after the grandchild's 60s".
        XCTAssertLessThan(elapsed, 40,
                          "run() must not wait for the orphaned grandchild to release the pipes; took \(elapsed)s")
    }

    // MARK: - Real-CLI smoke tests
    //
    // These hit the actual `claude` / `cursor-agent` binaries if installed.
    // They auto-skip on machines without the CLIs so CI stays green; on the
    // dev machine they catch the kind of "I shipped a default prompt that
    // hangs claude trying to use a tool it doesn't have" bug that motivated
    // this fix in the first place.

    private func resolve(_ name: String) -> String? {
        // Reuse the production lookup dirs (incl. nvm/Volta/asdf/npm-global) so
        // these smoke tests find CLIs installed by a node version manager
        // rather than spuriously skipping.
        for d in LLMRunner.searchDirectories() {
            let p = (d as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    func test_claude_cli_returns_a_title_for_a_sample_transcript() async throws {
        guard let claudePath = resolve("claude") else {
            throw XCTSkip("claude CLI not installed on this machine")
        }
        let transcript = "We agreed to migrate the staging ECR to the new account by Friday and Uri will open the PR."
        let result = try await LLMRunner.run(
            tool: .claude,
            prompt: LLMSettings.defaultNamePrompt,
            transcript: transcript,
            executablePathOverride: claudePath,
            timeout: 120
        )
        XCTAssertFalse(result.isEmpty, "claude returned empty output")
        // A title shouldn't be a paragraph. Anything under ~120 chars is a
        // safe upper bound for 3–6 words plus claude's occasional preamble.
        XCTAssertLessThan(result.count, 200,
                          "claude reply looks like prose, not a title: \(result)")
    }

    // MARK: - Argument tokenizer / shell quoting

    func test_tokenize_simple_space_separated() {
        XCTAssertEqual(LLMRunner.tokenizeArguments("--model sonnet --debug"),
                       ["--model", "sonnet", "--debug"])
    }

    func test_tokenize_empty_is_no_args() {
        XCTAssertEqual(LLMRunner.tokenizeArguments("   "), [])
    }

    func test_tokenize_double_quotes_keep_spaces_together() {
        XCTAssertEqual(LLMRunner.tokenizeArguments("--model \"claude sonnet 4\""),
                       ["--model", "claude sonnet 4"])
    }

    func test_tokenize_single_quotes_keep_spaces_together() {
        XCTAssertEqual(LLMRunner.tokenizeArguments("--name 'Big Meeting'"),
                       ["--name", "Big Meeting"])
    }

    func test_tokenize_backslash_escapes_space() {
        XCTAssertEqual(LLMRunner.tokenizeArguments("a\\ b c"),
                       ["a b", "c"])
    }

    func test_shellQuote_leaves_safe_tokens_bare() {
        XCTAssertEqual(LLMRunner.shellQuote("--model"), "--model")
        XCTAssertEqual(LLMRunner.shellQuote("claude-sonnet-4-6"), "claude-sonnet-4-6")
    }

    func test_shellQuote_wraps_tokens_with_spaces() {
        XCTAssertEqual(LLMRunner.shellQuote("hello world"), "'hello world'")
    }

    func test_shellQuote_escapes_embedded_single_quote() {
        XCTAssertEqual(LLMRunner.shellQuote("it's"), "'it'\\''s'")
    }

    func test_shellQuote_empty_is_quoted() {
        XCTAssertEqual(LLMRunner.shellQuote(""), "''")
    }

    // MARK: - diagnose() — non-throwing test path

    func test_diagnose_reports_setup_error_when_tool_disabled() async {
        let result = await LLMRunner.diagnose(tool: .none,
                                              prompt: "x",
                                              transcript: "y",
                                              executablePathOverride: nil)
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(result.didLaunch)
        XCTAssertNotNil(result.setupError)
    }

    func test_diagnose_reports_setup_error_for_missing_executable() async {
        let result = await LLMRunner.diagnose(tool: .claude,
                                              prompt: "x",
                                              transcript: "y",
                                              executablePathOverride: "/definitely/not/here/claude")
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(result.didLaunch)
        XCTAssertNotNil(result.setupError)
    }

    func test_diagnose_captures_command_stdout_and_success() async throws {
        // `/bin/cat` echoes its argv? No — use a script that prints the prompt
        // arg so we can assert stdout is captured and success is reported.
        let script = makeScript("""
            #!/bin/sh
            printf '%s' "${@: -1}"
            """)
        defer { try? FileManager.default.removeItem(at: script) }
        let result = await LLMRunner.diagnose(tool: .claude,
                                              prompt: "Title please",
                                              transcript: "the audio",
                                              executablePathOverride: script.path,
                                              timeout: 30)
        XCTAssertTrue(result.succeeded, "expected clean exit: \(result)")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.didLaunch)
        XCTAssertTrue(result.stdout.contains("Title please"), "stdout: \(result.stdout)")
        XCTAssertTrue(result.stdout.contains("the audio"), "stdout: \(result.stdout)")
        // Command is shown for copy/paste and points at the resolved binary.
        XCTAssertTrue(result.command.contains(script.path), "command: \(result.command)")
        XCTAssertNil(result.setupError)
    }

    func test_diagnose_captures_nonzero_exit_without_throwing() async {
        let result = await LLMRunner.diagnose(tool: .claude,
                                              prompt: "x",
                                              transcript: "y",
                                              executablePathOverride: "/usr/bin/false")
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.didLaunch)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertNil(result.setupError)
    }

    func test_run_appends_extra_args_after_prompt() async throws {
        // Emit each argument NUL-delimited so we can reconstruct argv exactly
        // and assert the extra args are the *trailing* tokens — the override
        // behaviour (a user --model wins) depends on them coming last, not
        // just being present.
        let script = makeScript("""
            #!/bin/sh
            for a in "$@"; do printf '%s\\0' "$a"; done
            """)
        defer { try? FileManager.default.removeItem(at: script) }
        let out = try await LLMRunner.run(tool: .claude,
                                          prompt: "Title",
                                          transcript: "body",
                                          executablePathOverride: script.path,
                                          extraArgs: ["--model", "some-model"],
                                          timeout: 30)
        let argv = out.split(separator: "\0").map(String.init)
        XCTAssertEqual(Array(argv.suffix(2)), ["--model", "some-model"],
                       "extra args must be appended after standard args: \(argv)")
    }

    func test_diagnose_reports_timeout_without_throwing() async throws {
        // Script ignores args and sleeps past the 1s timeout. diagnose maps
        // the timeout into the result fields the panel renders, never throws.
        let script = makeScript("""
            #!/bin/sh
            sleep 5
            """)
        defer { try? FileManager.default.removeItem(at: script) }
        let result = await LLMRunner.diagnose(tool: .claude,
                                              prompt: "x",
                                              transcript: "y",
                                              executablePathOverride: script.path,
                                              timeout: 1)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.didLaunch)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.exitCode, -1)
        XCTAssertNil(result.setupError)
    }

    func test_diagnose_appends_extra_args_to_command() async {
        let result = await LLMRunner.diagnose(tool: .claude,
                                              prompt: "x",
                                              transcript: "y",
                                              extraArgs: ["--model", "claude sonnet"],
                                              executablePathOverride: "/usr/bin/true")
        // The space-bearing arg must round-trip through shell quoting.
        XCTAssertTrue(result.command.contains("--model 'claude sonnet'"),
                      "command: \(result.command)")
    }

    func test_cursor_cli_returns_a_title_for_a_sample_transcript() async throws {
        guard let cursorPath = resolve("cursor-agent") else {
            throw XCTSkip("cursor-agent CLI not installed on this machine")
        }
        let transcript = "We agreed to migrate the staging ECR to the new account by Friday and Uri will open the PR."
        let result = try await LLMRunner.run(
            tool: .cursor,
            prompt: LLMSettings.defaultNamePrompt,
            transcript: transcript,
            executablePathOverride: cursorPath,
            timeout: 120
        )
        // The regression we're guarding against: cursor-agent ignores stdin.
        // If the runner accidentally went back to piping the transcript via
        // stdin, cursor-agent would respond with "the transcript wasn't
        // included" — assert we got *something else*.
        XCTAssertFalse(result.isEmpty, "cursor-agent returned empty output")
        XCTAssertFalse(result.lowercased().contains("wasn't included"),
                       "cursor-agent never saw the transcript — runner regressed: \(result)")
        XCTAssertFalse(result.lowercased().contains("could you paste"),
                       "cursor-agent never saw the transcript — runner regressed: \(result)")
    }

    // MARK: - Phase 10 — CLI regression guard (OpenAI branch must not leak)

    /// AC-REGRESS-01 — the early `.openaiCompatible` branch added in Phase 6
    /// must NOT divert `.claude` (or any CLI tool) into the HTTP path, even
    /// when the new OpenAI params are explicitly passed. We prove it by
    /// handing `.claude` a non-nil `openAIBaseURL` + `jsonMode` + `temperature`
    /// AND a `makeScript` stand-in: if the branch were mis-scoped (e.g.
    /// `tool != .none`), the runner would hit the HTTP transport instead of
    /// spawning the script, and the marker would never come back. Uses the
    /// shell-script stand-in (m1) — not `/bin/cat`.
    func test_run_claude_unchanged_resolvesExecutableAndSpawns() async throws {
        let script = makeScript("""
            #!/bin/sh
            printf 'CLI-PATH-MARKER:%s' "${@: -1}"
            """)
        defer { try? FileManager.default.removeItem(at: script) }
        let out = try await LLMRunner.run(
            tool: .claude,
            prompt: "hello",
            transcript: "world",
            executablePathOverride: script.path,
            timeout: 30,
            openAIBaseURL: "http://localhost:11434/v1",
            openAIAPIKey: "ignored-by-cli-path",
            jsonMode: true,
            temperature: 0.5
        )
        XCTAssertTrue(out.contains("CLI-PATH-MARKER:"),
                      "claude was diverted away from the CLI spawn path: \(out)")
        XCTAssertTrue(out.contains("hello"),
                      "composed prompt didn't reach the CLI: \(out)")
    }

    /// AC-REGRESS-02 — the OpenAI branch must not leak into `.none` or
    /// `.cursor`. `.none` still throws `toolDisabled` (not an OpenAI/HTTP
    /// error) even with OpenAI params present; `.cursor` still spawns the CLI
    /// stand-in and ignores the OpenAI params. The existing suite is the
    /// guard; this test pins the "no leak" invariant explicitly.
    func test_existingLLMRunnerTestsStillPass() async throws {
        // .none: OpenAI params present, but tool-disabled wins — no HTTP
        // attempt, no OpenAIRequestError, just .toolDisabled.
        do {
            _ = try await LLMRunner.run(tool: .none,
                                        prompt: "x", transcript: "y",
                                        executablePathOverride: nil,
                                        openAIBaseURL: "http://localhost:11434/v1",
                                        openAIAPIKey: "k",
                                        jsonMode: true,
                                        temperature: 0.5)
            XCTFail("Expected toolDisabled for .none")
        } catch let error as LLMRunnerError {
            guard case .toolDisabled = error else {
                XCTFail(".none leaked into a non-toolDisabled path: \(error)"); return
            }
        } catch {
            XCTFail("Wrong error type for .none: \(error)")
        }

        // .cursor: still spawns the CLI stand-in, ignoring the OpenAI params.
        let script = makeScript("""
            #!/bin/sh
            printf 'cursor-ran'
            """)
        defer { try? FileManager.default.removeItem(at: script) }
        let out = try await LLMRunner.run(tool: .cursor,
                                          prompt: "x", transcript: "y",
                                          executablePathOverride: script.path,
                                          timeout: 30,
                                          openAIBaseURL: "http://localhost:11434/v1",
                                          openAIAPIKey: "k",
                                          jsonMode: true,
                                          temperature: 0.5)
        XCTAssertEqual(out, "cursor-ran",
                       "cursor was diverted away from the CLI spawn path: \(out)")
    }

    // MARK: - Gemini CLI (LLMTool.gemini)

    func test_gemini_metadata_matches_cli() {
        XCTAssertEqual(LLMTool.gemini.executableName, "gemini")
        XCTAssertEqual(LLMTool.gemini.displayName, "Gemini (gemini CLI)")
        // Must be selectable in the Settings picker (ForEach over allCases).
        XCTAssertTrue(LLMTool.allCases.contains(.gemini))
    }

    func test_gemini_arguments_are_prompt_and_skip_trust_by_default() {
        // `--skip-trust` is always passed: we launch in an isolated sandbox
        // dir which gemini would otherwise reject as an untrusted workspace.
        XCTAssertEqual(LLMTool.gemini.arguments(prompt: "Summarize"),
                       ["-p", "Summarize", "--skip-trust"])
    }

    func test_gemini_arguments_append_model_with_short_flag() {
        // Gemini uses `-m`, unlike claude/cursor's `--model`.
        XCTAssertEqual(
            LLMTool.gemini.arguments(prompt: "Summarize", model: "gemini-2.5-flash"),
            ["-p", "Summarize", "--skip-trust", "-m", "gemini-2.5-flash"])
    }

    func test_gemini_arguments_blank_model_is_omitted() {
        XCTAssertEqual(LLMTool.gemini.arguments(prompt: "Summarize", model: "   "),
                       ["-p", "Summarize", "--skip-trust"])
    }

    func test_gemini_arguments_ignore_session() {
        // Gemini's -p mode has no conversation-resume flag; a session value
        // must not leak flags into argv.
        let args = LLMTool.gemini.arguments(prompt: "Summarize",
                                            session: .new(UUID()))
        XCTAssertEqual(args, ["-p", "Summarize", "--skip-trust"])
    }

    // MARK: - Executable lookup directories

    func test_searchDirectories_includes_version_manager_bins() {
        let dirs = LLMRunner.searchDirectories(home: "/Users/tester", pathEnv: nil)
        XCTAssertTrue(dirs.contains("/Users/tester/.volta/bin"), "\(dirs)")
        XCTAssertTrue(dirs.contains("/Users/tester/.asdf/shims"), "\(dirs)")
        XCTAssertTrue(dirs.contains("/Users/tester/.npm-global/bin"), "\(dirs)")
        XCTAssertTrue(dirs.contains("/opt/homebrew/bin"), "\(dirs)")
    }

    func test_searchDirectories_prepends_PATH_entries_in_order() {
        let dirs = LLMRunner.searchDirectories(home: "/Users/tester",
                                               pathEnv: "/a:/b")
        XCTAssertEqual(Array(dirs.prefix(2)), ["/a", "/b"])
    }

    func test_searchDirectories_enumerates_nvm_versions_newest_first() throws {
        // Build a fake home with two nvm node versions; the newer one must
        // sort ahead so a global CLI installed under it wins.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("mila-nvm-\(UUID().uuidString)")
        let nodeRoot = home.appendingPathComponent(".nvm/versions/node")
        for v in ["v20.1.0", "v22.15.0"] {
            try FileManager.default.createDirectory(
                at: nodeRoot.appendingPathComponent("\(v)/bin"),
                withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: home) }

        let dirs = LLMRunner.searchDirectories(home: home.path, pathEnv: nil)
        let nvmDirs = dirs.filter { $0.contains("/.nvm/versions/node/") }
        XCTAssertEqual(nvmDirs, [
            "\(home.path)/.nvm/versions/node/v22.15.0/bin",
            "\(home.path)/.nvm/versions/node/v20.1.0/bin",
        ], "nvm version bins must be present, newest first: \(dirs)")
    }

    func test_childEnvironment_prepends_executable_dir_to_PATH() {
        // node-shebang CLIs (gemini) need their sibling `node` on PATH; the
        // resolved binary's own dir must come first so that install wins.
        let exe = URL(fileURLWithPath: "/Users/tester/.nvm/versions/node/v22.15.0/bin/gemini")
        let env = LLMRunner.childEnvironment(for: exe, base: ["PATH": "/usr/bin"])
        let path = env["PATH"] ?? ""
        let entries = path.split(separator: ":").map(String.init)
        XCTAssertEqual(entries.first, "/Users/tester/.nvm/versions/node/v22.15.0/bin",
                       "executable dir must be first: \(path)")
        XCTAssertTrue(entries.contains("/usr/bin"), "inherited PATH must survive: \(path)")
        XCTAssertTrue(entries.contains("/opt/homebrew/bin"), "well-known dirs must be added: \(path)")
    }

    func test_childEnvironment_dedupes_and_preserves_other_vars() {
        let exe = URL(fileURLWithPath: "/opt/homebrew/bin/claude")
        let env = LLMRunner.childEnvironment(
            for: exe, base: ["PATH": "/opt/homebrew/bin", "HOME": "/Users/tester"])
        let entries = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        XCTAssertEqual(entries.filter { $0 == "/opt/homebrew/bin" }.count, 1,
                       "duplicate dirs must be collapsed: \(entries)")
        XCTAssertEqual(env["HOME"], "/Users/tester", "other env vars must be inherited")
    }

    func test_searchDirectories_without_nvm_is_stable() {
        // A home with no ~/.nvm must not crash or inject nvm dirs.
        let dirs = LLMRunner.searchDirectories(
            home: "/nonexistent-home-\(UUID().uuidString)", pathEnv: nil)
        XCTAssertFalse(dirs.contains { $0.contains("/.nvm/versions/node/") })
    }

    // MARK: - Configured npm prefix (~/.npmrc)

    /// A throwaway home directory, optionally carrying an `.npmrc`. Local to
    /// these tests — nothing else needs a fake home.
    private func makeHome(npmrc: String? = nil) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("mila-npmrc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home,
                                                withIntermediateDirectories: true)
        if let npmrc {
            try npmrc.write(to: home.appendingPathComponent(".npmrc"),
                            atomically: true, encoding: .utf8)
        }
        return home
    }

    func test_searchDirectories_honours_a_configured_npm_prefix() throws {
        // The whole point of the feature: a prefix that is *not* the
        // ~/.npm-global convention still gets searched.
        let home = try makeHome(npmrc: """
            registry=https://registry.npmjs.org/
            prefix=/opt/npm-elsewhere
            """)
        defer { try? FileManager.default.removeItem(at: home) }

        let dirs = LLMRunner.searchDirectories(home: home.path, pathEnv: nil)
        XCTAssertTrue(dirs.contains("/opt/npm-elsewhere/bin"), "\(dirs)")
        // Configured beats guessed: it must be probed before the conventions.
        let configured = try XCTUnwrap(dirs.firstIndex(of: "/opt/npm-elsewhere/bin"))
        let convention = try XCTUnwrap(dirs.firstIndex(of: "\(home.path)/.npm-global/bin"))
        XCTAssertLessThan(configured, convention, "\(dirs)")
    }

    func test_searchDirectories_expands_home_in_a_configured_npm_prefix() throws {
        // npmrc files are written by hand, so all three spellings of "my home
        // directory" show up in the wild. A literal "~" would be a directory
        // that cannot exist.
        for spelling in ["~/npm-here", "$HOME/npm-here", "${HOME}/npm-here"] {
            let home = try makeHome(npmrc: "prefix=\(spelling)\n")
            defer { try? FileManager.default.removeItem(at: home) }

            let dirs = LLMRunner.searchDirectories(home: home.path, pathEnv: nil)
            XCTAssertTrue(dirs.contains("\(home.path)/npm-here/bin"),
                          "\(spelling) was not expanded: \(dirs)")
        }
    }

    func test_searchDirectories_ignores_unusable_npm_prefix_values() throws {
        // A malformed, blank, relative or commented-out value must degrade to
        // "no extra directory" — never to a nonsense path we then probe.
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let npmrc = home.appendingPathComponent(".npmrc")
        let baseline = LLMRunner.searchDirectories(home: home.path, pathEnv: nil)

        for content in [
            "prefix=\n",                          // blank
            "prefix=   \n",                       // whitespace only
            "prefix=relative/dir\n",              // not absolute
            "; prefix=/opt/commented\n",          // ini comment
            "#prefix=/opt/commented\n",           // the other comment marker
            "prefix=~someoneelse/npm\n",          // another user's home
            "prefix\n",                           // no '=' at all
            "registry=https://example.com/\n",    // no prefix key
            "[scope]\nnothing-here=1\n"          // no prefix key, with a section
        ] {
            try content.write(to: npmrc, atomically: true, encoding: .utf8)
            XCTAssertEqual(LLMRunner.searchDirectories(home: home.path, pathEnv: nil),
                           baseline,
                           "unusable value must add nothing: \(content.debugDescription)")
        }
    }

    func test_npmPrefixBin_strips_quotes_and_inline_comments() throws {
        // npm parses npmrc with the `ini` package: a quoted value is verbatim,
        // an unquoted one ends at the first ; or #.
        let quoted = try makeHome(npmrc: "prefix = \"/opt/quoted npm\"\n")
        defer { try? FileManager.default.removeItem(at: quoted) }
        XCTAssertEqual(LLMRunner.npmPrefixBin(home: quoted.path),
                       "/opt/quoted npm/bin")

        let commented = try makeHome(npmrc: "prefix=/opt/trailing # set by hand\n")
        defer { try? FileManager.default.removeItem(at: commented) }
        XCTAssertEqual(LLMRunner.npmPrefixBin(home: commented.path),
                       "/opt/trailing/bin")
    }

    func test_npmPrefixBin_takes_the_last_assignment_and_normalises_slashes() throws {
        // Later wins, matching ini semantics; a trailing slash must not
        // produce "/opt/second//bin".
        let home = try makeHome(npmrc: """
            prefix=/opt/first
            prefix=/opt/second/
            """)
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertEqual(LLMRunner.npmPrefixBin(home: home.path), "/opt/second/bin")
    }

    func test_npmPrefixBin_handles_windows_line_endings() throws {
        // Swift treats CRLF as a single Character, so splitting on "\n" would
        // swallow the whole file into one line and the prefix would be lost.
        let home = try makeHome(npmrc: "registry=https://example.com/\r\nprefix=/opt/crlf\r\n")
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertEqual(LLMRunner.npmPrefixBin(home: home.path), "/opt/crlf/bin")
    }

    /// npm keeps an escaped `\\#` / `\\;` as a literal character in an unquoted
    /// value, so scanning for the bare delimiter cut `/opt/npm\\#tools` down to
    /// `/opt/npm\\` and probed a directory that does not exist. Verified against
    /// `npm config get prefix --userconfig` when this was found.
    func test_npmPrefixBin_preserves_escaped_comment_characters() throws {
        let hash = try makeHome(npmrc: "prefix=/opt/npm\\#tools\n")
        defer { try? FileManager.default.removeItem(at: hash) }
        XCTAssertEqual(LLMRunner.npmPrefixBin(home: hash.path), "/opt/npm#tools/bin")

        let semi = try makeHome(npmrc: "prefix=/opt/npm\\;tools\n")
        defer { try? FileManager.default.removeItem(at: semi) }
        XCTAssertEqual(LLMRunner.npmPrefixBin(home: semi.path), "/opt/npm;tools/bin")
    }

    /// The escape handling must not stop a genuine inline comment being cut.
    func test_npmPrefixBin_still_strips_a_real_inline_comment() throws {
        let hash = try makeHome(npmrc: "prefix=/opt/plain #a trailing note\n")
        defer { try? FileManager.default.removeItem(at: hash) }
        XCTAssertEqual(LLMRunner.npmPrefixBin(home: hash.path), "/opt/plain/bin")

        // Escaped first, then a real one: keep the literal, drop the comment.
        let both = try makeHome(npmrc: "prefix=/opt/a\\#b #note\n")
        defer { try? FileManager.default.removeItem(at: both) }
        XCTAssertEqual(LLMRunner.npmPrefixBin(home: both.path), "/opt/a#b/bin")
    }

    /// npm treats a backslash as an escape only before `\\`, `;` or `#`. Before an
    /// ordinary character both survive, so `prefix=/opt/npm\\tools` is a path
    /// containing a backslash -- an earlier fix for escaped comment markers
    /// stripped every backslash and turned it into `/opt/npmtools`.
    func test_npmPrefixBin_keeps_a_backslash_before_an_ordinary_character() throws {
        let home = try makeHome(npmrc: "prefix=/opt/npm\\tools\n")
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertEqual(LLMRunner.npmPrefixBin(home: home.path), "/opt/npm\\tools/bin")
    }

    /// An escaped backslash collapses to one, as npm does.
    func test_npmPrefixBin_collapses_an_escaped_backslash() throws {
        let home = try makeHome(npmrc: "prefix=/opt/npm\\\\tools\n")
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertEqual(LLMRunner.npmPrefixBin(home: home.path), "/opt/npm\\tools/bin")
    }

    /// `[section]` scopes what follows it. npm does not use a section-scoped
    /// `prefix` as the global prefix, so probing its `bin` would add a
    /// directory npm never installs into.
    func test_npmPrefixBin_ignores_a_section_scoped_prefix() throws {
        let scoped = try makeHome(npmrc: "[tool]\nprefix=/tmp/tool\n")
        defer { try? FileManager.default.removeItem(at: scoped) }
        XCTAssertNil(LLMRunner.npmPrefixBin(home: scoped.path))

        // A top-level value before a section still counts.
        let mixed = try makeHome(npmrc: "prefix=/opt/real\n[tool]\nprefix=/tmp/tool\n")
        defer { try? FileManager.default.removeItem(at: mixed) }
        XCTAssertEqual(LLMRunner.npmPrefixBin(home: mixed.path), "/opt/real/bin")
    }

    /// The search list must not probe the same directory twice, including when
    /// the inherited PATH itself repeats one.
    func test_searchDirectories_deduplicates_repeated_path_entries() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dirs = LLMRunner.searchDirectories(home: home.path,
                                               pathEnv: "/usr/local/bin:/usr/local/bin")
        XCTAssertEqual(dirs.filter { $0 == "/usr/local/bin" }.count, 1,
                       "a repeated PATH entry was probed twice: \(dirs)")
    }

    /// npm decodes escapes inside a DOUBLE-quoted value, so
    /// `prefix="/opt/npm\\\\tools"` resolves to `/opt/npm\\tools`. Stripping the
    /// quotes without decoding left both backslashes and probed a path that
    /// cannot exist. Verified against `npm config get prefix --userconfig`.
    func test_npmPrefixBin_decodes_escapes_in_a_double_quoted_value() throws {
        let home = try makeHome(npmrc: "prefix=\"/opt/npm\\\\tools\"\n")
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertEqual(LLMRunner.npmPrefixBin(home: home.path), "/opt/npm\\tools/bin")
    }

    /// `npm/ini` JSON-parses a double-quoted value, so every JSON escape
    /// applies -- `prefix="/opt/\\u006eode"` is `/opt/node` to npm. Decoding only
    /// `\\\\` and `\\"` by hand missed this, which is why the implementation now
    /// delegates to `JSONDecoder` rather than approximating the escape set.
    func test_npmPrefixBin_decodes_a_unicode_escape_in_a_double_quoted_value() throws {
        let home = try makeHome(npmrc: "prefix=\"/opt/\\u006eode\"\n")
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertEqual(LLMRunner.npmPrefixBin(home: home.path), "/opt/node/bin")
    }

    /// A double-quoted value npm itself cannot parse yields **no** prefix.
    ///
    /// Stripping the quotes instead would leave `/opt/bad\\q` -- absolute, so
    /// it passes the path check and gets probed, even though npm has no prefix
    /// from that file at all. A missing candidate is better than a wrong one.
    func test_npmPrefixBin_discards_an_undecodable_quoted_value() throws {
        let home = try makeHome(npmrc: "prefix=\"/opt/bad\\q\"\n")
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertNil(LLMRunner.npmPrefixBin(home: home.path))
    }

    /// ...and it erases an earlier good one, because last-assignment-wins
    /// holds even when the last assignment is malformed.
    ///
    /// `npm/ini` does not skip the unparseable line: its `JSON.parse` sits in
    /// a `try/catch` whose handler leaves the raw quoted text in place, and
    /// the parse loop assigns that like any other value. npm's effective
    /// `prefix` here is therefore the literal `"/opt/bad\\q"` -- quotes
    /// included, so not an absolute path, so no prefix at all. Retaining
    /// `/opt/good` instead would have Mila probe a directory the user's npm
    /// config no longer names and launch a CLI npm does not install into,
    /// where npm itself simply finds nothing.
    func test_npmPrefixBin_drops_an_earlier_prefix_when_a_later_one_is_undecodable() throws {
        // Control: the same first line on its own really does resolve, so the
        // nil below is the override taking effect -- not a fixture that failed
        // to write or a parser that choked on the whole file. Without this the
        // assertion would pass just as happily against a `makeHome` that wrote
        // nothing at all.
        let good = try makeHome(npmrc: "prefix=/opt/good\n")
        defer { try? FileManager.default.removeItem(at: good) }
        XCTAssertEqual(LLMRunner.npmPrefixBin(home: good.path), "/opt/good/bin")

        let overridden = try makeHome(npmrc: "prefix=/opt/good\nprefix=\"/opt/bad\\q\"\n")
        defer { try? FileManager.default.removeItem(at: overridden) }
        let resolved = LLMRunner.npmPrefixBin(home: overridden.path)
        XCTAssertNotEqual(resolved, "/opt/good/bin",
                          "the superseded prefix survived a malformed override")
        XCTAssertNil(resolved)
    }

    /// Single quotes are literal in npm -- no decoding there.
    func test_npmPrefixBin_leaves_single_quoted_values_literal() throws {
        let home = try makeHome(npmrc: "prefix='/opt/npm\\\\tools'\n")
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertEqual(LLMRunner.npmPrefixBin(home: home.path), "/opt/npm\\\\tools/bin")
    }

    func test_npmPrefixBin_is_nil_without_an_npmrc() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertNil(LLMRunner.npmPrefixBin(home: home.path))
    }

    func test_searchDirectories_does_not_duplicate_a_default_npm_prefix() throws {
        // /usr/local is npm's own default prefix, so the configured value
        // routinely collides with an entry that is already in the list.
        let home = try makeHome(npmrc: "prefix=/usr/local\n")
        defer { try? FileManager.default.removeItem(at: home) }

        let dirs = LLMRunner.searchDirectories(home: home.path, pathEnv: "/usr/local/bin")
        XCTAssertEqual(dirs.filter { $0 == "/usr/local/bin" }.count, 1, "\(dirs)")
    }

    func test_gemini_cli_returns_a_title_for_a_sample_transcript() async throws {
        guard let geminiPath = resolve("gemini") else {
            throw XCTSkip("gemini CLI not installed on this machine")
        }
        let transcript = "We agreed to migrate the staging ECR to the new account by Friday and Uri will open the PR."
        let result: String
        do {
            result = try await LLMRunner.run(
                tool: .gemini,
                prompt: LLMSettings.defaultNamePrompt,
                transcript: transcript,
                executablePathOverride: geminiPath,
                timeout: 120
            )
        } catch let error as LLMRunnerError {
            // An installed-but-unusable CLI is an environment problem, not a
            // regression in our argv/plumbing: gemini exits non-zero when the
            // machine isn't logged in, or when the account's tier is no longer
            // eligible (Google retired free-tier Code Assist for this client).
            // Skip rather than fail so the suite stays green off a login.
            guard case .nonZeroExit(_, let stderr) = error,
                  Self.looksLikeGeminiAuthFailure(stderr) else { throw error }
            throw XCTSkip("gemini CLI is installed but not usable on this machine (auth/tier): \(stderr.prefix(200))")
        }
        XCTAssertFalse(result.isEmpty, "gemini returned empty output")
        XCTAssertLessThan(result.count, 200,
                          "gemini reply looks like prose, not a title: \(result)")
    }

    /// Whether a `gemini` non-zero exit is an auth/eligibility problem (skip)
    /// rather than a real failure of the invocation we're testing (fail).
    private static func looksLikeGeminiAuthFailure(_ stderr: String) -> Bool {
        let s = stderr.lowercased()
        return s.contains("error authenticating")
            || s.contains("ineligibletiererror")
            || s.contains("please login")
            || s.contains("not authenticated")
    }
}
