import XCTest
@testable import Mila

/// Pins the **seed anchor weight** — `LiveSpeakerDiarizer.seedAnchorWeight`,
/// the cap `seedPool` puts on a returning speaker's stored `sampleCount`.
///
/// ## Why this file exists
///
/// Before it, the value was a bare `3` inside `seedPool` and **nothing
/// observed it**. `currentProfiles()` deliberately reports only the persisted
/// pair (`observedCentroid` / `observedCount`), never the matching pair, so
/// the seeded weight has no direct read-out; and every seeded fixture in
/// `LiveSpeakerDiarizerPoolTests`, `RecognisedSpeakerMergeTests`,
/// `CrossRecordingVoiceIsolationTests` and `RecognisedSpeakerAssignerTests`
/// uses vectors far enough apart that the outcome is identical for every
/// weight from 1 to uncapped. Changing 3 to 1 — or deleting the `min` and
/// letting a mature profile anchor at `VoiceProfile.maxSampleCount`, which
/// `seedAnchorWeight` documents as provably wrong — left the whole suite
/// green. This file closes that: it asserts the number, the arithmetic it
/// implies, and the two behaviours the number is chosen for.
///
/// ## What it does *not* claim
///
/// These tests do not show 3 is optimal. The arithmetic pins the ends, not
/// the interior — n₀ ∈ {2, 3, 4} are all well-formed and none of these
/// assertions distinguishes them. That question needs multi-recording audio
/// of the same speakers across different capture setups; #206 holds the
/// replay protocol. What is pinned here is that the anchor exists, that it is
/// a ceiling and not a floor, and that it stays inside the band where neither
/// end-failure occurs.
///
/// ## Fixture
///
/// A 2-D geometry embedded in 4-D vectors, so every similarity below is just
/// the cosine of an angle difference and the margins are checkable by hand:
///
///   * `stored` = `[1, 0, 0, 0]` — the profile on disk, at 0°.
///   * `sessionVoice` = `[0.8, 0.6, 0, 0]` — this session's acoustics, at
///     36.87°, i.e. cosine 0.8 to `stored`. Above the 0.7 threshold used
///     throughout, so it always folds; and because each fold moves the
///     centroid *towards* it, repeated folds stay confident.
///   * The probes sit either side, at angles chosen so the fold's outcome
///     flips across the weights this file cares about.
@MainActor
final class SeedAnchorWeightTests: XCTestCase {

    private let stored: [Float] = [1, 0, 0, 0]
    /// 36.87° off `stored` — cosine exactly 0.8.
    private let sessionVoice: [Float] = [0.8, 0.6, 0, 0]
    /// 70° off `stored`, on the same side as `sessionVoice`.
    private let farProbe: [Float] = [0.34202, 0.93969, 0, 0]
    /// 33° off `stored`, on the *opposite* side to `sessionVoice`.
    private let backProbe: [Float] = [0.83867, -0.54464, 0, 0]

    private func diarizer(seededWith storedCount: Int) -> LiveSpeakerDiarizer {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = 0.7
        d.reset()
        d.seedPool(with: [(id: "Alice", name: "Alice",
                           centroid: stored, sampleCount: storedCount)])
        return d
    }

    /// How many observations `SPEAKER_00` has folded in so far. This is the
    /// discriminator every behavioural test below uses, because it separates
    /// a **confident match** (which folds) from a **borderline attach**
    /// (which returns the same id but deliberately leaves the centroid
    /// alone) — a distinction the returned speaker id cannot show.
    private func observedCount(_ d: LiveSpeakerDiarizer) -> Int? {
        d.currentProfiles().first { $0.id == "SPEAKER_00" }?.observedCount
    }

    // MARK: - The value itself

    /// The tripwire. Hardcoded on purpose: a test that read the constant
    /// would move with it and pin nothing.
    ///
    /// If you are here because this failed, you changed the seed anchor
    /// weight. That is allowed — but the value was held at 3 by argument
    /// rather than by measurement, so the bar for moving it is evidence, not
    /// preference. Read `LiveSpeakerDiarizer.seedAnchorWeight` for what the
    /// number means and #206 for the replay protocol that would settle it,
    /// then update this test and the weight table in that doc comment
    /// together.
    func test_the_seed_anchor_weight_is_three() {
        XCTAssertEqual(LiveSpeakerDiarizer.seedAnchorWeight, 3,
                       "the seed anchor weight is a measured-by-nobody constant held at 3 "
                       + "on the asymmetry argument in its doc comment — see #206 before moving it")
    }

    /// The stored voice's share of the matching centroid after *k* confident
    /// matches, `n₀ / (n₀ + k)`, which is what the telescoped fold in
    /// `assign` reduces to. Documents what the constant buys in the units
    /// that matter; fails if the constant moves, so the table in
    /// `seedAnchorWeight`'s doc comment cannot silently go stale.
    func test_the_stored_voice_keeps_this_share_of_the_matching_centroid() {
        let n0 = Double(LiveSpeakerDiarizer.seedAnchorWeight)
        func share(afterMatches k: Int) -> Double { n0 / (n0 + Double(k)) }

        XCTAssertEqual(share(afterMatches: 1), 0.750, accuracy: 0.001)
        XCTAssertEqual(share(afterMatches: 2), 0.600, accuracy: 0.001)
        XCTAssertEqual(share(afterMatches: 3), 0.500, accuracy: 0.001)
        XCTAssertEqual(share(afterMatches: 5), 0.375, accuracy: 0.001)
        XCTAssertEqual(share(afterMatches: 10), 0.231, accuracy: 0.001)
        XCTAssertEqual(share(afterMatches: 20), 0.130, accuracy: 0.001)
    }

    // MARK: - The cap is a ceiling, not a floor

    /// `min(stored, n₀)` — a profile built from a single observation must
    /// anchor at 1, not be inflated to 3. Otherwise a voice heard once would
    /// steer matching as hard as one heard fifty times.
    ///
    /// Discriminating by construction. After one fold of `sessionVoice`, the
    /// matching centroid sits at 18.43° when the entry anchored at 1 and at
    /// 8.97° when it anchored at 3. `backProbe` is 33° the *other* side of
    /// `stored`, so it is 51.44° from the first and 41.97° from the
    /// second — cosine 0.623 versus 0.744, which straddles the 0.7 threshold.
    /// The weakly-anchored entry therefore only *attaches* the probe, while
    /// the fully-anchored one folds it in.
    func test_a_one_sample_profile_anchors_at_one_not_at_the_cap() {
        let young = diarizer(seededWith: 1)
        XCTAssertEqual(young.assign(embedding: sessionVoice), "SPEAKER_00")
        XCTAssertEqual(young.assign(embedding: backProbe), "SPEAKER_00",
                       "still the closest entry, so it attaches")
        XCTAssertEqual(observedCount(young), 1,
                       "one stored sample must anchor at 1: the single fold pulled the "
                       + "centroid far enough that the probe is no longer a confident "
                       + "match, so it attaches without folding. Reading 2 here means the "
                       + "cap became a floor and a barely-known voice now anchors as hard "
                       + "as a well-known one")
    }

    /// The control, and the other half of `min`: past the cap the stored
    /// count stops mattering, so a 40-sample profile anchors exactly as a
    /// 3-sample one does.
    func test_the_cap_binds_once_the_stored_count_reaches_it() {
        for storedCount in [3, 5, 40] {
            let d = diarizer(seededWith: storedCount)
            XCTAssertEqual(d.assign(embedding: sessionVoice), "SPEAKER_00")
            XCTAssertEqual(d.assign(embedding: backProbe), "SPEAKER_00")
            XCTAssertEqual(observedCount(d), 2,
                           "storedCount \(storedCount) must anchor at the cap, so the probe "
                           + "is still a confident match after one fold")
        }
    }

    // MARK: - The band the value has to stay in

    /// **The anchor must stay light enough to be outvoted.** Ten of this
    /// session's utterances have to be able to carry the matching centroid to
    /// today's acoustics — otherwise a returning speaker whose mic, room or
    /// health changed is compared forever against the old centroid, never
    /// clears the threshold, never gets a confident match, and so
    /// `observedCount` stays 0 and nothing is learned. That is the
    /// self-reinforcing failure `seedAnchorWeight` documents: the profile
    /// that most needs updating becomes the one that cannot be updated.
    ///
    /// After ten folds the centroid sits at 28.61° with the current weight,
    /// putting `farProbe` (70°) at cosine 0.750 — a confident match, so the
    /// eleventh utterance folds too. At a weight of 6 the centroid would
    /// still be at 23.20° and the probe at 0.685, a borderline attach; with
    /// no cap at all it would be at 7.13° and the probe at 0.456, below
    /// `createThreshold`, minting a *second* speaker for the same person.
    func test_ten_session_utterances_outweigh_the_seed_anchor() {
        let d = diarizer(seededWith: 40)
        for _ in 0..<10 {
            XCTAssertEqual(d.assign(embedding: sessionVoice), "SPEAKER_00")
        }

        XCTAssertEqual(d.assign(embedding: farProbe), "SPEAKER_00")
        XCTAssertEqual(observedCount(d), 11,
                       "after ten of this session's utterances the anchor must be outvoted "
                       + "enough that the probe is still a confident match. 10 here means a "
                       + "heavier anchor is holding the centroid on the stored voice, and "
                       + "this speaker can never adapt")
        XCTAssertEqual(d.currentProfiles().count, 1,
                       "and no duplicate speaker was minted for the same person — a heavier "
                       + "anchor increases over-segmentation, which is the opposite of the "
                       + "intuition that a stronger anchor means more stable speakers")
    }

    /// **The anchor must stay heavy enough to survive one utterance.** The
    /// mirror failure: at a weight of 1 the fold is
    /// `(c₀ + e) / 2`, so a single match takes the centroid halfway to that
    /// embedding. wespeaker similarity for the same speaker on 1–5 s VAD
    /// chunks routinely sits in 0.45–0.70, so a correct first match is often
    /// marginal *and* noisy — and if it is a false positive, the entry's
    /// identity is half-stolen by a different person on utterance one, with
    /// `observedCount > 0` letting the auto-name fire on the wrong voice.
    ///
    /// Same fixture as the ceiling test, read the other way: at the current
    /// weight the centroid only reaches 8.97° after one fold, leaving
    /// `backProbe` a confident match at 0.744. At a weight of 1 it would
    /// reach 18.43° and the probe would fall to 0.623.
    func test_one_utterance_cannot_take_the_centroid_halfway() {
        let d = diarizer(seededWith: 40)
        XCTAssertEqual(d.assign(embedding: sessionVoice), "SPEAKER_00")

        XCTAssertEqual(d.assign(embedding: backProbe), "SPEAKER_00")
        XCTAssertEqual(observedCount(d), 2,
                       "one utterance must not move the matching centroid so far that the "
                       + "stored voice stops matching. 1 here means the anchor has become "
                       + "light enough for a single noisy — or wrong — embedding to "
                       + "half-steal the entry")
    }

    // MARK: - The knob stays on the matching side

    /// Whatever the weight is, it must never reach persistence: the seeded
    /// count is `sampleCount`, and `currentProfiles()` reports
    /// `observedCount`. This is the #204 split that makes the anchor safe to
    /// tune at all — without it, any change here would also change how much
    /// weight gets written back into `speaker-profiles.json`.
    func test_the_seed_anchor_never_reaches_the_persisted_count() {
        let d = diarizer(seededWith: 40)
        XCTAssertEqual(observedCount(d), 0,
                       "a seeded entry that has not been heard yet has observed nothing, "
                       + "however much weight it anchors with")

        XCTAssertEqual(d.assign(embedding: sessionVoice), "SPEAKER_00")
        XCTAssertEqual(observedCount(d), 1,
                       "one utterance heard is one sample to persist — not "
                       + "\(LiveSpeakerDiarizer.seedAnchorWeight) + 1")
    }
}
