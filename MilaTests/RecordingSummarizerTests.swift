import XCTest
@testable import Mila

/// Tests for the post-record summarizer that runs whenever the LLM CLI
/// is configured (not just when Live AI mode was active).
///
/// End-to-end invocation goes through `RecordingSummarizer`'s injectable
/// `runLLM` seam (see `RecordingSummarizer.RunLLM`) rather than spawning a
/// real `claude`/`/bin/sh` subprocess. Earlier revisions wrote a temp shell
/// script and pointed `LLMSettings.executablePath` at it; under CI
/// contention the spawn / exec / pipe-drain could hiccup or time out, the
/// summarizer's `catch` would swallow the error, no summary got written, and
/// the assertion failed intermittently (e.g. CI run 28448415130). Injecting
/// a synchronous canned-output closure removes the subprocess-timing
/// dependency entirely, so these assertions are deterministic by
/// construction — no real CLI installed, no child process, no flake.
@MainActor
final class RecordingSummarizerTests: XCTestCase {

    private var tempRoot: URL!
    private var store: RecordingStore!
    private var llmDefaults: UserDefaults!
    private var liveDefaults: UserDefaults!
    private var llm: LLMSettings!
    private var liveAI: LiveAISettings!
    private var summarizer: RecordingSummarizer!

    private let llmSuite = "RecordingSummarizerTests.llm"
    private let liveSuite = "RecordingSummarizerTests.liveAI"

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "RecordingSummarizerTests")
        try FileManager.default.createDirectory(at: tempRoot,
                                                withIntermediateDirectories: true)
        store = RecordingStore(rootDirectory: tempRoot)
        UserDefaults().removePersistentDomain(forName: llmSuite)
        UserDefaults().removePersistentDomain(forName: liveSuite)
        llmDefaults = UserDefaults(suiteName: llmSuite)
        liveDefaults = UserDefaults(suiteName: liveSuite)
        llm = LLMSettings(defaults: llmDefaults)
        liveAI = LiveAISettings(defaults: liveDefaults)
        // Default summarizer uses the production `runLLM` (real CLI). The
        // gate-only tests below never reach it; the end-to-end tests rebuild
        // `summarizer` via `useStubRunner` with a deterministic stub.
        summarizer = RecordingSummarizer(store: store,
                                         llmSettings: llm,
                                         liveAISettings: liveAI)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        llmDefaults?.removePersistentDomain(forName: llmSuite)
        liveDefaults?.removePersistentDomain(forName: liveSuite)
        try await super.tearDown()
    }

    // MARK: - Gate

    func test_should_summarize_false_when_llm_not_configured() {
        llm.tool = .none
        let rec = Recording(title: "T", source: .microphone, audioFileName: "t.wav",
                            fullText: "hello world")
        XCTAssertFalse(summarizer.shouldSummarize(rec))
    }

    func test_should_summarize_false_when_summary_already_present() {
        llm.tool = .claude
        var rec = Recording(title: "T", source: .microphone, audioFileName: "t.wav",
                            fullText: "hello world")
        rec.summary = "already have one"
        XCTAssertFalse(summarizer.shouldSummarize(rec))
    }

    func test_should_summarize_false_when_transcript_is_empty() {
        llm.tool = .claude
        let rec = Recording(title: "T", source: .microphone, audioFileName: "t.wav",
                            fullText: "")
        XCTAssertFalse(summarizer.shouldSummarize(rec))
    }

    func test_should_summarize_true_when_configured_and_no_summary() {
        llm.tool = .claude
        let rec = Recording(title: "T", source: .microphone, audioFileName: "t.wav",
                            fullText: "the transcript")
        XCTAssertTrue(summarizer.shouldSummarize(rec))
    }

    /// The auto-summary master switch. When the user turns off
    /// "Automatically summarize recordings" the post-recording summary
    /// must NOT fire, even with the LLM configured and a transcript ready.
    func test_should_summarize_false_when_auto_summary_disabled() {
        llm.tool = .claude
        llm.summaryEnabled = false
        let rec = Recording(title: "T", source: .microphone, audioFileName: "t.wav",
                            fullText: "the transcript")
        XCTAssertFalse(summarizer.shouldSummarize(rec),
                       "Disabling auto-summary must gate shouldSummarize")
    }

    /// Default-on: existing users (and fresh installs) keep getting
    /// summaries unless they explicitly opt out. A bare `defaults.bool`
    /// would default to false and silently disable the feature for
    /// everyone, so the property must default to true.
    func test_summary_enabled_defaults_true() {
        XCTAssertTrue(llm.summaryEnabled,
                      "Auto-summary must default to on to preserve existing behaviour")
    }

    func test_should_summarize_treats_whitespace_summary_as_empty() {
        llm.tool = .claude
        var rec = Recording(title: "T", source: .microphone, audioFileName: "t.wav",
                            fullText: "the transcript")
        rec.summary = "   \n  "
        XCTAssertTrue(summarizer.shouldSummarize(rec),
                      "Whitespace-only summary should not block regeneration")
    }

    // MARK: - End-to-end via injected runner

    /// Verify the summarizer actually writes the LLM output to the
    /// recording's `summary` field, and that the sidecar lands too. The
    /// injected runner returns a canned summary synchronously — no real CLI.
    func test_summarize_stores_output_on_recording_and_writes_sidecar() async throws {
        llm.tool = .claude
        liveAI.model = ""
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in
            "A concise summary of the meeting."
        }

        let audioURL = store.freshAudioURL(suggestedName: "Meeting")
        // The audio file needs to exist for `RecordingStore.add` to be
        // happy, but the summarizer never reads it — only `fullText`.
        try Data("not-audio".utf8).write(to: audioURL)
        let rec = Recording(
            title: "Meeting",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "we discussed the roadmap and agreed to ship next week"
        )
        store.add(rec)

        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "A concise summary of the meeting.")
        let sidecar = store.summaryURL(for: updated)
        let onDisk = try String(contentsOf: sidecar, encoding: .utf8)
        XCTAssertEqual(onDisk, "A concise summary of the meeting.")
    }

    /// The core "right call" assertion: when a transcript is ready, the
    /// summarizer must invoke the configured CLI ONCE, in claude's one-shot
    /// `-p` shape, with the transcript embedded in the prompt via
    /// `LLMRunner.composedPrompt`. The stub reconstructs the exact argv the
    /// app WOULD have launched — by feeding the prompt/model it was handed
    /// through `LLMTool.arguments`, the same call the production `runLLM`
    /// makes — and records it, so we still assert the wire shape without a
    /// real subprocess. This is what replaced the old real-Anthropic e2e:
    /// instead of asking a live model and judging its answer, we verify Mila
    /// issues the correct invocation off the back of a transcription.
    func test_summarize_invokes_cli_with_transcript_in_one_shot_prompt() async throws {
        llm.tool = .claude
        liveAI.model = ""   // keep argv minimal: no --model passthrough

        // Capture the argv the app would have launched. The production
        // runner (`LLMRunner.run`) composes the user prompt + transcript via
        // `composedPrompt` BEFORE handing the blob to `LLMTool.arguments`, so
        // the stub does the same here — that's what embeds the transcript and
        // the "Transcript:" label into the `-p` argument. Reconstructing the
        // argv this way proves the one-shot `-p` shape without a subprocess.
        var capturedArgs: [String] = []
        var callCount = 0
        useStubRunner { tool, prompt, transcript, _, model, extraArgs, _, _, _, _, _ in
            callCount += 1
            let composed = LLMRunner.composedPrompt(prompt, transcript: transcript)
            capturedArgs = tool.arguments(prompt: composed, model: model) + extraArgs
            return "A concise summary of the meeting."
        }

        let transcript = "we discussed the roadmap and agreed to ship next week"
        let audioURL = store.freshAudioURL(suggestedName: "Call")
        try Data("x".utf8).write(to: audioURL)
        let rec = Recording(
            title: "Call",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: transcript
        )
        store.add(rec)

        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        // The CLI ran exactly once and its output was stored.
        XCTAssertEqual(callCount, 1, "the summarizer must invoke the CLI exactly once")
        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "A concise summary of the meeting.")

        // Assert the SHAPE of the call the app made.
        XCTAssertTrue(capturedArgs.contains("-p"),
                      "claude must be invoked in one-shot `-p` mode; got argv=\(capturedArgs)")
        let prompt = try XCTUnwrap(capturedArgs.first { $0.contains(transcript) },
                                   "the transcript must be embedded in the prompt; argv=\(capturedArgs)")
        XCTAssertTrue(prompt.contains("Transcript:"),
                      "prompt should use LLMRunner.composedPrompt's labelled format")
    }

    /// Empty CLI output must NOT clobber a (currently nil) summary — we
    /// don't want a wedged CLI to mask the recording as "summarized".
    func test_summarize_drops_empty_output() async throws {
        llm.tool = .claude
        // Stub returns empty output — the production runner trims stdout, so
        // an empty return models a CLI that printed nothing useful.
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in "" }

        let audioURL = store.freshAudioURL(suggestedName: "Empty")
        try Data("x".utf8).write(to: audioURL)
        let rec = Recording(
            title: "Empty",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "transcript text"
        )
        store.add(rec)

        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertNil(updated.summary)
    }

    /// If a live summary lands between enqueue and the CLI returning, the
    /// summarizer must NOT overwrite it. Deterministic: the stub blocks on a
    /// gate the test opens AFTER patching the store, so the "summary landed
    /// mid-flight" ordering is guaranteed without any `sleep`.
    func test_summarize_does_not_overwrite_summary_that_landed_mid_flight() async throws {
        llm.tool = .claude

        let gate = TestGate()
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in
            // Block until the test has patched the store, then return the
            // (now stale) CLI output.
            await gate.wait()
            return "OVERWRITE"
        }

        let audioURL = store.freshAudioURL(suggestedName: "Race")
        try Data("x".utf8).write(to: audioURL)
        let rec = Recording(
            title: "Race",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "transcript text"
        )
        store.add(rec)

        summarizer.summarizeIfNeeded(rec)
        // The runner is now parked in `gate.wait()`. Patch the store to
        // simulate a live summary landing while the one-shot CLI was still
        // running, then release the gate so the runner returns.
        XCTAssertTrue(summarizer.isSummarizing(rec.id),
                      "runner should be in flight before we patch the store")
        if var current = store.recordings.first(where: { $0.id == rec.id }) {
            current.summary = "live_summary_from_recording"
            store.update(current)
        }
        gate.open()

        await summarizer.awaitInFlight(rec.id)
        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "live_summary_from_recording",
                       "Late-arriving CLI output must not overwrite a summary that already exists")
    }

    /// End-to-end: with auto-summary disabled, a freshly transcribed
    /// recording must be left untouched — the runner is never invoked and no
    /// summary lands.
    func test_summarize_skips_when_auto_summary_disabled() async throws {
        llm.tool = .claude
        llm.summaryEnabled = false
        var called = false
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in
            called = true
            return "SHOULD NOT RUN"
        }

        let audioURL = store.freshAudioURL(suggestedName: "Off")
        try Data("x".utf8).write(to: audioURL)
        let rec = Recording(
            title: "Off",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "transcript text"
        )
        store.add(rec)

        summarizer.summarizeIfNeeded(rec)
        // The auto-summary gate is synchronous: a disabled toggle means
        // `runSummary` is never reached, so no CLI task is ever spawned.
        XCTAssertFalse(summarizer.isSummarizing(rec.id),
                       "Disabled auto-summary must not spawn a CLI task")
        await summarizer.awaitInFlight(rec.id)
        XCTAssertFalse(called, "the runner must not be invoked while auto-summary is disabled")
        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertNil(updated.summary,
                     "No summary should be written while auto-summary is disabled")
    }

    /// The explicit "Regenerate summary" affordance is a deliberate user
    /// action and must work even when AUTOMATIC summaries are turned off —
    /// the toggle governs the post-recording auto path, not on-demand use.
    func test_regenerate_works_even_when_auto_summary_disabled() async throws {
        llm.tool = .claude
        llm.summaryEnabled = false
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in "ON DEMAND" }

        let audioURL = store.freshAudioURL(suggestedName: "Manual")
        try Data("x".utf8).write(to: audioURL)
        var rec = Recording(
            title: "Manual",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "transcript text"
        )
        // Mirrors the real UI path: the "Regenerate summary" action is only
        // reachable on a recording that already has a summary (e.g. made
        // before the user disabled auto-summary). Regenerate must still
        // refresh it on demand despite the master switch being off.
        rec.summary = "stale summary from before auto-summary was disabled"
        store.add(rec)

        summarizer.regenerate(rec)
        await summarizer.awaitInFlight(rec.id)
        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "ON DEMAND")
    }

    // MARK: - Force / regenerate path

    /// `regenerate(_:)` must overwrite an existing summary — that's the
    /// whole point of the affordance. Without this the "Regenerate
    /// summary" context-menu item and the re-transcribe hook would both
    /// silently no-op.
    ///
    /// This is the test that was flaky on CI: previously it spawned a real
    /// `/bin/sh` script via the CLI runner and asserted on the result, so a
    /// subprocess hiccup made the summary fail to land. With the injected
    /// runner there's no subprocess — the canned "REGENERATED" is returned
    /// synchronously and the assertion is deterministic.
    func test_regenerate_overwrites_existing_summary() async throws {
        llm.tool = .claude
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in "REGENERATED" }

        let audioURL = store.freshAudioURL(suggestedName: "Regen")
        try Data("x".utf8).write(to: audioURL)
        var rec = Recording(
            title: "Regen",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "the new transcript text"
        )
        rec.summary = "stale summary from a previous run"
        store.add(rec)

        // `summarizeIfNeeded` would bail because a summary already
        // exists; `regenerate` bypasses that gate.
        summarizer.regenerate(rec)
        await summarizer.awaitInFlight(rec.id)
        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "REGENERATED")
    }

    /// `regenerate` still respects the two hard requirements:
    /// LLM configured + non-empty transcript.
    func test_regenerate_noops_when_llm_not_configured() async throws {
        llm.tool = .none
        var called = false
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in
            called = true
            return "should not reach here"
        }

        let audioURL = store.freshAudioURL(suggestedName: "NoLLM")
        try Data("x".utf8).write(to: audioURL)
        var rec = Recording(
            title: "NoLLM",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "transcript text"
        )
        rec.summary = "old summary"
        store.add(rec)

        summarizer.regenerate(rec)
        // The gate is synchronous: an unconfigured LLM means no task is spawned.
        XCTAssertFalse(summarizer.isSummarizing(rec.id),
                       "regenerate must not spawn a task when the LLM is unconfigured")
        await summarizer.awaitInFlight(rec.id)
        XCTAssertFalse(called, "the runner must not be invoked when the LLM is unconfigured")
        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "old summary")
    }

    func test_regenerate_noops_when_transcript_empty() async throws {
        llm.tool = .claude
        var called = false
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in
            called = true
            return "should not reach here"
        }

        let audioURL = store.freshAudioURL(suggestedName: "Empty")
        try Data("x".utf8).write(to: audioURL)
        var rec = Recording(
            title: "Empty",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: ""
        )
        rec.summary = "old"
        store.add(rec)

        summarizer.regenerate(rec)
        // The gate is synchronous: an empty transcript means no task is spawned.
        XCTAssertFalse(summarizer.isSummarizing(rec.id),
                       "regenerate must not spawn a task for an empty transcript")
        await summarizer.awaitInFlight(rec.id)
        XCTAssertFalse(called, "the runner must not be invoked for an empty transcript")
        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "old",
                       "Empty transcript must not trigger a CLI call")
    }

    /// `isSummarizing(_:)` flips true while a call is in flight and back
    /// to false when it lands. The detail view's spinner depends on this.
    /// Deterministic: the stub parks on a gate the test opens, so the
    /// in-flight window is observed without timing on a `sleep`.
    func test_is_summarizing_tracks_in_flight_state() async throws {
        llm.tool = .claude
        let gate = TestGate()
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in
            await gate.wait()
            return "done"
        }

        let audioURL = store.freshAudioURL(suggestedName: "Spin")
        try Data("x".utf8).write(to: audioURL)
        let rec = Recording(
            title: "Spin",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "transcript text"
        )
        store.add(rec)

        XCTAssertFalse(summarizer.isSummarizing(rec.id))
        summarizer.summarizeIfNeeded(rec)
        // `inFlightIDs.insert` runs synchronously inside `summarizeIfNeeded`
        // (before the Task is even created), so the flag is true the instant
        // the call returns — and the runner is parked on the gate.
        XCTAssertTrue(summarizer.isSummarizing(rec.id),
                      "isSummarizing should be true while CLI is running")

        // Release the runner and await the real task completion.
        gate.open()
        await summarizer.awaitInFlight(rec.id)
        XCTAssertFalse(summarizer.isSummarizing(rec.id),
                       "isSummarizing should clear after CLI returns")
    }

    // MARK: - OpenAI-compatible model threading (issue celarent7/mila#4)

    /// The OpenAI-compatible summarizer must send `openAIModelName` (the
    /// user's configured endpoint model), NOT `liveAISettings.model` (a Live
    /// AI CLI override such as "claude-sonnet-4-6"). The latter 404's at the
    /// endpoint as model-not-found. Mirrors `LiveAISession.kick`'s
    /// tool-conditional selection.
    func test_summarize_threadsOpenAIModelName_forOpenAICompatible() async throws {
        llm.tool = .openaiCompatible
        llm.openAIBaseURL = "https://api.openai.com/v1"
        llm.openAIModelName = "gpt-4o-mini"
        // Live AI's model is intentionally a *different* name — if the
        // summarizer used it (the bug), the stub would record it here.
        liveAI.model = "claude-sonnet-4-6"

        var capturedModel: String? = ""
        useStubRunner { _, _, _, _, model, _, _, _, _, _, _ in
            capturedModel = model
            return "A concise summary."
        }

        let audioURL = store.freshAudioURL(suggestedName: "Meeting")
        try Data("not-audio".utf8).write(to: audioURL)
        let rec = Recording(title: "Meeting", source: .microphone,
                            audioFileName: audioURL.lastPathComponent,
                            fullText: "we discussed the roadmap")
        store.add(rec)

        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        XCTAssertEqual(capturedModel, "gpt-4o-mini",
                       "The OpenAI summary path must send openAIModelName, not the Live AI model")
    }

    // MARK: - JSON envelope (summary + action items)

    /// The one-shot summarizer now asks for a JSON envelope so it can
    /// populate BOTH the summary and the action-items list from the full
    /// transcript — restoring the pair the pre-#87 inline final Live-AI
    /// tick used to produce. A well-formed envelope must land both halves.
    func test_summarize_parses_envelope_and_stores_summary_and_action_items() async throws {
        llm.tool = .claude
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in
            #"{"summary": "We agreed to ship next week.", "items": [{"id": "ship", "text": "Ship the beta", "speaker": null, "timestamp_seconds": 0, "source": "inferred"}, {"id": "deck", "text": "Dana sends the deck", "speaker": null, "timestamp_seconds": 0, "source": "inferred"}]}"#
        }

        let audioURL = store.freshAudioURL(suggestedName: "Envelope")
        try Data("x".utf8).write(to: audioURL)
        let rec = Recording(
            title: "Envelope",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "we discussed the roadmap and agreed to ship next week"
        )
        store.add(rec)

        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "We agreed to ship next week.")
        let items = try XCTUnwrap(updated.actionItems)
        XCTAssertEqual(items.map(\.text), ["Ship the beta", "Dana sends the deck"])
    }

    /// Back-compat: a model that ignores the JSON instruction and returns
    /// plain prose must still have its whole output stored as the summary,
    /// with no action items — exactly the pre-change behaviour.
    func test_summarize_plain_text_output_still_stored_as_summary_without_items() async throws {
        llm.tool = .claude
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in "Just a plain prose summary." }

        let audioURL = store.freshAudioURL(suggestedName: "Prose")
        try Data("x".utf8).write(to: audioURL)
        let rec = Recording(
            title: "Prose",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "transcript text"
        )
        store.add(rec)

        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "Just a plain prose summary.")
        XCTAssertNil(updated.actionItems,
                     "plain-text output must not fabricate an action-items list")
    }

    /// `regenerate` (the Live-AI finalize path + manual affordance) must
    /// REPLACE stale action items with the fresh full-transcript set, the
    /// same way it already replaces the summary.
    func test_regenerate_replaces_action_items_from_full_transcript() async throws {
        llm.tool = .claude
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in
            #"{"summary": "Fresh summary.", "items": [{"id": "new", "text": "New follow-up", "speaker": null, "timestamp_seconds": 0, "source": "inferred"}]}"#
        }

        let audioURL = store.freshAudioURL(suggestedName: "RegenItems")
        try Data("x".utf8).write(to: audioURL)
        var rec = Recording(
            title: "RegenItems",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "the full transcript"
        )
        rec.summary = "stale summary"
        rec.actionItems = [ActionItem(id: "old", text: "Stale item", speaker: nil,
                                      timestampSeconds: 0, source: .llmInferred,
                                      addedAt: Date())]
        store.add(rec)

        summarizer.regenerate(rec)
        await summarizer.awaitInFlight(rec.id)

        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "Fresh summary.")
        XCTAssertEqual(updated.actionItems?.map(\.text), ["New follow-up"],
                       "regenerate must replace the stale action items")
    }

    /// An empty (or absent) items list must NOT wipe action items the
    /// recording already has — e.g. a Live-AI recording's rolling snapshot.
    /// A glitchy prose response shouldn't cost the user their items.
    func test_regenerate_empty_items_preserves_existing_action_items() async throws {
        llm.tool = .claude
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in "Only a prose summary, no JSON." }

        let audioURL = store.freshAudioURL(suggestedName: "KeepItems")
        try Data("x".utf8).write(to: audioURL)
        var rec = Recording(
            title: "KeepItems",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "the full transcript"
        )
        rec.summary = "stale summary"
        rec.actionItems = [ActionItem(id: "keep", text: "Keep me", speaker: nil,
                                      timestampSeconds: 0, source: .llmInferred,
                                      addedAt: Date())]
        store.add(rec)

        summarizer.regenerate(rec)
        await summarizer.awaitInFlight(rec.id)

        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "Only a prose summary, no JSON.")
        XCTAssertEqual(updated.actionItems?.map(\.text), ["Keep me"],
                       "an empty items response must not wipe existing action items")
    }

    /// The prompt's preferred shape: a plain-text summary, the sentinel on
    /// its own line, then a JSON array. The summary stays plain text (no JSON
    /// wrapping) and the items are parsed from the trailing array.
    func test_summarize_parses_sentinel_format() async throws {
        llm.tool = .claude
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in
            """
            We agreed to ship next week and Dana owns the deck.
            \(RecordingSummarizer.actionItemsSentinel)
            [{"id": "ship", "text": "Ship the beta", "source": "inferred"}, {"id": "deck", "text": "Dana sends the deck", "source": "inferred"}]
            """
        }

        let audioURL = store.freshAudioURL(suggestedName: "Sentinel")
        try Data("x".utf8).write(to: audioURL)
        let rec = Recording(
            title: "Sentinel",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "we discussed the roadmap"
        )
        store.add(rec)

        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "We agreed to ship next week and Dana owns the deck.")
        XCTAssertFalse(updated.summary?.contains(RecordingSummarizer.actionItemsSentinel) ?? true,
                       "the sentinel marker must not leak into the summary")
        XCTAssertEqual(updated.actionItems?.map(\.text), ["Ship the beta", "Dana sends the deck"])
    }

    /// Regression for the reported bug: the model returned a JSON envelope
    /// whose summary value had UNESCAPED quotes and newlines (Hebrew review),
    /// so the object decode failed. The summarizer must NOT dump the raw
    /// `{...}` blob into the summary — it salvages the summary text and still
    /// recovers the (independently valid) items array.
    func test_summarize_salvages_summary_from_malformed_json_envelope() async throws {
        llm.tool = .claude
        // Note the unescaped inner quotes around על חלל and the literal \n —
        // exactly what broke JSONDecoder in production.
        let malformed = #"{"summary": "השיחה עסקה בניהול צוות.\n\n• בייליס מתנהג כאילו הוא "על חלל" ואינו לוקח אחריות.", "items": [{"id": "a", "text": "להחזיר לבייליס ביקורת ישירה", "source": "inferred"}, {"id": "b", "text": "לנטרל את גוליאן משיחות פרודקט", "source": "inferred"}]}"#
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in malformed }

        let audioURL = store.freshAudioURL(suggestedName: "Malformed")
        try Data("x".utf8).write(to: audioURL)
        let rec = Recording(
            title: "Malformed",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "the full transcript"
        )
        store.add(rec)

        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        let summary = try XCTUnwrap(updated.summary)
        XCTAssertFalse(summary.hasPrefix("{"),
                       "a raw JSON blob must never be shown as the summary")
        XCTAssertFalse(summary.contains("\"items\""),
                       "the items scaffolding must not leak into the summary")
        XCTAssertTrue(summary.contains("השיחה עסקה בניהול צוות"),
                      "the real summary text must be salvaged")
        XCTAssertTrue(summary.contains("\n"),
                      "escaped newlines must be restored so it renders as lines")
        XCTAssertEqual(updated.actionItems?.count, 2,
                       "the valid items array must still be recovered")
    }

    // MARK: - Parsing the one-shot output (pure, no runner)

    /// `parseSummaryAndItems` must say WHICH shape it got. The tolerant
    /// paths are the whole point of this fix, and a model that quietly
    /// ignores the output contract on every single call should be
    /// diagnosable from Console rather than invisible.
    func test_parse_origin_reports_which_shape_arrived() {
        XCTAssertEqual(RecordingSummarizer.parseSummaryAndItems(from: "Plain prose.").origin,
                       .plain)
        XCTAssertEqual(
            RecordingSummarizer.parseSummaryAndItems(
                from: "A summary.\n\(RecordingSummarizer.actionItemsSentinel)\n[]"
            ).origin,
            .sentinel)
        XCTAssertEqual(
            RecordingSummarizer.parseSummaryAndItems(
                from: #"{"summary": "A summary.", "items": []}"#
            ).origin,
            .envelope)
    }

    /// A malformed envelope that is PRETTY-PRINTED. The salvage anchored on
    /// the separator spelled exactly `", "items"` / `","items"`, so
    /// multi-line JSON — what a CLI printing an indented object emits — fell
    /// through to "take everything up to the last quote" and dragged the
    /// whole items array into the summary. That is the same scaffolding leak
    /// the fix exists to prevent, just one whitespace variation away.
    ///
    /// `legacySalvageSummaryValue` below reproduces the old anchor and is
    /// asserted to leak, so the assertions here are provably discriminating
    /// rather than vacuous.
    func test_parse_salvages_pretty_printed_malformed_envelope_without_leaking_scaffolding() {
        let malformed = """
        {
          "summary": "Team review. Baylis acts as if he is "on another planet" and takes no ownership.",
          "items": [
            {"id": "a", "text": "Give Baylis direct feedback", "source": "inferred"}
          ]
        }
        """

        let parsed = RecordingSummarizer.parseSummaryAndItems(from: malformed)

        XCTAssertEqual(parsed.origin, .salvagedEnvelope)
        XCTAssertFalse(parsed.summary.hasPrefix("{"),
                       "a raw JSON blob must never be shown as the summary")
        XCTAssertFalse(parsed.summary.contains("\"items\""),
                       "the items scaffolding must not leak into the summary")
        XCTAssertFalse(parsed.summary.contains("\"source\""),
                       "no item field may leak into the summary")
        XCTAssertTrue(parsed.summary.hasSuffix("takes no ownership."),
                      "the summary must end where its value ended; got \(parsed.summary)")
        XCTAssertTrue(parsed.summary.contains("\"on another planet\""),
                      "the unescaped quotes that broke the decode are part of the text")
        XCTAssertEqual(parsed.items.map(\.text), ["Give Baylis direct feedback"],
                       "the independently valid items array must still be recovered")

        // Negative control: the pre-fix anchor swallows the array.
        XCTAssertTrue(legacySalvageSummaryValue(from: malformed).contains("\"items\""),
                      "control: the literal-separator anchor must leak, or this test proves nothing")
    }

    /// A JSON object with no readable summary at all. Storing it verbatim is
    /// the reported bug, and it is self-perpetuating — a stored blob passes
    /// the "already summarized" gate, so the recording is never retried.
    /// No summary is the honest answer; the origin makes it diagnosable.
    func test_parse_unreadable_json_object_yields_no_summary_rather_than_the_blob() {
        let blob = #"{"resumen": "clave equivocada", "items": []}"#

        let parsed = RecordingSummarizer.parseSummaryAndItems(from: blob)

        XCTAssertEqual(parsed.origin, .unreadableEnvelope)
        XCTAssertTrue(parsed.summary.isEmpty,
                      "an unreadable object must yield no summary; got \(parsed.summary)")
    }

    /// The same malformed envelope, WRAPPED — a label line plus ```json
    /// fences, which is the shape an LLM emits most often. `parseEnvelope`
    /// accepts that wrapper (it plucks the first balanced block out of the
    /// string rather than requiring position 0), but the salvage and
    /// `unreadableEnvelope` branches were gated on `trimmed.hasPrefix("{")`.
    /// So the wrapped form failed the object decode AND the prefix test and
    /// landed in `.plain`, storing the whole fenced blob as the summary — the
    /// reported bug, for the commonest shape.
    func test_parse_salvages_a_malformed_envelope_inside_fences_and_a_label() {
        let fenced = """
        Here is the summary:
        ```json
        {
          "summary": "Team review. Baylis acts as if he is "on another planet".",
          "items": [
            {"id": "a", "text": "Give Baylis direct feedback", "source": "inferred"}
          ]
        }
        ```
        """

        let parsed = RecordingSummarizer.parseSummaryAndItems(from: fenced)

        XCTAssertEqual(parsed.origin, .salvagedEnvelope,
                       "a fenced malformed envelope is still an envelope")
        XCTAssertFalse(parsed.summary.contains("```"),
                       "fence scaffolding must never reach the summary")
        XCTAssertFalse(parsed.summary.contains("\"items\""),
                       "the items scaffolding must not leak into the summary")
        XCTAssertFalse(parsed.summary.hasPrefix("Here is the summary:"),
                       "the label must not be stored as the summary")
        XCTAssertTrue(parsed.summary.hasSuffix("\"on another planet\"."),
                      "the salvaged value must be the summary; got \(parsed.summary)")
        XCTAssertEqual(parsed.items.map(\.text), ["Give Baylis direct feedback"],
                       "items recovered by the lenient parse must survive the wrapper")

        // The unfenced label-only variant takes the same branch.
        let labelled = #"""
        Here is the JSON:
        {"summary": "A "quoted" thing.", "items": []}
        """#
        let labelledParse = RecordingSummarizer.parseSummaryAndItems(from: labelled)
        XCTAssertEqual(labelledParse.origin, .salvagedEnvelope)
        XCTAssertEqual(labelledParse.summary, "A \"quoted\" thing.")
    }

    /// The counterweight to the test above, and the reason the fix is not
    /// simply "the output contains a `{`". A real summary may quote braces or
    /// a code block; blanking a GOOD summary is a worse outcome than showing
    /// a blob, so an object must be what the output IS — nothing but
    /// whitespace after it, and at most a short label before it.
    func test_parse_keeps_prose_that_merely_quotes_braces_or_a_code_block() {
        let braces = "The team reviewed the config {mode: fast} and shipped it."
        let bracesParse = RecordingSummarizer.parseSummaryAndItems(from: braces)
        XCTAssertEqual(bracesParse.origin, .plain)
        XCTAssertEqual(bracesParse.summary, braces,
                       "prose that mentions a brace block must survive intact")

        let withCode = """
        The team walked through the retry handler at length and agreed the \
        default should change before the next release ships to users.
        ```
        {"retries": 3}
        ```
        """
        let codeParse = RecordingSummarizer.parseSummaryAndItems(from: withCode)
        XCTAssertEqual(codeParse.origin, .plain)
        XCTAssertTrue(codeParse.summary.hasPrefix("The team walked through"),
                      "a prose summary quoting a fenced block must survive intact")
    }

    // MARK: - Dictated action items survive the one-shot pass

    /// For a Live-AI recording, `QuickActionsController` snapshots the live
    /// action items — including ones the user DICTATED ("Mila, action
    /// item: …", `source == .voiceCommand`) — onto the recording at stop and
    /// then immediately calls `regenerate`. The one-shot prompt is never
    /// shown that list and only ever asks for `source: "inferred"`, so a
    /// wholesale replace trades what the user said out loud for the model's
    /// guess at it. Dictated items must survive.
    func test_regenerate_preserves_action_items_the_user_dictated() async throws {
        llm.tool = .claude
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in
            """
            Fresh summary.
            \(RecordingSummarizer.actionItemsSentinel)
            [{"id": "fresh", "text": "Ship the beta", "source": "inferred"}]
            """
        }

        let audioURL = store.freshAudioURL(suggestedName: "Dictated")
        try Data("x".utf8).write(to: audioURL)
        var rec = Recording(
            title: "Dictated",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "the full transcript"
        )
        rec.summary = "stale summary"
        rec.actionItems = [ActionItem(id: "dictated", text: "Call the bank",
                                      speaker: nil, timestampSeconds: 12,
                                      source: .voiceCommand, addedAt: Date())]
        store.add(rec)

        summarizer.regenerate(rec)
        await summarizer.awaitInFlight(rec.id)

        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(updated.summary, "Fresh summary.")
        let items = try XCTUnwrap(updated.actionItems)
        XCTAssertEqual(items.map(\.text), ["Call the bank", "Ship the beta"],
                       "a dictated item must not be dropped for the inferred set")
        XCTAssertEqual(items.first?.source, .voiceCommand,
                       "it must stay marked as dictated — the MCP surface reports that field")
    }

    /// The model usually DOES re-derive a dictated task from the transcript,
    /// under an id of its own. Keeping both would show the user the same
    /// task twice, so the fresh copy is dropped and the dictated one — the
    /// authoritative record of an explicit instruction — is kept. Matching
    /// is case- and whitespace-insensitive, which this fixture exercises.
    func test_regenerate_does_not_duplicate_a_dictated_item_the_model_re_derived() async throws {
        llm.tool = .claude
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in
            """
            Fresh summary.
            \(RecordingSummarizer.actionItemsSentinel)
            [{"id": "reinferred", "text": "call the   BANK", "source": "inferred"},
             {"id": "other", "text": "Ship the beta", "source": "inferred"}]
            """
        }

        let audioURL = store.freshAudioURL(suggestedName: "NoDupes")
        try Data("x".utf8).write(to: audioURL)
        var rec = Recording(
            title: "NoDupes",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "the full transcript"
        )
        rec.actionItems = [ActionItem(id: "dictated", text: "Call the bank",
                                      speaker: nil, timestampSeconds: 12,
                                      source: .voiceCommand, addedAt: Date())]
        store.add(rec)

        summarizer.regenerate(rec)
        await summarizer.awaitInFlight(rec.id)

        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        let items = try XCTUnwrap(updated.actionItems)
        XCTAssertEqual(items.map(\.text), ["Call the bank", "Ship the beta"],
                       "the re-derived copy of a dictated item must be folded away")
        XCTAssertEqual(items.first?.source, .voiceCommand)
    }

    /// End-to-end negative control for the malformed-JSON path: output the
    /// summarizer cannot read a summary out of must leave the recording
    /// WITHOUT a summary — never with the raw `{...}` blob, which is what
    /// shipped and what permanently blocked a retry.
    func test_summarize_never_stores_an_unreadable_json_object_as_the_summary() async throws {
        llm.tool = .claude
        let blob = #"{"resumen": "clave equivocada", "items": []}"#
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in blob }

        let audioURL = store.freshAudioURL(suggestedName: "Unreadable")
        try Data("x".utf8).write(to: audioURL)
        let rec = Recording(
            title: "Unreadable",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "the full transcript"
        )
        store.add(rec)

        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertNil(updated.summary,
                     "a blob must not be stored — the recording stays eligible for a retry")
        XCTAssertTrue(summarizer.shouldSummarize(updated),
                      "and the retry gate must actually still be open")
    }

    /// The same end-to-end control for the WRAPPED shape. This is the half of
    /// the bug that bites hardest: the stored blob satisfies
    /// `shouldSummarize`'s "already has a summary" gate, so the recording is
    /// never retried and the blob is what the detail view, the Obsidian note
    /// and the MCP surface report forever. Fences are the likeliest wrapper,
    /// so gating the recovery on a leading `{` left the common case broken.
    func test_summarize_never_stores_a_fenced_unreadable_json_object() async throws {
        llm.tool = .claude
        let fenced = """
        Here is the summary:
        ```json
        {"resumen": "clave equivocada", "items": []}
        ```
        """
        useStubRunner { _, _, _, _, _, _, _, _, _, _, _ in fenced }

        let audioURL = store.freshAudioURL(suggestedName: "FencedUnreadable")
        try Data("x".utf8).write(to: audioURL)
        let rec = Recording(
            title: "FencedUnreadable",
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            fullText: "the full transcript"
        )
        store.add(rec)

        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        let updated = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertNil(updated.summary,
                     "a fenced blob must not be stored; got \(updated.summary ?? "nil")")
        XCTAssertTrue(summarizer.shouldSummarize(updated),
                      "and the retry gate must actually still be open")
    }

    // MARK: - Helpers

    /// The pre-fix salvage end-anchor, kept ONLY as a negative control for
    /// `test_parse_salvages_pretty_printed_malformed_envelope_without_leaking_scaffolding`.
    /// It matched the separator between the summary value and the `"items"`
    /// key literally, so any other spelling of it fell through to
    /// `lastIndex(of:)`. Do not use for anything else.
    private func legacySalvageSummaryValue(from json: String) -> String {
        guard let keyRange = json.range(of: "\"summary\"") else { return "" }
        let afterKey = json[keyRange.upperBound...]
        guard let colon = afterKey.firstIndex(of: ":") else { return "" }
        let afterColon = afterKey[afterKey.index(after: colon)...]
        guard let openQuote = afterColon.firstIndex(of: "\"") else { return "" }
        let rest = afterColon[afterColon.index(after: openQuote)...]
        let endIdx: Substring.Index
        if let itemsAnchor = rest.range(of: "\", \"items\"")
            ?? rest.range(of: "\",\"items\"") {
            endIdx = itemsAnchor.lowerBound
        } else if let lastQuote = rest.lastIndex(of: "\"") {
            endIdx = lastQuote
        } else {
            endIdx = rest.endIndex
        }
        return String(rest[..<endIdx])
            .replacingOccurrences(of: "\\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Rebuild `summarizer` with a deterministic `runLLM` stub so the
    /// end-to-end tests don't depend on a real subprocess. Call after
    /// configuring `llm` / `liveAI` for the test.
    private func useStubRunner(_ run: @escaping RecordingSummarizer.RunLLM) {
        summarizer = RecordingSummarizer(store: store,
                                         llmSettings: llm,
                                         liveAISettings: liveAI,
                                         runLLM: run)
    }
}

/// A one-shot async gate for deterministically ordering a stubbed runner
/// against the test body — the stub awaits `wait()`, the test calls `open()`
/// once it has set up the mid-flight condition. Replaces `sleep`-based
/// ordering, which slipped under CI contention. Main-actor isolated because
/// the summarizer and tests both run on the main actor.
@MainActor
final class TestGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for c in pending { c.resume() }
    }
}
