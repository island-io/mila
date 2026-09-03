import Foundation
@testable import Mila

// MARK: - Significance

/// Exact two-sided Wilcoxon signed-rank test, for pairing the sweep's
/// per-speaker recall between two configurations.
///
/// ## Why this test, and why paired across speakers
///
/// #206's protocol is explicit about the pairing: utterances inside one
/// recording are heavily correlated (same mic, same room, same cold), so an
/// utterance-level test treats hundreds of near-duplicate observations as
/// independent and reports significance that is not there. The unit of
/// evidence is a **speaker**, and the comparison is within-speaker (their
/// recall at n₀=2 versus their recall at n₀=3), which is what makes it paired.
/// Signed-rank rather than a paired *t*-test because recall over a few dozen
/// utterances is bounded, discrete and skewed, so normality is not on offer.
///
/// ## Why exact rather than the normal approximation
///
/// The corpus the protocol asks for has ≥ 8 speakers, which is exactly where
/// the normal approximation is least trustworthy — and where it matters most,
/// since a marginal *p* is the whole reason to run the test. The null here is
/// a sign-flip permutation over the observed signed ranks, so the exact
/// distribution is computable: `p[sum]` is accumulated by a dynamic program
/// over doubled ranks (average ranks for ties are integers or half-integers,
/// so doubling makes every subset sum an integer). Cost is O(n² ) in the
/// number of speakers — nothing, at this scale — and the answer is the same on
/// every machine.
///
/// Because the null is a permutation over the *observed* ranks, ties are
/// handled without a correction factor: they enter the distribution the same
/// way they enter the statistic.
///
/// `WilcoxonSignedRankTests` pins the output against values cross-checked by
/// exhaustive enumeration (2ⁿ sign assignments) and against the textbook
/// all-positive case, where p must be exactly 2/2ⁿ.
enum WilcoxonSignedRank {

    struct Outcome: Equatable {
        /// Pairs with a non-zero difference. Zero differences carry no sign
        /// and are dropped, which is the standard treatment — and worth
        /// noticing when reading a result, since it is also the sample size
        /// the *p* refers to.
        let sampleSize: Int
        /// W⁺ — the sum of the ranks of the positive differences.
        let statistic: Double
        /// Exact two-sided *p*. 1.0 when there is nothing to test.
        let pValue: Double
        /// Median of the non-zero differences: the direction and rough size
        /// of the effect, which the *p* alone does not give.
        let medianDifference: Double
    }

    /// `pairs` are (candidate, baseline) per speaker. A positive difference
    /// means the candidate recognised that speaker better.
    static func test(pairs: [(candidate: Double, baseline: Double)]) -> Outcome {
        let differences = pairs
            .map { $0.candidate - $0.baseline }
            .filter { $0 != 0 && $0.isFinite }
        guard !differences.isEmpty else {
            return Outcome(sampleSize: 0, statistic: 0, pValue: 1, medianDifference: 0)
        }

        // Average ranks of |d|.
        let order = differences.indices.sorted { abs(differences[$0]) < abs(differences[$1]) }
        var ranks = [Double](repeating: 0, count: differences.count)
        var i = 0
        while i < order.count {
            var j = i
            while j + 1 < order.count,
                  abs(differences[order[j + 1]]) == abs(differences[order[i]]) {
                j += 1
            }
            let averageRank = Double((i + 1) + (j + 1)) / 2.0
            for k in i...j { ranks[order[k]] = averageRank }
            i = j + 1
        }

        var statistic = 0.0
        for (difference, rank) in zip(differences, ranks) where difference > 0 {
            statistic += rank
        }
        let totalRank = ranks.reduce(0, +)
        let mean = totalRank / 2.0

        // Exact null by DP over doubled ranks. `probability[s]` is the chance
        // that a uniformly random sign assignment puts W⁺ at s/2.
        let scaled = ranks.map { Int(($0 * 2).rounded()) }
        let totalScaled = scaled.reduce(0, +)
        var probability = [Double](repeating: 0, count: totalScaled + 1)
        probability[0] = 1
        for rank in scaled {
            var next = [Double](repeating: 0, count: totalScaled + 1)
            for sum in 0...totalScaled where probability[sum] != 0 {
                next[sum] += probability[sum] * 0.5
                if sum + rank <= totalScaled {
                    next[sum + rank] += probability[sum] * 0.5
                }
            }
            probability = next
        }

        let observedDeviation = abs(statistic - mean)
        var pValue = 0.0
        for sum in 0...totalScaled where probability[sum] != 0 {
            if abs(Double(sum) / 2.0 - mean) >= observedDeviation - 1e-9 {
                pValue += probability[sum]
            }
        }

        let sorted = differences.sorted()
        let middle = sorted.count / 2
        let median = sorted.count % 2 == 1
            ? sorted[middle]
            : (sorted[middle - 1] + sorted[middle]) / 2.0

        return Outcome(sampleSize: differences.count,
                       statistic: statistic,
                       pValue: min(1, max(0, pValue)),
                       medianDifference: median)
    }

    /// Pair two configurations' per-speaker recall on the speakers both
    /// scored. A speaker missing from either side is dropped rather than
    /// treated as zero recall — absent means "not measurable here", and
    /// scoring it 0 would invent evidence.
    static func compare(candidate: [String: Double],
                        baseline: [String: Double]) -> Outcome {
        var pairs: [(candidate: Double, baseline: Double)] = []
        for speaker in Set(candidate.keys).intersection(baseline.keys).sorted() {
            guard let mine = candidate[speaker], let theirs = baseline[speaker] else { continue }
            pairs.append((candidate: mine, baseline: theirs))
        }
        return test(pairs: pairs)
    }
}

// MARK: - Report

/// Renders a finished grid as text for a human, and as JSON to attach to the
/// issue.
///
/// The text report is the deliverable of an actual sweep run: paste it into
/// #206 and the next person can see the whole grid, which metrics disagreed,
/// and how strong the evidence was — rather than a single number with no
/// context, which is how the current 3 got here.
@MainActor
enum SeedAnchorSweepReport {

    static func text(for results: [SeedAnchorResult],
                     corpus: SeedAnchorCorpus,
                     tolerance: Double = 0.01) -> String {
        guard !results.isEmpty else { return "no results" }

        let thresholds = orderedThresholds(results)
        let weights = orderedWeights(results)
        var out = ""

        out += "Seed anchor sweep (#206)\n"
        out += "========================\n\n"
        out += corpusSummary(corpus)
        out += "\nShipping value: seedAnchorWeight = \(LiveSpeakerDiarizer.seedAnchorWeight)"
        out += " (threshold default 0.55)\n\n"

        out += table("1. Returning-speaker recall (higher is better)",
                     weights: weights, thresholds: thresholds, results: results) {
            $0.tally.returningRecall
        }
        out += table("2. Cross-speaker false-attach rate (lower is better)",
                     weights: weights, thresholds: thresholds, results: results) {
            $0.tally.falseAttachRate
        }
        out += table("3a. Auto-name precision (higher is better)",
                     weights: weights, thresholds: thresholds, results: results) {
            $0.tally.autoNamePrecision
        }
        out += table("3b. Auto-name recall (higher is better)",
                     weights: weights, thresholds: thresholds, results: results) {
            $0.tally.autoNameRecall
        }
        out += table("4a. Mean |speaker-count error| per recording (lower is better)",
                     weights: weights, thresholds: thresholds, results: results) {
            $0.tally.meanSpeakerCountAbsError
        }
        out += table("4b. Mean signed speaker-count error (positive = over-segmentation)",
                     weights: weights, thresholds: thresholds, results: results) {
            $0.tally.meanSpeakerCountSignedError
        }

        out += significanceTable(results: results, weights: weights, thresholds: thresholds)

        if let recommendation = SeedAnchorRecommendation.from(results, tolerance: tolerance) {
            out += "\nStarting point from the decision rule\n"
            out += "-------------------------------------\n"
            out += "  smallest anchor weight within \(fmt(tolerance)) of the best worst-case"
            out += " false-attach rate: n0 = \(recommendation.anchorLabel)\n"
            out += "  its worst case \(fmt(recommendation.worstCaseFalseAttach))"
            out += " vs grid best \(fmt(recommendation.gridBestWorstCase))\n"
            if !recommendation.rejected.isEmpty {
                let rejected = recommendation.rejected
                    .map { "n0=\($0.anchorLabel) (\(fmt($0.worstCaseFalseAttach)))" }
                    .joined(separator: ", ")
                out += "  ruled out: \(rejected)\n"
            }
        }

        out += """

        Reading this
        ------------
          * The four metrics are expected to disagree. That disagreement is the
            signal — a weight that lifts recall while lifting false-attach has
            not improved anything, it has moved the operating point.
          * Judge an anchor weight by its *worst* cell across the threshold row,
            not its best: users can set any threshold in 0.5...0.95.
          * The tolerance above is a judgement call with no measurement behind
            it. The real gate is the paired test on per-speaker recall, and
            #206's bar is a Wilcoxon over >= 8 speakers.
          * Prefer the smallest weight that is within noise of the best. A
            too-light anchor's damage is confined to one recording (n0 never
            reaches persistence, since #204); a too-heavy anchor's persists
            across every future recording of that speaker.
          * If the winner is not \(LiveSpeakerDiarizer.seedAnchorWeight), update the constant, the weight
            table in its doc comment, and SeedAnchorWeightTests together, and
            paste this report into #206.

        """
        return out
    }

    /// The same grid as JSON, for attaching to the issue or diffing two runs.
    static func json(for results: [SeedAnchorResult], corpus: SeedAnchorCorpus) throws -> Data {
        var cells: [[String: Any]] = []
        for result in results {
            var cell: [String: Any] = [
                "anchorWeight": result.configuration.anchorLabel,
                "similarityThreshold": result.configuration.similarityThreshold,
                "utterances": result.tally.utterancesTotal,
                "recordings": result.tally.recordings,
                "returningTotal": result.tally.returningTotal,
                "returningHits": result.tally.returningHits,
                "falseAttachments": result.tally.falseAttachments,
                "autoNamesIssued": result.tally.autoNamesIssued,
                "autoNamesCorrect": result.tally.autoNamesCorrect,
                "autoNamesExpected": result.tally.autoNamesExpected,
                "speakerCountAbsError": result.tally.speakerCountAbsError,
                "speakerCountSignedError": result.tally.speakerCountSignedError,
                "perSpeakerRecall": result.tally.perSpeakerRecall
            ]
            if let recall = result.tally.returningRecall { cell["returningRecall"] = recall }
            if let rate = result.tally.falseAttachRate { cell["falseAttachRate"] = rate }
            if let p = result.tally.autoNamePrecision { cell["autoNamePrecision"] = p }
            if let r = result.tally.autoNameRecall { cell["autoNameRecall"] = r }
            cells.append(cell)
        }
        let payload: [String: Any] = [
            "shippingSeedAnchorWeight": LiveSpeakerDiarizer.seedAnchorWeight,
            "speakers": corpus.enrolments.map(\.speaker).sorted(),
            "recordings": corpus.recordings.map(\.id),
            "setups": Array(Set(corpus.recordings.compactMap(\.setup))).sorted(),
            "embeddingDimension": corpus.embeddingDimension,
            "cells": cells
        ]
        return try JSONSerialization.data(withJSONObject: payload,
                                          options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Pieces

    static func corpusSummary(_ corpus: SeedAnchorCorpus) -> String {
        let utterances = corpus.recordings.reduce(0) { $0 + $1.utterances.count }
        let setups = Set(corpus.recordings.compactMap(\.setup)).sorted()
        var out = "Corpus: \(corpus.enrolments.count) enrolled speakers,"
        out += " \(corpus.recordings.count) recordings,"
        out += " \(utterances) utterances, dim \(corpus.embeddingDimension)\n"
        out += "Setups: \(setups.isEmpty ? "(unlabelled)" : setups.joined(separator: ", "))\n"
        if setups.count < 2 {
            out += "WARNING: fewer than two labelled capture setups. The cross-setup case is\n"
            out += "         the one this knob exists for; a single-setup corpus cannot show it.\n"
        }
        if corpus.enrolments.count < 8 {
            out += "WARNING: fewer than 8 enrolled speakers. #206's bar for acting on a\n"
            out += "         result is a paired test over >= 8 speakers.\n"
        }
        return out
    }

    private static func orderedThresholds(_ results: [SeedAnchorResult]) -> [Double] {
        var seen: [Double] = []
        for result in results where !seen.contains(result.configuration.similarityThreshold) {
            seen.append(result.configuration.similarityThreshold)
        }
        return seen.sorted()
    }

    private static func orderedWeights(_ results: [SeedAnchorResult]) -> [Int] {
        var seen: [Int] = []
        for result in results where !seen.contains(result.configuration.anchorWeight) {
            seen.append(result.configuration.anchorWeight)
        }
        return seen.sorted()
    }

    private static func fmt(_ value: Double?) -> String {
        guard let value else { return "   —  " }
        return String(format: "%6.3f", value)
    }

    private static func table(_ title: String,
                              weights: [Int],
                              thresholds: [Double],
                              results: [SeedAnchorResult],
                              metric: (SeedAnchorResult) -> Double?) -> String {
        var out = "\(title)\n"
        out += "  n0       " + thresholds.map { String(format: "  %.2f ", $0) }.joined() + "\n"
        for weight in weights {
            let label = SeedAnchorConfiguration(anchorWeight: weight,
                                                similarityThreshold: 0).anchorLabel
            out += "  " + label.padding(toLength: 9, withPad: " ", startingAt: 0)
            for threshold in thresholds {
                let cell = results.first {
                    $0.configuration.anchorWeight == weight
                        && $0.configuration.similarityThreshold == threshold
                }
                out += fmt(cell.flatMap(metric)) + " "
            }
            out += "\n"
        }
        return out + "\n"
    }

    /// Per-cell exact *p* for per-speaker recall against the shipping weight
    /// at the same threshold. The baseline is held at the same threshold on
    /// purpose: comparing across thresholds would confound the two knobs.
    private static func significanceTable(results: [SeedAnchorResult],
                                          weights: [Int],
                                          thresholds: [Double]) -> String {
        let baselineWeight = LiveSpeakerDiarizer.seedAnchorWeight
        guard weights.contains(baselineWeight) else {
            return "Significance vs n0=\(baselineWeight): not computed — the grid does not"
                + " include the shipping weight.\n\n"
        }
        var out = "5. Exact Wilcoxon p for per-speaker recall vs n0=\(baselineWeight)"
        out += " (paired across speakers)\n"
        out += "  n0       " + thresholds.map { String(format: "  %.2f ", $0) }.joined() + "\n"
        for weight in weights {
            let label = SeedAnchorConfiguration(anchorWeight: weight,
                                                similarityThreshold: 0).anchorLabel
            out += "  " + label.padding(toLength: 9, withPad: " ", startingAt: 0)
            for threshold in thresholds {
                if weight == baselineWeight {
                    out += "  base  "
                    continue
                }
                let candidate = results.first {
                    $0.configuration.anchorWeight == weight
                        && $0.configuration.similarityThreshold == threshold
                }
                let baseline = results.first {
                    $0.configuration.anchorWeight == baselineWeight
                        && $0.configuration.similarityThreshold == threshold
                }
                guard let candidate, let baseline else {
                    out += "   —   "
                    continue
                }
                let outcome = WilcoxonSignedRank.compare(
                    candidate: candidate.tally.perSpeakerRecall,
                    baseline: baseline.tally.perSpeakerRecall)
                out += fmt(outcome.pValue) + " "
            }
            out += "\n"
        }
        out += "  (n = speakers with a non-zero difference; a p over a handful of speakers"
        out += " is not evidence)\n\n"
        return out
    }
}
