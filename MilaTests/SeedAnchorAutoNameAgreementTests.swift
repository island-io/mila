import XCTest
@testable import Mila

/// **Invariant: the sweep harness's auto-name metric counts exactly the names
/// `RecognisedSpeakerAssigner.finish` would actually apply.**
///
/// ## Why this file exists
///
/// `SeedAnchorTally` scores recording-level auto-naming from a predicate over
/// the pool — `profileName != nil && observedCount > 0` — rather than by
/// running the real `finish` per grid cell. That is a deliberate trade: a
/// 40-cell sweep would otherwise need a `RecordingStore`, a
/// `SpeakerProfileStore` and a disk write per cell, turning a
/// milliseconds-per-configuration replay into something nobody will run.
///
/// The cost of that trade is the classic one: a predicate copied out of
/// `finish` drifts from `finish`, and a drifted metric does not fail — it
/// quietly reports a different number. #248 found the same hazard one layer
/// down, where a *simulation* of `assign` agreed with itself for every anchor
/// weight from 1 to uncapped while the real fold did not.
///
/// So the predicate is not trusted; it is pinned. Each test below drives the
/// real pipeline — real `RecordingStore`, real `SpeakerProfileStore`, real
/// `LiveSpeakerDiarizer`, real `RecognisedSpeakerAssigner` — and the harness's
/// replay over an identical corpus, and asserts the two agree on how many
/// names get applied. If someone adds a fifth guard to `finish`, or changes
/// what `observedCount` means, this fails instead of the sweep silently
/// measuring the old behaviour.
///
/// ## The two guards that are not modelled, and why that is sound
///
/// `finish` has four guards. Two depend on acoustics and are modelled here.
/// The other two cannot vary during a replay:
///
///   * *the user did not already name this speaker* — a replay has no live
///     transcript and so no user-typed names;
///   * *the profile is still stored* — a corpus's profiles exist for the
///     whole run; nobody deletes one mid-sweep.
///
/// Both would only ever *suppress* a name, so modelling them as "true" is also
/// the direction that cannot overstate recognition.
@MainActor
final class SeedAnchorAutoNameAgreementTests: XCTestCase {

    private var tempRoot: URL!
    private var suiteNames: [String] = []

    /// Alice's stored profile, and a vector close enough to it to be a
    /// confident match at the 0.7 threshold used throughout.
    private let aliceStored: [Float] = [1, 0, 0, 0]
    private let aliceSpeaking: [Float] = [0.99, 0.01, 0, 0]
    /// Cosine exactly 0.6 to `aliceStored`: above the 0.55 create floor, below
    /// the 0.7 match threshold — so `assign` attaches it to Alice's entry
    /// without folding it in, leaving `observedCount` at zero. This is the
    /// case that separates "produced an interval" from "confidently matched",
    /// and the reason `finish` gates on `observedCount` rather than intervals.
    private let borderline: [Float] = [0.6, 0.8, 0, 0]
    /// Orthogonal to everything seeded: mints a speaker of its own.
    private let stranger: [Float] = [0, 0, 1, 0]

    private let threshold = 0.7

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "SeedAnchorAutoNameAgreementTests")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        suiteNames.removeAll()
        try await super.tearDown()
    }

    // MARK: - The real pipeline

    private struct World {
        let store: RecordingStore
        let profiles: SpeakerProfileStore
        let diarizer: LiveSpeakerDiarizer
        let assigner: RecognisedSpeakerAssigner
    }

    /// Alice on disk and a seeded pool — the same wiring `MilaApp.init`
    /// installs, and the same shape `RecognisedSpeakerAssignerTests` uses.
    private func makeWorld() -> World {
        let suite = "SeedAnchorAutoNameAgreementTests.\(UUID())"
        suiteNames.append(suite)
        let settings = VoiceRecognitionSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.diarizationReady = { true }
        settings.isEnabled = true

        let profiles = SpeakerProfileStore(directory: tempRoot, settings: settings)
        profiles.updateProfile(name: "Alice", embedding: aliceStored, sampleCount: 40)

        let store = RecordingStore(rootDirectory: tempRoot)
        let snapshots = ObservedVoiceSnapshots()
        store.onSpeakerNamed = { recordingID, rawID, name in
            guard settings.isConfigured else { return }
            guard let observed = snapshots.observation(forSpeaker: rawID,
                                                       in: recordingID) else { return }
            profiles.updateProfile(name: name,
                                   embedding: observed.observedCentroid,
                                   sampleCount: observed.observedCount)
        }

        let diarizer = LiveSpeakerDiarizer()
        diarizer.similarityThreshold = threshold
        diarizer.reset()
        diarizer.seedPool(with: profiles.seedEntries())

        let assigner = RecognisedSpeakerAssigner(
            store: store,
            diarizer: diarizer,
            snapshots: snapshots,
            settings: settings,
            profileStillStored: { profiles.profileExists(name: $0) })
        return World(store: store, profiles: profiles, diarizer: diarizer, assigner: assigner)
    }

    /// The same utterances, replayed through the harness against a corpus that
    /// mirrors the world: one enrolment for Alice at the same stored count,
    /// the shipping anchor weight, the same threshold.
    private func harnessNamesIssued(for embeddings: [[Float]]) throws -> Int {
        let utterances = embeddings.enumerated().map { index, embedding in
            SeedAnchorCorpus.Utterance(speaker: "Alice",
                                       start: Double(index) * 3,
                                       end: Double(index) * 3 + 2,
                                       embedding: embedding)
        }
        let corpus = try SeedAnchorCorpus(
            enrolments: [.init(speaker: "Alice", centroid: aliceStored, sampleCount: 40)],
            recordings: [.init(id: "r1", setup: "agreement", utterances: utterances)]
        ).validated()

        let results = try SeedAnchorSweepHarness.sweep(
            corpus: corpus,
            anchorWeights: [LiveSpeakerDiarizer.seedAnchorWeight],
            thresholds: [threshold])
        return try XCTUnwrap(results.first).tally.autoNamesIssued
    }

    /// Drive the world's diarizer with the same embeddings, finish the
    /// recording, and report how many raw ids ended up carrying a name.
    private func pipelineNamesApplied(for embeddings: [[Float]]) -> (applied: Int, names: [String: String]) {
        let world = makeWorld()
        for embedding in embeddings {
            _ = world.diarizer.assign(embedding: embedding)
        }
        let meeting = Recording(title: "Meeting", createdAt: Date(),
                                source: .microphone, audioFileName: "Meeting.wav")
        world.store.add(meeting)
        world.assigner.finish(recording: meeting.id)
        let names = world.store.recordings.first { $0.id == meeting.id }?.speakerNames ?? [:]
        return (names.count, names)
    }

    // MARK: - Agreement

    /// A speaker who confidently matched is named by the pipeline, and counted
    /// by the harness.
    func test_a_confident_match_is_named_by_both() throws {
        let embeddings = [aliceSpeaking]
        let pipeline = pipelineNamesApplied(for: embeddings)

        XCTAssertEqual(pipeline.names["SPEAKER_00"], "Alice",
                       "precondition: the real pipeline auto-names the recognised speaker")
        XCTAssertEqual(try harnessNamesIssued(for: embeddings), pipeline.applied,
                       "the harness's auto-name metric must count exactly the names `finish` "
                       + "applies — if these diverge the sweep is scoring a predicate that no "
                       + "longer matches the code it claims to model")
    }

    /// The case that makes the predicate non-obvious: an utterance that
    /// *attaches* to Alice's entry without folding into it. The entry produces
    /// an interval and carries her name from the seed, but `observedCount`
    /// stays 0 — so `finish` refuses to auto-name, and the harness must refuse
    /// to count it.
    ///
    /// A predicate written as "was seeded and got at least one utterance"
    /// would pass every other test in this file and fail only here.
    func test_a_borderline_attach_is_named_by_neither() throws {
        let embeddings = [borderline, stranger]
        let pipeline = pipelineNamesApplied(for: embeddings)

        XCTAssertTrue(pipeline.names.isEmpty,
                      "precondition: a borderline attach is not a recognition, and a minted "
                      + "speaker has no profile to be named from")
        XCTAssertEqual(try harnessNamesIssued(for: embeddings), 0)
        XCTAssertEqual(try harnessNamesIssued(for: embeddings), pipeline.applied)
    }

    /// And the mixed case: one confident match plus a stranger. Exactly one
    /// name, from both sides — the minted speaker must not be counted just
    /// because it has observations.
    func test_a_minted_speaker_is_counted_by_neither() throws {
        let embeddings = [aliceSpeaking, stranger]
        let pipeline = pipelineNamesApplied(for: embeddings)

        XCTAssertEqual(pipeline.applied, 1)
        XCTAssertNil(pipeline.names["SPEAKER_01"],
                     "precondition: a speaker minted in-recording has no stored profile "
                     + "behind it, so there is no name to apply")
        XCTAssertEqual(try harnessNamesIssued(for: embeddings), 1)
    }
}
