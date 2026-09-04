import XCTest
import TranscriptionCore
@testable import Mila

@MainActor
final class TranscriptionServiceTests: XCTestCase {

    private var tempRoot: URL!
    private var store: RecordingStore!
    private var manager: ModelManager!
    private var stub: StubWhisperEngine!
    private var service: TranscriptionService!
    private var modelDefaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "TranscriptionServiceTests")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        store = RecordingStore(rootDirectory: tempRoot)
        UserDefaults().removePersistentDomain(forName: "TranscriptionServiceTests.models")
        modelDefaults = UserDefaults(suiteName: "TranscriptionServiceTests.models")
        manager = ModelManager(modelsDirectory: tempRoot.appendingPathComponent("Models"), defaults: modelDefaults)
        try TestSupport.installFakeModel(into: manager)

        stub = StubWhisperEngine()
        // Inject an isolated, local-backend RemoteTranscriptionSettings so the
        // service can't read `.standard` and route to a real remote endpoint
        // (which would bypass the stub). See TestSupport.isolatedRemoteSettings.
        service = TranscriptionService(
            store: store,
            modelManager: manager,
            diarizationSettings: DiarizationSettings(defaults: .init(suiteName: "TranscriptionServiceTests.diarization")!),
            remoteSettings: TestSupport.isolatedRemoteSettings(label: "TranscriptionServiceTests"),
            engine: stub)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        modelDefaults.removePersistentDomain(forName: "TranscriptionServiceTests.models")
        try await super.tearDown()
    }

    // MARK: - Remote backend error surfacing
    //
    // Regression coverage for the silent-failure bug: a remote backend with a
    // bad key (or unreachable endpoint) used to empty the live transcript with
    // NO visible error — the failure only appeared on the Stop batch pass, and
    // CI never caught it because the remote E2E suite only tested the happy
    // path against an accepting mock. These tests pin the two new guards.

    func test_probeRemoteBackendIfActive_isNoopForLocalBackend() async {
        // The default `service` uses the on-device backend. Probing must do
        // nothing — never touch the network or the Keychain, never error.
        XCTAssertNil(service.lastError)
        await service.probeRemoteBackendIfActive()
        XCTAssertNil(service.lastError, "Local backend must not be probed")
    }

    func test_probeRemoteBackendIfActive_surfacesAuthFailure() async {
        // The record-start probe must turn a 401 into an immediate, actionable
        // error instead of a blank live pane discovered 13 minutes later.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Probe401URLProtocol.self]
        let session = URLSession(configuration: config)
        let suite = UserDefaults(suiteName: "TranscriptionServiceTests.probe401")!
        suite.removePersistentDomain(forName: "TranscriptionServiceTests.probe401")
        let keychainKey = "TranscriptionServiceTests.probe401.apiKey"
        defer { KeychainHelper.delete(key: keychainKey) }
        let remote = RemoteTranscriptionSettings(
            defaults: suite, urlSession: session, apiKeyKeychainKey: keychainKey)
        remote.backend = .remote
        remote.endpoint = "https://api.openai.com/v1"
        remote.apiKey = "test-key-123"
        let svc = TranscriptionService(
            store: store, modelManager: manager,
            diarizationSettings: DiarizationSettings(defaults: .init(suiteName: "TranscriptionServiceTests.probe401.diar")!),
            remoteSettings: remote, engine: StubWhisperEngine())

        XCTAssertNil(svc.lastError)
        await svc.probeRemoteBackendIfActive()
        XCTAssertNotNil(svc.lastError, "A 401 at record-start must surface immediately")
        XCTAssertTrue(svc.lastError?.contains("Settings") ?? false,
                      "Error should point the user at Settings: \(svc.lastError ?? "nil")")
    }

    func test_liveRemoteFailure_setsLastError() async {
        // The live/dictation path must surface a remote failure, not return a
        // silently-empty result indistinguishable from "no speech detected".
        let suite = UserDefaults(suiteName: "TranscriptionServiceTests.liveRemoteFail")!
        suite.removePersistentDomain(forName: "TranscriptionServiceTests.liveRemoteFail")
        let keychainKey = "TranscriptionServiceTests.liveRemoteFail.apiKey"
        defer { KeychainHelper.delete(key: keychainKey) }
        let remote = RemoteTranscriptionSettings(
            defaults: suite, apiKeyKeychainKey: keychainKey)
        remote.backend = .remote
        // Self-hosted endpoint → isConfigured without a key, so routing reaches
        // the (injected, always-throwing) remote engine.
        remote.endpoint = "http://localhost:8080/v1"
        let svc = TranscriptionService(
            store: store, modelManager: manager,
            diarizationSettings: DiarizationSettings(defaults: .init(suiteName: "TranscriptionServiceTests.liveRemoteFail.diar")!),
            remoteSettings: remote, engine: StubWhisperEngine(),
            remoteEngine: ThrowingRemoteEngine())

        XCTAssertNil(svc.lastError)
        let segs = await svc.transcribeOnceSegments(samples: [0.1, 0.2, 0.3], language: "he", audioCtx: nil)
        XCTAssertTrue(segs.isEmpty, "A remote failure yields no segments")
        XCTAssertNotNil(svc.lastError, "A live remote failure must surface, not silently empty the pane")
    }

    // MARK: - Empty capture never reaches the network (issue #147)

    /// A recording session that delivered zero frames used to be encoded to a
    /// header-only file and POSTed anyway; the server answered
    /// `HTTP 500: {"detail":"Failed to decode audio."}` and the user read that
    /// as "the transcription server is down". The microphone's failure has to
    /// be reported as the microphone's failure, and the upload must not happen.
    func test_zeroFrameCapture_neverReachesTheUploadPath() async {
        let suite = UserDefaults(suiteName: "TranscriptionServiceTests.emptyAudio")!
        suite.removePersistentDomain(forName: "TranscriptionServiceTests.emptyAudio")
        let keychainKey = "TranscriptionServiceTests.emptyAudio.apiKey"
        defer { KeychainHelper.delete(key: keychainKey) }
        let remote = RemoteTranscriptionSettings(defaults: suite, apiKeyKeychainKey: keychainKey)
        remote.backend = .remote
        remote.endpoint = "http://localhost:8080/v1"
        let counting = CountingRemoteEngine()
        let svc = TranscriptionService(
            store: store, modelManager: manager,
            diarizationSettings: DiarizationSettings(defaults: .init(suiteName: "TranscriptionServiceTests.emptyAudio.diar")!),
            remoteSettings: remote, engine: StubWhisperEngine(),
            remoteEngine: counting)

        let segs = await svc.transcribeOnceSegments(samples: [], language: "en", audioCtx: nil)

        XCTAssertTrue(segs.isEmpty)
        let calls = await counting.transcribeCalls
        XCTAssertEqual(calls, 0, "empty audio must never be handed to the remote backend")
        XCTAssertEqual(svc.lastError, TranscriptionService.noAudioCapturedMessage,
                       "the user must be told nothing was captured, not shown the server's decode error")
    }

    /// Same for a buffer that has samples but no signal — a muted or dead
    /// input device. There is nothing to transcribe and nothing to upload.
    func test_digitalSilence_neverReachesTheUploadPath() async {
        let suite = UserDefaults(suiteName: "TranscriptionServiceTests.silentAudio")!
        suite.removePersistentDomain(forName: "TranscriptionServiceTests.silentAudio")
        let keychainKey = "TranscriptionServiceTests.silentAudio.apiKey"
        defer { KeychainHelper.delete(key: keychainKey) }
        let remote = RemoteTranscriptionSettings(defaults: suite, apiKeyKeychainKey: keychainKey)
        remote.backend = .remote
        remote.endpoint = "http://localhost:8080/v1"
        let counting = CountingRemoteEngine()
        let svc = TranscriptionService(
            store: store, modelManager: manager,
            diarizationSettings: DiarizationSettings(defaults: .init(suiteName: "TranscriptionServiceTests.silentAudio.diar")!),
            remoteSettings: remote, engine: StubWhisperEngine(),
            remoteEngine: counting)

        let segs = await svc.transcribeOnceSegments(samples: [Float](repeating: 0, count: 16_000),
                                                    language: "en", audioCtx: nil)

        XCTAssertTrue(segs.isEmpty)
        let calls = await counting.transcribeCalls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(svc.lastError, TranscriptionService.noAudioCapturedMessage)
    }

    /// The guard is the strictest possible one, so ordinary quiet speech is
    /// still transcribed — a 0.2s utterance at -60 dBFS must go through.
    func test_quietButRealAudio_isStillTranscribed() async {
        let suite = UserDefaults(suiteName: "TranscriptionServiceTests.quietAudio")!
        suite.removePersistentDomain(forName: "TranscriptionServiceTests.quietAudio")
        let keychainKey = "TranscriptionServiceTests.quietAudio.apiKey"
        defer { KeychainHelper.delete(key: keychainKey) }
        let remote = RemoteTranscriptionSettings(defaults: suite, apiKeyKeychainKey: keychainKey)
        remote.backend = .remote
        remote.endpoint = "http://localhost:8080/v1"
        let counting = CountingRemoteEngine()
        let svc = TranscriptionService(
            store: store, modelManager: manager,
            diarizationSettings: DiarizationSettings(defaults: .init(suiteName: "TranscriptionServiceTests.quietAudio.diar")!),
            remoteSettings: remote, engine: StubWhisperEngine(),
            remoteEngine: counting)

        var samples = [Float](repeating: 0, count: 3_200)   // 0.2s @ 16kHz
        samples[1_000] = 0.001
        let segs = await svc.transcribeOnceSegments(samples: samples, language: "en", audioCtx: nil)

        XCTAssertEqual(segs.count, 1, "quiet is not the same as empty")
        let calls = await counting.transcribeCalls
        XCTAssertEqual(calls, 1)
        XCTAssertNil(svc.lastError)
    }

    // MARK: - Single recording happy path

    func test_enqueue_single_recording_marks_running_then_completed() async throws {
        let fixture = try TestRecordingFixture.make(in: store, title: "Hello")
        let canned = [TranscriptSegment(start: 0, end: 0.5, text: "שלום")]
        await stub.setDefaultCanned(canned)

        XCTAssertNil(service.activeRecordingID)
        service.enqueue(fixture.recording)
        XCTAssertTrue(service.pendingIDs.contains(fixture.recording.id) ||
                      service.activeRecordingID == fixture.recording.id,
                      "Just-enqueued recording must be either active or pending")

        await service.waitForIdle()

        let stored = try XCTUnwrap(store.recordings.first { $0.id == fixture.recording.id })
        XCTAssertEqual(stored.status, .completed)
        XCTAssertEqual(stored.fullText, "שלום")
        XCTAssertEqual(stored.segments.count, 1)
        XCTAssertEqual(stored.modelName, WhisperModel.ivritLarge.displayName)
        XCTAssertNil(service.activeRecordingID)
        XCTAssertTrue(service.pendingIDs.isEmpty)
    }

    // MARK: - The bug we're fixing

    /// REGRESSION: Before the queue refactor, calling enqueue twice while the
    /// first transcription was still running would stomp on `activeRecordingID`
    /// and `progress`, making the UI think the OLD recording was being
    /// transcribed even after the NEW one started.
    func test_enqueueing_second_recording_during_first_does_not_drop_either() async throws {
        let a = try TestRecordingFixture.make(in: store, title: "A")
        let b = try TestRecordingFixture.make(in: store, title: "B")

        await stub.setDefaultDelay(0.25)
        await stub.setCannedQueue([
            [TranscriptSegment(start: 0, end: 1, text: "from A")],
            [TranscriptSegment(start: 0, end: 1, text: "from B")]
        ])

        service.enqueue(a.recording)
        service.enqueue(b.recording)

        await service.waitForIdle()

        let storedA = try XCTUnwrap(store.recordings.first { $0.id == a.recording.id })
        let storedB = try XCTUnwrap(store.recordings.first { $0.id == b.recording.id })

        XCTAssertEqual(storedA.status, .completed)
        XCTAssertEqual(storedA.fullText, "from A")

        XCTAssertEqual(storedB.status, .completed)
        XCTAssertEqual(storedB.fullText, "from B")

        let maxConcurrent = await stub.maxConcurrentInFlight
        XCTAssertEqual(maxConcurrent, 1,
                       "The queue must serialize work; we never want two transcriptions live at once")
    }

    // MARK: - Strict FIFO ordering

    func test_three_recordings_process_in_FIFO_order() async throws {
        let a = try TestRecordingFixture.make(in: store, title: "Alpha")
        let b = try TestRecordingFixture.make(in: store, title: "Bravo")
        let c = try TestRecordingFixture.make(in: store, title: "Charlie")

        await stub.setDefaultDelay(0.05)
        await stub.setCannedQueue([
            [TranscriptSegment(start: 0, end: 1, text: "alpha-text")],
            [TranscriptSegment(start: 0, end: 1, text: "bravo-text")],
            [TranscriptSegment(start: 0, end: 1, text: "charlie-text")]
        ])

        service.enqueue(a.recording)
        service.enqueue(b.recording)
        service.enqueue(c.recording)

        // While the worker is working we should see the right queue depth.
        XCTAssertEqual(service.pendingIDs.count + (service.activeRecordingID == nil ? 0 : 1), 3)

        await service.waitForIdle()

        let map = Dictionary(uniqueKeysWithValues: store.recordings.map { ($0.id, $0) })
        XCTAssertEqual(map[a.recording.id]?.fullText, "alpha-text")
        XCTAssertEqual(map[b.recording.id]?.fullText, "bravo-text")
        XCTAssertEqual(map[c.recording.id]?.fullText, "charlie-text")

        let calls = await stub.transcribeCalls
        XCTAssertEqual(calls.count, 3)
    }

    // MARK: - Progress updates only the active recording

    func test_progress_updates_only_apply_to_active_recording() async throws {
        let a = try TestRecordingFixture.make(in: store, title: "First")
        let b = try TestRecordingFixture.make(in: store, title: "Second")

        await stub.setDefaultDelay(0.15)
        await stub.setCannedQueue([
            [TranscriptSegment(start: 0, end: 1, text: "ok")],
            [TranscriptSegment(start: 0, end: 1, text: "ok")]
        ])

        service.enqueue(a.recording)
        service.enqueue(b.recording)

        // Sample progress while running. activeRecordingID and progress must
        // refer to the same job at every observation.
        var observations: [(UUID?, Double)] = []
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline,
              service.activeRecordingID != nil || !service.pendingIDs.isEmpty {
            observations.append((service.activeRecordingID, service.progress))
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        await service.waitForIdle()

        // Whenever progress was non-zero, activeRecordingID had to be non-nil.
        for (id, prog) in observations where prog > 0 {
            XCTAssertNotNil(id, "progress=\(prog) but no activeRecordingID")
        }
        // We must have seen both recordings serve as active at some point.
        let seen = Set(observations.compactMap(\.0))
        XCTAssertTrue(seen.contains(a.recording.id), "First recording never became active")
        XCTAssertTrue(seen.contains(b.recording.id), "Second recording never became active")
    }

    // MARK: - Idempotent enqueue

    func test_enqueue_is_idempotent_for_same_recording_id() async throws {
        let fixture = try TestRecordingFixture.make(in: store, title: "Once")
        await stub.setDefaultDelay(0.1)

        service.enqueue(fixture.recording)
        service.enqueue(fixture.recording)
        service.enqueue(fixture.recording)

        await service.waitForIdle()

        let calls = await stub.transcribeCalls
        XCTAssertEqual(calls.count, 1, "Duplicate enqueues should be ignored")
    }

    // MARK: - Failure path

    func test_engine_failure_marks_recording_as_failed_and_continues_queue() async throws {
        let a = try TestRecordingFixture.make(in: store, title: "Will fail")
        let b = try TestRecordingFixture.make(in: store, title: "Should still run")

        await stub.setNextError(NSError(domain: "TestEngine", code: 42,
                                        userInfo: [NSLocalizedDescriptionKey: "fake whisper crash"]))
        await stub.setDefaultCanned([
            TranscriptSegment(start: 0, end: 1, text: "second one fine")
        ])

        service.enqueue(a.recording)
        service.enqueue(b.recording)

        await service.waitForIdle()

        let storedA = try XCTUnwrap(store.recordings.first { $0.id == a.recording.id })
        let storedB = try XCTUnwrap(store.recordings.first { $0.id == b.recording.id })

        XCTAssertEqual(storedA.status, .failed)
        XCTAssertEqual(storedA.fullText, "")
        XCTAssertEqual(storedB.status, .completed)
        XCTAssertEqual(storedB.fullText, "second one fine")
        XCTAssertNotNil(service.lastError)
    }

    // MARK: - Empty transcript counts as failure

    func test_empty_transcript_is_marked_failed() async throws {
        let fixture = try TestRecordingFixture.make(in: store, title: "Silent")
        await stub.setDefaultCanned([])

        service.enqueue(fixture.recording)
        await service.waitForIdle()

        let stored = try XCTUnwrap(store.recordings.first { $0.id == fixture.recording.id })
        XCTAssertEqual(stored.status, .failed)
        XCTAssertEqual(stored.fullText, "")
    }

    // MARK: - Auto-drop short + empty recordings (issue #61)

    /// Wire the real gate onto the service so these tests exercise the exact
    /// production path (`RecordingStorageSettings.shouldAutoDrop` +
    /// `TranscriptionService.process`), not a test-only shortcut.
    private func enableAutoDrop(threshold: Double = 5) {
        service.shouldAutoDropShortEmpty = { duration, transcript in
            RecordingStorageSettings.shouldAutoDrop(
                duration: duration, transcript: transcript, threshold: threshold)
        }
    }

    func test_short_empty_recording_is_auto_dropped_after_transcription() async throws {
        enableAutoDrop()
        // Audible + long enough to reach whisper (passes the silence guard),
        // but the engine returns no segments → empty transcript, under 5s.
        let fixture = try TestRecordingFixture.make(in: store,
                                                    title: "Hotkey misfire",
                                                    durationSeconds: 1.0)
        await stub.setDefaultCanned([])

        service.enqueue(fixture.recording)
        await service.waitForIdle()

        XCTAssertNil(store.recordings.first { $0.id == fixture.recording.id },
                     "A short recording with an empty transcript must be dropped from the store")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.audioURL.path),
                       "The dropped recording's audio file must be removed (no orphan)")
        let calls = await stub.transcribeCalls
        XCTAssertEqual(calls.count, 1, "Drop happens AFTER transcription resolves")
    }

    func test_short_but_transcribed_recording_is_kept() async throws {
        // The explicit edge case from the issue: short, but it produced text.
        enableAutoDrop()
        let fixture = try TestRecordingFixture.make(in: store,
                                                    title: "Short but real",
                                                    durationSeconds: 1.0)
        await stub.setDefaultCanned([
            TranscriptSegment(start: 0, end: 1, text: "quick note to self")
        ])

        service.enqueue(fixture.recording)
        await service.waitForIdle()

        let stored = try XCTUnwrap(store.recordings.first { $0.id == fixture.recording.id })
        XCTAssertEqual(stored.status, .completed)
        XCTAssertEqual(stored.fullText, "quick note to self")
    }

    func test_short_empty_recording_is_kept_when_gate_disabled() async throws {
        // Threshold 0 disables the gate: the short+empty clip stays as .failed
        // (the pre-#61 behaviour), it is NOT dropped.
        enableAutoDrop(threshold: 0)
        let fixture = try TestRecordingFixture.make(in: store,
                                                    title: "Kept because gate off",
                                                    durationSeconds: 1.0)
        await stub.setDefaultCanned([])

        service.enqueue(fixture.recording)
        await service.waitForIdle()

        let stored = try XCTUnwrap(store.recordings.first { $0.id == fixture.recording.id })
        XCTAssertEqual(stored.status, .failed)
    }

    func test_short_empty_recording_is_kept_when_no_hook_wired() async throws {
        // Default: no gate wired at all (every existing caller/test). Behaviour
        // is unchanged — the short+empty recording lands .failed and stays.
        let fixture = try TestRecordingFixture.make(in: store,
                                                    title: "No hook",
                                                    durationSeconds: 1.0)
        await stub.setDefaultCanned([])

        service.enqueue(fixture.recording)
        await service.waitForIdle()

        let stored = try XCTUnwrap(store.recordings.first { $0.id == fixture.recording.id })
        XCTAssertEqual(stored.status, .failed)
    }

    /// The gate targets accidental *local mic* captures only. A short, empty
    /// Voice Memos import must NOT be permanently deleted — it has its own
    /// handling, and deleting it would tombstone the source memo (issue #61
    /// review: scope the gate away from imports).
    func test_voice_memo_short_empty_is_not_auto_dropped() async throws {
        enableAutoDrop()
        let fixture = try TestRecordingFixture.make(in: store,
                                                    title: "Imported memo",
                                                    durationSeconds: 1.0,
                                                    source: .voiceMemo)
        await stub.setDefaultCanned([])

        service.enqueue(fixture.recording)
        await service.waitForIdle()

        let stored = try XCTUnwrap(store.recordings.first { $0.id == fixture.recording.id },
                                   "A Voice Memo import must not be auto-dropped by the mic-capture gate")
        XCTAssertEqual(stored.status, .failed)
    }

    /// Regression: the gate must use the DECODED audio duration, not
    /// `recording.duration`, which crash-recovered rows seed with a stale `0`.
    /// A long-but-empty clip whose stored duration is `0` must stay `.failed`,
    /// not be deleted as if it were short (issue #61 review).
    func test_long_empty_recording_is_kept_despite_stale_zero_duration() async throws {
        enableAutoDrop()
        let audioURL = store.freshAudioURL(suggestedName: "Long silent")
        try TestSupport.writeSineWav(at: audioURL, durationSeconds: 6.0)  // > 5s threshold
        let rec = Recording(title: "Long silent", duration: 0,  // stale — real audio is 6s
                            source: .microphone, audioFileName: audioURL.lastPathComponent,
                            language: "he")
        store.add(rec)
        await stub.setDefaultCanned([])

        service.enqueue(rec)
        await service.waitForIdle()

        let stored = try XCTUnwrap(store.recordings.first { $0.id == rec.id },
                                   "A 6s clip must not be dropped just because recording.duration was a stale 0")
        XCTAssertEqual(stored.status, .failed)
    }

    /// A manual re-transcribe of an EXISTING recording that comes back empty
    /// must not be auto-dropped — the recording already had content, and
    /// deleting it would destroy the user's data. Only first-time captures are
    /// eligible for auto-drop (issue #61 review).
    func test_short_empty_retranscribe_of_existing_recording_is_kept() async throws {
        enableAutoDrop()
        let fixture = try TestRecordingFixture.make(in: store,
                                                    title: "Existing note",
                                                    durationSeconds: 1.0)
        var rec = fixture.recording
        rec.status = .completed
        rec.fullText = "the note I already transcribed"
        store.update(rec)                 // now it has prior content
        await stub.setDefaultCanned([])   // the retry produces nothing

        service.enqueue(rec)
        await service.waitForIdle()

        XCTAssertNotNil(store.recordings.first { $0.id == rec.id },
                        "Re-transcribing an existing recording to an empty result must not delete it")
    }

    /// The silence guard rejects the clip before whisper runs; the auto-drop
    /// gate must still remove it (short + empty), so accidental sub-0.3s /
    /// silent captures never even reach the list.
    func test_silence_rejected_recording_is_auto_dropped_when_short() async throws {
        enableAutoDrop()
        let url = store.freshAudioURL(suggestedName: "Silent misfire")
        try TestSupport.writeSineWav(at: url, durationSeconds: 0.06, amplitude: 0.0001)
        let recording = Recording(title: "Silent misfire",
                                  duration: 0.06,
                                  source: .microphone,
                                  audioFileName: url.lastPathComponent,
                                  language: "he")
        store.add(recording)

        service.enqueue(recording)
        await service.waitForIdle()

        XCTAssertNil(store.recordings.first { $0.id == recording.id },
                     "A silence-rejected short clip must be auto-dropped")
        let calls = await stub.transcribeCalls
        XCTAssertTrue(calls.isEmpty, "Silence guard still short-circuits before whisper")
    }

    // MARK: - User-reported "every empty recording shows the same transcript"

    /// REGRESSION: When the second/third Voice Memo captures almost no audio
    /// (because of an `AVAudioEngine` restart bug), the auto-gain in
    /// WhisperEngine amplifies that ~60ms of mic noise to clipping levels and
    /// Whisper hallucinates a confident-looking Hebrew test phrase like
    /// "1, 2, 3, בדיקה, בדיקה, 4, 5" — the SAME phrase for every silent
    /// recording. From the user's POV it looks like the new recording is
    /// "stuck on the previous one's transcript".
    ///
    /// The transcription service must short-circuit on essentially-silent /
    /// extremely short audio so we never hand it to Whisper at all.
    func test_silent_or_too_short_audio_is_rejected_without_calling_whisper() async throws {
        let url = store.freshAudioURL(suggestedName: "Silent")
        try TestSupport.writeSineWav(at: url,
                                     durationSeconds: 0.06,
                                     amplitude: 0.0001)
        let recording = Recording(
            title: "Silent",
            duration: 0.06,
            source: .microphone,
            audioFileName: url.lastPathComponent,
            language: "he"
        )
        store.add(recording)

        // If the guard is missing, the stub will return this and the user will
        // see it as a "ghost transcript" on the empty recording — exactly the
        // bug being fixed.
        await stub.setDefaultCanned([
            TranscriptSegment(start: 0, end: 1,
                              text: "GHOST TRANSCRIPT THAT MUST NEVER APPEAR")
        ])

        service.enqueue(recording)
        await service.waitForIdle()

        let stored = try XCTUnwrap(store.recordings.first { $0.id == recording.id })
        XCTAssertEqual(stored.status, .failed)
        XCTAssertEqual(stored.fullText, "")
        XCTAssertTrue(stored.segments.isEmpty)

        let calls = await stub.transcribeCalls
        XCTAssertTrue(calls.isEmpty,
                      "Whisper must NOT be called on essentially-silent / extremely short audio")
    }

    /// Companion to the above: a normal audio file (>= the duration threshold,
    /// non-trivial peak) MUST go through Whisper as expected. We don't want to
    /// over-correct and start dropping legitimate quiet recordings.
    func test_quiet_but_audible_recording_still_reaches_whisper() async throws {
        let url = store.freshAudioURL(suggestedName: "Quiet but audible")
        try TestSupport.writeSineWav(at: url,
                                     durationSeconds: 1.0,
                                     amplitude: 0.05)
        let recording = Recording(
            title: "Quiet but audible",
            duration: 1.0,
            source: .microphone,
            audioFileName: url.lastPathComponent,
            language: "he"
        )
        store.add(recording)
        await stub.setDefaultCanned([
            TranscriptSegment(start: 0, end: 1, text: "should be transcribed")
        ])

        service.enqueue(recording)
        await service.waitForIdle()

        let stored = try XCTUnwrap(store.recordings.first { $0.id == recording.id })
        XCTAssertEqual(stored.status, .completed)
        XCTAssertEqual(stored.fullText, "should be transcribed")
        let calls = await stub.transcribeCalls
        XCTAssertEqual(calls.count, 1)
    }

    // MARK: - Soft-deleted recordings are skipped

    func test_soft_deleted_recording_is_not_transcribed() async throws {
        let fixture = try TestRecordingFixture.make(in: store, title: "Trashed")
        store.softDelete(fixture.recording)

        service.enqueue(fixture.recording)
        await service.waitForIdle()

        let calls = await stub.transcribeCalls
        XCTAssertTrue(calls.isEmpty, "Should not run whisper on a deleted recording")
    }

    // MARK: - Model gating

    func test_no_model_installed_marks_recording_failed() async throws {
        try manager.delete(.ivritLarge)
        XCTAssertFalse(manager.isInstalled(.ivritLarge))

        let fixture = try TestRecordingFixture.make(in: store, title: "Skipped")
        service.enqueue(fixture.recording)
        await service.waitForIdle()

        let stored = try XCTUnwrap(store.recordings.first { $0.id == fixture.recording.id })
        XCTAssertEqual(stored.status, .failed)

        let calls = await stub.transcribeCalls
        XCTAssertTrue(calls.isEmpty)
    }

    // MARK: - transcribeOnce (dictation path)

    func test_transcribe_once_returns_concatenated_segment_text() async {
        await stub.setDefaultCanned([
            TranscriptSegment(start: 0, end: 0.5, text: "שלום "),
            TranscriptSegment(start: 0.5, end: 1.0, text: "עולם")
        ])

        let samples = [Float](repeating: 0.1, count: 16_000)
        let text = await service.transcribeOnce(samples: samples, language: "he")

        XCTAssertEqual(text, "שלום עולם")
    }

    func test_transcribe_once_returns_empty_when_engine_throws() async {
        await stub.setNextError(NSError(domain: "TestEngine", code: 7))

        let samples = [Float](repeating: 0.1, count: 16_000)
        let text = await service.transcribeOnce(samples: samples, language: "he")
        XCTAssertEqual(text, "")
    }

    // MARK: - Cancellation

    /// Cancelling a recording while it's still pending in the queue should
    /// short-circuit `process()` so whisper is never called. This is the
    /// path users hit most often — they cancel before the model even loads.
    func test_cancel_before_active_skips_whisper_entirely() async throws {
        let blocker = try TestRecordingFixture.make(in: store, title: "Blocker")
        let target = try TestRecordingFixture.make(in: store, title: "Target")

        // Make the first job slow so the second sits in the queue while we
        // cancel it.
        await stub.setDefaultDelay(0.4)

        service.enqueue(blocker.recording)
        service.enqueue(target.recording)

        // Wait for the worker to actually pop the blocker as the active job
        // before we cancel — that's the realistic scenario for users (one
        // recording is being transcribed, a new one is queued behind it).
        let activeDeadline = Date().addingTimeInterval(2)
        while service.activeRecordingID != blocker.recording.id && Date() < activeDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(service.pendingIDs, [target.recording.id])

        service.cancel(recordingID: target.recording.id)
        XCTAssertTrue(service.pendingIDs.isEmpty,
                      "Cancel must drop the recording from pendingIDs immediately")

        await service.waitForIdle()

        let calls = await stub.transcribeCalls
        XCTAssertEqual(calls.count, 1, "Only the blocker should have hit whisper")
    }

    /// Cancelling while the recording is the active job should trip the
    /// abort_callback the stub polls. The stub throws `CancellationError`
    /// when it sees the flag flip, exactly mirroring whisper.cpp's behaviour
    /// when `abort_callback` returns true mid-`whisper_full`.
    func test_cancel_during_active_aborts_via_callback() async throws {
        let target = try TestRecordingFixture.make(in: store, title: "Mid-run")
        await stub.setDefaultDelay(0.4)

        service.enqueue(target.recording)

        // Wait for the worker to actually pick the job up.
        let deadline = Date().addingTimeInterval(2)
        while service.activeRecordingID != target.recording.id && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(service.activeRecordingID, target.recording.id)

        service.cancel(recordingID: target.recording.id)
        await service.waitForIdle()

        // The recording must NOT be marked as `.failed` — that's a user-
        // initiated cancel, not an engine error. The coordinator will be
        // along to delete it shortly.
        let stored = try XCTUnwrap(store.recordings.first { $0.id == target.recording.id })
        XCTAssertNotEqual(stored.status, .failed,
                          "User-cancelled recordings must not surface as engine failures")
    }

    /// The Queue's "Stop" button flow: abort the active run via the service AND
    /// flip the store status (the service leaves it alone). The recording must
    /// end in a terminal state so it drops out of the Queue instead of showing
    /// "Transcribing" forever, but the audio + row must survive for a later
    /// re-transcribe.
    func test_stop_from_queue_leaves_recording_terminal_and_kept() async throws {
        let target = try TestRecordingFixture.make(in: store, title: "Stop me")
        await stub.setDefaultDelay(0.4)

        service.enqueue(target.recording)
        let deadline = Date().addingTimeInterval(2)
        while service.activeRecordingID != target.recording.id && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(service.activeRecordingID, target.recording.id)

        // Mirror QueueRow.cancel(): trip the abort flag + stop (move to trash).
        service.cancel(recordingID: target.recording.id)
        store.stopTranscription(target.recording)
        await service.waitForIdle()

        let stored = try XCTUnwrap(store.recordings.first { $0.id == target.recording.id })
        XCTAssertEqual(stored.status, .failed,
                       "A stopped recording must leave the running/pending Queue state")
        XCTAssertTrue(stored.isTrashed,
                      "Stop moves the recording to Recently Deleted so it leaves the list")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.audioURL.path),
                      "Stop keeps the audio (in the trash) so the user can restore / re-transcribe")
    }

    // MARK: - Re-transcribe with the other language

    /// Drives the right-click "Re-transcribe in [other language]" path: the
    /// caller flips `recording.language` from `"he"` to `"en"` and re-enqueues.
    /// The service must pick that up and load the OpenAI model on the second
    /// pass instead of the ivrit.ai one used on the first.
    func test_changing_recording_language_routes_to_other_model_on_reenqueue() async throws {
        try TestSupport.installFakeModel(into: manager, model: .openaiTurbo)

        let fixture = try TestRecordingFixture.make(in: store,
                                                    title: "Was Hebrew",
                                                    language: "he")
        await stub.setCannedQueue([
            [TranscriptSegment(start: 0, end: 1, text: "first pass")],
            [TranscriptSegment(start: 0, end: 1, text: "second pass")]
        ])

        service.enqueue(fixture.recording)
        await service.waitForIdle()
        let firstLoad = await stub.loadedModel
        XCTAssertEqual(firstLoad?.lastPathComponent,
                       manager.url(for: .ivritLarge).lastPathComponent,
                       "First pass should hit the Hebrew model")

        // Flip the language + re-enqueue through the production chokepoint.
        // (Previously this clobbered the store with a stale snapshot via
        // `store.update`, which could rewrite a since-compressed `.m4a` audio
        // name back to a deleted `.wav` and flake the second pass to `.failed`.)
        let swapped = try XCTUnwrap(store.prepareForRetranscription(id: fixture.recording.id, language: "en"))
        service.enqueue(swapped)
        await service.waitForIdle()

        let secondLoad = await stub.loadedModel
        XCTAssertEqual(secondLoad?.lastPathComponent,
                       manager.url(for: .openaiTurbo).lastPathComponent,
                       "Second pass should hit the English model after the language swap")

        let stored = try XCTUnwrap(store.recordings.first { $0.id == fixture.recording.id })
        XCTAssertEqual(stored.fullText, "second pass")
        XCTAssertEqual(stored.language, "en")
        XCTAssertEqual(stored.status, .completed)
    }

    /// REGRESSION (flaky CI): re-transcribing a recording whose previous pass's
    /// background WAV→m4a compression has ALREADY finished must still succeed.
    ///
    /// Root cause of the flake: after a completed transcription the service
    /// kicks off `RecordingStore.compressRecordingAudio`, which renames the
    /// `.wav` to `.m4a` and deletes the WAV. The re-transcribe path enqueued a
    /// stale `Recording` snapshot still pointing at the now-deleted `.wav`, so
    /// the second pass failed with "file not found" — landing `.failed` with the
    /// OLD transcript still showing. Under CI contention the compression
    /// regularly won that race; locally it usually didn't, hence the flake.
    ///
    /// This test makes that ordering DETERMINISTIC by awaiting the compression
    /// before re-enqueuing — the second pass must read the recording's CURRENT
    /// on-disk audio (the `.m4a`), not the stale snapshot's `.wav`.
    func test_retranscribe_after_audio_compressed_reads_current_file_not_stale_wav() async throws {
        let fixture = try TestRecordingFixture.make(in: store,
                                                    title: "Compressed then retranscribed",
                                                    durationSeconds: 1.0,
                                                    language: "he")
        await stub.setCannedQueue([
            [TranscriptSegment(start: 0, end: 1, text: "first pass")],
            [TranscriptSegment(start: 0, end: 1, text: "second pass")]
        ])

        // First pass.
        service.enqueue(fixture.recording)
        await service.waitForIdle()
        let firstStored = try XCTUnwrap(store.recordings.first { $0.id == fixture.recording.id })
        XCTAssertEqual(firstStored.status, .completed)
        XCTAssertEqual(firstStored.fullText, "first pass")

        // Force the post-completion compression to FULLY complete: this renames
        // the WAV to .m4a and deletes the WAV — exactly the on-disk state the CI
        // flake hit when compression won the race against re-transcribe.
        //
        // Via `drainPostCompletionCompression`, NOT a bare
        // `await store.compressRecordingAudio(id:)`. That call is not a join:
        // its `compressingIDs` guard is taken before the first suspension, so
        // when the first pass's auto-kicked transcode is already mid-encode our
        // call returns straight back having done nothing, and the assertions
        // below then run against the still-`.wav` state. That is a scheduling
        // race, not a code fault, and it is what this test failed on in CI —
        // three wrong values in 0.124s, i.e. it never paid for an encode
        // (issue #255). The helper waits for the observable end state instead.
        await drainPostCompletionCompression(fixture.recording.id)
        let compressed = try XCTUnwrap(store.recordings.first { $0.id == fixture.recording.id })
        XCTAssertTrue(compressed.audioFileName.lowercased().hasSuffix(".m4a"),
                      "Compression should have swapped the audio to .m4a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audioURL(for: fixture.recording).path),
                       "The original .wav (stale snapshot's path) must be gone")

        // Re-transcribe via the store's `prepareForRetranscription` chokepoint
        // (what the real re-transcribe UI now uses). It must preserve the
        // current `.m4a` audioFileName rather than clobbering it back to the
        // deleted `.wav` from a stale snapshot.
        let prepared = try XCTUnwrap(store.prepareForRetranscription(id: fixture.recording.id))
        XCTAssertTrue(prepared.audioFileName.lowercased().hasSuffix(".m4a"),
                      "prepareForRetranscription must keep the compressed .m4a name")
        service.enqueue(prepared)
        await service.waitForIdle()

        let stored = try XCTUnwrap(store.recordings.first { $0.id == fixture.recording.id })
        XCTAssertEqual(stored.status, .completed,
                       "Re-transcribe must succeed against the compressed .m4a, not fail on the stale .wav")
        XCTAssertEqual(stored.fullText, "second pass",
                       "Second pass transcript must overwrite the first")
        let calls = await stub.transcribeCalls
        XCTAssertEqual(calls.count, 2, "Both passes must have reached the engine")
    }

    /// Direct unit test for the chokepoint: `prepareForRetranscription` must
    /// NOT reset the store-owned `audioFileName` even when the previous pass's
    /// compression has already renamed the audio to `.m4a`. (Regression for the
    /// stale-snapshot clobber that failed re-transcription with "file not
    /// found".)
    func test_prepareForRetranscription_preserves_compressed_audio_filename() async throws {
        let fixture = try TestRecordingFixture.make(in: store, title: "Keep m4a", durationSeconds: 1.0)
        await stub.setDefaultCanned([TranscriptSegment(start: 0, end: 1, text: "done")])
        service.enqueue(fixture.recording)
        await service.waitForIdle()
        // Same reason as the test above: `compressRecordingAudio` no-ops rather
        // than joins when the auto-kicked transcode is already in flight, so
        // wait for the end state (issue #255).
        await drainPostCompletionCompression(fixture.recording.id)

        let beforeName = try XCTUnwrap(store.recordings.first { $0.id == fixture.recording.id }).audioFileName
        XCTAssertTrue(beforeName.lowercased().hasSuffix(".m4a"),
                      "compression must have run before this asserts on its result")

        let prepared = try XCTUnwrap(store.prepareForRetranscription(id: fixture.recording.id, language: "en"))
        XCTAssertEqual(prepared.audioFileName, beforeName, "audioFileName must be preserved")
        XCTAssertEqual(prepared.language, "en", "language must be switched")
        XCTAssertEqual(prepared.status, .pending, "status must be reset to pending")
    }

    // MARK: - Edits made DURING a pass must survive the write-back (issue #152)
    //
    // `process` snapshots the row when the pass begins and used to write that
    // snapshot back wholesale when the pass finished, silently reverting any
    // edit the user made in the (potentially minutes-long) gap. These pin the
    // merge: pass-owned fields land, user-owned fields are left alone, and a
    // deleted recording is never resurrected.

    /// How long the stub pretends to transcribe for in these tests. Long
    /// enough that the mid-pass edit reliably lands inside the window even on
    /// a loaded CI box; `liveRowMidPass` asserts it actually did.
    private static let midPassDelay: Double = 0.8

    /// Block until the pass for `id` is genuinely in flight, then hand back the
    /// LIVE store row so the test can edit it — exactly like a user clicking
    /// around the sidebar while a batch transcription runs. Fails loudly if the
    /// pass already finished, so a mistimed run can never pass by accident.
    private func liveRowMidPass(_ id: UUID,
                                timeout: TimeInterval = 3,
                                file: StaticString = #filePath,
                                line: UInt = #line) async throws -> Recording {
        let deadline = Date().addingTimeInterval(timeout)
        while service.activeRecordingID != id && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(service.activeRecordingID, id,
                       "Transcription never became active — can't test the mid-pass window",
                       file: file, line: line)
        let live = try XCTUnwrap(store.recordings.first { $0.id == id }, file: file, line: line)
        XCTAssertEqual(live.status, .running,
                       "The pass must still be in flight when the test edits the row",
                       file: file, line: line)
        return live
    }

    /// Settle the WAV→m4a transcode the completion path kicks off in a detached
    /// `Task`. `waitForIdle` only tracks `activeRecordingID` and the queue, so
    /// without this the transcode can outlive the test and run against a
    /// `tempRoot` that `tearDown` has already removed.
    ///
    /// One `await store.compressRecordingAudio(id:)` is NOT a join on its own:
    /// the in-flight guard (`compressingIDs`) is taken before the first
    /// suspension, so if the detached task got there first our call returns
    /// straight back while its transcode is still running. So kick it — a
    /// no-op when the detached task already started or already finished — and
    /// then wait for the observable end state: the row's audio is no longer
    /// the `.wav`. Returns early if the row is gone (nothing left to settle).
    private func drainPostCompletionCompression(_ id: UUID,
                                                timeout: TimeInterval = 5) async {
        await store.compressRecordingAudio(id: id)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let current = store.recordings.first(where: { $0.id == id }) else { return }
            if !current.audioFileName.lowercased().hasSuffix(".wav") { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func test_rename_during_transcription_survives_the_write_back() async throws {
        let fixture = try TestRecordingFixture.make(in: store, title: "Old name", durationSeconds: 1.0)
        await stub.setDefaultDelay(Self.midPassDelay)
        await stub.setDefaultCanned([TranscriptSegment(start: 0, end: 1, text: "the transcript")])

        service.enqueue(fixture.recording)
        let live = try await liveRowMidPass(fixture.recording.id)
        store.rename(live, to: "New name")

        await service.waitForIdle()
        await drainPostCompletionCompression(fixture.recording.id)

        let stored = try XCTUnwrap(store.recordings.first { $0.id == fixture.recording.id })
        XCTAssertEqual(stored.title, "New name",
                       "A rename made while the pass was running must not be reverted by the write-back")
        XCTAssertEqual(stored.status, .completed, "The pass still owns status")
        XCTAssertEqual(stored.fullText, "the transcript", "The pass still owns the transcript")
        XCTAssertEqual(stored.segments.count, 1)
    }

    func test_folder_assignment_during_transcription_survives_the_write_back() async throws {
        let fixture = try TestRecordingFixture.make(in: store, title: "Filed mid-pass", durationSeconds: 1.0)
        await stub.setDefaultDelay(Self.midPassDelay)
        await stub.setDefaultCanned([TranscriptSegment(start: 0, end: 1, text: "filed")])

        service.enqueue(fixture.recording)
        let live = try await liveRowMidPass(fixture.recording.id)
        XCTAssertNil(live.folder)
        store.assign(live, toFolder: "Work")

        await service.waitForIdle()
        await drainPostCompletionCompression(fixture.recording.id)

        let stored = try XCTUnwrap(store.recordings.first { $0.id == fixture.recording.id })
        XCTAssertEqual(stored.folder, "Work",
                       "Dropping a recording into a folder mid-pass must not be reverted")
        XCTAssertEqual(store.recordings(inFolder: "Work").map(\.id), [fixture.recording.id])
        XCTAssertEqual(stored.status, .completed)
        XCTAssertEqual(stored.fullText, "filed")
    }

    /// Edits must also survive a pass that ends in failure. A pass that comes
    /// back EMPTY minted no `SPEAKER_NN` ids, so it owns neither the user's
    /// rename nor their hand-typed speaker names — only `status`.
    func test_rename_and_speaker_names_survive_a_failing_pass() async throws {
        let fixture = try TestRecordingFixture.make(in: store, title: "Will come back empty", durationSeconds: 1.0)
        store.setSpeakerName("Daniel", forSpeaker: "SPEAKER_00", recordingID: fixture.recording.id)
        store.setSpeakerName("Maya", forSpeaker: "SPEAKER_01", recordingID: fixture.recording.id)
        await stub.setDefaultDelay(Self.midPassDelay)
        await stub.setDefaultCanned([])   // empty transcript → .failed

        service.enqueue(fixture.recording)
        let live = try await liveRowMidPass(fixture.recording.id)
        store.rename(live, to: "Renamed anyway")

        await service.waitForIdle()

        let stored = try XCTUnwrap(store.recordings.first { $0.id == fixture.recording.id })
        XCTAssertEqual(stored.title, "Renamed anyway")
        XCTAssertEqual(stored.status, .failed)
        XCTAssertEqual(stored.speakerNames, ["SPEAKER_00": "Daniel", "SPEAKER_01": "Maya"],
                       "A pass that produced no segments re-keyed nothing, so it must not wipe the user's speaker names")
    }

    /// The other side of that contract: a pass that DID produce segments re-keys
    /// every `SPEAKER_NN`, so the old names would label the wrong voice and must
    /// be cleared — even though the user's rename in the same window survives.
    func test_successful_pass_clears_speaker_names_but_keeps_the_rename() async throws {
        let fixture = try TestRecordingFixture.make(in: store, title: "Re-keyed", durationSeconds: 1.0)
        store.setSpeakerName("Daniel", forSpeaker: "SPEAKER_00", recordingID: fixture.recording.id)
        await stub.setDefaultDelay(Self.midPassDelay)
        await stub.setDefaultCanned([TranscriptSegment(start: 0, end: 1, text: "fresh clustering")])

        service.enqueue(fixture.recording)
        let live = try await liveRowMidPass(fixture.recording.id)
        store.rename(live, to: "Renamed during re-key")

        await service.waitForIdle()
        await drainPostCompletionCompression(fixture.recording.id)

        let stored = try XCTUnwrap(store.recordings.first { $0.id == fixture.recording.id })
        XCTAssertEqual(stored.title, "Renamed during re-key", "User-owned: the rename wins")
        XCTAssertTrue(stored.speakerNames.isEmpty,
                      "Pass-owned: a pass that produced segments re-keyed the ids, so stale names go")
        XCTAssertEqual(stored.fullText, "fresh clustering")
    }

    /// Soft-deleting mid-pass must NOT be undone by the write-back: the
    /// recording stays in Recently Deleted. It still reaches a terminal status
    /// (otherwise it sits in the queue UI as "Transcribing" forever) and keeps
    /// its transcript for a later restore, but gets none of the user-facing
    /// completion work — no `.srt` sidecar, no summarizer/LLM spend.
    func test_soft_delete_during_transcription_is_not_resurrected() async throws {
        let fixture = try TestRecordingFixture.make(in: store, title: "Trashed mid-pass", durationSeconds: 1.0)
        await stub.setDefaultDelay(Self.midPassDelay)
        await stub.setDefaultCanned([TranscriptSegment(start: 0, end: 1, text: "still transcribed")])

        var completionFired = false
        service.onTranscriptionCompleted = { _, _ in completionFired = true }

        service.enqueue(fixture.recording)
        let live = try await liveRowMidPass(fixture.recording.id)
        store.softDelete(live)

        await service.waitForIdle()
        await drainPostCompletionCompression(fixture.recording.id)

        let stored = try XCTUnwrap(store.recordings.first { $0.id == fixture.recording.id })
        XCTAssertTrue(stored.isTrashed,
                      "A recording the user deleted mid-pass must not be resurrected by the write-back")
        XCTAssertEqual(stored.status, .completed,
                       "It must still leave the running state or the queue shows it as Transcribing forever")
        XCTAssertEqual(stored.fullText, "still transcribed",
                       "The transcript is kept so a restore isn't empty")
        XCTAssertFalse(completionFired,
                       "No summarizer/LLM work for a recording on its way to the trash")
        let srt = store.recordingsDirectory.appendingPathComponent(stored.subtitleFileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: srt.path),
                       "No stray .srt sidecar for a trashed recording")
    }

    /// The row can also disappear ENTIRELY mid-pass (hard delete, or emptying
    /// Recently Deleted). The write-back must not re-add it.
    func test_hard_delete_during_transcription_does_not_recreate_the_row() async throws {
        let fixture = try TestRecordingFixture.make(in: store, title: "Gone mid-pass", durationSeconds: 1.0)
        await stub.setDefaultDelay(Self.midPassDelay)
        await stub.setDefaultCanned([TranscriptSegment(start: 0, end: 1, text: "orphan")])

        service.enqueue(fixture.recording)
        let live = try await liveRowMidPass(fixture.recording.id)
        store.permanentlyDelete(live)
        XCTAssertNil(store.recordings.first { $0.id == fixture.recording.id })

        await service.waitForIdle()

        XCTAssertNil(store.recordings.first { $0.id == fixture.recording.id },
                     "A hard-deleted recording must not be recreated by the transcription write-back")
    }

    // MARK: - Speaker label normalization

    func test_normalizeSpeakerLabels_closes_gaps_from_diarizer_clustering() {
        // Pyannote occasionally emits non-contiguous speaker ids
        // (SPEAKER_00 and SPEAKER_02 with no SPEAKER_01) when its
        // clustering pass merges an intermediate cluster. The UI
        // would otherwise show "Speaker A, Speaker C" with no B.
        let segments: [TranscriptSegment] = [
            .init(start: 0, end: 1, text: "hi", speaker: "SPEAKER_00"),
            .init(start: 1, end: 2, text: "yo", speaker: "SPEAKER_02"),
            .init(start: 2, end: 3, text: "ya", speaker: "SPEAKER_00"),
            .init(start: 3, end: 4, text: "bye", speaker: "SPEAKER_02"),
        ]
        let normalized = TranscriptionService.normalizeSpeakerLabels(in: segments)
        XCTAssertEqual(normalized.map(\.speaker),
                       ["SPEAKER_00", "SPEAKER_01", "SPEAKER_00", "SPEAKER_01"])
    }

    func test_normalizeSpeakerLabels_uses_first_appearance_order() {
        // The user who SPEAKS FIRST always ends up as SPEAKER_00,
        // regardless of what id pyannote happened to assign.
        let segments: [TranscriptSegment] = [
            .init(start: 0, end: 1, text: "first speaker", speaker: "SPEAKER_05"),
            .init(start: 1, end: 2, text: "second speaker", speaker: "SPEAKER_01"),
            .init(start: 2, end: 3, text: "third speaker", speaker: "SPEAKER_03"),
            .init(start: 3, end: 4, text: "first again", speaker: "SPEAKER_05"),
        ]
        let normalized = TranscriptionService.normalizeSpeakerLabels(in: segments)
        XCTAssertEqual(normalized.map(\.speaker),
                       ["SPEAKER_00", "SPEAKER_01", "SPEAKER_02", "SPEAKER_00"])
    }

    func test_normalizeSpeakerLabels_passes_through_segments_without_labels() {
        // Mixed: some segments have speakers, some don't (e.g.
        // background noise the diarizer couldn't attribute). The
        // unlabeled segments stay unlabeled; only the labeled ones
        // get renumbered.
        let segments: [TranscriptSegment] = [
            .init(start: 0, end: 1, text: "a", speaker: "SPEAKER_03"),
            .init(start: 1, end: 2, text: "b", speaker: nil),
            .init(start: 2, end: 3, text: "c", speaker: "SPEAKER_07"),
        ]
        let normalized = TranscriptionService.normalizeSpeakerLabels(in: segments)
        XCTAssertEqual(normalized[0].speaker, "SPEAKER_00")
        XCTAssertNil(normalized[1].speaker)
        XCTAssertEqual(normalized[2].speaker, "SPEAKER_01")
    }

    // MARK: - Server-side speaker labels survive the offline pass (issue #180)

    func test_hasSpeakerLabels_distinguishes_server_diarized_transcripts() {
        // What the batch worker branches on: a `diarized_json` response
        // already carries speakers, so the local pyannote pass must not
        // relabel it. Everything else (local whisper, `verbose_json`, `json`)
        // arrives unlabelled and does need the offline pass.
        XCTAssertTrue(TranscriptionService.hasSpeakerLabels([
            .init(start: 0, end: 1, text: "hi", speaker: "SPEAKER_00"),
            .init(start: 1, end: 2, text: "yo", speaker: "SPEAKER_01"),
        ]))
        XCTAssertFalse(TranscriptionService.hasSpeakerLabels([
            .init(start: 0, end: 1, text: "hi"),
            .init(start: 1, end: 2, text: "yo"),
        ]))
        XCTAssertFalse(TranscriptionService.hasSpeakerLabels([]))
        // A present-but-empty label is not a label — an empty string would
        // otherwise suppress diarization and render as a blank speaker.
        XCTAssertFalse(TranscriptionService.hasSpeakerLabels([
            .init(start: 0, end: 1, text: "hi", speaker: ""),
        ]))
        // One labelled segment is enough: a diarize response can leave a
        // stretch unattributed, and mixing the two label spaces is exactly
        // what the guard exists to prevent.
        XCTAssertTrue(TranscriptionService.hasSpeakerLabels([
            .init(start: 0, end: 1, text: "hi"),
            .init(start: 1, end: 2, text: "yo", speaker: "SPEAKER_00"),
        ]))
    }

    func test_normalizeSpeakerLabels_rekeys_foreign_server_labels() {
        // A remote diarizer speaks its own label space ("A", "B", …), which
        // `friendlySpeakerLabel(language:)` would pass through verbatim.
        let segments: [TranscriptSegment] = [
            .init(start: 0, end: 1, text: "hi", speaker: "B"),
            .init(start: 1, end: 2, text: "yo", speaker: "A"),
            .init(start: 2, end: 3, text: "ya", speaker: "B"),
        ]
        let normalized = TranscriptionService.normalizeSpeakerLabels(in: segments)
        XCTAssertEqual(normalized.map(\.speaker),
                       ["SPEAKER_00", "SPEAKER_01", "SPEAKER_00"])
        XCTAssertEqual(normalized[0].speaker?.friendlySpeakerLabel(language: "en"), "Speaker A")
    }
}

/// Returns 401 for any request — lets the record-start probe reach `.failed`
/// without a real server. (Distinct from `RemoteTranscriptionTests`' copy so
/// each test file is self-contained.)
private final class Probe401URLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 401,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":{"message":"Incorrect API key provided: test-key-123"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Counts how many times the service actually handed audio to the remote
/// backend. Used to prove that a session which captured nothing never reaches
/// the upload path at all.
private actor CountingRemoteEngine: RemoteTranscribing {
    private(set) var transcribeCalls = 0
    func configure(_ config: RemoteTranscriptionConfig) async {}
    func loadIfNeeded(modelURL: URL, displayName: String) async throws {}
    func shutdown() async {}
    func transcribe(samples: [Float],
                    language: String,
                    audioCtx: Int32?,
                    progress: (@Sendable (Float) -> Void)?,
                    isCancelled: (@Sendable () -> Bool)?) async throws -> [TranscriptSegment] {
        transcribeCalls += 1
        return [TranscriptSegment(start: 0, end: 1, text: "uploaded")]
    }
}

/// A remote engine that always throws an HTTP 401 — stands in for a
/// misconfigured remote backend so the live-path error-surfacing can be tested
/// without a network round-trip.
private actor ThrowingRemoteEngine: RemoteTranscribing {
    func configure(_ config: RemoteTranscriptionConfig) async {}
    func loadIfNeeded(modelURL: URL, displayName: String) async throws {}
    func shutdown() async {}
    func transcribe(samples: [Float],
                    language: String,
                    audioCtx: Int32?,
                    progress: (@Sendable (Float) -> Void)?,
                    isCancelled: (@Sendable () -> Bool)?) async throws -> [TranscriptSegment] {
        throw RemoteWhisperEngine.RemoteError.http(
            status: 401,
            body: #"{"error":{"message":"Incorrect API key provided: test-key-123"}}"#)
    }
}
