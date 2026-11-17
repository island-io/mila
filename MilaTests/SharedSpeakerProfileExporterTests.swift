import XCTest
import TranscriptionCore
@testable import Mila

@MainActor
final class SharedSpeakerProfileExporterTests: XCTestCase {

    private var dir: URL!
    private var suiteNames: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        dir = TestSupport.makeTempRoot(label: "SharedSpeakerProfileExporterTests")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        try await super.tearDown()
    }

    private func makeStore(enabled: Bool) -> SpeakerProfileStore {
        let name = "SharedSpeakerProfileExporterTests.\(UUID())"
        suiteNames.append(name)
        let settings = VoiceRecognitionSettings(defaults: UserDefaults(suiteName: name)!)
        settings.diarizationReady = { true }
        settings.isEnabled = enabled
        return SpeakerProfileStore(directory: dir, settings: settings)
    }

    private func profile(_ name: String, samples: Int = 3, model: String? = nil) -> VoiceProfile {
        VoiceProfile(id: UUID(), name: name, embedding: [1, 0], sampleCount: samples,
                     createdAt: Date(), lastSeenAt: Date(), embeddingModel: model)
    }

    private let recording = Recording(
        title: "Sync", source: .meeting, audioFileName: "a.wav", status: .completed,
        segments: [TranscriptSegment(start: 0, end: 1, text: "a", speaker: "SPEAKER_00"),
                   TranscriptSegment(start: 1, end: 2, text: "b", speaker: "SPEAKER_01")],
        speakerNames: ["SPEAKER_00": "Daniel", "SPEAKER_01": "Ada", "SPEAKER_07": "Stale"])

    func test_nothing_is_exported_unless_the_box_is_ticked() {
        var selection = SharedSpeakersExportSelection(available: [profile("Daniel"), profile("Ada")])
        XCTAssertFalse(selection.includeProfiles, "the opt-in starts off")
        XCTAssertEqual(SharedSpeakerProfileExporter.manifestEntries(selection), [])
        selection.includeProfiles = true
        XCTAssertEqual(SharedSpeakerProfileExporter.manifestEntries(selection).map(\.name), ["Daniel", "Ada"])
    }

    func test_excluded_speakers_are_dropped_and_entries_carry_the_model_stamp() {
        let daniel = profile("Daniel")
        var selection = SharedSpeakersExportSelection(available: [daniel, profile("Ada", model: "legacy-stamp")])
        selection.includeProfiles = true
        selection.setIncluded(false, for: daniel)
        XCTAssertFalse(selection.isIncluded(daniel))
        let entries = SharedSpeakerProfileExporter.manifestEntries(selection)
        XCTAssertEqual(entries.map(\.name), ["Ada"])
        XCTAssertEqual(entries[0].embeddingModel, "legacy-stamp")
        XCTAssertEqual(entries[0].sampleCount, 3)

        var unstamped = SharedSpeakersExportSelection(available: [profile("Daniel")])
        unstamped.includeProfiles = true
        XCTAssertEqual(SharedSpeakerProfileExporter.manifestEntries(unstamped)[0].embeddingModel,
                       SpeakerEmbeddingModel.current.id, "a legacy row is stamped with the only model that ever shipped")
    }

    func test_only_profiles_of_speakers_named_in_the_transcript_are_available() {
        let store = makeStore(enabled: true)
        store.updateProfile(name: "Daniel", embedding: [1, 0], sampleCount: 1)
        store.updateProfile(name: "Stale", embedding: [1, 0], sampleCount: 1)      // mapped, but no segment
        store.updateProfile(name: "Stranger", embedding: [1, 0], sampleCount: 1)   // not in the recording
        let available = SharedSpeakerProfileExporter.availableProfiles(for: recording, store: store)
        XCTAssertEqual(available.map(\.name), ["Daniel"], "Ada has no profile; Stale and Stranger aren't speaking")
        XCTAssertEqual(SharedSpeakerProfileExporter.namedSpeakers(in: recording), ["Daniel", "Ada"])
    }

    func test_voice_recognition_off_offers_nothing() {
        let store = makeStore(enabled: false)
        XCTAssertEqual(SharedSpeakerProfileExporter.availableProfiles(for: recording, store: store), [])
    }

    func test_shared_profile_round_trips_and_decodes_leniently() throws {
        let p = SharedSpeakerProfile(name: "Ada", embedding: [0.25, 0.5], sampleCount: 2,
                                     embeddingModel: SpeakerEmbeddingModel.current.id)
        let decoded = try JSONDecoder().decode(SharedSpeakerProfile.self, from: try JSONEncoder().encode(p))
        XCTAssertEqual(decoded, p)
        let sparse = try JSONDecoder().decode(SharedSpeakerProfile.self, from: Data(#"{ "name": "X" }"#.utf8))
        XCTAssertEqual(sparse.embedding, [])
        XCTAssertEqual(sparse.sampleCount, 0)
        XCTAssertEqual(sparse.embeddingModel, "")
    }
}
