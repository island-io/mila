import XCTest
import TranscriptionCore
@testable import Mila

/// "Stop Transcribing" (`TranscriptionService.deferTranscription(of:)` +
/// `RecordingStore.markTranscriptionDeferred`): take a batch transcription off
/// the CPU now, keep the recording, run it later.
///
/// What it has to guarantee, and what each test pins:
///  * the run actually stops — queued ones never reach whisper, an active one
///    aborts — and the diarization subprocess goes with it
///    (`withPolledCancellation`, the half the polled stop flag never reached);
///  * the recording stays in the library, readable as "stopped" rather than
///    "failed", and in a state the launch recovery sweep leaves alone;
///  * starting it again later works the FIRST time: no cancellation flag may
///    outlive the run it was meant for (`process` silently skips a flagged id);
///  * nothing happens when there is no run to stop, so a click can't park a
///    row that `stopRecording` is still finalizing.
@MainActor
final class TranscriptionDeferralTests: XCTestCase {

    private let suitePrefix = "TranscriptionDeferralTests"

    private var tempRoot: URL!
    private var store: RecordingStore!
    private var stub: StubWhisperEngine!
    private var service: TranscriptionService!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: suitePrefix)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = RecordingStore(rootDirectory: tempRoot)
        let manager = TestSupport.isolatedModelManager(
            modelsDirectory: tempRoot.appendingPathComponent("Models"),
            label: suitePrefix)
        try TestSupport.installFakeModel(into: manager)
        stub = StubWhisperEngine()
        service = TranscriptionService(
            store: store,
            modelManager: manager,
            diarizationSettings: DiarizationSettings(
                defaults: .init(suiteName: "\(suitePrefix).diarization")!),
            remoteSettings: TestSupport.isolatedRemoteSettings(label: suitePrefix),
            engine: stub)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        UserDefaults().removePersistentDomain(forName: "\(suitePrefix).diarization")
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func row(_ id: UUID) throws -> Recording {
        try XCTUnwrap(store.recordings.first { $0.id == id })
    }

    private func waitUntilActive(_ id: UUID, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(5)
        while service.activeRecordingID != id && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(service.activeRecordingID, id, "precondition: the run started", file: file, line: line)
    }

    /// Wait until whisper has actually been entered, so a stop lands in the
    /// abort-callback window rather than the model-load one (which
    /// `test_a_stop_during_the_model_load_never_starts_whisper` covers).
    /// `activeRecordingID` alone is published before the load.
    private func waitUntilWhisperStarted(calls expected: Int = 1,
                                         file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(5)
        var count = await stub.transcribeCalls.count
        while count < expected && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
            count = await stub.transcribeCalls.count
        }
        XCTAssertEqual(count, expected, "precondition: whisper started", file: file, line: line)
    }

    /// A finished recording: `.completed`, with a transcript, in `language`.
    private func makeFinished(_ title: String, language: String = "en",
                              text: String = "an earlier, complete transcript",
                              durationSeconds: Double = 0.5) throws -> UUID {
        let fixture = try TestRecordingFixture.make(in: store, title: title,
                                                    durationSeconds: durationSeconds,
                                                    language: language)
        var finished = try row(fixture.recording.id)
        finished.status = .completed
        finished.modelName = "Earlier model"
        finished.fullText = text
        finished.segments = [TranscriptSegment(start: 0, end: 1, text: text)]
        store.update(finished)
        return fixture.recording.id
    }

    private struct LoadFailure: Error {}

    /// The ordinary Transcribe action, exactly as the detail view and context
    /// menu run it.
    private func transcribeAgain(_ id: UUID) {
        guard let prepared = store.prepareForRetranscription(id: id) else {
            return XCTFail("recording vanished")
        }
        service.enqueue(prepared, isRetranscription: true)
    }

    private func assertParkedAsStopped(_ id: UUID, file: StaticString = #filePath, line: UInt = #line) throws {
        let stopped = try row(id)
        XCTAssertEqual(stopped.status, .failed,
                       "must leave .pending/.running, or the Queue keeps it and the launch sweep restarts it",
                       file: file, line: line)
        XCTAssertNotNil(stopped.transcriptionDeferredAt, "must read as stopped, not failed", file: file, line: line)
        XCTAssertFalse(stopped.isTrashed, "Stop Transcribing keeps the recording in the library", file: file, line: line)
        XCTAssertEqual(MilaApp.recoveryAction(status: stopped.status, wavExists: true), .leaveAlone,
                       "the launch recovery sweep must not restart a stopped transcription",
                       file: file, line: line)
    }

    // MARK: - Stopping

    func test_stopping_a_queued_recording_keeps_it_and_never_runs_whisper_on_it() async throws {
        let blocker = try TestRecordingFixture.make(in: store, title: "Blocker")
        let target = try TestRecordingFixture.make(in: store, title: "Later")
        await stub.setDefaultDelay(0.4)
        service.enqueue(blocker.recording)
        service.enqueue(target.recording)
        await waitUntilActive(blocker.recording.id)
        XCTAssertEqual(service.pendingIDs, [target.recording.id])

        XCTAssertTrue(service.deferTranscription(of: target.recording.id))
        XCTAssertTrue(service.pendingIDs.isEmpty, "a stopped item must leave the queue at once")
        await service.waitForIdle()

        let calls = await stub.transcribeCalls
        XCTAssertEqual(calls.count, 1, "only the blocker may reach whisper")
        try assertParkedAsStopped(target.recording.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.audioURL.path),
                      "the audio stays for the later run")
    }

    func test_stopping_the_active_run_aborts_it_and_the_pass_does_not_overwrite_the_stop() async throws {
        let target = try TestRecordingFixture.make(in: store, title: "Mid-run")
        await stub.setDefaultDelay(0.8)
        service.enqueue(target.recording)
        await waitUntilActive(target.recording.id)
        await waitUntilWhisperStarted()

        XCTAssertTrue(service.deferTranscription(of: target.recording.id))
        await service.waitForIdle()

        XCTAssertNil(service.activeRecordingID)
        XCTAssertTrue(try row(target.recording.id).fullText.isEmpty,
                      "the aborted pass must not have written a transcript")
        try assertParkedAsStopped(target.recording.id)
        XCTAssertNil(service.lastError, "a user's stop is not an error to surface")
    }

    /// The model load is not interruptible (a first CoreML compile takes
    /// ~13 s). A stop that lands during it must still keep whisper and
    /// pyannote from starting afterwards — and must not reach the too-short
    /// branch, which writes `.failed` without the marker and can auto-drop the
    /// recording outright.
    func test_a_stop_during_the_model_load_never_starts_whisper() async throws {
        let target = try TestRecordingFixture.make(in: store, title: "Loading")
        await stub.setLoadDelay(0.6)
        service.enqueue(target.recording)
        await waitUntilActive(target.recording.id)

        XCTAssertTrue(service.deferTranscription(of: target.recording.id))
        // The load can't be interrupted, so the run is still active for a
        // while: the UI must read "Stopping…" and offer no second Stop.
        XCTAssertEqual(service.stoppingRecordingID, target.recording.id)
        XCTAssertFalse(service.isQueuedOrActive(target.recording.id),
                       "a run that is already stopping has nothing left to stop")
        await service.waitForIdle()

        XCTAssertNil(service.stoppingRecordingID, "cleared once the run has unwound")
        let calls = await stub.transcribeCalls
        XCTAssertTrue(calls.isEmpty, "whisper must not start after a stop that landed during the model load")
        try assertParkedAsStopped(target.recording.id)
    }

    /// A stopped run can still fail for an unrelated reason before it notices
    /// the stop (here: the model load throws). It was stopped all the same —
    /// no error banner, and the status the stop settled must stand.
    func test_a_stopped_run_that_then_fails_is_not_reported_as_failed() async throws {
        let target = try TestRecordingFixture.make(in: store, title: "Stop then fail")
        await stub.setLoadDelay(0.6)
        await stub.setLoadError(LoadFailure())
        service.enqueue(target.recording)
        await waitUntilActive(target.recording.id)

        XCTAssertTrue(service.deferTranscription(of: target.recording.id))
        await service.waitForIdle()

        XCTAssertNil(service.lastError, "the user stopped it — there is no failure to report")
        try assertParkedAsStopped(target.recording.id)
    }

    /// Same, for a re-run of a finished recording: the error must not demote
    /// the transcript the stop just restored.
    func test_a_stopped_rerun_that_then_fails_keeps_its_finished_transcript() async throws {
        let id = try makeFinished("Rerun then fail")
        await stub.setLoadDelay(0.6)
        await stub.setLoadError(LoadFailure())
        transcribeAgain(id)
        await waitUntilActive(id)

        XCTAssertTrue(service.deferTranscription(of: id))
        await service.waitForIdle()

        XCTAssertNil(service.lastError)
        XCTAssertEqual(try row(id).status, .completed)
    }

    // MARK: - Transcribing later

    /// The point of the feature: stop now, Transcribe later, and it runs —
    /// the first time. A cancellation flag left behind by the stop would make
    /// `process` silently skip this run and strand the row as `.pending`.
    func test_a_stopped_active_run_transcribes_on_the_first_try_later() async throws {
        let target = try TestRecordingFixture.make(in: store, title: "Resume")
        await stub.setDefaultDelay(0.8)
        service.enqueue(target.recording)
        await waitUntilActive(target.recording.id)
        await waitUntilWhisperStarted()
        service.deferTranscription(of: target.recording.id)
        await service.waitForIdle()
        try assertParkedAsStopped(target.recording.id)

        await stub.setDefaultDelay(0)
        transcribeAgain(target.recording.id)
        await service.waitForIdle()

        let done = try row(target.recording.id)
        XCTAssertEqual(done.status, .completed, "the later run must actually run")
        XCTAssertFalse(done.fullText.isEmpty)
        XCTAssertNil(done.transcriptionDeferredAt, "a finished run no longer reads as stopped")
        let calls = await stub.transcribeCalls
        XCTAssertEqual(calls.count, 2, "one aborted pass, one real one")
    }

    /// Transcribe clicked while the stopped run is still unwinding — the
    /// "Stopping…" window, which lasts until whisper notices the abort flag
    /// (or for the whole model load, which cannot be interrupted). `enqueue`
    /// used to see the unwinding run as "already in flight" and drop the
    /// request silently, leaving the row `.pending` and unqueued until a
    /// second click. It is queued behind the stop instead, and runs once the
    /// stop has completed.
    func test_transcribe_during_stopping_is_queued_behind_the_stop_and_runs() async throws {
        let target = try TestRecordingFixture.make(in: store, title: "Eager")
        await stub.setDefaultDelay(0.8)
        service.enqueue(target.recording)
        await waitUntilActive(target.recording.id)
        await waitUntilWhisperStarted()
        service.deferTranscription(of: target.recording.id)
        XCTAssertEqual(service.stoppingRecordingID, target.recording.id, "precondition: still stopping")
        try assertParkedAsStopped(target.recording.id)

        await stub.setDefaultDelay(0)
        transcribeAgain(target.recording.id)
        XCTAssertEqual(service.pendingIDs, [target.recording.id],
                       "the request must be queued behind the stop, not dropped")
        XCTAssertTrue(service.isQueuedOrActive(target.recording.id),
                      "the re-queued run must be stoppable: it is the run Stop now addresses")

        await waitUntilWhisperStarted(calls: 2)
        await service.waitForIdle()
        let done = try row(target.recording.id)
        XCTAssertEqual(done.status, .completed, "the re-run must run without a second click")
        XCTAssertNil(done.transcriptionDeferredAt)
        XCTAssertFalse(done.fullText.isEmpty)
        XCTAssertNil(service.stoppingRecordingID)
    }

    func test_a_stopped_queued_item_transcribes_on_the_first_try_later() async throws {
        let blocker = try TestRecordingFixture.make(in: store, title: "Blocker")
        let target = try TestRecordingFixture.make(in: store, title: "Queued")
        await stub.setDefaultDelay(0.4)
        service.enqueue(blocker.recording)
        service.enqueue(target.recording)
        await waitUntilActive(blocker.recording.id)
        service.deferTranscription(of: target.recording.id)
        await service.waitForIdle()

        transcribeAgain(target.recording.id)
        await service.waitForIdle()

        XCTAssertEqual(try row(target.recording.id).status, .completed)
    }

    /// Same stale-flag trap through the EXISTING Queue Stop (cancel + move to
    /// Recently Deleted): restoring a recording that was stopped while queued
    /// and clicking Transcribe used to no-op once, because `cancel` flagged an
    /// id it had already dropped from the queue and nothing ever consumed it.
    func test_restoring_a_recording_cancelled_while_queued_transcribes_on_the_first_try() async throws {
        let blocker = try TestRecordingFixture.make(in: store, title: "Blocker")
        let target = try TestRecordingFixture.make(in: store, title: "Trashed")
        await stub.setDefaultDelay(0.4)
        service.enqueue(blocker.recording)
        service.enqueue(target.recording)
        await waitUntilActive(blocker.recording.id)

        service.cancel(recordingID: target.recording.id)
        store.stopTranscription(target.recording)
        await service.waitForIdle()
        store.restore(try row(target.recording.id))

        transcribeAgain(target.recording.id)
        await service.waitForIdle()

        XCTAssertEqual(try row(target.recording.id).status, .completed,
                       "a stale cancellation flag swallowed the Transcribe")
    }

    // MARK: - Nothing to stop

    /// A `.pending` row that isn't queued is still being finalized by
    /// `stopRecording`, which enqueues it at the end and would overwrite a
    /// deferral written now. With no run to stop, the stop must do nothing.
    func test_stopping_with_no_run_to_stop_changes_nothing() throws {
        let idle = try TestRecordingFixture.make(in: store, title: "Finalizing")
        XCTAssertFalse(service.deferTranscription(of: idle.recording.id))
        let untouched = try row(idle.recording.id)
        XCTAssertEqual(untouched.status, .pending)
        XCTAssertNil(untouched.transcriptionDeferredAt)
    }

    // MARK: - Store semantics

    func test_stopping_a_retranscription_keeps_the_existing_transcript_completed() throws {
        let id = try makeFinished("Done before")
        _ = store.prepareForRetranscription(id: id)

        store.markTranscriptionDeferred(id)

        let kept = try row(id)
        XCTAssertEqual(kept.status, .completed,
                       "stopping a re-run must not demote a transcript that is still whole")
        XCTAssertNil(kept.transcriptionDeferredAt)
        XCTAssertEqual(kept.fullText, "an earlier, complete transcript")
    }

    /// "Re-transcribe in Hebrew" on an English recording, stopped mid-pass:
    /// the English transcript stays, so everything describing it has to go
    /// back too — or the English text renders right-to-left with Hebrew
    /// speaker labels, MCP reports it as Hebrew, and "Re-transcribe
    /// (current)" re-runs the Hebrew pass the user just stopped.
    func test_stopping_a_rerun_in_the_other_language_restores_the_language_and_model() async throws {
        let id = try makeFinished("English meeting", language: "en")
        await stub.setDefaultDelay(0.8)
        guard let prepared = store.prepareForRetranscription(id: id, language: "he") else {
            return XCTFail("recording vanished")
        }
        service.enqueue(prepared, isRetranscription: true)
        await waitUntilActive(id)
        await waitUntilWhisperStarted()
        XCTAssertNotEqual(try row(id).modelName, "Earlier model",
                          "precondition: the pass has already stamped its own model on the row")

        XCTAssertTrue(service.deferTranscription(of: id))
        await service.waitForIdle()

        let restored = try row(id)
        XCTAssertEqual(restored.status, .completed)
        XCTAssertEqual(restored.language, "en", "the kept transcript is English")
        XCTAssertEqual(restored.modelName, "Earlier model", "…and was made by the earlier model")
        XCTAssertEqual(restored.fullText, "an earlier, complete transcript")
    }

    /// The same stop, after a relaunch (island-io/mila#320). The re-run was
    /// set up, the app quit before it finished, and the launch sweep handed
    /// the `.pending` row straight back to a fresh worker — nothing in the new
    /// process called `prepareForRetranscription`. What the row looked like
    /// before the re-run therefore has to come off the row itself.
    func test_stopping_a_rerun_after_a_relaunch_still_restores_the_language_and_model() async throws {
        let id = try makeFinished("English meeting", language: "en")
        _ = try XCTUnwrap(store.prepareForRetranscription(id: id, language: "he"))
        // Quit mid-pass: the interrupted pass had already moved the row to
        // `.running` and stamped its own model on it.
        var stamped = try row(id)
        stamped.status = .running
        stamped.modelName = "Re-run model"
        store.update(stamped)

        // Relaunch: a fresh store and service over the same directory.
        let relaunchedStore = RecordingStore(rootDirectory: tempRoot)
        let manager = TestSupport.isolatedModelManager(
            modelsDirectory: tempRoot.appendingPathComponent("Models"),
            label: "\(suitePrefix).relaunch")
        try TestSupport.installFakeModel(into: manager)
        let relaunchedStub = StubWhisperEngine()
        await relaunchedStub.setDefaultDelay(0.8)
        let relaunchedService = TranscriptionService(
            store: relaunchedStore,
            modelManager: manager,
            diarizationSettings: DiarizationSettings(
                defaults: .init(suiteName: "\(suitePrefix).diarization")!),
            remoteSettings: TestSupport.isolatedRemoteSettings(label: "\(suitePrefix).relaunch"),
            engine: relaunchedStub)
        let reloaded = try XCTUnwrap(relaunchedStore.recordings.first { $0.id == id })
        XCTAssertEqual(reloaded.status, .running, "precondition: the sweep finds a re-run to resume")
        XCTAssertEqual(reloaded.language, "he")
        XCTAssertEqual(MilaApp.recoveryAction(status: reloaded.status, wavExists: true), .reenqueue)

        // As `enqueueRecoveredRecordings` does: `.running` reset to
        // `.pending` from a snapshot, written back with `updateAll`, then
        // straight to the worker as a re-transcription — never through
        // `prepareForRetranscription`. Behind another job so the stop finds
        // it queued.
        var fixed = reloaded
        fixed.status = .pending
        relaunchedStore.updateAll([fixed])
        let blocker = try TestRecordingFixture.make(in: relaunchedStore, title: "Blocker")
        relaunchedService.enqueue(blocker.recording)
        relaunchedService.enqueue(fixed, isRetranscription: true)
        XCTAssertTrue(relaunchedService.deferTranscription(of: id))
        await relaunchedService.waitForIdle()

        let restored = try XCTUnwrap(relaunchedStore.recordings.first { $0.id == id })
        XCTAssertEqual(restored.status, .completed, "the kept transcript is still a finished one")
        XCTAssertNil(restored.transcriptionDeferredAt)
        XCTAssertEqual(restored.language, "en", "the kept transcript is English")
        XCTAssertEqual(restored.modelName, "Earlier model", "…and was made by the earlier model")
        XCTAssertNil(restored.retranscriptionPriorState, "consumed by the stop")
        XCTAssertNil(RecordingStore(rootDirectory: tempRoot).recordings
                        .first { $0.id == id }?.retranscriptionPriorState,
                     "…and the consumption is persisted")
    }

    /// A re-run that finishes leaves nothing to undo, so it must not leave the
    /// prior state behind on the row.
    func test_a_finished_rerun_clears_the_prior_state() async throws {
        let id = try makeFinished("English meeting", language: "en")
        guard let prepared = store.prepareForRetranscription(id: id, language: "he") else {
            return XCTFail("recording vanished")
        }
        XCTAssertNotNil(try row(id).retranscriptionPriorState, "precondition: captured")
        service.enqueue(prepared, isRetranscription: true)
        await service.waitForIdle()

        XCTAssertEqual(try row(id).status, .completed)
        XCTAssertNil(try row(id).retranscriptionPriorState)
    }

    /// A re-run in the other language that FAILS, rather than being stopped
    /// (island-io/mila#330). The pass produced nothing, so the English
    /// transcript is still there and the re-run is undone as a stop undoes
    /// it: English, by the earlier model, still `.completed` (demoting an
    /// intact transcript would switch off SRT, summaries and the MCP "latest
    /// recording"). The failure is reported through `lastError`.
    func test_a_failed_rerun_in_the_other_language_restores_the_finished_transcript() async throws {
        let id = try makeFinished("English meeting", language: "en")
        await stub.setNextError(LoadFailure())
        guard let prepared = store.prepareForRetranscription(id: id, language: "he") else {
            return XCTFail("recording vanished")
        }
        service.enqueue(prepared, isRetranscription: true)
        await service.waitForIdle()

        XCTAssertNotNil(service.lastError, "a genuine failure is still reported")
        let restored = try row(id)
        XCTAssertEqual(restored.status, .completed, "the kept transcript is still a finished one")
        XCTAssertNil(restored.transcriptionDeferredAt)
        XCTAssertEqual(restored.language, "en", "the kept transcript is English")
        XCTAssertEqual(restored.modelName, "Earlier model", "…and was made by the earlier model")
        XCTAssertEqual(restored.fullText, "an earlier, complete transcript")
        XCTAssertNil(restored.retranscriptionPriorState, "settled: nothing left to undo")
        XCTAssertNil(RecordingStore(rootDirectory: tempRoot).recordings
                        .first { $0.id == id }?.retranscriptionPriorState,
                     "…and the consumption is persisted")
    }

    // MARK: - Re-runs that produce no usable text

    /// What a re-run that produced nothing usable must leave behind: the
    /// earlier English transcript, exactly as it was, with the status,
    /// language and model that describe it — the same undo a failed re-run
    /// gets — and no completion work (SRT, summary regeneration) for a
    /// transcript that did not change. The reason goes to `lastError`.
    private func assertEarlierTranscriptKept(_ id: UUID, completions: Int,
                                             file: StaticString = #filePath, line: UInt = #line) throws {
        let kept = try row(id)
        XCTAssertEqual(kept.fullText, "an earlier, complete transcript",
                       "an empty re-run must not replace the transcript", file: file, line: line)
        XCTAssertEqual(kept.segments.map(\.text), ["an earlier, complete transcript"], file: file, line: line)
        XCTAssertEqual(kept.speakerNames, ["SPEAKER_00": "Dana"], file: file, line: line)
        XCTAssertEqual(kept.status, .completed, "the kept transcript is still a finished one", file: file, line: line)
        XCTAssertEqual(kept.language, "en", "the kept transcript is English", file: file, line: line)
        XCTAssertEqual(kept.modelName, "Earlier model", file: file, line: line)
        XCTAssertNil(kept.transcriptionDeferredAt, file: file, line: line)
        XCTAssertNil(kept.retranscriptionPriorState, "settled: nothing left to undo", file: file, line: line)
        XCTAssertTrue(service.lastError?.contains("earlier transcript was kept") == true,
                      "the user asked for this run, so it says why nothing changed: \(service.lastError ?? "nil")",
                      file: file, line: line)
        XCTAssertEqual(completions, 0, "no completion work for a transcript that did not change",
                       file: file, line: line)
        let reloaded = try XCTUnwrap(RecordingStore(rootDirectory: tempRoot).recordings.first { $0.id == id },
                                     file: file, line: line)
        XCTAssertEqual(reloaded.fullText, "an earlier, complete transcript", "…and that is what is persisted",
                       file: file, line: line)
        XCTAssertEqual(reloaded.language, "en", file: file, line: line)
        XCTAssertNil(reloaded.retranscriptionPriorState, file: file, line: line)
    }

    private func nameSpeaker(_ id: UUID) throws {
        var named = try row(id)
        named.speakerNames = ["SPEAKER_00": "Dana"]
        store.update(named)
    }

    func test_a_rerun_that_returns_no_text_keeps_the_earlier_transcript() async throws {
        let id = try makeFinished("English meeting", language: "en")
        try nameSpeaker(id)
        // Whitespace-only segments: no text, but not an empty segment list
        // either — the pass must not keep them or re-key the speaker names.
        await stub.setCannedQueue([[TranscriptSegment(start: 0, end: 1, text: "  ")]])
        var completions = 0
        service.onTranscriptionCompleted = { _, _ in completions += 1 }
        guard let prepared = store.prepareForRetranscription(id: id, language: "he") else {
            return XCTFail("recording vanished")
        }
        service.enqueue(prepared, isRetranscription: true)
        await service.waitForIdle()

        let calls = await stub.transcribeCalls
        XCTAssertEqual(calls.count, 1, "precondition: whisper ran and came back empty")
        try assertEarlierTranscriptKept(id, completions: completions)
    }

    func test_a_rerun_whose_audio_is_rejected_keeps_the_earlier_transcript() async throws {
        // Under `minimumAudioDurationSeconds`: rejected before whisper.
        let id = try makeFinished("English meeting", language: "en", durationSeconds: 0.1)
        try nameSpeaker(id)
        var completions = 0
        service.onTranscriptionCompleted = { _, _ in completions += 1 }
        guard let prepared = store.prepareForRetranscription(id: id, language: "he") else {
            return XCTFail("recording vanished")
        }
        service.enqueue(prepared, isRetranscription: true)
        await service.waitForIdle()

        let calls = await stub.transcribeCalls
        XCTAssertEqual(calls.count, 0, "precondition: the audio was rejected before whisper")
        try assertEarlierTranscriptKept(id, completions: completions)
    }

    /// Sent to Recently Deleted mid-pass: still settled back to the kept
    /// transcript (so a restore is not empty), but no alert about a
    /// recording the user just threw away.
    func test_an_empty_rerun_of_a_trashed_recording_keeps_the_transcript_without_an_alert() async throws {
        let id = try makeFinished("English meeting", language: "en")
        await stub.setCannedQueue([[]])
        await stub.setDefaultDelay(0.4)
        guard let prepared = store.prepareForRetranscription(id: id, language: "he") else {
            return XCTFail("recording vanished")
        }
        service.enqueue(prepared, isRetranscription: true)
        await waitUntilWhisperStarted()
        store.softDelete(try row(id))
        await service.waitForIdle()

        let kept = try row(id)
        XCTAssertTrue(kept.isTrashed)
        XCTAssertEqual(kept.fullText, "an earlier, complete transcript")
        XCTAssertEqual(kept.status, .completed)
        XCTAssertEqual(kept.language, "en")
        XCTAssertNil(service.lastError)
    }

    /// A FIRST transcription that comes back empty is unchanged: `.failed`,
    /// no transcript, and no alert (it runs in the background).
    func test_a_first_transcription_with_no_text_still_fails_quietly() async throws {
        let fixture = try TestRecordingFixture.make(in: store, title: "Fresh", source: .systemAudio)
        await stub.setCannedQueue([[]])
        service.enqueue(fixture.recording)
        await service.waitForIdle()

        let failed = try row(fixture.recording.id)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.fullText, "")
        XCTAssertNil(service.lastError)
    }

    /// `settleFailedPass` undoes only an in-flight re-run whose earlier
    /// transcript is still there, and consumes the prior state in every case.
    func test_settling_a_failed_pass_undoes_only_a_rerun_with_a_kept_transcript() {
        let before = Recording.RetranscriptionPriorState(
            status: .completed, language: "en", modelName: "Earlier model", transcriptionDeferredAt: nil)
        var rerun = Recording(title: "t", source: .microphone, audioFileName: "t.wav",
                              status: .running, language: "he", modelName: "Re-run model",
                              fullText: "an earlier transcript", retranscriptionPriorState: before)
        XCTAssertTrue(rerun.isRetranscriptionInFlight)
        XCTAssertEqual(rerun.transcriptLanguage, "en", "the text on the row is still the English one")

        // A stale prior state on a settled row describes nothing.
        var settled = rerun
        settled.status = .completed
        XCTAssertFalse(settled.isRetranscriptionInFlight)
        XCTAssertEqual(settled.transcriptLanguage, "he")
        XCTAssertFalse(settled.restoreRetranscriptionPriorState())
        XCTAssertEqual(settled.language, "he")

        var noTranscript = rerun
        noTranscript.fullText = ""
        noTranscript.settleFailedPass()
        XCTAssertEqual(noTranscript.status, .failed)
        XCTAssertEqual(noTranscript.language, "he", "nothing kept for the earlier labels to describe")
        XCTAssertNil(noTranscript.retranscriptionPriorState)

        var firstPass = rerun
        firstPass.retranscriptionPriorState = nil
        firstPass.settleFailedPass()
        XCTAssertEqual(firstPass.status, .failed)
        XCTAssertEqual(firstPass.language, "he")

        // A re-run of a stopped live draft goes back to reading as stopped.
        var stoppedDraft = rerun
        let stoppedAt = Date(timeIntervalSince1970: 1_700_000_000)
        stoppedDraft.retranscriptionPriorState = .init(
            status: .failed, language: "en", modelName: nil, transcriptionDeferredAt: stoppedAt)
        stoppedDraft.settleFailedPass()
        XCTAssertEqual(stoppedDraft.status, .failed)
        XCTAssertEqual(stoppedDraft.transcriptionDeferredAt, stoppedAt)
        XCTAssertEqual(stoppedDraft.language, "en")

        rerun.settleFailedPass()
        XCTAssertEqual(rerun.status, .completed)
        XCTAssertEqual(rerun.language, "en")
        XCTAssertEqual(rerun.modelName, "Earlier model")
        XCTAssertNil(rerun.retranscriptionPriorState)
    }

    /// A chunk-mode live draft waiting on its first full pass has text but was
    /// never transcribed properly. Stopping it must not pass it off as
    /// finished (`.completed` would skip the SRT/summary/compression only a
    /// finished pass triggers): it reads as stopped, and keeps its draft.
    func test_stopping_a_live_drafts_first_pass_parks_it_as_stopped_and_keeps_the_draft() async throws {
        let blocker = try TestRecordingFixture.make(in: store, title: "Blocker")
        let fixture = try TestRecordingFixture.make(in: store, title: "Draft")
        var draft = try row(fixture.recording.id)
        draft.fullText = "speakerless live draft"
        draft.segments = [TranscriptSegment(start: 0, end: 1, text: "speakerless live draft")]
        store.update(draft)
        await stub.setDefaultDelay(0.4)
        service.enqueue(blocker.recording)
        service.enqueue(try row(fixture.recording.id))   // as finalizeTail does: no prepare
        await waitUntilActive(blocker.recording.id)

        XCTAssertTrue(service.deferTranscription(of: fixture.recording.id))
        await service.waitForIdle()

        try assertParkedAsStopped(fixture.recording.id)
        XCTAssertEqual(try row(fixture.recording.id).fullText, "speakerless live draft",
                       "the draft stays visible")
    }

    func test_marking_a_finished_row_is_a_no_op() throws {
        let id = try makeFinished("Finished")
        store.markTranscriptionDeferred(id)
        XCTAssertEqual(try row(id).status, .completed,
                       "a click racing a just-finished pass must leave the finished row alone")
        XCTAssertNil(try row(id).transcriptionDeferredAt)
    }

    /// A pass keeps running after the recording is moved to Recently Deleted,
    /// and its Stop is still reachable from the trashed row's page. A stopped
    /// pass writes no status itself, so the stop has to settle the row —
    /// otherwise it stays `.running`, and the launch sweep restarts it every
    /// launch.
    func test_stopping_a_run_on_a_recording_in_recently_deleted_still_settles_it() async throws {
        let target = try TestRecordingFixture.make(in: store, title: "Trashed mid-run")
        await stub.setDefaultDelay(0.8)
        service.enqueue(target.recording)
        await waitUntilActive(target.recording.id)
        await waitUntilWhisperStarted()
        store.softDelete(try row(target.recording.id))

        XCTAssertTrue(service.deferTranscription(of: target.recording.id))
        await service.waitForIdle()

        let settled = try row(target.recording.id)
        XCTAssertTrue(settled.isTrashed, "stopping must not restore it from the trash")
        XCTAssertEqual(settled.status, .failed)
        XCTAssertNotNil(settled.transcriptionDeferredAt)
        XCTAssertEqual(MilaApp.recoveryAction(status: settled.status, wavExists: true), .leaveAlone)
    }

    func test_the_stopped_marker_survives_a_relaunch_and_transcribe_clears_it() throws {
        let fixture = try TestRecordingFixture.make(in: store, title: "Persisted")
        store.markTranscriptionDeferred(fixture.recording.id)

        let relaunched = RecordingStore(rootDirectory: tempRoot)
        let reloaded = try XCTUnwrap(relaunched.recordings.first { $0.id == fixture.recording.id })
        XCTAssertNotNil(reloaded.transcriptionDeferredAt)
        XCTAssertEqual(reloaded.status, .failed)

        let prepared = try XCTUnwrap(relaunched.prepareForRetranscription(id: fixture.recording.id))
        XCTAssertNil(prepared.transcriptionDeferredAt, "Transcribe starts the run the user put off")
        XCTAssertEqual(prepared.status, .pending)
    }

    /// Older builds decode `status` strictly and load recordings.json
    /// all-or-nothing, which is why the stop is a new optional KEY on a
    /// `.failed` row rather than a new status value. Pin both halves: the
    /// marker is an extra key, and the status is a raw value every shipped
    /// build already knows.
    func test_a_stopped_row_is_readable_by_a_build_that_predates_the_marker() throws {
        let fixture = try TestRecordingFixture.make(in: store, title: "Old reader")
        store.markTranscriptionDeferred(fixture.recording.id)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(try row(fixture.recording.id))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "failed")
        XCTAssertNotNil(object["transcriptionDeferredAt"])
    }

    // MARK: - withPolledCancellation

    func test_polled_cancellation_returns_the_operation_value_when_not_stopped() async throws {
        let value = try await TranscriptionService.withPolledCancellation(
            every: .milliseconds(20),
            isCancelled: { false }
        ) { 42 }
        XCTAssertEqual(value, 42)
    }

    /// The bridge that makes Stop reach pyannote: the batch pass's stop is a
    /// polled flag, the diarization subprocess only dies on task
    /// cancellation. Exercised against a real subprocess through the same
    /// `runPython` the diarizer uses — a 30 s `sleep` standing in for a long
    /// pyannote pass.
    func test_polled_cancellation_terminates_a_running_subprocess_promptly() async throws {
        let flag = CancellationFlag()
        let id = UUID()
        let run = Task {
            try await TranscriptionService.withPolledCancellation(
                every: .milliseconds(50),
                isCancelled: { flag.contains(id) }
            ) {
                // `/bin/sleep` itself, not `sh -c "sleep 30"`: the test terminates
                // the PID `runPython` spawned, and a shell that forks rather than
                // execs would die while its child kept the stdout pipe open for
                // the full 30 s.
                try await SpeakerDiarizer.runPython(path: "/bin/sleep", arguments: ["30"])
            }
        }
        try await Task.sleep(nanoseconds: 300_000_000)   // let the subprocess start

        let stoppedAt = Date()
        flag.insert(id)
        let result = await run.result
        let elapsed = Date().timeIntervalSince(stoppedAt)

        switch result {
        case .success(let r):
            XCTFail("expected a stop, but the subprocess ran to completion (exit \(r.exitCode))")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "a stop must surface as CancellationError, not \(error)")
        }
        // Generous for CI jitter; the point is seconds, not the full 30 s.
        XCTAssertLessThan(elapsed, 10, "the subprocess must be terminated, not waited out (took \(elapsed)s)")
    }
}
