import Foundation
@testable import Mila

// MARK: - Corpus

/// A cached corpus of speaker embeddings, and the ground truth for who said
/// what — the input to the seed-anchor sweep (#206).
///
/// ## Why this shape
///
/// The question #206 asks is whether `LiveSpeakerDiarizer.seedAnchorWeight`
/// (n₀ = 3) recognises returning speakers better than 2 or 4 would. Answering
/// it needs real audio, but it does **not** need the app or the Python daemon
/// in the replay loop: `seedPool`, `assign` and `cosineSimilarity` are
/// synchronous and pure over their inputs, and the only thing that needs
/// pyannote is turning audio into embeddings.
///
/// So the expensive step happens exactly once. `scripts/extract-voice-embeddings.py`
/// runs the same embedding model the app uses over a labelled corpus and
/// writes this JSON; every configuration in the sweep then replays the cached
/// vectors through the real matching code in milliseconds. That is what makes
/// a 40-cell grid (8 anchor weights × 5 thresholds) cheap enough to run at
/// all, and it is why the numbers are reproducible: the same corpus file
/// gives the same grid on any machine, with no model or GPU in the loop.
///
/// `docs/seed-anchor-sweep.md` documents the file format for humans, how to
/// produce one, and what to do with the result.
struct SeedAnchorCorpus: Decodable {

    /// One VAD utterance: the embedding the daemon produced for it, its
    /// ground-truth speaker, and its position in the recording.
    ///
    /// `start`/`end` are not decoration. `assign` treats an utterance shorter
    /// than a second as untrustworthy for *minting* a speaker, and it folds
    /// matches into the centroid in arrival order, so both the duration and
    /// the chronology change the outcome. A corpus that loses them measures
    /// something other than what the app does.
    struct Utterance: Decodable {
        let speaker: String
        let start: Double
        let end: Double
        let embedding: [Float]

        var duration: Double { max(0, end - start) }
    }

    /// One recording, replayed as a unit: a fresh pool, seeded once, then
    /// every utterance in chronological order.
    struct Recording: Decodable {
        let id: String
        /// Free-text capture setup ("headset-office", "laptop-mic-kitchen").
        /// Reported but not used in any metric — its purpose is to let
        /// whoever runs the sweep confirm the corpus actually spans more than
        /// one setup, which is the case the whole question is about.
        let setup: String?
        let utterances: [Utterance]
    }

    /// A speaker's stored profile as it would sit in `speaker-profiles.json`
    /// at the moment the recording starts.
    ///
    /// Build these from a **held-out** enrolment recording, never from the
    /// recordings being replayed: `centroid` is that recording's observed
    /// centroid and `sampleCount` its observation count, which is exactly
    /// what `SpeakerProfileStore.updateProfile` would have written. Reusing a
    /// replayed recording here leaks the answer into the profile and every
    /// anchor weight scores implausibly well.
    struct Enrolment: Decodable {
        let speaker: String
        let centroid: [Float]
        let sampleCount: Int
    }

    let enrolments: [Enrolment]
    let recordings: [Recording]

    /// Every speaker with a stored profile. The recall metric is defined only
    /// over these; utterances from anyone else can still *harm* a metric (see
    /// `SeedAnchorTally.falseAttachRate`) but they cannot be recognised.
    var enrolledSpeakers: Set<String> { Set(enrolments.map(\.speaker)) }

    /// The dimension every vector in the corpus must share, from the first
    /// enrolment. `validated()` enforces it.
    var embeddingDimension: Int { enrolments.first?.centroid.count ?? 0 }
}

/// Why a corpus was refused. Every case is something that would otherwise
/// produce a grid of plausible-looking numbers that measure nothing.
///
/// `LocalizedError` as well as `CustomStringConvertible` so the explanation
/// survives whichever of the two XCTest reaches for: a bare `Error` enum's
/// `localizedDescription` is the useless generic "operation couldn't be
/// completed", and someone whose corpus was rejected mid-run needs the reason,
/// not the case name.
enum SeedAnchorCorpusError: Error, LocalizedError, CustomStringConvertible {
    case noEnrolments
    case noRecordings
    case duplicateEnrolment(speaker: String)
    case emptyRecording(recording: String)
    case emptyVector(context: String)
    case nonFiniteVector(context: String)
    case dimensionMismatch(context: String, expected: Int, found: Int)
    case badSampleCount(speaker: String, count: Int)
    case negativeDuration(recording: String, speaker: String)

    var description: String {
        switch self {
        case .noEnrolments:
            return "corpus has no enrolments — with no stored profile there is nothing for the seed anchor to weight"
        case .noRecordings:
            return "corpus has no recordings to replay"
        case .duplicateEnrolment(let speaker):
            return "two enrolments for speaker \(speaker) — seeded ids are resolved by profile name, so the mapping would be ambiguous"
        case .emptyRecording(let recording):
            return "recording \(recording) has no utterances"
        case .emptyVector(let context):
            return "empty embedding at \(context) — `assign` skips empty centroids and refuses empty embeddings, so this row would silently vanish"
        case .nonFiniteVector(let context):
            return "non-finite value in embedding at \(context) — a NaN makes every later comparison NaN, which reads as 'never matched' rather than as an error"
        case .dimensionMismatch(let context, let expected, let found):
            return "embedding dimension \(found) at \(context), expected \(expected) — `assign` refuses a confident match across dimensions, so a mixed-dimension corpus scores zero recall for reasons that have nothing to do with the anchor weight"
        case .badSampleCount(let speaker, let count):
            return "enrolment for \(speaker) has sampleCount \(count), which must be in 1...VoiceProfile.maxSampleCount — the same bound `updateProfile` enforces, and what keeps `assign`'s `n + 1` from overflowing under an uncapped anchor"
        case .negativeDuration(let recording, let speaker):
            return "utterance by \(speaker) in \(recording) ends before it starts"
        }
    }

    var errorDescription: String? { description }
}

extension SeedAnchorCorpus {

    /// Refuse a corpus that cannot answer the question, rather than reporting
    /// a grid computed from it.
    ///
    /// The bounds on `sampleCount` mirror `SpeakerProfileStore.updateProfile`
    /// deliberately: the harness must only accept profiles the app itself
    /// would have accepted, or the sweep is measuring a state that cannot
    /// occur. It is also load-bearing for the *uncapped* configuration —
    /// there `seedPool` passes the stored count through untouched, and
    /// `assign` computes `Float(n + 1)`, which would trap on `Int.max`.
    @discardableResult
    func validated() throws -> SeedAnchorCorpus {
        guard !enrolments.isEmpty else { throw SeedAnchorCorpusError.noEnrolments }
        guard !recordings.isEmpty else { throw SeedAnchorCorpusError.noRecordings }

        let dimension = enrolments[0].centroid.count

        var seen = Set<String>()
        for enrolment in enrolments {
            guard seen.insert(enrolment.speaker).inserted else {
                throw SeedAnchorCorpusError.duplicateEnrolment(speaker: enrolment.speaker)
            }
            let context = "enrolment \(enrolment.speaker)"
            guard !enrolment.centroid.isEmpty else {
                throw SeedAnchorCorpusError.emptyVector(context: context)
            }
            guard enrolment.centroid.allSatisfy({ $0.isFinite }) else {
                throw SeedAnchorCorpusError.nonFiniteVector(context: context)
            }
            guard enrolment.centroid.count == dimension else {
                throw SeedAnchorCorpusError.dimensionMismatch(context: context,
                                                              expected: dimension,
                                                              found: enrolment.centroid.count)
            }
            guard enrolment.sampleCount > 0,
                  enrolment.sampleCount <= VoiceProfile.maxSampleCount else {
                throw SeedAnchorCorpusError.badSampleCount(speaker: enrolment.speaker,
                                                           count: enrolment.sampleCount)
            }
        }

        for recording in recordings {
            guard !recording.utterances.isEmpty else {
                throw SeedAnchorCorpusError.emptyRecording(recording: recording.id)
            }
            for (index, utterance) in recording.utterances.enumerated() {
                let context = "\(recording.id)[\(index)] (\(utterance.speaker))"
                guard !utterance.embedding.isEmpty else {
                    throw SeedAnchorCorpusError.emptyVector(context: context)
                }
                guard utterance.embedding.allSatisfy({ $0.isFinite }) else {
                    throw SeedAnchorCorpusError.nonFiniteVector(context: context)
                }
                guard utterance.embedding.count == dimension else {
                    throw SeedAnchorCorpusError.dimensionMismatch(context: context,
                                                                  expected: dimension,
                                                                  found: utterance.embedding.count)
                }
                guard utterance.end >= utterance.start else {
                    throw SeedAnchorCorpusError.negativeDuration(recording: recording.id,
                                                                 speaker: utterance.speaker)
                }
            }
        }
        return self
    }

    static func load(from url: URL) throws -> SeedAnchorCorpus {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SeedAnchorCorpus.self, from: data).validated()
    }
}

// MARK: - Configuration

/// One cell of the sweep grid.
struct SeedAnchorConfiguration: Hashable {
    /// The seed anchor weight under test, n₀ — what `seedPool` caps a
    /// returning speaker's `sampleCount` at. `uncappedAnchorWeight` means
    /// "no cap": the profile anchors at its true stored count, which is
    /// exactly what deleting the `min` in `seedPool` would do.
    let anchorWeight: Int
    /// `LiveSpeakerDiarizer.similarityThreshold` for this cell. Swept
    /// alongside n₀ rather than held at the default because the two
    /// interact: n₀ sets how fast the compared centroid moves and the
    /// threshold sets how far it may move before a match is refused, so the
    /// best n₀ at 0.55 need not be the best at 0.70 — and Settings lets users
    /// pick anything in 0.5...0.95.
    let similarityThreshold: Double

    static let uncappedAnchorWeight = Int.max

    /// The grid from #206's protocol. It includes both ends deliberately —
    /// 1 is the lightest well-formed anchor and `uncapped` is the failure
    /// `seedAnchorWeight`'s doc comment describes — so the sweep *reports*
    /// them instead of assuming them.
    static let defaultAnchorWeights: [Int] = [1, 2, 3, 4, 6, 8, 12,
                                              SeedAnchorConfiguration.uncappedAnchorWeight]

    /// Spans the useful part of the Settings slider around the 0.55 default.
    /// Swept alongside n₀ because the two knobs interact — see
    /// `similarityThreshold` above.
    static let defaultThresholds: [Double] = [0.50, 0.55, 0.60, 0.65, 0.70]

    var anchorLabel: String {
        anchorWeight == Self.uncappedAnchorWeight ? "uncapped" : "\(anchorWeight)"
    }

    var label: String {
        String(format: "n0=%@ thr=%.2f", anchorLabel, similarityThreshold)
    }
}

// MARK: - Replay output

/// What one replayed recording produced. Deliberately just the observations —
/// every metric is computed from this by `SeedAnchorTally`, so the metric
/// definitions are testable without a diarizer and the replay is testable
/// without the metrics.
struct SeedAnchorRecordingOutcome {

    struct Assignment: Equatable {
        let trueSpeaker: String
        let assignedID: String
    }

    /// The end-of-recording pool as `currentProfiles()` reports it — the
    /// exact rows `RecognisedSpeakerAssigner.finish` reads.
    struct PoolEntry: Equatable {
        let id: String
        let observedCount: Int
        let profileName: String?
    }

    let recordingID: String
    /// One per utterance, in replay (chronological) order.
    let assignments: [Assignment]
    let pool: [PoolEntry]
    /// speaker label → the `SPEAKER_NN` id `seedPool` gave that speaker's
    /// profile. Read back out of the pool rather than recomputed, so it
    /// cannot drift from how `seedPool` actually mints ids.
    let seededID: [String: String]
    /// The inverse: `SPEAKER_NN` → the speaker whose profile seeded it.
    let speakerBehindSeededID: [String: String]
    /// Every speaker with a stored profile, whether or not they spoke here.
    let enrolledSpeakers: Set<String>
}

// MARK: - Metrics

/// The four metrics #206 asks for, as raw counts so recordings aggregate by
/// addition and the rates are computed once over the whole corpus.
///
/// Counts rather than per-recording rates on purpose: a rate whose
/// denominator is zero for some recordings (a recording where nobody
/// enrolled spoke, say) has no well-defined average, and averaging rates
/// across recordings of very different lengths silently weights a 20-utterance
/// recording the same as a 300-utterance one.
struct SeedAnchorTally: Equatable {

    /// Utterances whose true speaker has a stored profile.
    var returningTotal = 0
    /// …of those, the ones `assign` sent to the entry seeded from *that
    /// speaker's* profile. "It recognised me."
    var returningHits = 0

    /// Every utterance replayed, the denominator for `falseAttachRate`.
    var utterancesTotal = 0
    /// Utterances that landed on a seeded entry belonging to a **different**
    /// true speaker. This is the harm the whole knob risks: the wrong name
    /// against someone's words, and — once `finish` auto-names it — the wrong
    /// voice folded into a stored profile.
    ///
    /// Counted for utterances from *any* speaker, enrolled or not: a
    /// stranger's utterance landing on Alice's entry is exactly as harmful as
    /// Bob's, so restricting this to enrolled speakers would hide the case a
    /// heavy anchor makes most likely.
    var falseAttachments = 0

    /// Pool entries that would be auto-named — `profileName != nil &&
    /// observedCount > 0`, which is `RecognisedSpeakerAssigner.finish`'s guard
    /// set restricted to the two guards that depend on acoustics. (Its other
    /// two cannot vary in a replay: there are no live user-typed names, and
    /// every profile in a corpus is still stored.)
    ///
    /// `SeedAnchorAutoNameAgreementTests` pins this predicate against the real
    /// `finish`, so it cannot drift into a private reimplementation.
    var autoNamesIssued = 0
    /// …of those, the ones naming the right person: the utterances assigned to
    /// that id have a *unique* plurality true speaker and it is the named one.
    /// A tie counts as wrong, matching how the rest of this subsystem fails
    /// closed.
    var autoNamesCorrect = 0
    /// Enrolled speakers who actually spoke, summed over recordings — the
    /// recall denominator. A profile whose owner never opened their mouth
    /// cannot be recognised and must not count against recall.
    var autoNamesExpected = 0

    /// Σ |distinct ids used − distinct true speakers| over recordings.
    var speakerCountAbsError = 0
    /// The same sum, signed. Positive means over-segmentation — the same
    /// person split across several `SPEAKER_NN`s, which is the
    /// counter-intuitive interaction a *heavier* anchor is expected to make
    /// worse.
    var speakerCountSignedError = 0

    var recordings = 0

    /// Recognisable and recognised utterance counts for one speaker.
    ///
    /// A named struct rather than a tuple because `SeedAnchorTally` is
    /// `Equatable` and a `Dictionary` whose value is a tuple is not — tuples
    /// have `==` overloads, not a conformance, so the synthesized
    /// `Equatable` would fail to compile.
    struct SpeakerCounts: Equatable {
        var total = 0
        var hits = 0
    }

    /// speaker → how many of their utterances were recognisable, and how many
    /// were recognised. Kept per speaker because the significance test has to
    /// be paired **across speakers**: utterances inside one recording are
    /// heavily correlated, so an utterance-level test finds significance that
    /// is not there.
    var perSpeaker: [String: SpeakerCounts] = [:]

    var returningRecall: Double? {
        returningTotal == 0 ? nil : Double(returningHits) / Double(returningTotal)
    }
    var falseAttachRate: Double? {
        utterancesTotal == 0 ? nil : Double(falseAttachments) / Double(utterancesTotal)
    }
    var autoNamePrecision: Double? {
        autoNamesIssued == 0 ? nil : Double(autoNamesCorrect) / Double(autoNamesIssued)
    }
    var autoNameRecall: Double? {
        autoNamesExpected == 0 ? nil : Double(autoNamesCorrect) / Double(autoNamesExpected)
    }
    var meanSpeakerCountAbsError: Double? {
        recordings == 0 ? nil : Double(speakerCountAbsError) / Double(recordings)
    }
    var meanSpeakerCountSignedError: Double? {
        recordings == 0 ? nil : Double(speakerCountSignedError) / Double(recordings)
    }

    /// Per-speaker recall, the vector the Wilcoxon test is paired over.
    var perSpeakerRecall: [String: Double] {
        perSpeaker.compactMapValues { counts -> Double? in
            counts.total == 0 ? nil : Double(counts.hits) / Double(counts.total)
        }
    }

    static func + (lhs: SeedAnchorTally, rhs: SeedAnchorTally) -> SeedAnchorTally {
        var out = lhs
        out.returningTotal += rhs.returningTotal
        out.returningHits += rhs.returningHits
        out.utterancesTotal += rhs.utterancesTotal
        out.falseAttachments += rhs.falseAttachments
        out.autoNamesIssued += rhs.autoNamesIssued
        out.autoNamesCorrect += rhs.autoNamesCorrect
        out.autoNamesExpected += rhs.autoNamesExpected
        out.speakerCountAbsError += rhs.speakerCountAbsError
        out.speakerCountSignedError += rhs.speakerCountSignedError
        out.recordings += rhs.recordings
        for (speaker, counts) in rhs.perSpeaker {
            var existing = out.perSpeaker[speaker] ?? SpeakerCounts()
            existing.total += counts.total
            existing.hits += counts.hits
            out.perSpeaker[speaker] = existing
        }
        return out
    }

    /// Score one replayed recording. Pure — no diarizer, no I/O — so every
    /// metric definition above is pinned by tests over hand-built outcomes.
    static func scoring(_ outcome: SeedAnchorRecordingOutcome) -> SeedAnchorTally {
        var tally = SeedAnchorTally()
        tally.recordings = 1
        tally.utterancesTotal = outcome.assignments.count

        for assignment in outcome.assignments {
            if outcome.enrolledSpeakers.contains(assignment.trueSpeaker) {
                tally.returningTotal += 1
                var counts = tally.perSpeaker[assignment.trueSpeaker] ?? SpeakerCounts()
                counts.total += 1
                if outcome.seededID[assignment.trueSpeaker] == assignment.assignedID {
                    tally.returningHits += 1
                    counts.hits += 1
                }
                tally.perSpeaker[assignment.trueSpeaker] = counts
            }
            if let seededOwner = outcome.speakerBehindSeededID[assignment.assignedID],
               seededOwner != assignment.trueSpeaker {
                tally.falseAttachments += 1
            }
        }

        // Auto-naming, evaluated over the same pool rows `finish` reads.
        for entry in outcome.pool {
            guard let profileName = entry.profileName, entry.observedCount > 0 else { continue }
            tally.autoNamesIssued += 1
            var byTrueSpeaker: [String: Int] = [:]
            for assignment in outcome.assignments where assignment.assignedID == entry.id {
                byTrueSpeaker[assignment.trueSpeaker, default: 0] += 1
            }
            guard let top = byTrueSpeaker.values.max() else { continue }
            let leaders = byTrueSpeaker.filter { $0.value == top }.map { $0.key }
            if leaders.count == 1, leaders[0] == profileName {
                tally.autoNamesCorrect += 1
            }
        }
        let spoke = Set(outcome.assignments.map(\.trueSpeaker))
        tally.autoNamesExpected = outcome.enrolledSpeakers.intersection(spoke).count

        let idsUsed = Set(outcome.assignments.map(\.assignedID)).count
        let signed = idsUsed - spoke.count
        tally.speakerCountSignedError = signed
        tally.speakerCountAbsError = abs(signed)

        return tally
    }
}

/// One cell of the grid, scored.
struct SeedAnchorResult {
    let configuration: SeedAnchorConfiguration
    let tally: SeedAnchorTally
    /// Per-recording tallies, kept so a run can be inspected recording by
    /// recording when a cell looks surprising.
    let perRecording: [String: SeedAnchorTally]
}

// MARK: - Harness

/// Replays a cached corpus through the **real** `LiveSpeakerDiarizer` matching
/// path once per grid cell, and scores it.
///
/// The replay drives `reset()`, `seedPool(with:)` and `assign(embedding:
/// utteranceDuration:)` — the shipping code, not a model of it. That is the
/// point: #248 established that a simulation of `assign` was green for every
/// anchor weight from 1 to uncapped, so anything short of the real fold can
/// agree with itself while disagreeing with the app.
///
/// Nothing here has a default that changes app behaviour: the only knob it
/// touches is `seedAnchorWeightOverride`, which is `nil` everywhere else.
@MainActor
enum SeedAnchorSweepHarness {

    /// Replay one recording under one configuration.
    static func replay(recording: SeedAnchorCorpus.Recording,
                       enrolments: [SeedAnchorCorpus.Enrolment],
                       configuration: SeedAnchorConfiguration) -> SeedAnchorRecordingOutcome {
        let diarizer = LiveSpeakerDiarizer()
        diarizer.similarityThreshold = configuration.similarityThreshold
        diarizer.seedAnchorWeightOverride = configuration.anchorWeight
        diarizer.reset()

        // Sorted by speaker so the seeded id a speaker gets is a function of
        // the corpus, not of dictionary or file ordering. Ids are minted
        // positionally by `seedPool`, so an unstable order would reshuffle
        // them between runs and make two grids incomparable.
        let ordered = enrolments.sorted { $0.speaker < $1.speaker }
        diarizer.seedPool(with: ordered.map {
            (id: $0.speaker, name: $0.speaker, centroid: $0.centroid, sampleCount: $0.sampleCount)
        })

        // Read the mapping back off the pool instead of recomputing
        // `SPEAKER_%02d` from the index: if `seedPool` ever mints ids
        // differently, this follows it rather than silently mislabelling
        // every hit as a miss.
        var seededID: [String: String] = [:]
        var speakerBehindSeededID: [String: String] = [:]
        for entry in diarizer.currentProfiles() {
            guard let name = entry.profileName else { continue }
            seededID[name] = entry.id
            speakerBehindSeededID[entry.id] = name
        }

        // Chronological, with a total order so equal timestamps cannot
        // reorder between runs — `sorted(by:)` is not documented as stable.
        let chronological = recording.utterances.enumerated().sorted { lhs, rhs in
            if lhs.element.start != rhs.element.start { return lhs.element.start < rhs.element.start }
            if lhs.element.end != rhs.element.end { return lhs.element.end < rhs.element.end }
            return lhs.offset < rhs.offset
        }.map { $0.element }

        var assignments: [SeedAnchorRecordingOutcome.Assignment] = []
        assignments.reserveCapacity(chronological.count)
        for utterance in chronological {
            let assigned = diarizer.assign(embedding: utterance.embedding,
                                           utteranceDuration: utterance.duration)
            assignments.append(.init(trueSpeaker: utterance.speaker, assignedID: assigned))
        }

        let pool = diarizer.currentProfiles().map {
            SeedAnchorRecordingOutcome.PoolEntry(id: $0.id,
                                                 observedCount: $0.observedCount,
                                                 profileName: $0.profileName)
        }

        return SeedAnchorRecordingOutcome(recordingID: recording.id,
                                          assignments: assignments,
                                          pool: pool,
                                          seededID: seededID,
                                          speakerBehindSeededID: speakerBehindSeededID,
                                          enrolledSpeakers: Set(enrolments.map(\.speaker)))
    }

    /// Score every recording in the corpus under one configuration.
    static func evaluate(corpus: SeedAnchorCorpus,
                         configuration: SeedAnchorConfiguration) -> SeedAnchorResult {
        var total = SeedAnchorTally()
        var perRecording: [String: SeedAnchorTally] = [:]
        for recording in corpus.recordings {
            let outcome = replay(recording: recording,
                                 enrolments: corpus.enrolments,
                                 configuration: configuration)
            let tally = SeedAnchorTally.scoring(outcome)
            perRecording[recording.id] = tally
            total = total + tally
        }
        return SeedAnchorResult(configuration: configuration,
                                tally: total,
                                perRecording: perRecording)
    }

    /// The whole grid, in row-major order (anchor weight outer, threshold
    /// inner) so `report` can slice it without re-sorting.
    static func sweep(corpus: SeedAnchorCorpus,
                      anchorWeights: [Int] = SeedAnchorConfiguration.defaultAnchorWeights,
                      thresholds: [Double] = SeedAnchorConfiguration.defaultThresholds)
                      throws -> [SeedAnchorResult] {
        try corpus.validated()
        var results: [SeedAnchorResult] = []
        for weight in anchorWeights {
            for threshold in thresholds {
                let configuration = SeedAnchorConfiguration(anchorWeight: weight,
                                                            similarityThreshold: threshold)
                results.append(evaluate(corpus: corpus, configuration: configuration))
            }
        }
        return results
    }
}

// MARK: - Recommendation

/// The decision rule from #206, applied to a finished grid — as a **starting
/// point for a human**, not a verdict.
///
/// The rule: prefer the *smallest* anchor weight whose worst false-attach rate
/// across the threshold row is within `tolerance` of the best any weight
/// achieves. Smallest-wins comes from the asymmetry that keeps the anchor
/// small in the first place — a too-light anchor's damage is confined to one
/// recording, because n₀ never reaches persistence, while a too-heavy anchor's
/// damage persists across every future recording of that speaker.
///
/// `tolerance` is a judgement call with no measurement behind it, which is why
/// it is a parameter and why this type reports what it rejected. The gate that
/// actually matters is the paired significance test on per-speaker recall
/// (`WilcoxonSignedRank`), reported per cell alongside this.
struct SeedAnchorRecommendation {
    let anchorWeight: Int
    let anchorLabel: String
    /// Worst (highest) false-attach rate this weight produced across the
    /// swept thresholds — the row is judged by its worst cell, not its best,
    /// because users can set any threshold in 0.5...0.95.
    let worstCaseFalseAttach: Double
    let gridBestWorstCase: Double
    let tolerance: Double
    /// Weights ruled out, with the worst-case that ruled them out.
    let rejected: [(anchorLabel: String, worstCaseFalseAttach: Double)]

    static func from(_ results: [SeedAnchorResult],
                     tolerance: Double = 0.01) -> SeedAnchorRecommendation? {
        var worstCase: [Int: Double] = [:]
        for result in results {
            guard let rate = result.tally.falseAttachRate else { continue }
            worstCase[result.configuration.anchorWeight] =
                max(worstCase[result.configuration.anchorWeight] ?? 0, rate)
        }
        guard let best = worstCase.values.min() else { return nil }
        let candidates = worstCase.filter { $0.value <= best + tolerance }.keys.sorted()
        guard let winner = candidates.first else { return nil }
        let rejected = worstCase.filter { !candidates.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { (anchorLabel: SeedAnchorConfiguration(anchorWeight: $0.key,
                                                         similarityThreshold: 0).anchorLabel,
                    worstCaseFalseAttach: $0.value) }
        return SeedAnchorRecommendation(
            anchorWeight: winner,
            anchorLabel: SeedAnchorConfiguration(anchorWeight: winner,
                                                 similarityThreshold: 0).anchorLabel,
            worstCaseFalseAttach: worstCase[winner] ?? best,
            gridBestWorstCase: best,
            tolerance: tolerance,
            rejected: rejected)
    }
}
