import XCTest
@testable import Mila

/// The entry point for actually running the seed-anchor sweep (#206), plus
/// tests for the two layers that turn a grid into a decision: the report and
/// the decision rule.
///
/// ## How to run the sweep
///
/// ```
/// MILA_SEED_ANCHOR_CORPUS=/path/to/corpus.json \
///   xcodebuild test -scheme Mila \
///   -only-testing:MilaTests/SeedAnchorSweepTests/test_sweep_a_provided_corpus
/// ```
///
/// Optional:
///   * `MILA_SEED_ANCHOR_REPORT=/path/out.json` — also write the grid as JSON.
///   * `MILA_SEED_ANCHOR_WEIGHTS=1,2,3,uncapped` — narrow the anchor weights.
///   * `MILA_SEED_ANCHOR_THRESHOLDS=0.55` — narrow the thresholds.
///
/// Without a corpus the sweep test skips, which is the state CI runs in and
/// the state this repository ships in: nobody has produced the audio yet.
/// `docs/seed-anchor-sweep.md` covers producing a corpus, and
/// `scripts/extract-voice-embeddings.py` does the embedding pass.
///
/// **This test cannot tell you the anchor weight is right.** It replays real
/// recordings through the real matching code and reports what happened; the
/// decision is still a human reading four metrics that disagree. What it
/// removes is the need to re-derive the protocol from a GitHub comment.
@MainActor
final class SeedAnchorSweepTests: XCTestCase {

    // MARK: - The sweep

    func test_sweep_a_provided_corpus() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["MILA_SEED_ANCHOR_CORPUS"], !path.isEmpty else {
            throw XCTSkip("""
                No corpus. Set MILA_SEED_ANCHOR_CORPUS to a JSON corpus of cached \
                speaker embeddings to run the #206 sweep — see docs/seed-anchor-sweep.md. \
                The seed anchor weight stays at \(LiveSpeakerDiarizer.seedAnchorWeight) \
                until someone runs it; this skip is the honest state of the question, \
                not a failure.
                """)
        }

        let corpus = try SeedAnchorCorpus.load(from: URL(fileURLWithPath: path))
        let weights = Self.weights(from: environment["MILA_SEED_ANCHOR_WEIGHTS"])
            ?? SeedAnchorConfiguration.defaultAnchorWeights
        let thresholds = Self.thresholds(from: environment["MILA_SEED_ANCHOR_THRESHOLDS"])
            ?? SeedAnchorConfiguration.defaultThresholds

        let results = try SeedAnchorSweepHarness.sweep(corpus: corpus,
                                                        anchorWeights: weights,
                                                        thresholds: thresholds)
        XCTAssertEqual(results.count, weights.count * thresholds.count,
                       "every cell of the grid must be scored")

        // The deliverable of a run: paste this into #206.
        print(SeedAnchorSweepReport.text(for: results, corpus: corpus))

        if let out = environment["MILA_SEED_ANCHOR_REPORT"], !out.isEmpty {
            let data = try SeedAnchorSweepReport.json(for: results, corpus: corpus)
            try data.write(to: URL(fileURLWithPath: out))
            print("seed-anchor sweep: grid written to \(out)")
        }

        // Deliberately not asserted: which anchor weight wins. A test that
        // failed when the grid disagreed with the shipping constant would be
        // asserting the answer nobody has measured — the exact thing #206
        // exists to avoid.
    }

    /// `uncapped` is spelled out rather than given as a number, because the
    /// number that means "no cap" (`VoiceProfile.maxSampleCount`) is not
    /// something anyone should have to type.
    static func weights(from raw: String?) -> [Int]? {
        guard let raw, !raw.isEmpty else { return nil }
        let parsed = raw.split(separator: ",").compactMap { token -> Int? in
            let trimmed = token.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed == "uncapped" || trimmed == "none" {
                return SeedAnchorConfiguration.uncappedAnchorWeight
            }
            return Int(trimmed)
        }
        return parsed.isEmpty ? nil : parsed
    }

    static func thresholds(from raw: String?) -> [Double]? {
        guard let raw, !raw.isEmpty else { return nil }
        let parsed = raw.split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        return parsed.isEmpty ? nil : parsed
    }

    func test_the_grid_can_be_narrowed_from_the_environment() {
        XCTAssertEqual(Self.weights(from: "1, 2,3"), [1, 2, 3])
        XCTAssertEqual(Self.weights(from: "3,uncapped"),
                       [3, SeedAnchorConfiguration.uncappedAnchorWeight])
        XCTAssertNil(Self.weights(from: ""), "an empty value falls back to the full grid")
        XCTAssertNil(Self.weights(from: "nonsense"),
                     "and so does an unparseable one, rather than sweeping nothing")
        XCTAssertEqual(Self.thresholds(from: "0.55, 0.7"), [0.55, 0.7])
        XCTAssertNil(Self.thresholds(from: nil))
    }

    // MARK: - The decision rule

    private func result(weight: Int,
                        threshold: Double,
                        falseAttachments: Int,
                        utterances: Int) -> SeedAnchorResult {
        var tally = SeedAnchorTally()
        tally.utterancesTotal = utterances
        tally.falseAttachments = falseAttachments
        tally.recordings = 1
        return SeedAnchorResult(
            configuration: .init(anchorWeight: weight, similarityThreshold: threshold),
            tally: tally,
            perRecording: [:])
    }

    /// Ties go to the **smaller** anchor weight. That is not a stylistic
    /// preference: since #204 the seeded weight never reaches persistence, so
    /// a too-light anchor's damage is confined to the one recording, while a
    /// too-heavy anchor keeps a returning speaker below the match threshold
    /// forever and the profile that most needs updating becomes the one that
    /// cannot be updated.
    func test_the_smallest_weight_within_tolerance_wins() throws {
        let results = [
            result(weight: 2, threshold: 0.55, falseAttachments: 55, utterances: 1000),
            result(weight: 3, threshold: 0.55, falseAttachments: 50, utterances: 1000),
            result(weight: 4, threshold: 0.55, falseAttachments: 51, utterances: 1000)
        ]
        let recommendation = try XCTUnwrap(SeedAnchorRecommendation.from(results,
                                                                        tolerance: 0.01))
        XCTAssertEqual(recommendation.anchorWeight, 2,
                       "0.055 is within 0.01 of the grid's best 0.050, so the lighter anchor "
                       + "wins the tie")
        XCTAssertEqual(recommendation.gridBestWorstCase, 0.05, accuracy: 1e-9)
    }

    /// A weight is judged by its **worst** cell across the threshold row, not
    /// its best. Users can set any threshold in 0.5...0.95, so a weight that
    /// is excellent at 0.55 and dreadful at 0.70 has not earned the default.
    func test_a_weight_is_judged_by_its_worst_threshold() throws {
        let results = [
            // Best single cell in the grid — and the worst row.
            result(weight: 2, threshold: 0.55, falseAttachments: 5, utterances: 1000),
            result(weight: 2, threshold: 0.70, falseAttachments: 200, utterances: 1000),
            // Unremarkable everywhere, and therefore safe everywhere.
            result(weight: 3, threshold: 0.55, falseAttachments: 60, utterances: 1000),
            result(weight: 3, threshold: 0.70, falseAttachments: 62, utterances: 1000)
        ]
        let recommendation = try XCTUnwrap(SeedAnchorRecommendation.from(results,
                                                                        tolerance: 0.01))
        XCTAssertEqual(recommendation.anchorWeight, 3,
                       "n0=2 has the single best cell (0.005) and the worst row (0.200)")
        XCTAssertEqual(recommendation.rejected.map { $0.anchorLabel }, ["2"])
    }

    func test_no_results_recommends_nothing() {
        XCTAssertNil(SeedAnchorRecommendation.from([]))
    }

    // MARK: - The report

    /// The report is the artefact a sweep run produces, so it has to carry
    /// enough for someone reading it in the issue months later: every metric,
    /// the corpus it came from, and — loudly — whether that corpus was big
    /// enough to act on.
    func test_the_report_names_every_metric_and_warns_about_a_thin_corpus() throws {
        let corpus = try SeedAnchorCorpus(
            enrolments: [.init(speaker: "alice", centroid: [1, 0, 0, 0], sampleCount: 40)],
            recordings: [.init(id: "r1", setup: "headset", utterances: [
                .init(speaker: "alice", start: 0, end: 2, embedding: [0.99, 0.01, 0, 0])
            ])]).validated()

        let results = try SeedAnchorSweepHarness.sweep(
            corpus: corpus,
            anchorWeights: [LiveSpeakerDiarizer.seedAnchorWeight,
                            SeedAnchorConfiguration.uncappedAnchorWeight],
            thresholds: [0.55])
        let text = SeedAnchorSweepReport.text(for: results, corpus: corpus)

        for heading in ["Returning-speaker recall",
                        "Cross-speaker false-attach rate",
                        "Auto-name precision",
                        "Auto-name recall",
                        "speaker-count error",
                        "Exact Wilcoxon p"] {
            XCTAssertTrue(text.contains(heading), "the report must include \(heading)")
        }
        XCTAssertTrue(text.contains("uncapped"), "the uncapped row must be labelled, not 9e18")
        XCTAssertTrue(text.contains("fewer than 8 enrolled speakers"),
                      "a corpus below #206's bar must say so in the report itself — the grid "
                      + "will otherwise be quoted without that caveat")
        XCTAssertTrue(text.contains("fewer than two labelled capture setups"),
                      "the cross-setup case is the one this knob exists for")
    }

    func test_the_grid_serialises_to_json() throws {
        let corpus = try SeedAnchorCorpus(
            enrolments: [.init(speaker: "alice", centroid: [1, 0, 0, 0], sampleCount: 40)],
            recordings: [.init(id: "r1", setup: "headset", utterances: [
                .init(speaker: "alice", start: 0, end: 2, embedding: [0.99, 0.01, 0, 0])
            ])]).validated()
        let results = try SeedAnchorSweepHarness.sweep(corpus: corpus,
                                                        anchorWeights: [3],
                                                        thresholds: [0.55])

        let data = try SeedAnchorSweepReport.json(for: results, corpus: corpus)
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: data)
                                    as? [String: Any])
        XCTAssertEqual(parsed["shippingSeedAnchorWeight"] as? Int,
                       LiveSpeakerDiarizer.seedAnchorWeight)
        XCTAssertEqual(parsed["speakers"] as? [String], ["alice"])
        let cells = try XCTUnwrap(parsed["cells"] as? [[String: Any]])
        XCTAssertEqual(cells.count, 1)
        XCTAssertEqual(cells[0]["anchorWeight"] as? String, "3")
        XCTAssertEqual(cells[0]["returningHits"] as? Int, 1)
    }
}
