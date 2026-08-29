import XCTest
import Combine
import MilaKit
import TranscriptionCore
@testable import Mila

/// REGRESSION (CodeRabbit on #183, Major): `stopRecording` used to close the
/// live sidecar — publishing `state: completed` plus `final_recording_id` —
/// immediately after `store.add(recording)`, i.e. BEFORE the inline
/// live-pipeline drain wrote the final transcript onto that row.
///
/// `completed` + an id is a promise: it tells an external poller "stop
/// polling, this id now resolves to the authoritative transcript". Nothing
/// makes a poller wait, so an MCP client that saw `completed` at that point
/// and immediately called `get_transcript(final_recording_id)` got the
/// PRE-DRAIN snapshot — the transcript as it stood the instant Stop was
/// pressed — and then stopped polling, silently losing the tail of the
/// meeting. The comment in the old code asserted the opposite ("the inline
/// drain below keeps updating the STORED recording, which is what the
/// handoff reads"), which is true but beside the point: it does not stop the
/// client reading first.
///
/// The observation seam is `postRecording.present(recording)`, which
/// `stopRecording` calls synchronously between `store.add` and the drain's
/// first `await`. With the bug, the sidecar on disk is already `completed`
/// by then; with the fix it is still `recording`, heartbeat ticking, and
/// only flips after `store.update`.
///
/// (The client-side half of the same contract — a `completed` snapshot's id
/// resolving to the final text, and a `completed` snapshot with no id
/// pointing at `list_recordings` — is covered out of process by
/// `MilaKitTests.MilaMCPToolHandlersTests`.)
@MainActor
final class LiveSidecarHandoffOrderingTests: XCTestCase {

    private var tempRoot: URL!
    private var sidecarRoot: URL!
    private var store: RecordingStore!
    private var manager: ModelManager!
    private var stub: StubWhisperEngine!
    private var service: TranscriptionService!
    private var session: RecordingSession!
    private var languageSettings: RecordingLanguageSettings!
    private var postRecording: PostRecordingCoordinator!
    private var sidecar: LiveTranscriptSidecarWriter!
    private var controller: QuickActionsController!
    private var cancellables: Set<AnyCancellable> = []

    private let suitePrefix = "LiveSidecarHandoffOrderingTests"
    private var savedSelection: String?

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: suitePrefix)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        sidecarRoot = tempRoot.appendingPathComponent("SidecarRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: sidecarRoot, withIntermediateDirectories: true)

        store = RecordingStore(rootDirectory: tempRoot)
        try FileManager.default.createDirectory(at: store.recordingsDirectory,
                                                withIntermediateDirectories: true)
        manager = ModelManager(modelsDirectory: tempRoot.appendingPathComponent("Models"))
        savedSelection = UserDefaults.standard.string(forKey: "selectedModelName")
        try TestSupport.installFakeModel(into: manager)

        stub = StubWhisperEngine()
        service = TranscriptionService(
            store: store,
            modelManager: manager,
            diarizationSettings: DiarizationSettings(
                defaults: .init(suiteName: "\(suitePrefix).diarization")!),
            remoteSettings: TestSupport.isolatedRemoteSettings(label: suitePrefix),
            engine: stub)
        session = RecordingSession()
        languageSettings = RecordingLanguageSettings(
            defaults: UserDefaults(suiteName: "\(suitePrefix).language")!)
        postRecording = PostRecordingCoordinator(
            store: store,
            transcription: service,
            llm: LLMSettings(defaults: UserDefaults(suiteName: "\(suitePrefix).llm")!))
        controller = QuickActionsController(session: session,
                                            store: store,
                                            transcription: service,
                                            languageSettings: languageSettings,
                                            postRecording: postRecording)
        // A long heartbeat keeps the timer out of the assertions — every
        // write this test observes is one `begin`/`finish` made explicitly.
        sidecar = LiveTranscriptSidecarWriter(root: sidecarRoot,
                                              minWriteInterval: 0,
                                              heartbeatInterval: 3600)
        controller.liveSidecarWriter = sidecar
    }

    override func tearDown() async throws {
        cancellables.removeAll()
        // Always restore write permission, or the temp tree can't be removed.
        setRecordingsDirWritable(true)
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        if let savedSelection {
            UserDefaults.standard.set(savedSelection, forKey: "selectedModelName")
        } else {
            UserDefaults.standard.removeObject(forKey: "selectedModelName")
        }
        for suffix in ["diarization", "language", "llm"] {
            UserDefaults().removePersistentDomain(forName: "\(suitePrefix).\(suffix)")
        }
        try await super.tearDown()
    }

    private func snapshot() -> LiveTranscriptSnapshot? {
        LiveTranscriptSnapshot.read(root: sidecarRoot)
    }

    /// The `.txt` transcript sidecar lives in the recordings directory, so
    /// revoking write permission there is what makes `writeTranscript` fail
    /// while leaving `recordings.json` (at the root) writable — isolating the
    /// transcript-persistence failure from everything else.
    private func setRecordingsDirWritable(_ writable: Bool) {
        guard let dir = store?.recordingsDirectory else { return }
        try? FileManager.default.setAttributes(
            [.posixPermissions: writable ? 0o755 : 0o500], ofItemAtPath: dir.path)
    }

    /// Start a fake capture with a real (short) WAV on disk, and open the
    /// live sidecar the way `MilaApp.wireLiveAIPipeline` does at record time.
    private func startFakeRecording() async throws -> URL {
        let url = store.freshAudioURL(suggestedName: "SidecarOrdering")
        try TestSupport.writeStereo48kSineWav(at: url, durationSeconds: 0.6)
        await controller.startFakeRecordingForTesting(outputURL: url)
        sidecar.begin(title: "SidecarOrdering", source: "microphone", liveAvailable: true)
        XCTAssertEqual(snapshot()?.state, .recording)
        return url
    }

    // MARK: -

    func test_sidecar_stays_recording_until_the_final_store_update() async throws {
        _ = try await startFakeRecording()

        // Sampled synchronously inside `present`, i.e. after `store.add`
        // and before the drain's first await.
        var stateAtPresent: LiveTranscriptSnapshot.State?
        var idAtPresent: UUID??
        var presentedID: UUID?
        postRecording.$pending
            .compactMap { $0 }
            .first()
            .sink { [weak self] recording in
                presentedID = recording.id
                let snap = self?.snapshot()
                stateAtPresent = snap?.state
                idAtPresent = snap?.finalRecordingID
            }
            .store(in: &cancellables)

        await controller.stopRecording()

        XCTAssertEqual(stateAtPresent, .recording,
                       "the sidecar must not advertise `completed` while the stored row still holds the pre-drain transcript")
        XCTAssertEqual(idAtPresent, .some(nil),
                       "no handoff id may be published before the final store update")

        // And by the time stopRecording returns, the sidecar is closed against
        // the row the drain just wrote.
        let savedID = try XCTUnwrap(presentedID)
        XCTAssertNotNil(store.recordings.first { $0.id == savedID })
        let final = try XCTUnwrap(snapshot())
        XCTAssertEqual(final.state, .completed)
        // No id here, and that is a separate rule from the ordering this test
        // is about: this fixture has no live segments, so the row is `.pending`
        // and its transcript is owed by the batch worker. See
        // `test_no_handoff_id_while_the_transcript_is_still_pending`.
        XCTAssertNil(final.finalRecordingID)
    }

    /// The recording can vanish mid-finalize — the user cancels the rename
    /// sheet, which permanently deletes the row the drain was about to
    /// update. That path returns early, and it must still close the sidecar:
    /// leaving it in `recording` strands a poller on a transcript that will
    /// never grow (until the next `begin`, or a relaunch rewrites it as
    /// `interrupted`). It closes with NO id, because the row the poller
    /// would have been sent to no longer exists.
    func test_recording_removed_during_finalization_finishes_with_no_handoff_id() async throws {
        _ = try await startFakeRecording()

        var presentedID: UUID?
        postRecording.$pending
            .compactMap { $0 }
            .first()
            .sink { [weak self] recording in
                presentedID = recording.id
                self?.store.permanentlyDelete(recording)
            }
            .store(in: &cancellables)

        await controller.stopRecording()

        let removedID = try XCTUnwrap(presentedID)
        XCTAssertNil(store.recordings.first { $0.id == removedID },
                     "precondition: the row must actually be gone by the time the drain looks for it")
        let final = try XCTUnwrap(snapshot())
        XCTAssertEqual(final.state, .completed,
                       "the removal path must still close the sidecar — a poller cannot wait forever on a row that is gone")
        XCTAssertNil(final.finalRecordingID,
                     "handing out the id of a deleted recording gives get_transcript nothing but a 404")
    }

    /// REGRESSION (CodeRabbit on #183, Major — "do not publish the handoff
    /// when transcript persistence fails"):
    ///
    /// The ordering fix above governs WHEN the handoff is published. This is
    /// WHETHER. `RecordingStore.update` writes the `.txt` sidecar, and
    /// `writeTranscript` used to swallow its write errors (a `print` and carry
    /// on), so `finish(recordingID:)` published `completed` + the id even when
    /// the transcript never reached disk. `MilaStoreReader.transcriptText`
    /// reads that sidecar FIRST, so the client following the id got the
    /// PREVIOUS text — indistinguishable, from its side, from a real answer.
    ///
    /// Here the final transcript is empty (no live segments), so `update`
    /// clears the sidecar — and the stale one can't be removed because the
    /// recordings directory is read-only. A reader would keep serving the old
    /// text, so no id may be published.
    func test_no_handoff_id_when_the_transcript_sidecar_cannot_be_written() async throws {
        let url = try await startFakeRecording()
        let sidecarTxt = url.deletingPathExtension().appendingPathExtension("txt")
        try "stale transcript from a previous run".write(to: sidecarTxt,
                                                        atomically: true, encoding: .utf8)
        setRecordingsDirWritable(false)

        await controller.stopRecording()

        let final = try XCTUnwrap(snapshot())
        XCTAssertEqual(final.state, .completed, "the recording is over either way")
        XCTAssertNil(final.finalRecordingID,
                     "an id whose transcript is stale on disk must not be handed out")
        XCTAssertEqual(try String(contentsOf: sidecarTxt, encoding: .utf8),
                       "stale transcript from a previous run",
                       "precondition: the stale sidecar really did survive, which is the hazard")
    }

    /// REGRESSION (CodeRabbit on #183, Major — "do not publish a final handoff
    /// for a pending transcript"):
    ///
    /// **This test previously encoded the bug.** It drove a recording with no
    /// live segments — so `liveTranscriptIsAuthoritative` is false and the row
    /// is saved `.pending` with EMPTY `fullText` — and then asserted that a
    /// handoff id *was* published, calling that "the common path". It was not a
    /// correct path at all: `get_live_transcript` describes
    /// `final_recording_id` as resolving to "the authoritative transcript", and
    /// here it resolved to a row the batch worker had not transcribed yet.
    ///
    /// The assertion is now inverted, which is the actual contract: no
    /// transcript, no handoff. The client is sent to `list_recordings` instead,
    /// and the id arrives later from the batch-completion hook (covered by
    /// `test_late_handoff_is_published_after_batch_completion` below and by
    /// `LiveTranscriptSidecarWriterTests`).
    func test_no_handoff_id_while_the_transcript_is_still_pending() async throws {
        _ = try await startFakeRecording()

        await controller.stopRecording()

        let saved = try XCTUnwrap(store.recordings.first)
        XCTAssertEqual(saved.status, .pending,
                       "precondition: no live segments means the batch worker still owes us a transcript")

        let final = try XCTUnwrap(snapshot())
        XCTAssertEqual(final.state, .completed, "the recording itself is over")
        XCTAssertNil(final.finalRecordingID,
                     "a `.pending` row must not be advertised as the authoritative transcript")
        let note = try XCTUnwrap(finalNoteForClient())
        XCTAssertTrue(note.contains("list_recordings"), note)
    }

    /// The deferred half of the same contract: once the batch pass completes,
    /// the handoff IS published, against the same snapshot, without a new
    /// recording having started.
    func test_late_handoff_is_published_after_batch_completion() async throws {
        _ = try await startFakeRecording()
        await controller.stopRecording()

        let saved = try XCTUnwrap(store.recordings.first)
        XCTAssertNil(try XCTUnwrap(snapshot()).finalRecordingID, "precondition")

        // What `TranscriptionService.onTranscriptionCompleted` does for this
        // recording once its batch transcript lands.
        sidecar.attachHandoff(forRecording: saved.id)

        let final = try XCTUnwrap(snapshot())
        XCTAssertEqual(final.state, .completed)
        XCTAssertEqual(final.finalRecordingID, saved.id,
                       "the handoff must arrive once there is a real transcript to hand off")
    }

    /// A completion for some OTHER recording — a user re-transcribing an old
    /// row, which fires the same global hook — must not stamp this snapshot.
    func test_late_handoff_ignores_an_unrelated_completion() async throws {
        _ = try await startFakeRecording()
        await controller.stopRecording()

        sidecar.attachHandoff(forRecording: UUID())

        XCTAssertNil(try XCTUnwrap(snapshot()).finalRecordingID,
                     "the completion hook is global; only the awaited recording may claim the handoff")
    }

    /// And a late completion must never touch a NEWER meeting's snapshot.
    func test_late_handoff_does_not_clobber_a_new_recording() async throws {
        _ = try await startFakeRecording()
        await controller.stopRecording()
        let saved = try XCTUnwrap(store.recordings.first)

        // A second meeting starts before the first one's batch pass lands.
        sidecar.begin(title: "Next meeting", source: "microphone", liveAvailable: true)
        let liveSession = try XCTUnwrap(snapshot()).sessionID

        sidecar.attachHandoff(forRecording: saved.id)

        let current = try XCTUnwrap(snapshot())
        XCTAssertEqual(current.state, .recording, "the live meeting's snapshot must survive intact")
        XCTAssertEqual(current.sessionID, liveSession)
        XCTAssertNil(current.finalRecordingID)
    }

    /// The `note` an MCP client would receive for the current snapshot, taken
    /// from the same handler the helper runs.
    private func finalNoteForClient() throws -> String? {
        try MCPAccessGate.set(true, root: sidecarRoot)
        let raw = try MilaMCPToolHandlers(root: sidecarRoot)
            .handle(tool: "get_live_transcript", arguments: [:])
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        return json["note"] as? String
    }
}
