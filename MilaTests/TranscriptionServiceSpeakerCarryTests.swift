import XCTest
import TranscriptionCore
@testable import Mila

/// Collects the two completion hooks in the order the service fires them. A
/// class rather than captured `var`s, so both escaping closures write to one
/// place.
@MainActor
private final class PassRecorder {
    var events: [String] = []
    var clearedID: UUID?
    var clearedNames: [String: String]?
    var namesOnTheCompletedRow: [String: String]?
}

/// The half of island-io/mila#260 that only a real pass can pin: a batch
/// transcription clears the recording's `speakerNames` wholesale, and the
/// names it drops have to be handed over **before** the completion hook —
/// because `OfflineVoiceEmbedder.matchAfterPass`, wired to that hook, drops
/// every observation those names were keyed to as its first act.
///
/// `OfflineVoiceEmbedderTests` supplies the pass output by hand, which means
/// it cannot see the service capture the names as it clears them, or fire the
/// two hooks in the wrong order. Those are exactly the ways this can fail
/// silently — no crash, no error, just a profile contribution stranded again
/// — so they are driven here through `enqueue`, a real store write and a real
/// (stubbed-engine) pass.
@MainActor
final class TranscriptionServiceSpeakerCarryTests: XCTestCase {

    private var tempRoot: URL!
    private var store: RecordingStore!
    private var manager: ModelManager!
    private var stub: StubWhisperEngine!
    private var service: TranscriptionService!
    private var savedSelection: String?

    private let suite = "TranscriptionServiceSpeakerCarryTests"

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: suite)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        store = RecordingStore(rootDirectory: tempRoot)
        manager = ModelManager(modelsDirectory: tempRoot.appendingPathComponent("Models"))
        savedSelection = UserDefaults.standard.string(forKey: "selectedModelName")
        try TestSupport.installFakeModel(into: manager)

        stub = StubWhisperEngine()
        service = TranscriptionService(
            store: store,
            modelManager: manager,
            diarizationSettings: DiarizationSettings(
                defaults: .init(suiteName: "\(suite).diarization")!),
            remoteSettings: TestSupport.isolatedRemoteSettings(label: suite),
            engine: stub)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        for name in ["\(suite).diarization", "\(suite).remote"] {
            UserDefaults().removePersistentDomain(forName: name)
        }
        if let savedSelection {
            UserDefaults.standard.set(savedSelection, forKey: "selectedModelName")
        } else {
            UserDefaults.standard.removeObject(forKey: "selectedModelName")
        }
        try await super.tearDown()
    }

    private func wireHooks(to recorder: PassRecorder) {
        service.onPassClearedSpeakerNames = { recordingID, names in
            recorder.events.append("cleared")
            recorder.clearedID = recordingID
            recorder.clearedNames = names
        }
        service.onTranscriptionCompleted = { rec, _ in
            recorder.events.append("completed")
            recorder.namesOnTheCompletedRow = rec.speakerNames
        }
    }

    /// The pass re-keys every `SPEAKER_NN`, so it clears the names bound to
    /// the old ids — and each of those names had folded an observation into a
    /// voice profile. This is the only moment those pairs still exist: the
    /// row handed to `onTranscriptionCompleted` has already lost them, which
    /// the last assertion here pins directly.
    func test_a_pass_hands_over_the_speaker_names_it_clears() async throws {
        let fixture = try TestRecordingFixture.make(in: store, title: "Named")
        store.setSpeakerName("Alice", forSpeaker: "SPEAKER_00", recordingID: fixture.recording.id)
        store.setSpeakerName("Bob", forSpeaker: "SPEAKER_01", recordingID: fixture.recording.id)
        await stub.setDefaultCanned([TranscriptSegment(start: 0, end: 0.5, text: "hello")])

        let recorder = PassRecorder()
        wireHooks(to: recorder)

        service.enqueue(try XCTUnwrap(store.recordings.first { $0.id == fixture.recording.id }))
        await service.waitForIdle()

        let stored = try XCTUnwrap(store.recordings.first { $0.id == fixture.recording.id })
        XCTAssertEqual(stored.status, .completed)
        XCTAssertTrue(stored.speakerNames.isEmpty,
                      "precondition: a segment-producing pass still clears the names it re-keyed")
        XCTAssertEqual(recorder.clearedID, fixture.recording.id)
        XCTAssertEqual(recorder.clearedNames,
                       ["SPEAKER_00": "Alice", "SPEAKER_01": "Bob"],
                       "every pair the row lost, taken from the row that was actually written")
        XCTAssertEqual(recorder.namesOnTheCompletedRow, [String: String](),
                       "the completed row carries none of them — which is why they need their own hand-over")
    }

    /// The ordering the repair depends on. `matchAfterPass` runs off
    /// `onTranscriptionCompleted` and invalidates the recording's
    /// observations immediately, so a hand-over that arrived afterwards would
    /// name contributions nothing can resolve any more. Swapping the two
    /// lines in `announceCompletion` fails nothing else in the suite.
    func test_the_cleared_names_arrive_before_the_completion_hook() async throws {
        let fixture = try TestRecordingFixture.make(in: store, title: "Ordered")
        store.setSpeakerName("Alice", forSpeaker: "SPEAKER_00", recordingID: fixture.recording.id)
        await stub.setDefaultCanned([TranscriptSegment(start: 0, end: 0.5, text: "hello")])

        let recorder = PassRecorder()
        wireHooks(to: recorder)

        service.enqueue(try XCTUnwrap(store.recordings.first { $0.id == fixture.recording.id }))
        await service.waitForIdle()

        XCTAssertEqual(recorder.events, ["cleared", "completed"])
    }

    /// A first transcription has nothing to hand over, and says so. The hook
    /// still fires for every completed pass — `OfflineVoiceEmbedder` uses the
    /// empty announcement to clear anything a previous pass left behind.
    func test_a_pass_with_nothing_to_clear_still_reports_an_empty_map() async throws {
        let fixture = try TestRecordingFixture.make(in: store, title: "Fresh")
        await stub.setDefaultCanned([TranscriptSegment(start: 0, end: 0.5, text: "hello")])

        let recorder = PassRecorder()
        wireHooks(to: recorder)

        service.enqueue(fixture.recording)
        await service.waitForIdle()

        XCTAssertEqual(recorder.events, ["cleared", "completed"])
        XCTAssertEqual(recorder.clearedNames, [String: String]())
    }

    /// The negative control on the capture: a pass that produced NO segments
    /// re-keyed nothing, so it neither clears the user's speaker names nor
    /// reports any. (It lands `.failed`, so neither hook fires at all.) A
    /// capture taken outside the `enrichedSegments` check would report names
    /// that are still on the row — inviting a correction for a change that
    /// never happened.
    func test_an_empty_pass_neither_clears_nor_reports_the_names() async throws {
        let fixture = try TestRecordingFixture.make(in: store, title: "Silent")
        store.setSpeakerName("Alice", forSpeaker: "SPEAKER_00", recordingID: fixture.recording.id)
        await stub.setDefaultCanned([])

        let recorder = PassRecorder()
        wireHooks(to: recorder)

        service.enqueue(try XCTUnwrap(store.recordings.first { $0.id == fixture.recording.id }))
        await service.waitForIdle()

        let stored = try XCTUnwrap(store.recordings.first { $0.id == fixture.recording.id })
        XCTAssertEqual(stored.status, .failed)
        XCTAssertEqual(stored.speakerNames, ["SPEAKER_00": "Alice"],
                       "hand-typed names survive a pass that produced nothing")
        XCTAssertEqual(recorder.events, [String](), "and nothing is announced about them")
        XCTAssertNil(recorder.clearedNames)
    }
}
