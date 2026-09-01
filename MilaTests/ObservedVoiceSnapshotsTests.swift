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

    // MARK: - Partial writes (`merge`)

    /// The bug this method exists for. The on-demand extractor writes one
    /// speaker at a time — naming `SPEAKER_00` and then `SPEAKER_01` on an
    /// old recording are two independent Python runs — and `record` replaces
    /// the whole per-recording map, so the second landing erased the first.
    /// Un-naming the first speaker afterwards then found nothing to subtract
    /// and left the polluted profile alone, which is the failure
    /// island-io/mila#237 exists to remove.
    func test_merging_a_single_speaker_keeps_the_others() {
        let snapshots = ObservedVoiceSnapshots()
        let rec = UUID()

        snapshots.merge(entries([("SPEAKER_00", [1, 0], 1, nil)]), for: rec)
        snapshots.merge(entries([("SPEAKER_01", [0, 1], 1, nil)]), for: rec)

        XCTAssertEqual(snapshots.observation(forSpeaker: "SPEAKER_00", in: rec)?.observedCentroid,
                       [1, 0], "the first extraction must survive the second")
        XCTAssertEqual(snapshots.observation(forSpeaker: "SPEAKER_01", in: rec)?.observedCentroid,
                       [0, 1])
        XCTAssertEqual(snapshots.heldRecordingCount, 1)
    }

    /// The negative control: `record` still replaces, because the live-stop
    /// path hands over the complete pool and wants exactly that.
    func test_record_still_replaces_the_whole_map() {
        let snapshots = ObservedVoiceSnapshots()
        let rec = UUID()

        snapshots.record(entries([("SPEAKER_00", [1, 0], 1, nil)]), for: rec)
        snapshots.record(entries([("SPEAKER_01", [0, 1], 1, nil)]), for: rec)

        XCTAssertNil(snapshots.observation(forSpeaker: "SPEAKER_00", in: rec),
                     "if this passes as non-nil, `merge` above is no longer testing anything")
    }

    func test_merging_the_same_speaker_twice_takes_the_newer_observation() {
        let snapshots = ObservedVoiceSnapshots()
        let rec = UUID()

        snapshots.merge(entries([("SPEAKER_00", [1, 0], 1, nil)]), for: rec)
        snapshots.merge(entries([("SPEAKER_00", [0, 1], 3, "Alice")]), for: rec)

        XCTAssertEqual(snapshots.observation(forSpeaker: "SPEAKER_00", in: rec),
                       .init(observedCentroid: [0, 1], observedCount: 3, profileName: "Alice"))
    }

    /// A merge into a recording nothing is held for still enrols it in the
    /// eviction queue exactly once.
    func test_merging_into_an_unknown_recording_enrols_it_once() {
        let snapshots = ObservedVoiceSnapshots()
        let rec = UUID()

        snapshots.merge(entries([("SPEAKER_00", [1, 0], 1, nil)]), for: rec)
        snapshots.merge(entries([("SPEAKER_01", [0, 1], 1, nil)]), for: rec)

        XCTAssertEqual(snapshots.heldRecordingCount, 1,
                       "two partial writes to one recording must not take two eviction slots")
    }

    // MARK: - Invalidation on a re-key

    /// A pass that re-keys `SPEAKER_NN` makes every held embedding meaningless
    /// — the same string may now denote a different person. Nothing must
    /// resolve through them afterwards.
    func test_invalidating_a_recording_drops_everything_it_held() {
        let snapshots = ObservedVoiceSnapshots()
        let rec = UUID(), other = UUID()
        snapshots.record(entries([("SPEAKER_00", [1, 0], 2, "Alice"),
                                  ("SPEAKER_01", [0, 1], 2, nil)]), for: rec)
        snapshots.record(entries([("SPEAKER_00", [1, 1], 2, nil)]), for: other)

        snapshots.invalidate(rec)

        XCTAssertNil(snapshots.observation(forSpeaker: "SPEAKER_00", in: rec))
        XCTAssertNil(snapshots.observation(forSpeaker: "SPEAKER_01", in: rec))
        XCTAssertEqual(snapshots.heldRecordingCount, 1, "its eviction slot goes too")
        XCTAssertNotNil(snapshots.observation(forSpeaker: "SPEAKER_00", in: other),
                        "other recordings are untouched")
    }

    /// Invalidation must free the slot, not merely blank the entry —
    /// otherwise a re-keyed recording keeps holding a place in the queue and
    /// evicts a live one.
    func test_invalidating_frees_the_eviction_slot() {
        let snapshots = ObservedVoiceSnapshots(limit: 2)
        let a = UUID(), b = UUID(), c = UUID()
        snapshots.record(entries([("SPEAKER_00", [1, 0], 1, nil)]), for: a)
        snapshots.invalidate(a)
        snapshots.record(entries([("SPEAKER_00", [1, 0], 1, nil)]), for: b)
        snapshots.record(entries([("SPEAKER_00", [1, 0], 1, nil)]), for: c)

        XCTAssertNotNil(snapshots.observation(forSpeaker: "SPEAKER_00", in: b),
                        "b must not have been evicted by a slot `a` no longer needs")
        XCTAssertNotNil(snapshots.observation(forSpeaker: "SPEAKER_00", in: c))
    }

    func test_invalidating_an_unknown_recording_is_a_no_op() {
        let snapshots = ObservedVoiceSnapshots()
        let rec = UUID()
        snapshots.record(entries([("SPEAKER_00", [1, 0], 1, nil)]), for: rec)

        snapshots.invalidate(UUID())

        XCTAssertEqual(snapshots.heldRecordingCount, 1)
        XCTAssertNotNil(snapshots.observation(forSpeaker: "SPEAKER_00", in: rec))
    }

    // MARK: - Retiring one speaker id

    /// `splitSegmentSpeaker` hands out the lowest free `SPEAKER_NN`, so an id
    /// that a merge retired comes back. Its embedding must not.
    func test_forgetting_a_retired_speaker_leaves_the_rest_of_the_recording() {
        let snapshots = ObservedVoiceSnapshots()
        let rec = UUID()
        snapshots.record(entries([("SPEAKER_00", [1, 0], 2, nil),
                                  ("SPEAKER_01", [0, 1], 2, "Bob")]), for: rec)

        snapshots.forget(speaker: "SPEAKER_01", in: rec)

        XCTAssertNil(snapshots.observation(forSpeaker: "SPEAKER_01", in: rec))
        XCTAssertEqual(snapshots.observation(forSpeaker: "SPEAKER_00", in: rec)?.observedCentroid,
                       [1, 0])
        XCTAssertEqual(snapshots.heldRecordingCount, 1,
                       "the recording is still held — only one speaker went")
    }

    func test_forgetting_an_unknown_speaker_or_recording_is_a_no_op() {
        let snapshots = ObservedVoiceSnapshots()
        let rec = UUID()
        snapshots.record(entries([("SPEAKER_00", [1, 0], 2, nil)]), for: rec)

        snapshots.forget(speaker: "SPEAKER_09", in: rec)
        snapshots.forget(speaker: "SPEAKER_00", in: UUID())

        XCTAssertNotNil(snapshots.observation(forSpeaker: "SPEAKER_00", in: rec))
        XCTAssertEqual(snapshots.heldRecordingCount, 1)
    }

    // MARK: - Absorbing a retired id

    /// A merge moves the source's *profile* contribution onto the target, so
    /// the target's snapshot has to account for both — otherwise un-naming
    /// the target subtracts one observation from a profile that received two
    /// and strands the rest with no way to reach it.
    func test_absorbing_combines_both_observations_under_the_target() {
        let snapshots = ObservedVoiceSnapshots()
        let rec = UUID()
        snapshots.record(entries([("SPEAKER_00", [1, 0], 1, nil),
                                  ("SPEAKER_01", [0, 1], 1, nil)]), for: rec)

        snapshots.absorb(speaker: "SPEAKER_01", into: "SPEAKER_00", in: rec)

        XCTAssertNil(snapshots.observation(forSpeaker: "SPEAKER_01", in: rec))
        let merged = snapshots.observation(forSpeaker: "SPEAKER_00", in: rec)
        XCTAssertEqual(merged?.observedCount, 2, "the target now accounts for both")
        // Weighted mean of [1,0] x1 and [0,1] x1.
        XCTAssertEqual(merged?.observedCentroid.first ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(merged?.observedCentroid.last ?? 0, 0.5, accuracy: 0.0001)
    }

    /// The weighting has to match `updateProfile`'s fold, which is what makes
    /// "add A then add B" and "add mean(A, B) at the summed count"
    /// interchangeable — and so makes `subtractObservation` an exact inverse
    /// of the pair.
    func test_absorbing_weights_by_sample_count() {
        let snapshots = ObservedVoiceSnapshots()
        let rec = UUID()
        snapshots.record(entries([("SPEAKER_00", [1, 0], 3, nil),
                                  ("SPEAKER_01", [0, 1], 1, nil)]), for: rec)

        snapshots.absorb(speaker: "SPEAKER_01", into: "SPEAKER_00", in: rec)

        let merged = snapshots.observation(forSpeaker: "SPEAKER_00", in: rec)
        XCTAssertEqual(merged?.observedCount, 4)
        XCTAssertEqual(merged?.observedCentroid.first ?? 0, 0.75, accuracy: 0.0001)
        XCTAssertEqual(merged?.observedCentroid.last ?? 0, 0.25, accuracy: 0.0001)
    }

    /// The target may have no observation of its own — a speaker nobody named
    /// on a recording with a partial snapshot. The source's simply becomes
    /// the target's.
    func test_absorbing_into_a_speaker_with_no_observation_moves_it_across() {
        let snapshots = ObservedVoiceSnapshots()
        let rec = UUID()
        snapshots.record(entries([("SPEAKER_01", [0, 1], 2, "Bob")]), for: rec)

        snapshots.absorb(speaker: "SPEAKER_01", into: "SPEAKER_00", in: rec)

        XCTAssertNil(snapshots.observation(forSpeaker: "SPEAKER_01", in: rec))
        XCTAssertEqual(snapshots.observation(forSpeaker: "SPEAKER_00", in: rec)?.observedCount, 2)
    }

    func test_absorbing_an_unknown_source_or_into_itself_is_a_no_op() {
        let snapshots = ObservedVoiceSnapshots()
        let rec = UUID()
        snapshots.record(entries([("SPEAKER_00", [1, 0], 1, nil)]), for: rec)

        snapshots.absorb(speaker: "SPEAKER_09", into: "SPEAKER_00", in: rec)
        snapshots.absorb(speaker: "SPEAKER_00", into: "SPEAKER_00", in: rec)

        XCTAssertEqual(snapshots.observation(forSpeaker: "SPEAKER_00", in: rec)?.observedCount, 1,
                       "absorbing a speaker into itself must not double its count")
    }

    /// Two extractions from different embedding models cannot be averaged.
    /// Keep the target's own rather than persist a centroid spanning two
    /// spaces.
    func test_absorbing_across_embedding_dimensions_keeps_the_target() {
        let snapshots = ObservedVoiceSnapshots()
        let rec = UUID()
        snapshots.record(entries([("SPEAKER_00", [1, 0], 1, nil),
                                  ("SPEAKER_01", [0, 1, 0], 1, nil)]), for: rec)

        snapshots.absorb(speaker: "SPEAKER_01", into: "SPEAKER_00", in: rec)

        XCTAssertEqual(snapshots.observation(forSpeaker: "SPEAKER_00", in: rec)?.observedCentroid,
                       [1, 0])
        XCTAssertNil(snapshots.observation(forSpeaker: "SPEAKER_01", in: rec))
    }

    // MARK: - Carrying observations across a re-key

    /// The offline re-diarize keeps the names, so the observations that back
    /// them have to survive too — on the same mapping. Dropping them left
    /// every re-diarized recording unable to correct a profile, which is the
    /// whole of island-io/mila#237.
    func test_remapping_carries_observations_onto_the_new_ids() {
        let snapshots = ObservedVoiceSnapshots()
        let rec = UUID()
        snapshots.record(entries([("SPEAKER_00", [1, 0], 2, "Alice"),
                                  ("SPEAKER_01", [0, 1], 3, nil)]), for: rec)

        // old -> new: the pass renumbered them the other way round.
        snapshots.remapSpeakerIDs(["SPEAKER_00": "SPEAKER_01",
                                   "SPEAKER_01": "SPEAKER_00"], in: rec)

        XCTAssertEqual(snapshots.observation(forSpeaker: "SPEAKER_01", in: rec),
                       .init(observedCentroid: [1, 0], observedCount: 2, profileName: "Alice"))
        XCTAssertEqual(snapshots.observation(forSpeaker: "SPEAKER_00", in: rec),
                       .init(observedCentroid: [0, 1], observedCount: 3, profileName: nil))
    }

    /// **Collapsing over-segmentation is what the offline pass is FOR**, so
    /// this is the common outcome, not an edge. `finish` folded all three
    /// fragments into one profile; all three have to arrive on the new id,
    /// combined — keeping only the dominant one would let un-naming give
    /// back a third of what the recording contributed and strand the rest.
    func test_remapping_combines_every_fragment_that_lands_on_one_new_id() {
        let snapshots = ObservedVoiceSnapshots()
        let rec = UUID()
        snapshots.record(entries([("SPEAKER_00", [1, 0], 2, "Alice"),
                                  ("SPEAKER_03", [1, 0], 1, "Alice"),
                                  ("SPEAKER_07", [1, 0], 3, "Alice")]), for: rec)

        snapshots.remapSpeakerIDs(["SPEAKER_00": "SPEAKER_00",
                                   "SPEAKER_03": "SPEAKER_00",
                                   "SPEAKER_07": "SPEAKER_00"], in: rec)

        let carried = snapshots.observation(forSpeaker: "SPEAKER_00", in: rec)
        XCTAssertEqual(carried?.observedCount, 6,
                       "2 + 1 + 3 — every fragment the profile received")
        XCTAssertEqual(carried?.observedCentroid, [1, 0])
        XCTAssertNil(snapshots.observation(forSpeaker: "SPEAKER_03", in: rec))
        XCTAssertNil(snapshots.observation(forSpeaker: "SPEAKER_07", in: rec))
    }

    /// The fold is weighted, so a combined fragment set is worth exactly what
    /// the separate `updateProfile` calls put into the profile.
    func test_remapping_weights_the_combined_fragments() {
        let snapshots = ObservedVoiceSnapshots()
        let rec = UUID()
        snapshots.record(entries([("SPEAKER_00", [1, 0], 3, nil),
                                  ("SPEAKER_01", [0, 1], 1, nil)]), for: rec)

        snapshots.remapSpeakerIDs(["SPEAKER_00": "SPEAKER_00",
                                   "SPEAKER_01": "SPEAKER_00"], in: rec)

        let carried = snapshots.observation(forSpeaker: "SPEAKER_00", in: rec)
        XCTAssertEqual(carried?.observedCount, 4)
        XCTAssertEqual(carried?.observedCentroid.first ?? 0, 0.75, accuracy: 0.0001)
        XCTAssertEqual(carried?.observedCentroid.last ?? 0, 0.25, accuracy: 0.0001)
    }

    /// The other direction: an old speaker the pass SPLIT in two must not
    /// hand the same embedding to both halves, or un-naming both subtracts
    /// one observation twice. Keying the mapping old→new makes that
    /// unrepresentable — the split speaker has exactly one destination, and
    /// the other half simply has no observation.
    func test_a_split_speaker_lands_on_one_half_only() {
        let snapshots = ObservedVoiceSnapshots()
        let rec = UUID()
        snapshots.record(entries([("SPEAKER_00", [1, 0], 2, nil),
                                  ("SPEAKER_01", [0, 1], 2, nil)]), for: rec)

        // The pass split old SPEAKER_00 across new SPEAKER_00 and SPEAKER_02,
        // and SPEAKER_02 took more of it — so that is where its voice goes,
        // and new SPEAKER_00 is left holding nothing despite sharing the id.
        snapshots.remapSpeakerIDs(["SPEAKER_00": "SPEAKER_02",
                                   "SPEAKER_01": "SPEAKER_01"], in: rec)

        XCTAssertEqual(snapshots.observation(forSpeaker: "SPEAKER_02", in: rec)?.observedCount, 2,
                       "the split speaker's voice lands on the half that owns it")
        XCTAssertNil(snapshots.observation(forSpeaker: "SPEAKER_00", in: rec),
                     "the other half carries no copy to double-subtract — and note the id "
                     + "still exists in the transcript, so a stale entry would be found")
        XCTAssertEqual(snapshots.observation(forSpeaker: "SPEAKER_01", in: rec)?.observedCentroid,
                       [0, 1], "the speaker that mapped one-to-one is unaffected")
    }

    /// A mapping that carries nothing is an invalidation, eviction slot and
    /// all — an empty entry would hold a slot for a recording with no voices.
    func test_remapping_that_carries_nothing_releases_the_recording() {
        let snapshots = ObservedVoiceSnapshots()
        let rec = UUID()
        snapshots.record(entries([("SPEAKER_00", [1, 0], 1, nil)]), for: rec)

        snapshots.remapSpeakerIDs(["SPEAKER_07": "SPEAKER_09"], in: rec)

        XCTAssertEqual(snapshots.heldRecordingCount, 0)
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
