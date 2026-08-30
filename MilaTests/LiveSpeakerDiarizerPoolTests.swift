import XCTest
@testable import Mila

/// Pure-Swift unit tests for the cosine-similarity speaker pool inside
/// `LiveSpeakerDiarizer`. No Python or pyannote involved — we feed in
/// synthetic embedding vectors and assert the pool's matching logic.
@MainActor
final class LiveSpeakerDiarizerPoolTests: XCTestCase {

    func test_cosineSimilarity_identical_vectors_is_one() {
        let v: [Float] = [1, 2, 3, 4, 5]
        XCTAssertEqual(cosineSimilarity(v, v), 1.0, accuracy: 1e-6)
    }

    func test_cosineSimilarity_orthogonal_vectors_is_zero() {
        XCTAssertEqual(cosineSimilarity([1, 0, 0], [0, 1, 0]), 0.0, accuracy: 1e-6)
    }

    func test_cosineSimilarity_handles_zero_vectors_gracefully() {
        XCTAssertEqual(cosineSimilarity([0, 0, 0], [1, 1, 1]), 0.0, accuracy: 1e-6)
    }

    func test_cosineSimilarity_handles_length_mismatch() {
        XCTAssertEqual(cosineSimilarity([1, 0], [1, 0, 0]), 0.0)
    }

    func test_assign_first_speaker_creates_SPEAKER_00() {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = 0.7
        let id = d.assign(embedding: [1, 0, 0, 0])
        XCTAssertEqual(id, "SPEAKER_00")
    }

    func test_assign_similar_embedding_maps_to_same_speaker() {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = 0.7
        _ = d.assign(embedding: [1, 0, 0, 0])
        // Slightly perturbed — well above the 0.7 cosine threshold.
        let id = d.assign(embedding: [0.99, 0.01, 0.01, 0.01])
        XCTAssertEqual(id, "SPEAKER_00")
    }

    /// Regression test for "diarizer kept adding speakers". User
    /// reported a 2-person conversation produced 13 distinct
    /// SPEAKER_NN IDs in 70s. Cause: 0.75 similarity threshold was
    /// too strict for wespeaker on 1-5s VAD utterances. With realistic
    /// intra-speaker variance (cosine 0.55-0.70 between same-person
    /// short clips) and 0.55 threshold, the pool should consolidate
    /// to exactly 2 speakers across many alternating utterances.
    func test_two_speakers_with_realistic_variance_stays_at_two_speakers() {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = 0.55

        // Two "true" centroid directions in 16-dim space. Each call
        // perturbs the centroid by random Gaussian noise calibrated
        // so intra-speaker cosine sim falls in 0.55-0.75 (the wespeaker
        // short-clip regime) and inter-speaker sim stays under 0.4.
        func makeBase(_ seed: Int) -> [Float] {
            // Two near-orthogonal directions.
            if seed == 0 { return [1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0] }
            return [0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1]
        }
        var rng = SeededRNG(seed: 1)
        func sampled(_ base: [Float]) -> [Float] {
            // Heavy additive noise (±0.7 per element on a ~1-magnitude
            // base) keeps intra-speaker cos-sim around 0.7-0.8 —
            // characteristic of wespeaker on sub-2s clips.
            return base.map { $0 + Float(rng.next() * 1.4 - 0.7) }
        }

        let alice = makeBase(0)
        let bob = makeBase(1)
        // 30 alternating utterances — long enough that any threshold
        // miscalibration would spawn extra IDs.
        var ids: [String] = []
        for i in 0..<30 {
            let speaker = (i % 2 == 0) ? alice : bob
            ids.append(d.assign(embedding: sampled(speaker)))
        }
        let unique = Set(ids)
        XCTAssertEqual(unique.count, 2,
            "Two-speaker conversation produced \(unique.count) speaker IDs: \(unique). Threshold likely too strict for realistic short-clip variance.")
    }

    /// Threshold sweep — documents which thresholds let realistic
    /// intra-speaker variance over-split or under-merge. Fails if 0.55
    /// (our chosen default) doesn't consolidate to exactly 2 and 0.85
    /// (way too strict) doesn't over-split.
    func test_threshold_sensitivity_against_realistic_variance() {
        func runWithThreshold(_ t: Double) -> Int {
            let d = LiveSpeakerDiarizer()
            d.similarityThreshold = t
            var rng = SeededRNG(seed: 42)
            let base0: [Float] = [1, 0, 1, 0, 1, 0, 1, 0]
            let base1: [Float] = [0, 1, 0, 1, 0, 1, 0, 1]
            var ids: [String] = []
            for i in 0..<20 {
                let b = (i % 2 == 0) ? base0 : base1
                let v = b.map { $0 + Float(rng.next() * 1.4 - 0.7) }
                ids.append(d.assign(embedding: v))
            }
            return Set(ids).count
        }
        let c55 = runWithThreshold(0.55)
        let c85 = runWithThreshold(0.85)
        XCTAssertEqual(c55, 2,
            "Default 0.55 should consolidate to 2 speakers on realistic variance")
        // With hysteresis, even a too-strict MATCH threshold no longer
        // catastrophically over-splits — the create floor (max(0.40,t-0.15))
        // catches intra-speaker variance. (Pre-hysteresis 0.85 produced ≥6.)
        XCTAssertLessThanOrEqual(c85, 4,
            "Hysteresis should keep a too-strict threshold from over-splitting")
    }

    func test_assign_dissimilar_embedding_creates_new_speaker() {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = 0.7
        _ = d.assign(embedding: [1, 0, 0, 0])
        let id = d.assign(embedding: [0, 1, 0, 0])
        XCTAssertEqual(id, "SPEAKER_01")
    }

    func test_assign_two_distinct_voices_then_revisit_first() {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = 0.7
        let a1 = d.assign(embedding: [1, 0, 0, 0])
        let b1 = d.assign(embedding: [0, 1, 0, 0])
        let a2 = d.assign(embedding: [0.95, 0.05, 0, 0])
        let b2 = d.assign(embedding: [0.05, 0.95, 0, 0])
        XCTAssertEqual(a1, "SPEAKER_00")
        XCTAssertEqual(b1, "SPEAKER_01")
        XCTAssertEqual(a2, "SPEAKER_00")
        XCTAssertEqual(b2, "SPEAKER_01")
    }

    func test_centroid_updates_pull_threshold_toward_drifting_voice() {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = 0.75
        // First sample: pure vector along the X axis.
        _ = d.assign(embedding: [1, 0, 0, 0])
        // Drift the speaker's representation gradually. After several
        // updates the centroid should track the drift, so a vector
        // with significant Y component still matches.
        _ = d.assign(embedding: [0.85, 0.5, 0, 0])
        _ = d.assign(embedding: [0.7, 0.7, 0, 0])
        // This is far from the original [1,0,0,0] (cosine ~0.5) but
        // the centroid has drifted enough that it should match.
        let id = d.assign(embedding: [0.6, 0.8, 0, 0])
        XCTAssertEqual(id, "SPEAKER_00")
    }

    /// Hysteresis: it takes a clearly-dissimilar embedding to mint a new
    /// speaker, NOT merely one below the (high) match threshold. The create
    /// floor is `max(0.40, threshold - 0.15)`, so at threshold 0.99 the floor
    /// is 0.84 — a 0.95-sim vector attaches instead of forking (this is the
    /// fix for "every sentence a new speaker"), while a near-orthogonal
    /// vector still forks.
    func test_hysteresis_attaches_borderline_but_forks_dissimilar() {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = 0.99
        _ = d.assign(embedding: [1, 0, 0, 0])
        // sim ≈ 0.95: below the 0.99 match bar but above the 0.84 create
        // floor → attach, don't fork.
        let attached = d.assign(embedding: [0.95, 0.3, 0, 0])
        XCTAssertEqual(attached, "SPEAKER_00",
            "Borderline-high similarity must attach via hysteresis, not mint a new speaker")
        // sim ≈ 0.0: below the create floor → genuinely new speaker.
        let forked = d.assign(embedding: [0, 1, 0, 0])
        XCTAssertEqual(forked, "SPEAKER_01",
            "A clearly-dissimilar embedding must still create a new speaker")
    }

    /// Regression for the user-reported "almost every sentence is a different
    /// speaker" on a single-narrator source: real wespeaker cosine sim for
    /// the SAME voice on short VAD chunks dips into 0.45–0.55, just under the
    /// 0.55 match threshold. Pre-hysteresis each such dip forked a new
    /// SPEAKER_NN. The create floor (0.40) must keep them on one speaker.
    func test_borderline_same_speaker_dips_do_not_fork() {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = 0.55
        let first = d.assign(embedding: [1, 0, 0, 0])
        // sim ≈ 0.53 to [1,0,0,0]: cos = 0.85/sqrt(0.85²+0.53²) ≈ 0.849…
        // Use a vector whose cosine lands in the [0.40, 0.55) borderline band.
        // [0.5, 0.85, 0, 0] → cos ≈ 0.507 — under match (0.55), over floor (0.40).
        let dip = d.assign(embedding: [0.5, 0.85, 0, 0])
        XCTAssertEqual(first, "SPEAKER_00")
        XCTAssertEqual(dip, "SPEAKER_00",
            "A same-speaker similarity dip into the [0.40,0.55) band must attach, not fork")
    }

    /// The confident-match fold walks `centroid.count` and indexes
    /// `embedding` in step, so an entry whose centroid has a *different*
    /// dimension must never reach it. `cosineSimilarity` returns 0 on a count
    /// mismatch, which keeps such an entry out only while the threshold is
    /// positive — and `similarityThreshold` is a plain `var` (Settings clamps
    /// its slider to 0.5...0.95, but nothing binds a direct caller). At a
    /// non-positive threshold that 0 clears the bar, and without the explicit
    /// dimension check in `assign` the fold would read off the end of the
    /// shorter vector. The mismatch has a real source: `seedPool` takes
    /// centroids straight off disk, so a profile written by a different
    /// embedding model arrives at whatever length it was stored at.
    func test_non_positive_threshold_cannot_fold_a_mismatched_dimension_profile() {
        for threshold in [0.0, -1.0] {
            let d = LiveSpeakerDiarizer()
            d.similarityThreshold = threshold
            // Seeded from disk with an 8-dim centroid; this "daemon" emits
            // 4-dim embeddings.
            d.seedPool(with: [(id: "Ada", name: "Ada",
                               centroid: [Float](repeating: 1, count: 8),
                               sampleCount: 3)])

            // Long enough to mint: the mismatched entry is not a confident
            // match, so it forks instead of folding.
            let minted = d.assign(embedding: [1, 0, 0, 0], utteranceDuration: 2.0)
            XCTAssertEqual(minted, "SPEAKER_01",
                "A dimension-mismatched entry must not count as a confident match (threshold \(threshold))")

            // Too short to mint: attaches to the closest entry — which is the
            // mismatched one — still without folding into it.
            let attached = d.assign(embedding: [0, 1, 0, 0], utteranceDuration: 0.5)
            XCTAssertEqual(attached, "SPEAKER_00",
                "A short utterance attaches to the closest entry (threshold \(threshold))")

            let seeded = d.currentProfiles().first { $0.profileName == "Ada" }
            XCTAssertEqual(seeded?.observedCount, 0,
                "The mismatched seeded profile must record no observations (threshold \(threshold))")
            XCTAssertEqual(seeded?.observedCentroid.count, 0,
                "The mismatched seeded profile must not take on this recording's embeddings")
        }
    }

    /// Positive control for the dimension check: it rejects mismatched entries
    /// only. At the same non-positive threshold a same-dimension entry still
    /// folds exactly as before.
    func test_non_positive_threshold_still_folds_matching_dimensions() {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = 0.0
        XCTAssertEqual(d.assign(embedding: [1, 0, 0, 0]), "SPEAKER_00")
        XCTAssertEqual(d.assign(embedding: [0, 1, 0, 0]), "SPEAKER_00",
            "sim 0 clears a 0 threshold, so a same-dimension entry is still a confident match")
        let profile = d.currentProfiles().first
        XCTAssertEqual(profile?.observedCount, 2, "Both embeddings must have folded in")
        XCTAssertEqual(profile?.observedCentroid.count, 4)
    }

    // MARK: - forgetSeededProfiles (deleting voice profiles mid-recording)

    /// A seeded entry that has not been heard yet holds nothing but the
    /// deleted profile, so after `forgetSeededProfiles` its owner is a
    /// stranger: she mints a fresh, nameless speaker instead of being
    /// recognised. The emptied entry is kept rather than removed — ids are
    /// minted positionally from `pool.count`, so removing it would collide
    /// the next mint with an id already in `intervals`.
    func test_forgetSeededProfiles_stops_an_unheard_voice_being_recognised() {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = 0.7
        d.seedPool(with: [(id: "Alice", name: "Alice", centroid: [1, 0, 0, 0], sampleCount: 40)])

        d.forgetSeededProfiles()

        XCTAssertEqual(d.assign(embedding: [0.99, 0.01, 0, 0]), "SPEAKER_01",
                       "the erased centroid must not match her any more")
        let pool = d.currentProfiles()
        XCTAssertEqual(pool.count, 2, "the emptied entry stays so ids cannot collide")
        XCTAssertEqual(pool.map(\.id), ["SPEAKER_00", "SPEAKER_01"])
        XCTAssertTrue(pool.allSatisfy { $0.profileName == nil }, "and carries no name")
    }

    /// Control for the same fixture without the deletion: she *is*
    /// recognised, on her seeded entry, under her name.
    func test_an_unforgotten_seeded_voice_is_still_recognised() {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = 0.7
        d.seedPool(with: [(id: "Alice", name: "Alice", centroid: [1, 0, 0, 0], sampleCount: 40)])

        XCTAssertEqual(d.assign(embedding: [0.99, 0.01, 0, 0]), "SPEAKER_00")
        XCTAssertEqual(d.currentProfiles().first?.profileName, "Alice")
    }

    /// An emptied entry must not collect utterances through the *attach*
    /// branch either. `cosineSimilarity` scores it 0, which keeps it out of
    /// the confident-match branch — but the borderline / too-short-to-mint
    /// branch takes the best entry whatever its score, so without the
    /// empty-centroid skip in `assign` a short utterance would land on a
    /// speaker whose voice the user just deleted.
    func test_a_short_utterance_does_not_attach_to_a_forgotten_entry() {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = 0.7
        d.seedPool(with: [(id: "Alice", name: "Alice", centroid: [1, 0, 0, 0], sampleCount: 40)])
        d.forgetSeededProfiles()

        XCTAssertEqual(d.assign(embedding: [0, 0, 1, 0], utteranceDuration: 0.4), "SPEAKER_01",
                       "too short to mint, but there is no longer anything to attach to")
    }

    /// What a heard-from entry keeps is exactly what *this recording*
    /// produced: the seeded weight is dropped and the matching centroid falls
    /// back to the observed one, so the deleted numbers stop steering
    /// matching while the speaker stays coherent for the rest of the
    /// recording.
    ///
    /// Discriminating by construction. `U` folds into the seeded entry
    /// (cos 0.75 to the stored centroid), leaving a matching centroid of
    /// `[0.9375, 0.165, 0, 0]` — three parts stored, one part heard. The
    /// probe `P` sits at cos 0.37 to that blend but cos 0.80 to `U` alone,
    /// so it mints a new speaker while the seeded weight is there and
    /// matches `SPEAKER_00` once it is gone.
    func test_forgetSeededProfiles_drops_the_seeded_weight_and_keeps_the_heard_one() {
        let stored: [Float] = [1, 0, 0, 0]
        let U: [Float] = [0.75, 0.66, 0, 0]
        let P: [Float] = [0.2, 0.98, 0, 0]

        let control = LiveSpeakerDiarizer()
        control.similarityThreshold = 0.7
        control.seedPool(with: [(id: "Alice", name: "Alice", centroid: stored, sampleCount: 40)])
        XCTAssertEqual(control.assign(embedding: U), "SPEAKER_00")
        XCTAssertEqual(control.assign(embedding: P), "SPEAKER_01",
                       "with the seeded weight in place, P is a different speaker")

        let forgotten = LiveSpeakerDiarizer()
        forgotten.similarityThreshold = 0.7
        forgotten.seedPool(with: [(id: "Alice", name: "Alice", centroid: stored, sampleCount: 40)])
        XCTAssertEqual(forgotten.assign(embedding: U), "SPEAKER_00")
        forgotten.forgetSeededProfiles()
        XCTAssertEqual(forgotten.assign(embedding: P), "SPEAKER_00",
                       "matching now runs off what this recording heard, not off disk")
        let entry = forgotten.currentProfiles().first
        XCTAssertNil(entry?.profileName)
        XCTAssertEqual(entry?.observedCount, 2, "the recording's own observations are kept")
    }

    /// Deleting one profile leaves the others seeded and recognisable.
    func test_forgetSeededProfiles_by_name_leaves_the_others_alone() {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = 0.7
        d.seedPool(with: [(id: "Alice", name: "Alice", centroid: [1, 0, 0, 0], sampleCount: 40),
                          (id: "Bob", name: "Bob", centroid: [0, 1, 0, 0], sampleCount: 40)])

        d.forgetSeededProfiles(named: ["Alice"])

        XCTAssertEqual(d.assign(embedding: [0.02, 0.99, 0, 0]), "SPEAKER_01", "Bob is untouched")
        XCTAssertEqual(d.currentProfiles().first { $0.id == "SPEAKER_01" }?.profileName, "Bob")
        XCTAssertEqual(d.assign(embedding: [0.99, 0.01, 0, 0]), "SPEAKER_02", "Alice is a stranger")
        XCTAssertNil(d.currentProfiles().first { $0.id == "SPEAKER_00" }?.profileName)
    }

    func test_higher_threshold_makes_pool_more_conservative() {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = 0.99
        _ = d.assign(embedding: [1, 0, 0, 0])
        // Below the 0.84 create floor (sim ≈ 0.30) → new speaker even though
        // a lower match threshold would have merged it.
        let id = d.assign(embedding: [0.3, 0.95, 0, 0])
        XCTAssertEqual(id, "SPEAKER_01")
    }
}

/// Deterministic linear-congruential RNG so threshold-sweep tests
/// produce byte-identical results across runs. XCTest's randomness
/// would make the "did it consolidate to 2 speakers?" check flake.
private struct SeededRNG {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed &* 2_862_933_555_777_941_757 &+ 3_037_000_493 }
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 33) / Double(1 << 31)
    }
}
