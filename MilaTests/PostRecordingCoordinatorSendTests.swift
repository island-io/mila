import XCTest
import TranscriptionCore
import MilaKit
@testable import Mila

/// Tests for `PostRecordingCoordinator`'s background "Send to <LLM>"
/// runner — the path the rename sheet's "Send to Claude" button and the
/// right-click "Send to <LLM>…" sheet now delegate to.
///
/// Like `RecordingSummarizerTests`, end-to-end invocation uses a shell
/// script masquerading as `claude` so the test runs without the real CLI
/// installed.
@MainActor
final class PostRecordingCoordinatorSendTests: XCTestCase {

    private var tempRoot: URL!
    private var store: RecordingStore!
    private var manager: ModelManager!
    private var stub: StubWhisperEngine!
    private var service: TranscriptionService!
    private var coordinator: PostRecordingCoordinator!

    private let diarSuite = "PostRecordingCoordinatorSendTests.diarization"

    // MARK: - Bounds (issue #208)
    //
    // Both constants exist for one reason: **a test must never adopt a
    // production timeout that is longer than the budget CI gives the test.**
    // This bundle runs with `-default-test-execution-time-allowance 240`
    // (`.github/workflows/ios-tests.yml`), and the two waits a send makes
    // ship at 600s and 300s respectively. When the test's bound is the longer
    // one, it decides which watchdog fires first — and the two outcomes are
    // not equivalent:
    //
    //   * bound < allowance — the wait expires on its own, the assertion
    //     fails with a message, and `-retry-tests-on-failure` re-runs it.
    //   * bound > allowance — XCTest kills the whole test HOST. There is no
    //     assertion message and nothing for the retry policy to recover, so
    //     the job reports a bare `Failing tests: …` line with no cause
    //     attached anywhere in the log.
    //
    // The second shape is what took main red on aec65fc (via `LLMRunnerTests`)
    // and it is the "red tick that tells you nothing" #208 is about.

    /// Bound for `awaitFinalTranscript`. `transcriptWaitTimeout` ships at
    /// **600s** — right for a user who hit Send while a long meeting is still
    /// transcribing, wrong here.
    ///
    /// This suite is not hypothetically exposed to that wait; several cases
    /// enter it on purpose. `test_send_waits_for_transcript_when_fired_early`
    /// fires before the transcript exists, and the #211 cases park in
    /// `awaitSpeakerFinalization` until the test releases the marker. If
    /// whatever is supposed to release the wait ever doesn't, 60s vs 600s is
    /// the difference between a legible, retryable failure and a dead runner.
    ///
    /// 60s is still far longer than the longest wait any case here actually
    /// needs (hundreds of milliseconds), so it cannot make a slow runner
    /// fail; it only caps the pathological case. Cases that assert the wait
    /// is NOT taken set their own, shorter value on top of this.
    private static let testTranscriptWait: TimeInterval = 60

    /// Bound for the CLI half: `sendToLLM`'s `cliTimeout` defaults to
    /// `LLMRunner.defaultTimeout` (300s), also longer than the allowance. The
    /// longest script in this file sleeps 20s.
    private static let testCLITimeout: TimeInterval = 30

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "PostRecordingCoordinatorSendTests")
        try FileManager.default.createDirectory(at: tempRoot,
                                                withIntermediateDirectories: true)
        store = RecordingStore(rootDirectory: tempRoot)
        manager = ModelManager(modelsDirectory: tempRoot.appendingPathComponent("Models"))
        stub = StubWhisperEngine()
        service = TranscriptionService(
            store: store,
            modelManager: manager,
            diarizationSettings: DiarizationSettings(defaults: .init(suiteName: diarSuite)!),
            remoteSettings: TestSupport.isolatedRemoteSettings(label: "PostRecordingCoordinatorSendTests"),
            engine: stub
        )
        coordinator = PostRecordingCoordinator(store: store, transcription: service,
                                               llm: LLMSettings(defaults: UserDefaults(suiteName: "PostRecordingCoordinatorSendTests.llm")!))
        coordinator.transcriptWaitTimeout = Self.testTranscriptWait
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        UserDefaults().removePersistentDomain(forName: diarSuite)
        try await super.tearDown()
    }

    // MARK: - Background send runs + survives the caller

    /// The send must run to completion on the coordinator even though the
    /// caller (the sheet) returns immediately. We assert the banner ends
    /// up carrying the scripted CLI output, and that `isSending` flips
    /// true while in flight and clears afterward (id-keyed bookkeeping).
    func test_send_runs_in_background_and_reports_via_banner() async throws {
        let script = makeScript("""
            #!/bin/sh
            sleep 0.3
            printf 'CLI ANSWER'
            """)
        defer { try? FileManager.default.removeItem(at: script) }

        let rec = addCompletedRecording(text: "the transcript text")

        XCTAssertFalse(coordinator.isSending(rec.id))
        coordinator.sendToLLM(recordingID: rec.id,
                              tool: .claude,
                              prompt: "Summarize",
                              transcript: "the transcript text",
                              summary: "",
                              executableOverride: script.path,
                              cliTimeout: Self.testCLITimeout)
        // Yield so the task body starts and registers itself.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(coordinator.isSending(rec.id),
                      "isSending should be true while the CLI is running")

        try await waitForBanner(containing: "CLI ANSWER", timeoutSeconds: 30)
        XCTAssertFalse(coordinator.isSending(rec.id),
                       "isSending should clear once the CLI returns")
        XCTAssertEqual(coordinator.activityIsError, false)
    }

    /// A second send for the same recording id cancels + replaces the
    /// first — no two competing CLI calls writing the same banner.
    func test_second_send_for_same_id_replaces_the_first() async throws {
        // First script blocks long enough that the replacement lands while
        // it's still "running".
        let slow = makeScript("""
            #!/bin/sh
            sleep 5
            printf 'SLOW'
            """)
        let fast = makeScript("""
            #!/bin/sh
            printf 'FAST'
            """)
        defer {
            try? FileManager.default.removeItem(at: slow)
            try? FileManager.default.removeItem(at: fast)
        }

        let rec = addCompletedRecording(text: "transcript")

        coordinator.sendToLLM(recordingID: rec.id, tool: .claude, prompt: "p",
                              transcript: "transcript", summary: "",
                              executableOverride: slow.path,
                              cliTimeout: Self.testCLITimeout)
        try await Task.sleep(nanoseconds: 100_000_000)
        coordinator.sendToLLM(recordingID: rec.id, tool: .claude, prompt: "p",
                              transcript: "transcript", summary: "",
                              executableOverride: fast.path,
                              cliTimeout: Self.testCLITimeout)

        // The fast replacement wins; the slow one was cancelled (its
        // .cancelled error is swallowed silently).
        try await waitForBanner(containing: "FAST", timeoutSeconds: 30)
        XCTAssertFalse(coordinator.activityStatus?.contains("SLOW") ?? false,
                       "Replaced send must not surface its output")
    }

    /// Regression: when a send is cancelled-and-replaced, the REPLACED
    /// task's self-cleanup must not wipe the REPLACEMENT's handle. Before
    /// the fix, the first task's unconditional `defer { sendTasks[id] = nil }`
    /// ran when it unwound with `.cancelled` — `isSending` went false while
    /// the replacement CLI was still running, and `cancelAndDiscard` could
    /// no longer reach it (the CLI kept running against a recording that
    /// was being permanently deleted).
    func test_replaced_send_does_not_orphan_replacement_handle() async throws {
        let first = makeScript("""
            #!/bin/sh
            sleep 5
            printf 'FIRST'
            """)
        let second = makeScript("""
            #!/bin/sh
            sleep 20
            printf 'SECOND'
            """)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let rec = addCompletedRecording(text: "transcript")
        coordinator.present(rec)

        coordinator.sendToLLM(recordingID: rec.id, tool: .claude, prompt: "p",
                              transcript: "transcript", summary: "",
                              executableOverride: first.path,
                              cliTimeout: Self.testCLITimeout)
        try await Task.sleep(nanoseconds: 150_000_000)
        // Replace: cancels the first task (its CLI gets SIGTERM'd and it
        // unwinds through its defer while the second is still running).
        coordinator.sendToLLM(recordingID: rec.id, tool: .claude, prompt: "p",
                              transcript: "transcript", summary: "",
                              executableOverride: second.path,
                              cliTimeout: Self.testCLITimeout)
        // Give the replaced task ample time to unwind and run its cleanup.
        try await Task.sleep(nanoseconds: 1_000_000_000)

        XCTAssertTrue(coordinator.isSending(rec.id),
                      "The replacement send is still in flight — the replaced task's cleanup must not have cleared its handle")

        // And the handle still works: discard reaches the replacement.
        coordinator.cancelAndDiscard()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(coordinator.isSending(rec.id),
                       "cancelAndDiscard must be able to cancel the replacement send")
    }

    // MARK: - Discard cancels an in-flight send

    /// Discarding the recording (cancelAndDiscard) must cancel a pending
    /// send so the CLI isn't left chewing on a transcript whose recording
    /// has been deleted out from under it. After discard, `isSending`
    /// clears and the recording is gone from the store.
    func test_discard_cancels_in_flight_send() async throws {
        let slow = makeScript("""
            #!/bin/sh
            sleep 10
            printf 'SHOULD NOT LAND'
            """)
        defer { try? FileManager.default.removeItem(at: slow) }

        // The recording must be `pending` in the coordinator for
        // cancelAndDiscard to act on it.
        let audioURL = store.freshAudioURL(suggestedName: "Discard")
        try Data("x".utf8).write(to: audioURL)
        var rec = Recording(title: "Discard", source: .microphone,
                            audioFileName: audioURL.lastPathComponent,
                            fullText: "transcript")
        rec.status = .completed
        store.add(rec)
        coordinator.present(rec)

        coordinator.sendToLLM(recordingID: rec.id, tool: .claude, prompt: "p",
                              transcript: "transcript", summary: "",
                              executableOverride: slow.path,
                              cliTimeout: Self.testCLITimeout)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(coordinator.isSending(rec.id))

        coordinator.cancelAndDiscard()
        // Cancellation propagates to the CLI (SIGTERM) — give it a beat.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(coordinator.isSending(rec.id),
                       "Discard must cancel + clear the in-flight send")
        XCTAssertNil(store.recordings.first(where: { $0.id == rec.id }),
                     "Discard permanently deletes the recording")
    }

    // MARK: - Fired before the transcript is ready

    /// "Send" can now be pressed before transcription finishes. With an
    /// empty transcript snapshot the coordinator waits for the recording
    /// to leave the in-progress states, then pulls the finished transcript
    /// from the store and sends THAT — rather than no-op'ing on empty.
    func test_send_waits_for_transcript_when_fired_early() async throws {
        // Script echoes back enough of its argv that we can confirm the
        // late-arriving transcript made it into the prompt.
        let script = makeScript("""
            #!/bin/sh
            printf 'sent:%s' "$2"
            """)
        defer { try? FileManager.default.removeItem(at: script) }

        // Recording starts in-progress with no text — mimics pressing
        // Send while whisper is still running.
        let audioURL = store.freshAudioURL(suggestedName: "Early")
        try Data("x".utf8).write(to: audioURL)
        var rec = Recording(title: "Early", source: .microphone,
                            audioFileName: audioURL.lastPathComponent,
                            fullText: "")
        rec.status = .running
        store.add(rec)

        coordinator.sendToLLM(recordingID: rec.id, tool: .claude, prompt: "Do it",
                              transcript: "",  // empty: fired early
                              summary: "",
                              executableOverride: script.path,
                              cliTimeout: Self.testCLITimeout)
        // It should still be in flight (waiting on the transcript), not
        // bailed out.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(coordinator.isSending(rec.id),
                      "Send should wait, not give up, on an empty transcript")

        // Transcription finishes a moment later.
        if var current = store.recordings.first(where: { $0.id == rec.id }) {
            current.fullText = "finished transcript"
            current.segments = [TranscriptSegment(start: 0, end: 1, text: "finished transcript")]
            current.status = .completed
            store.update(current)
        }

        try await waitForBanner(containing: "finished transcript", timeoutSeconds: 30)
        XCTAssertFalse(coordinator.isSending(rec.id))
    }

    // MARK: - Fired before the offline speaker pass lands (issue #211)

    /// NEGATIVE CONTROL for issue #211.
    ///
    /// The user stops a meeting and hits Send immediately. On the live/VAD
    /// path the row is ALREADY `.completed` at that instant — `stopRecording`
    /// writes it before spinning off `finalizeTail` — but the labels on it are
    /// the live diarizer's over-segmented ones: one person split across four
    /// `SPEAKER_NN`, with the name the user typed stuck to only the first.
    /// The offline pass that collapses them lands seconds later.
    ///
    /// Before the fix the send took two shortcuts that both landed on the
    /// stale text: the click-time snapshot was used verbatim whenever it was
    /// non-empty (always, on this path), and even falling through,
    /// `awaitTranscript` only waited for the status to leave
    /// `.pending`/`.running` — which it already had.
    ///
    /// The assertion is deliberately on the PAYLOAD, not on the plumbing:
    /// what reaches the runner must carry the POST-remap labels. Remove the
    /// speaker wait, or the re-read that follows it, and this fails — the
    /// captured transcript comes back full of `SPEAKER_01`…`SPEAKER_03`.
    func test_send_waits_for_speaker_finalization_and_sends_the_remapped_labels() async throws {
        var captured: String?
        var callCount = 0
        let coordinator = makeCoordinator(label: "speakers.\(#function)") {
            _, _, transcript, _, _, _, _, _, _, _, _, _, _, _ in
            captured = transcript
            callCount += 1
            return "ANSWER"
        }

        let rec = addCompletedRecording(
            text: "one two three four",
            segments: [seg(0, 1, "one", "SPEAKER_00"),
                       seg(1, 2, "two", "SPEAKER_01"),
                       seg(2, 3, "three", "SPEAKER_02"),
                       seg(3, 4, "four", "SPEAKER_03")],
            speakerNames: ["SPEAKER_00": "Ada"])
        // Exactly what the sheet would hand `sendToLLM` at click time.
        let clickTime = TranscriptFormatter.plainText(segments: rec.segments,
                                                      fallback: rec.fullText,
                                                      names: rec.speakerNames)
        XCTAssertTrue(clickTime.contains("SPEAKER_03"),
                      "Sanity: the click-time snapshot carries the live diarizer's labels")

        // `finalizeTail` has published the marker and the pyannote pass is
        // running — the window a Send fired right after Stop lands in.
        service.beginSpeakerFinalization(rec.id)

        coordinator.sendToLLM(recordingID: rec.id, tool: .claude,
                              prompt: "Summarize", transcript: clickTime,
                              summary: "", executableOverride: nil)

        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(callCount, 0,
                       "The send must not reach the CLI while the speaker labels are still being re-keyed")
        XCTAssertEqual(coordinator.activityStatus,
                       PostRecordingCoordinator.waitingForSpeakersStatus,
                       "The wait must be explained, not just felt as an unexplained delay")

        // The offline pass lands: four speakers collapse to one, and
        // `SpeakerNameRemapper` carries the name onto the surviving id.
        var current = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        current.segments = [seg(0, 1, "one", "SPEAKER_00"),
                            seg(1, 2, "two", "SPEAKER_00"),
                            seg(2, 3, "three", "SPEAKER_00"),
                            seg(3, 4, "four", "SPEAKER_00")]
        current.speakerNames = ["SPEAKER_00": "Ada"]
        store.update(current)
        service.endSpeakerFinalization(rec.id)

        try await waitFor(callCount > 0)
        let sent = try XCTUnwrap(captured)
        XCTAssertFalse(sent.contains("SPEAKER_01"),
                       "The CLI must not receive the pre-re-diarize labels — got: \(sent)")
        XCTAssertFalse(sent.contains("SPEAKER_02"))
        XCTAssertFalse(sent.contains("SPEAKER_03"))
        XCTAssertTrue(sent.contains("Ada: one two three four"),
                      "The remapped name must cover every turn — got: \(sent)")
    }

    /// The counterpart, so the fix cannot degenerate into "always sleep".
    ///
    /// A recording the live pass already pinned at ≤
    /// `maxLiveSpeakersToSkipRediarize` speakers skips the offline pass
    /// entirely, so `finalizeTail` publishes no marker and the send must pay
    /// NOTHING for the new wait.
    ///
    /// Discriminating by construction: nothing in this test ever calls
    /// `endSpeakerFinalization`, and `transcriptWaitTimeout` is shortened to
    /// 3s. An unconditional wait would therefore park the send for the full
    /// timeout and blow the 1s assertion window.
    func test_send_does_not_wait_when_the_recording_skipped_rediarization() async throws {
        var captured: String?
        var callCount = 0
        let coordinator = makeCoordinator(label: "nowait.\(#function)") {
            _, _, transcript, _, _, _, _, _, _, _, _, _, _, _ in
            captured = transcript
            callCount += 1
            return "ANSWER"
        }
        coordinator.transcriptWaitTimeout = 3

        let rec = addCompletedRecording(
            text: "hello there",
            segments: [seg(0, 1, "hello", "SPEAKER_00"),
                       seg(1, 2, "there", "SPEAKER_01")],
            speakerNames: [:])
        XCTAssertFalse(service.isAwaitingSpeakerFinalization(rec.id),
                       "Sanity: a recording that skipped re-diarization carries no marker")

        coordinator.sendToLLM(recordingID: rec.id, tool: .claude,
                              prompt: "Summarize", transcript: "hello there",
                              summary: "", executableOverride: nil)

        try await waitFor(callCount > 0, timeoutSeconds: 1)
        XCTAssertNotEqual(coordinator.activityStatus,
                          PostRecordingCoordinator.waitingForSpeakersStatus,
                          "Nothing was pending, so no speaker wait should ever have been announced")
        XCTAssertEqual(captured, "SPEAKER_00: hello\nSPEAKER_01: there")
    }

    /// The marker is per-recording: one recording still finalizing must not
    /// hold up a send for a different, already-final one.
    func test_speaker_wait_is_scoped_to_the_recording_being_sent() async throws {
        var callCount = 0
        let coordinator = makeCoordinator(label: "scoped.\(#function)") {
            _, _, _, _, _, _, _, _, _, _, _, _, _, _ in
            callCount += 1
            return "ANSWER"
        }
        coordinator.transcriptWaitTimeout = 3

        let other = addCompletedRecording(text: "other meeting")
        service.beginSpeakerFinalization(other.id)
        defer { service.endSpeakerFinalization(other.id) }

        let rec = addCompletedRecording(text: "this meeting")
        coordinator.sendToLLM(recordingID: rec.id, tool: .claude,
                              prompt: "Summarize", transcript: "this meeting",
                              summary: "", executableOverride: nil)

        try await waitFor(callCount > 0, timeoutSeconds: 1)
    }

    /// The background auto-title job shares the wait (issue #211, point 4) —
    /// a title built from over-segmented speakers is the same stale input.
    /// It must NOT announce the wait, though: it runs unattended on every
    /// recording, so a banner would be noise for something the user never
    /// asked for.
    func test_auto_title_waits_for_speaker_finalization_without_a_banner() async throws {
        let suiteName = "PostRecordingCoordinatorSendTests.titleWait.\(#function)"
        UserDefaults().removePersistentDomain(forName: suiteName)
        let llm = LLMSettings(defaults: UserDefaults(suiteName: suiteName)!,
                              apiKeyKeychainKey: suiteName)
        llm.tool = .claude
        llm.nameGenerationEnabled = true

        var captured: String?
        var callCount = 0
        let coordinator = PostRecordingCoordinator(
            store: store, transcription: service, llm: llm,
            runLLM: { _, _, transcript, _, _, _, _, _, _, _, _, _, _, _ in
                captured = transcript
                callCount += 1
                return "A Tidy Title"
            })

        let rec = addCompletedRecording(
            text: "one two",
            segments: [seg(0, 1, "one", "SPEAKER_00"),
                       seg(1, 2, "two", "SPEAKER_01")],
            speakerNames: [:])
        service.beginSpeakerFinalization(rec.id)

        coordinator.present(rec)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(callCount, 0, "The auto-title job must wait for the speaker pass too")
        XCTAssertNil(coordinator.activityStatus,
                     "The unattended title job must not post a banner about the wait")

        var current = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        current.segments = [seg(0, 1, "one", "SPEAKER_00"), seg(1, 2, "two", "SPEAKER_00")]
        store.update(current)
        service.endSpeakerFinalization(rec.id)

        try await waitFor(callCount > 0)
        XCTAssertEqual(captured, "SPEAKER_00: one two",
                       "The title must be generated from the post-remap transcript")
    }

    // MARK: - OpenAI-compatible model threading (issue celarent7/mila#3)

    /// `sendToLLM` must thread `openAIModelName` as the `model` argument for
    /// the OpenAI-compatible path — otherwise the HTTP request POSTs an empty
    /// model name and the endpoint rejects it. We inject a `runLLM` stub that
    /// records the `model` it was handed and returns canned text, so the
    /// assertion needs no network or CLI.
    func test_sendToLLM_threadsOpenAIModelName_forOpenAICompatible() async throws {
        let suite = UserDefaults(suiteName: "PostRecordingCoordinatorSendTests.openai.\(#function)")!
        suite.removePersistentDomain(forName: "PostRecordingCoordinatorSendTests.openai.\(#function)")
        let key = "PostRecordingCoordinatorSendTests.openai.\(#function).apiKey"
        KeychainHelper.delete(key: key)
        let llm = LLMSettings(defaults: suite, apiKeyKeychainKey: key)
        llm.tool = .openaiCompatible
        llm.openAIBaseURL = "https://api.openai.com/v1"
        llm.openAIModelName = "gpt-4o-mini"

        var capturedModel: String? = nil
        var callCount = 0
        let openAICoordinator = PostRecordingCoordinator(
            store: store, transcription: service, llm: llm,
            runLLM: { _, _, _, _, _, model, _, _, _, _, _, _, _, _ in
                capturedModel = model
                callCount += 1
                return "OPENAI ANSWER"
            })

        let rec = addCompletedRecording(text: "the transcript text")
        openAICoordinator.sendToLLM(recordingID: rec.id,
                                    tool: .openaiCompatible,
                                    prompt: "Summarize",
                                    transcript: "the transcript text",
                                    summary: "",
                                    executableOverride: nil)
        try await waitFor(callCount > 0)
        XCTAssertEqual(capturedModel, "gpt-4o-mini",
                       "The OpenAI path must thread openAIModelName, not an empty model")
    }

    /// The CLI path must keep passing `nil` for `model` (the CLI picks its
    /// own) — the OpenAI-model threading must not leak into `.claude`/`.cursor`.
    func test_sendToLLM_passesNilModel_forCLIPath() async throws {
        let suite = UserDefaults(suiteName: "PostRecordingCoordinatorSendTests.cli.\(#function)")!
        suite.removePersistentDomain(forName: "PostRecordingCoordinatorSendTests.cli.\(#function)")
        let key = "PostRecordingCoordinatorSendTests.cli.\(#function).apiKey"
        KeychainHelper.delete(key: key)
        let llm = LLMSettings(defaults: suite, apiKeyKeychainKey: key)
        llm.tool = .claude

        var capturedModel: String? = "SENTINEL"
        var callCount = 0
        let cliCoordinator = PostRecordingCoordinator(
            store: store, transcription: service, llm: llm,
            runLLM: { _, _, _, _, _, model, _, _, _, _, _, _, _, _ in
                capturedModel = model
                callCount += 1
                return "CLI ANSWER"
            })

        let rec = addCompletedRecording(text: "the transcript text")
        cliCoordinator.sendToLLM(recordingID: rec.id,
                                 tool: .claude,
                                 prompt: "Summarize",
                                 transcript: "the transcript text",
                                 summary: "",
                                 executableOverride: nil)
        try await waitFor(callCount > 0)
        XCTAssertNil(capturedModel,
                     "The CLI path must leave model nil (the CLI chooses its own)")
    }

    // MARK: - Transcript delivery (issue #179)

    /// With the setting on, the send must hand the runner the recording's own
    /// sidecars rather than the transcript body. The paths have to come from the
    /// store — the sheets that call `sendToLLM` only ever pass text, so if the
    /// coordinator didn't derive them nothing would.
    func test_sendToLLM_references_the_recordings_sidecars_when_enabled() async throws {
        let suite = UserDefaults(suiteName: "PostRecordingCoordinatorSendTests.byPath.\(#function)")!
        suite.removePersistentDomain(forName: "PostRecordingCoordinatorSendTests.byPath.\(#function)")
        let llm = LLMSettings(defaults: suite,
                              apiKeyKeychainKey: "PostRecordingCoordinatorSendTests.byPath.\(#function)")
        llm.tool = .claude
        llm.actionTranscriptByPath = true

        var captured: TranscriptDelivery?
        var callCount = 0
        let coordinator = PostRecordingCoordinator(
            store: store, transcription: service, llm: llm,
            runLLM: { _, _, _, _, _, _, _, _, _, _, _, _, _, delivery in
                captured = delivery
                callCount += 1
                return "ANSWER"
            })

        let rec = addCompletedRecording(text: "the transcript text")
        // `store.add` writes the `.txt`; the `.srt` is written by the
        // transcription pass, which the stub engine never runs here.
        let srt = store.subtitleURL(for: rec)
        try "1\n00:00:01,000 --> 00:00:04,000\nSPEAKER_00: hello\n\n"
            .write(to: srt, atomically: true, encoding: .utf8)

        coordinator.sendToLLM(recordingID: rec.id,
                              tool: .claude,
                              prompt: "File this",
                              transcript: "the transcript text",
                              summary: "",
                              executableOverride: nil)
        try await waitFor(callCount > 0)

        guard case .reference(let files) = captured else {
            return XCTFail("expected a reference delivery, got \(String(describing: captured))")
        }
        XCTAssertEqual(files.subtitles, srt)
        XCTAssertEqual(files.plainText, store.transcriptURL(for: rec))
        XCTAssertEqual(files.audio, store.audioURL(for: rec))
    }

    /// Off by default (#179's first constraint), so an untouched install keeps
    /// inlining exactly as it did before.
    func test_sendToLLM_inlines_by_default() async throws {
        var captured: TranscriptDelivery?
        var callCount = 0
        let coordinator = PostRecordingCoordinator(
            store: store, transcription: service,
            llm: LLMSettings(defaults: UserDefaults(suiteName: "PostRecordingCoordinatorSendTests.inline.\(#function)")!,
                             apiKeyKeychainKey: "PostRecordingCoordinatorSendTests.inline.\(#function)"),
            runLLM: { _, _, _, _, _, _, _, _, _, _, _, _, _, delivery in
                captured = delivery
                callCount += 1
                return "ANSWER"
            })

        let rec = addCompletedRecording(text: "the transcript text")
        coordinator.sendToLLM(recordingID: rec.id,
                              tool: .claude,
                              prompt: "Summarize",
                              transcript: "the transcript text",
                              summary: "",
                              executableOverride: nil)
        try await waitFor(callCount > 0)

        XCTAssertEqual(captured, .inline)
    }

    /// The recording was discarded while the send was waiting for its
    /// transcript, so there is nothing left to reference. Inline is the safe
    /// answer — it is what the runner would fall back to anyway.
    func test_sendToLLM_inlines_when_the_recording_is_gone() async throws {
        let suite = UserDefaults(suiteName: "PostRecordingCoordinatorSendTests.gone.\(#function)")!
        suite.removePersistentDomain(forName: "PostRecordingCoordinatorSendTests.gone.\(#function)")
        let llm = LLMSettings(defaults: suite,
                              apiKeyKeychainKey: "PostRecordingCoordinatorSendTests.gone.\(#function)")
        llm.tool = .claude
        llm.actionTranscriptByPath = true

        var captured: TranscriptDelivery?
        var callCount = 0
        let coordinator = PostRecordingCoordinator(
            store: store, transcription: service, llm: llm,
            runLLM: { _, _, _, _, _, _, _, _, _, _, _, _, _, delivery in
                captured = delivery
                callCount += 1
                return "ANSWER"
            })

        coordinator.sendToLLM(recordingID: UUID(),
                              tool: .claude,
                              prompt: "Summarize",
                              // Non-empty, so the send doesn't stall in
                              // `awaitTranscript` looking for a recording that
                              // was never in the store.
                              transcript: "the transcript text",
                              summary: "",
                              executableOverride: nil)
        try await waitFor(callCount > 0)

        XCTAssertEqual(captured, .inline)
    }

    /// The title path is deliberately excluded from path delivery: it runs
    /// unattended on every recording, so a CLI that skipped the read would
    /// quietly title everything from a prompt with no transcript in it.
    func test_auto_title_always_inlines() async throws {
        let suite = UserDefaults(suiteName: "PostRecordingCoordinatorSendTests.title.\(#function)")!
        suite.removePersistentDomain(forName: "PostRecordingCoordinatorSendTests.title.\(#function)")
        let llm = LLMSettings(defaults: suite,
                              apiKeyKeychainKey: "PostRecordingCoordinatorSendTests.title.\(#function)")
        llm.tool = .claude
        llm.nameGenerationEnabled = true
        llm.actionTranscriptByPath = true

        var captured: TranscriptDelivery?
        var callCount = 0
        let coordinator = PostRecordingCoordinator(
            store: store, transcription: service, llm: llm,
            runLLM: { _, _, _, _, _, _, _, _, _, _, _, _, _, delivery in
                captured = delivery
                callCount += 1
                return "A Tidy Title"
            })

        coordinator.present(addCompletedRecording(text: "the transcript text"))
        try await waitFor(callCount > 0)

        XCTAssertEqual(captured, .inline)
    }

    /// A recording saved under a meeting name the user typed must not be
    /// auto-titled: the baseline guard in `applyAutoSuggestedTitle` can't
    /// protect it (the baseline IS the user's title), so the CLI suggestion
    /// would replace the name they chose.
    func test_present_skips_auto_title_when_the_user_named_the_recording() async throws {
        let suite = UserDefaults(suiteName: "PostRecordingCoordinatorSendTests.named.\(#function)")!
        suite.removePersistentDomain(forName: "PostRecordingCoordinatorSendTests.named.\(#function)")
        let llm = LLMSettings(defaults: suite,
                              apiKeyKeychainKey: "PostRecordingCoordinatorSendTests.named.\(#function)")
        llm.tool = .claude
        llm.nameGenerationEnabled = true

        var callCount = 0
        let coordinator = PostRecordingCoordinator(
            store: store, transcription: service, llm: llm,
            runLLM: { _, _, _, _, _, _, _, _, _, _, _, _, _, _ in
                callCount += 1
                return "An LLM Title"
            })

        var rec = addCompletedRecording(text: "the transcript text")
        rec.title = "Weekly Sync"
        store.update(rec)

        coordinator.present(rec, titleWasUserProvided: true)
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(callCount, 0, "the auto-title CLI must not run for a user-named recording")
        XCTAssertEqual(store.recordings.first(where: { $0.id == rec.id })?.title, "Weekly Sync")
        XCTAssertFalse(coordinator.autoSuggestingIDs.contains(rec.id))
    }

    /// Discard has to reach the vault, not just the store. Covers the wiring
    /// `MilaApp` installs — without it the coordinator deletes the recording
    /// and leaves its exported note behind.
    func test_cancelAndDiscard_removes_the_obsidian_note() async throws {
        let vault = tempRoot.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let suite = "PostRecordingCoordinatorSendTests.obsidian.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let settings = ObsidianVaultSettings(defaults: defaults)
        settings.enabled = true
        settings.subfolder = ""
        XCTAssertTrue(settings.setVault(vault))
        let exporter = ObsidianExporter(settings: settings, defaults: defaults)
        coordinator.obsidianExporter = exporter

        let rec = addCompletedRecording(text: "the transcript text")
        let note = try XCTUnwrap(exporter.export(rec), "precondition: the note was written")
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path))

        coordinator.present(rec)
        coordinator.cancelAndDiscard()

        XCTAssertTrue(store.recordings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.path),
                       "discarding the recording must take its note out of the vault")
    }

    // MARK: - Helpers

    /// Wait up to `timeoutSeconds` (default 5) for `condition` to hold, polling
    /// every 50 ms. Fails the test on timeout — used by the OpenAI seam tests.
    private func waitFor(_ condition: @autoclosure () async -> Bool,
                         timeoutSeconds: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting on an injected runLLM stub to fire")
    }

    /// Add a `.completed` recording with the given transcript text, with a
    /// placeholder audio file so `RecordingStore.add` is happy. `segments` /
    /// `speakerNames` let a test stage a diarized row — the shape the issue
    /// #211 tests need.
    private func addCompletedRecording(text: String,
                                       segments: [TranscriptSegment] = [],
                                       speakerNames: [String: String] = [:]) -> Recording {
        let audioURL = store.freshAudioURL(suggestedName: "Send")
        try? Data("not-audio".utf8).write(to: audioURL)
        var rec = Recording(title: "Send", source: .microphone,
                            audioFileName: audioURL.lastPathComponent,
                            fullText: text)
        rec.status = .completed
        rec.segments = segments
        rec.speakerNames = speakerNames
        store.add(rec)
        return rec
    }

    /// One utterance, labeled by the diarizer.
    private func seg(_ start: Double, _ end: Double,
                     _ text: String, _ speaker: String) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: text, speaker: speaker)
    }

    /// A coordinator with an injected `runLLM` seam, so the assertions can
    /// read exactly what the CLI would have been handed without spawning one.
    private func makeCoordinator(
        label: String,
        runLLM: @escaping PostRecordingCoordinator.RunLLM
    ) -> PostRecordingCoordinator {
        let suiteName = "PostRecordingCoordinatorSendTests.\(label)"
        UserDefaults().removePersistentDomain(forName: suiteName)
        let llm = LLMSettings(defaults: UserDefaults(suiteName: suiteName)!,
                              apiKeyKeychainKey: suiteName)
        llm.tool = .claude
        let made = PostRecordingCoordinator(store: store, transcription: service,
                                            llm: llm, runLLM: runLLM)
        // Same bound as the setUp coordinator — see `testTranscriptWait`.
        // These coordinators are the ones that deliberately park in
        // `awaitSpeakerFinalization`, so they are the ones most exposed to the
        // 600s production default outliving CI's 240s per-test allowance.
        // Cases that want a shorter wait still override it after this.
        made.transcriptWaitTimeout = Self.testTranscriptWait
        return made
    }

    private func waitForBanner(containing needle: String,
                               timeoutSeconds: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let status = coordinator.activityStatus, status.contains(needle) {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for banner containing \"\(needle)\" (was: \(coordinator.activityStatus ?? "nil"))")
    }

    private func makeScript(_ body: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mila-send-test-\(UUID().uuidString).sh")
        try? body.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
        return url
    }
}
