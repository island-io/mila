import XCTest
@testable import Mila

/// Unit tests for the per-recording snapshot store that keeps one recording's
/// voices from being written into another's profile.
@MainActor
final class ObservedVoiceSnapshotsTests: XCTestCase {

    private var suiteNames: [String] = []

    override func tearDown() async throws {
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        suiteNames.removeAll()
        try await super.tearDown()
    }

    private func makeSettings(enabled: Bool = true) -> VoiceRecognitionSettings {
        let name = "ObservedVoiceSnapshotsTests.\(UUID())"
        suiteNames.append(name)
        let settings = VoiceRecognitionSettings(defaults: UserDefaults(suiteName: name)!)
        settings.diarizationReady = { true }
        settings.isEnabled = enabled
        return settings
    }

    private func entries(_ pairs: [(String, [Float], Int, String?)])
        -> [(id: String, observedCentroid: [Float], observedCount: Int, profileName: String?)] {
        pairs.map { (id: $0.0, observedCentroid: $0.1, observedCount: $0.2, profileName: $0.3) }
    }

    // MARK: - Per-recording isolation

    /// The same raw speaker id in two recordings resolves to two different
    /// voices. This is the whole point: `SPEAKER_00` is positional and means
    /// nothing across recordings.
    func test_the_same_raw_id_in_two_recordings_resolves_separately() {
        let snapshots = ObservedVoiceSnapshots()
        let recA = UUID(), recB = UUID()

        snapshots.record(entries([("SPEAKER_00", [1, 0], 2, "Alice")]), for: recA)
        snapshots.record(entries([("SPEAKER_00", [0, 1], 5, nil)]), for: recB)

        XCTAssertEqual(snapshots.observation(forSpeaker: "SPEAKER_00", in: recA),
                       .init(observedCentroid: [1, 0], observedCount: 2, profileName: "Alice"))
        XCTAssertEqual(snapshots.observation(forSpeaker: "SPEAKER_00", in: recB),
                       .init(observedCentroid: [0, 1], observedCount: 5, profileName: nil))
    }

    func test_an_unknown_recording_or_speaker_resolves_to_nil() {
        let snapshots = ObservedVoiceSnapshots()
        let rec = UUID()
        snapshots.record(entries([("SPEAKER_00", [1, 0], 2, nil)]), for: rec)

        XCTAssertNil(snapshots.observation(forSpeaker: "SPEAKER_01", in: rec),
                     "unknown speaker in a known recording")
        XCTAssertNil(snapshots.observation(forSpeaker: "SPEAKER_00", in: UUID()),
                     "known speaker id in an unknown recording — must not fall through")
    }

    /// Every pool entry is retained, seeded or not: a speaker the user names
    /// by hand is how profiles get created in the first place.
    func test_unseeded_entries_are_retained_too() {
        let snapshots = ObservedVoiceSnapshots()
        let rec = UUID()
        snapshots.record(entries([("SPEAKER_00", [1, 0], 1, nil),
                                  ("SPEAKER_01", [0, 1], 3, "Bob")]), for: rec)

        XCTAssertEqual(snapshots.observation(forSpeaker: "SPEAKER_00", in: rec)?.observedCount, 1)
        XCTAssertNil(snapshots.observation(forSpeaker: "SPEAKER_00", in: rec)?.profileName)
        XCTAssertEqual(snapshots.observation(forSpeaker: "SPEAKER_01", in: rec)?.profileName, "Bob")
    }

    /// Re-snapshotting a recording replaces its entry rather than
    /// accumulating a second one, and doesn't consume another eviction slot.
    func test_re_recording_the_same_recording_replaces_in_place() {
        let snapshots = ObservedVoiceSnapshots()
        let rec = UUID()

        snapshots.record(entries([("SPEAKER_00", [1, 0], 1, nil)]), for: rec)
        snapshots.record(entries([("SPEAKER_00", [1, 0], 4, nil)]), for: rec)

        XCTAssertEqual(snapshots.heldRecordingCount, 1)
        XCTAssertEqual(snapshots.observation(forSpeaker: "SPEAKER_00", in: rec)?.observedCount, 4)
    }

    // MARK: - Bounded retention

    /// Held snapshots are capped, oldest evicted first, so embeddings don't
    /// accumulate for the life of the process.
    func test_retention_is_bounded_and_evicts_oldest_first() {
        let snapshots = ObservedVoiceSnapshots(limit: 3)
        let ids = (0..<5).map { _ in UUID() }
        for id in ids {
            snapshots.record(entries([("SPEAKER_00", [1, 0], 1, nil)]), for: id)
        }

        XCTAssertEqual(snapshots.heldRecordingCount, 3)
        XCTAssertNil(snapshots.observation(forSpeaker: "SPEAKER_00", in: ids[0]), "evicted")
        XCTAssertNil(snapshots.observation(forSpeaker: "SPEAKER_00", in: ids[1]), "evicted")
        XCTAssertNotNil(snapshots.observation(forSpeaker: "SPEAKER_00", in: ids[2]))
        XCTAssertNotNil(snapshots.observation(forSpeaker: "SPEAKER_00", in: ids[4]))
    }

    func test_a_limit_below_one_is_clamped() {
        let snapshots = ObservedVoiceSnapshots(limit: 0)
        let rec = UUID()
        snapshots.record(entries([("SPEAKER_00", [1, 0], 1, nil)]), for: rec)
        XCTAssertEqual(snapshots.heldRecordingCount, 1,
                       "a zero limit would drop the snapshot it was just handed")
    }

    // MARK: - Opt-out

    /// Opting out discards everything held, so an opted-out user has no voice
    /// data in memory here either — matching `SpeakerProfileStore`, which
    /// drops its loaded profiles on the same signal.
    func test_opting_out_discards_held_observations() {
        let settings = makeSettings()
        let snapshots = ObservedVoiceSnapshots()
        snapshots.clearOnOptOut(of: settings)
        let rec = UUID()
        snapshots.record(entries([("SPEAKER_00", [1, 0], 2, "Alice")]), for: rec)
        XCTAssertEqual(snapshots.heldRecordingCount, 1)

        settings.isEnabled = false

        XCTAssertEqual(snapshots.heldRecordingCount, 0)
        XCTAssertNil(snapshots.observation(forSpeaker: "SPEAKER_00", in: rec))
    }

    /// Opting back *in* doesn't resurrect anything — those recordings' pools
    /// are gone.
    func test_opting_back_in_does_not_restore_discarded_observations() {
        let settings = makeSettings()
        let snapshots = ObservedVoiceSnapshots()
        snapshots.clearOnOptOut(of: settings)
        let rec = UUID()
        snapshots.record(entries([("SPEAKER_00", [1, 0], 2, nil)]), for: rec)

        settings.isEnabled = false
        settings.isEnabled = true

        XCTAssertEqual(snapshots.heldRecordingCount, 0)
    }

    /// Two objects observing the same settings must *both* hear an opt-out.
    /// With a single assignable callback slot the second registrant silently
    /// unhooked the first, so whichever was constructed last would have been
    /// the only one to react — the store would have kept its profiles loaded,
    /// or the snapshots their embeddings, depending on construction order.
    func test_multiple_observers_all_hear_an_opt_out() {
        let settings = makeSettings()
        var heard: [String] = []
        settings.addEnabledObserver { _ in heard.append("first") }
        settings.addEnabledObserver { _ in heard.append("second") }

        settings.isEnabled = false

        XCTAssertEqual(heard, ["first", "second"])
    }

    /// The store and the snapshots are the two real registrants; assert they
    /// coexist rather than clobbering each other.
    func test_the_profile_store_and_snapshots_both_react_to_an_opt_out() throws {
        let tempRoot = TestSupport.makeTempRoot(label: "ObservedVoiceSnapshotsTests")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let settings = makeSettings()
        let profiles = SpeakerProfileStore(directory: tempRoot, settings: settings)
        let snapshots = ObservedVoiceSnapshots()
        snapshots.clearOnOptOut(of: settings)

        profiles.updateProfile(name: "Alice", embedding: [1, 0], sampleCount: 3)
        snapshots.record(entries([("SPEAKER_00", [1, 0], 1, "Alice")]), for: UUID())
        XCTAssertEqual(profiles.profiles.count, 1)
        XCTAssertEqual(snapshots.heldRecordingCount, 1)

        settings.isEnabled = false

        XCTAssertTrue(profiles.profiles.isEmpty, "store dropped its loaded profiles")
        XCTAssertEqual(snapshots.heldRecordingCount, 0, "snapshots dropped their observations")
    }
}
