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
                              text: String = "an earlier, complete transcript") throws -> UUID {
        let fixture = try TestRecordingFixture.make(in: store, title: title, language: language)
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
                try await SpeakerDiarizer.runPython(path: "/bin/sh", arguments: ["-c", "sleep 30"])
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
