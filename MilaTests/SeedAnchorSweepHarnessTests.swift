import XCTest
@testable import Mila

/// Exercises `SeedAnchorSweepHarness` — the offline replay that makes #206's
/// question answerable — on synthetic embeddings, so the harness itself is
/// verified on every CI run rather than the first time someone points it at a
/// corpus.
///
/// ## What these tests are for
///
/// The sweep's output will be used to decide whether to move
/// `LiveSpeakerDiarizer.seedAnchorWeight`, a constant that changes how every
/// existing user's stored profiles behave. A harness that quietly measured
/// nothing would be worse than no harness: it would produce a grid of
/// plausible numbers and licence a change on the strength of them. So the
/// tests below pin, on hand-checkable geometry:
///
///   * that varying the anchor weight actually **changes the outcome** — the
///     one property that cannot be assumed, since #248 established that every
///     seeded fixture in the existing suite scores identically for every
///     weight from 1 to uncapped;
///   * each metric's definition, on a fixture built so the four metrics
///     disagree;
///   * that replay is chronological rather than file-ordered.
///
/// ## Fixture geometry
///
/// A 2-D geometry embedded in 4-D vectors, the same one `SeedAnchorWeightTests`
/// uses, so the two files describe one arithmetic:
///
///   * `stored` = `[1, 0, 0, 0]` — the profile on disk, at 0°.
///   * `sessionVoice` = `[0.8, 0.6, 0, 0]` — today's acoustics, 36.87° away
///     (cosine 0.8), above every threshold used here, so it always folds.
///   * `farProbe` — 70° from `stored`. Whether it still matches after ten
///     folds is exactly the question the anchor weight decides.
///   * `backProbe` — 33° the *other* side of `stored`.
///
/// Every expected number below was cross-computed by replaying the same fold
/// arithmetic in float32 outside Swift, and the values agree with the weight
/// table in `seedAnchorWeight`'s doc comment (0.750 at n₀=3, 0.685 at n₀=6,
/// 0.456 uncapped) — which was derived independently, in #248.
@MainActor
final class SeedAnchorSweepHarnessTests: XCTestCase {

    private let stored: [Float] = [1, 0, 0, 0]
    /// 36.87° off `stored` — cosine exactly 0.8.
    private let sessionVoice: [Float] = [0.8, 0.6, 0, 0]
    /// 70° off `stored`, same side as `sessionVoice`.
    private let farProbe: [Float] = [0.34202, 0.93969, 0, 0]
    /// 33° off `stored`, the opposite side.
    private let backProbe: [Float] = [0.83867, -0.54464, 0, 0]

    private let uncapped = SeedAnchorConfiguration.uncappedAnchorWeight

    // MARK: - Fixtures

    private func utterance(_ speaker: String,
                           _ embedding: [Float],
                           at start: Double,
                           duration: Double = 2.0) -> SeedAnchorCorpus.Utterance {
        .init(speaker: speaker, start: start, end: start + duration, embedding: embedding)
    }

    /// One returning speaker, ten of today's utterances, then a probe far
    /// enough out that whether it still matches depends on how hard the
    /// stored voice is still anchoring.
    ///
    /// The shape is not arbitrary. The anchor weight can only change an
    /// outcome *after* a confident match has folded something into the
    /// centroid — before that, every weight compares against the same stored
    /// vector. So any fixture that discriminates between weights must have a
    /// confident match first and the interesting probe second, which is why
    /// this one runs ten folds before asking the question.
    private func adaptationCorpus(reversed: Bool = false) -> SeedAnchorCorpus {
        var utterances = (0..<10).map { utterance("alice", sessionVoice, at: Double($0) * 3) }
        utterances.append(utterance("alice", farProbe, at: 30))
        if reversed { utterances.reverse() }
        return SeedAnchorCorpus(
            enrolments: [.init(speaker: "alice", centroid: stored, sampleCount: 40)],
            recordings: [.init(id: "r1", setup: "headset", utterances: utterances)])
    }

    /// Two enrolled speakers and one stranger who sounds like Alice — built so
    /// the four metrics give four different answers about the same recording.
    private func mixedCorpus() -> SeedAnchorCorpus {
        SeedAnchorCorpus(
            enrolments: [.init(speaker: "alice", centroid: [1, 0, 0, 0], sampleCount: 40),
                         .init(speaker: "bob", centroid: [0, 1, 0, 0], sampleCount: 40)],
            recordings: [.init(id: "r1", setup: "office", utterances: [
                utterance("alice", [1, 0, 0, 0], at: 0),
                // 18° off Alice's stored centroid: comfortably a confident
                // match, and not Alice.
                utterance("carol", [0.95, 0.31, 0, 0], at: 3),
                utterance("bob", [0, 1, 0, 0], at: 6)
            ])])
    }

    private func tally(_ results: [SeedAnchorResult], weight: Int) throws -> SeedAnchorTally {
        try XCTUnwrap(results.first { $0.configuration.anchorWeight == weight }?.tally,
                      "no result for anchor weight \(weight)")
    }

    // MARK: - The harness measures the knob

    /// **The load-bearing test.** If the anchor weight did not reach
    /// `seedPool`, every cell of the grid would be identical and the sweep
    /// would report a confident, meaningless answer.
    ///
    /// With ten of this session's utterances folded in, the eleventh probe at
    /// 70° is a confident match at every capped weight — the entry has moved
    /// far enough towards today's acoustics — but *uncapped*, the entry is
    /// still pinned at the stored voice (7.13° away, probe similarity 0.456,
    /// below the 0.55 create floor), so the same speaker mints a second
    /// `SPEAKER_NN`. That is the over-segmentation interaction
    /// `seedAnchorWeight` describes, reproduced end to end through the real
    /// `seedPool`/`assign`.
    func test_the_grid_separates_anchor_weights_instead_of_reporting_one_number() throws {
        let corpus = try adaptationCorpus().validated()
        let results = try SeedAnchorSweepHarness.sweep(
            corpus: corpus,
            anchorWeights: [1, 2, 3, 4, 6, 12, uncapped],
            thresholds: [0.70])

        for weight in [1, 2, 3, 4, 6, 12] {
            let capped = try tally(results, weight: weight)
            XCTAssertEqual(try XCTUnwrap(capped.returningRecall), 1.0, accuracy: 1e-9,
                           "at n0=\(weight) every utterance should reach the seeded entry")
            XCTAssertEqual(try XCTUnwrap(capped.meanSpeakerCountAbsError), 0, accuracy: 1e-9,
                           "and no duplicate speaker should be minted for the same person")
            XCTAssertEqual(try XCTUnwrap(capped.falseAttachRate), 0, accuracy: 1e-9)
        }

        let uncappedTally = try tally(results, weight: uncapped)
        XCTAssertEqual(try XCTUnwrap(uncappedTally.returningRecall), 10.0 / 11.0, accuracy: 1e-9,
                       "uncapped, the anchor holds the entry on the stored voice and the "
                       + "eleventh utterance falls out of the speaker entirely")
        XCTAssertEqual(try XCTUnwrap(uncappedTally.meanSpeakerCountAbsError), 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(uncappedTally.meanSpeakerCountSignedError), 1, accuracy: 1e-9,
                       "positive means over-segmentation — a heavier anchor splitting one "
                       + "person across two ids, which runs opposite to the intuition that a "
                       + "stronger anchor means more stable speakers")

        let three = try tally(results, weight: LiveSpeakerDiarizer.seedAnchorWeight)
        XCTAssertNotEqual(three.returningRecall, uncappedTally.returningRecall,
                          "if these are equal the anchor weight is not reaching seedPool and "
                          + "every cell of the sweep is measuring the same configuration")
    }

    /// The override must not leak into the app: an untouched diarizer anchors
    /// at the shipping constant.
    func test_a_diarizer_nobody_configured_uses_the_shipping_weight() {
        let diarizer = LiveSpeakerDiarizer()
        XCTAssertNil(diarizer.seedAnchorWeightOverride,
                     "the sweep hook must be off unless a sweep turned it on")
        XCTAssertEqual(diarizer.effectiveSeedAnchorWeight, LiveSpeakerDiarizer.seedAnchorWeight)
    }

    /// A weight below 1 is clamped, not honoured.
    ///
    /// `assign` folds with `(c·n + e) / (n + 1)`, so n₀ = 0 discards the stored
    /// voice on its own first match and n₀ = -1 divides by zero. The clamp is
    /// what keeps a mistyped sweep configuration from putting an infinity or a
    /// NaN into a centroid, which reads as "never matched" rather than as an
    /// error.
    ///
    /// The behavioural half is discriminating by construction: after one fold
    /// of `sessionVoice` at n₀ = 1 the centroid sits at 18.43°, leaving
    /// `backProbe` at cosine 0.623 — borderline, so it attaches and the pool
    /// stays at one speaker. Had 0 been honoured the centroid would *be*
    /// `sessionVoice`, putting `backProbe` at 0.344 — below the 0.55 create
    /// floor, minting a second speaker for the same person.
    func test_an_anchor_weight_below_one_is_clamped() {
        XCTAssertEqual(clampedDiarizer(override: 0).effectiveSeedAnchorWeight, 1)
        XCTAssertEqual(clampedDiarizer(override: -5).effectiveSeedAnchorWeight, 1)

        let diarizer = clampedDiarizer(override: 0)
        diarizer.reset()
        diarizer.seedPool(with: [(id: "alice", name: "alice", centroid: stored, sampleCount: 40)])
        XCTAssertEqual(diarizer.assign(embedding: sessionVoice), "SPEAKER_00")
        XCTAssertEqual(diarizer.assign(embedding: backProbe), "SPEAKER_00",
                       "clamped to 1 the stored voice still carries half the centroid, so the "
                       + "probe attaches. SPEAKER_01 here means 0 was honoured and the stored "
                       + "voice was discarded by its own first match")
        XCTAssertEqual(diarizer.currentProfiles().count, 1)
    }

    private func clampedDiarizer(override: Int) -> LiveSpeakerDiarizer {
        let diarizer = LiveSpeakerDiarizer()
        diarizer.similarityThreshold = 0.7
        diarizer.seedAnchorWeightOverride = override
        return diarizer
    }

    /// Replay order is the corpus's chronology, not the order the file happens
    /// to list utterances in. Discriminating: reversed, the 70° probe would be
    /// the *first* utterance, and at 0.342 against the stored centroid it is
    /// below the create floor — so a file-ordered replay mints a speaker for
    /// it and scores differently.
    func test_replay_follows_the_clock_not_the_file() throws {
        let inOrder = try SeedAnchorSweepHarness.sweep(
            corpus: try adaptationCorpus().validated(),
            anchorWeights: [3, uncapped], thresholds: [0.70])
        let shuffled = try SeedAnchorSweepHarness.sweep(
            corpus: try adaptationCorpus(reversed: true).validated(),
            anchorWeights: [3, uncapped], thresholds: [0.70])

        for weight in [3, uncapped] {
            XCTAssertEqual(try tally(inOrder, weight: weight),
                           try tally(shuffled, weight: weight),
                           "listing the utterances in a different order must not change the "
                           + "result — `assign` folds in arrival order, so a file-ordered "
                           + "replay measures a recording that never happened")
        }
    }

    // MARK: - The metric definitions

    /// One fixture, four metrics, four different answers — which is the point
    /// #206 makes about reporting all of them.
    ///
    /// Alice speaks once and is recognised. A stranger who sounds like her
    /// lands on her seeded entry. Bob speaks once and is recognised. So:
    /// recall is perfect (both enrolled speakers reached their own entry),
    /// while a third of all utterances were false-attached; auto-naming is
    /// half right (Alice's entry is a tie between her and the stranger, so it
    /// is not counted correct); and the recording under-segments, three true
    /// speakers collapsing onto two ids.
    func test_the_four_metrics_score_the_same_recording_differently() throws {
        let results = try SeedAnchorSweepHarness.sweep(corpus: try mixedCorpus().validated(),
                                                       anchorWeights: [3],
                                                       thresholds: [0.70])
        let scored = try tally(results, weight: 3)

        XCTAssertEqual(scored.utterancesTotal, 3)
        XCTAssertEqual(scored.recordings, 1)

        XCTAssertEqual(scored.returningTotal, 2, "carol has no profile, so she is not recallable")
        XCTAssertEqual(scored.returningHits, 2)
        XCTAssertEqual(try XCTUnwrap(scored.returningRecall), 1.0, accuracy: 1e-9)

        XCTAssertEqual(scored.falseAttachments, 1, "carol landed on alice's seeded entry")
        XCTAssertEqual(try XCTUnwrap(scored.falseAttachRate), 1.0 / 3.0, accuracy: 1e-9,
                       "the denominator is every utterance, not just the recallable ones — a "
                       + "stranger's utterance on someone's entry is exactly the harm this "
                       + "metric exists to count")

        XCTAssertEqual(scored.autoNamesIssued, 2)
        XCTAssertEqual(scored.autoNamesCorrect, 1, "only bob's entry names the right person")
        XCTAssertEqual(scored.autoNamesExpected, 2)
        XCTAssertEqual(try XCTUnwrap(scored.autoNamePrecision), 0.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(scored.autoNameRecall), 0.5, accuracy: 1e-9)

        XCTAssertEqual(scored.speakerCountSignedError, -1,
                       "two ids for three speakers — negative is under-segmentation")
        XCTAssertEqual(scored.speakerCountAbsError, 1)

        XCTAssertEqual(scored.perSpeakerRecall["alice"], 1.0)
        XCTAssertEqual(scored.perSpeakerRecall["bob"], 1.0)
        XCTAssertNil(scored.perSpeakerRecall["carol"],
                     "a speaker with no profile has no recall to pair on")
    }

    /// An auto-name whose entry heard two people equally is not counted
    /// correct. Failing closed on a tie matches the rest of this subsystem,
    /// and the alternative — picking one arbitrarily — would make the metric
    /// depend on dictionary ordering.
    func test_an_auto_name_split_between_two_speakers_is_not_correct() {
        let outcome = SeedAnchorRecordingOutcome(
            recordingID: "r1",
            assignments: [.init(trueSpeaker: "alice", assignedID: "SPEAKER_00"),
                          .init(trueSpeaker: "carol", assignedID: "SPEAKER_00")],
            pool: [.init(id: "SPEAKER_00", observedCount: 2, profileName: "alice")],
            seededID: ["alice": "SPEAKER_00"],
            speakerBehindSeededID: ["SPEAKER_00": "alice"],
            enrolledSpeakers: ["alice"])

        let scored = SeedAnchorTally.scoring(outcome)
        XCTAssertEqual(scored.autoNamesIssued, 1)
        XCTAssertEqual(scored.autoNamesCorrect, 0, "a tie is not a plurality")

        // One more utterance from Alice breaks the tie in her favour.
        let clear = SeedAnchorRecordingOutcome(
            recordingID: "r1",
            assignments: outcome.assignments + [.init(trueSpeaker: "alice",
                                                      assignedID: "SPEAKER_00")],
            pool: outcome.pool,
            seededID: outcome.seededID,
            speakerBehindSeededID: outcome.speakerBehindSeededID,
            enrolledSpeakers: outcome.enrolledSpeakers)
        XCTAssertEqual(SeedAnchorTally.scoring(clear).autoNamesCorrect, 1)
    }

    /// A seeded speaker who never confidently matched is not auto-named — the
    /// `observedCount > 0` half of `finish`'s guard set — and does not count
    /// against recall unless they actually spoke.
    func test_a_seeded_speaker_who_never_matched_issues_no_name() {
        let silent = SeedAnchorRecordingOutcome(
            recordingID: "r1",
            assignments: [.init(trueSpeaker: "carol", assignedID: "SPEAKER_01")],
            pool: [.init(id: "SPEAKER_00", observedCount: 0, profileName: "alice"),
                   .init(id: "SPEAKER_01", observedCount: 1, profileName: nil)],
            seededID: ["alice": "SPEAKER_00"],
            speakerBehindSeededID: ["SPEAKER_00": "alice"],
            enrolledSpeakers: ["alice"])

        let scored = SeedAnchorTally.scoring(silent)
        XCTAssertEqual(scored.autoNamesIssued, 0)
        XCTAssertEqual(scored.autoNamesExpected, 0,
                       "alice never spoke, so failing to name her is not a miss")
        XCTAssertNil(scored.autoNameRecall, "and the rate is undefined rather than zero")
        XCTAssertEqual(scored.falseAttachments, 0,
                       "SPEAKER_01 was minted in-recording, so nobody was attached to a "
                       + "stored voice that is not theirs")
    }

    /// Tallies add, so recordings of different lengths pool by count rather
    /// than by averaging rates — a 20-utterance recording must not weigh the
    /// same as a 300-utterance one.
    func test_tallies_pool_by_count() throws {
        var first = SeedAnchorTally()
        first.utterancesTotal = 10
        first.falseAttachments = 1
        first.recordings = 1
        first.perSpeaker["alice"] = .init(total: 10, hits: 9)

        var second = SeedAnchorTally()
        second.utterancesTotal = 90
        second.falseAttachments = 44
        second.recordings = 1
        second.perSpeaker["alice"] = .init(total: 90, hits: 45)

        let pooled = first + second
        XCTAssertEqual(pooled.utterancesTotal, 100)
        XCTAssertEqual(try XCTUnwrap(pooled.falseAttachRate), 0.45, accuracy: 1e-12,
                       "0.45, not the 0.30 that averaging the two rates would give")
        XCTAssertEqual(pooled.perSpeaker["alice"], .init(total: 100, hits: 54))
        XCTAssertEqual(pooled.recordings, 2)
    }

    // MARK: - The corpus is refused rather than mis-measured

    func test_a_corpus_with_mixed_dimensions_is_refused() {
        let corpus = SeedAnchorCorpus(
            enrolments: [.init(speaker: "alice", centroid: [1, 0, 0, 0], sampleCount: 40)],
            recordings: [.init(id: "r1", setup: nil,
                               utterances: [utterance("alice", [1, 0], at: 0)])])
        XCTAssertThrowsError(try corpus.validated(),
                             "a dimension mismatch can never be a confident match, so this "
                             + "would score zero recall for a reason unrelated to the anchor")
    }

    func test_a_corpus_with_a_non_finite_embedding_is_refused() {
        let corpus = SeedAnchorCorpus(
            enrolments: [.init(speaker: "alice", centroid: [1, 0, 0, 0], sampleCount: 40)],
            recordings: [.init(id: "r1", setup: nil,
                               utterances: [utterance("alice", [.nan, 0, 0, 0], at: 0)])])
        XCTAssertThrowsError(try corpus.validated(),
                             "a NaN reads as 'never matched' rather than as an error")
    }

    func test_a_corpus_with_an_out_of_range_sample_count_is_refused() {
        for count in [0, -1, VoiceProfile.maxSampleCount + 1] {
            let corpus = SeedAnchorCorpus(
                enrolments: [.init(speaker: "alice", centroid: [1, 0, 0, 0], sampleCount: count)],
                recordings: [.init(id: "r1", setup: nil,
                                   utterances: [utterance("alice", [1, 0, 0, 0], at: 0)])])
            XCTAssertThrowsError(try corpus.validated(),
                                 "sampleCount \(count) is outside what updateProfile would "
                                 + "have written, and an uncapped anchor would carry it into "
                                 + "`Float(n + 1)`")
        }
    }

    func test_two_enrolments_for_one_speaker_are_refused() {
        let corpus = SeedAnchorCorpus(
            enrolments: [.init(speaker: "alice", centroid: [1, 0, 0, 0], sampleCount: 40),
                         .init(speaker: "alice", centroid: [0, 1, 0, 0], sampleCount: 40)],
            recordings: [.init(id: "r1", setup: nil,
                               utterances: [utterance("alice", [1, 0, 0, 0], at: 0)])])
        XCTAssertThrowsError(try corpus.validated(),
                             "seeded ids are resolved by profile name, so two profiles under "
                             + "one name make the mapping ambiguous")
    }

    // MARK: - The file format

    func test_a_corpus_decodes_from_json() throws {
        let json = """
        {
          "enrolments": [
            {"speaker": "alice", "centroid": [1, 0], "sampleCount": 12}
          ],
          "recordings": [
            {"id": "r1", "setup": "headset-office", "utterances": [
              {"speaker": "alice", "start": 0.0, "end": 1.5, "embedding": [0.9, 0.1]}
            ]},
            {"id": "r2", "utterances": [
              {"speaker": "alice", "start": 2.0, "end": 2.4, "embedding": [0.8, 0.2]}
            ]}
          ]
        }
        """
        let corpus = try JSONDecoder()
            .decode(SeedAnchorCorpus.self, from: Data(json.utf8))
            .validated()

        XCTAssertEqual(corpus.enrolledSpeakers, ["alice"])
        XCTAssertEqual(corpus.embeddingDimension, 2)
        XCTAssertEqual(corpus.recordings.count, 2)
        XCTAssertEqual(corpus.recordings[0].setup, "headset-office")
        XCTAssertNil(corpus.recordings[1].setup, "setup is optional")
        XCTAssertEqual(corpus.recordings[1].utterances[0].duration, 0.4, accuracy: 1e-9,
                       "durations survive decoding — `assign` refuses to mint a speaker from "
                       + "anything under a second, so they change the outcome")
    }
}
