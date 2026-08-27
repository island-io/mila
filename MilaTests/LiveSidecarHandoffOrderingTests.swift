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

        // And by the time stopRecording returns, the handoff IS published,
        // naming the row the drain just wrote.
        let savedID = try XCTUnwrap(presentedID)
        XCTAssertNotNil(store.recordings.first { $0.id == savedID })
        let final = try XCTUnwrap(snapshot())
        XCTAssertEqual(final.state, .completed)
        XCTAssertEqual(final.finalRecordingID, savedID)
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
}
