import XCTest
@testable import Mila

/// Two invariants on the voice-profile write path, both about *which* voice
/// gets written.
///
/// 1. **A name applied to recording A persists A's voice, never a later
///    recording's.** `SPEAKER_00` is positional and restarts from zero on
///    every `LiveSpeakerDiarizer.reset()`, so resolving a name against the
///    *live* pool by raw id silently returned whoever was `SPEAKER_00` in the
///    newest recording. Naming an older recording from the sidebar — an
///    entirely ordinary thing to do — poisoned the named profile with a
///    stranger's embedding, with nothing to show it had happened.
/// 2. **Automatic naming requires a confident match, not merely an
///    interval.** `assign` attaches borderline utterances (and anything under
///    a second) to the nearest existing speaker *without* folding them into
///    the centroid, so such an utterance yields an interval while leaving
///    `observedCount` at zero. Gating on intervals alone stamped a stored
///    profile's name onto a speaker that never confidently matched it.
///
/// Real `LiveSpeakerDiarizer`, real `ObservedVoiceSnapshots`, real
/// `RecordingStore`, real `SpeakerProfileStore`. Only the three-line
/// `onSpeakerNamed` closure is replicated from `MilaApp.init` — that is
/// unreachable from a unit test — and it is written verbatim below. Each
/// invariant has a negative control reproducing the old shape, so the
/// assertions are provably discriminating.
@MainActor
final class CrossRecordingVoiceIsolationTests: XCTestCase {

    private var tempRoot: URL!
    private var suiteNames: [String] = []

    /// Alice, as stored on disk before any of this.
    private let aliceStored: [Float] = [1, 0, 0, 0]
    /// Close enough to Alice to be a confident match at threshold 0.7.
    private let aliceSpeaking: [Float] = [0.99, 0.01, 0, 0]
    /// Nothing like Alice — a different person entirely.
    private let strangerSpeaking: [Float] = [0, 1, 0, 0]

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "CrossRecordingVoiceIsolationTests")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        suiteNames.removeAll()
        try await super.tearDown()
    }

    // MARK: - Fixture

    private func makeSettings() -> VoiceRecognitionSettings {
        let name = "CrossRecordingVoiceIsolationTests.\(UUID())"
        suiteNames.append(name)
        let settings = VoiceRecognitionSettings(defaults: UserDefaults(suiteName: name)!)
        settings.diarizationReady = { true }
        settings.isEnabled = true
        return settings
    }

    private func makeDiarizer() -> LiveSpeakerDiarizer {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = 0.7
        return d
    }

    @discardableResult
    private func addRecording(_ title: String, to store: RecordingStore) -> Recording {
        let rec = Recording(title: title,
                            duration: 60,
                            source: .microphone,
                            audioFileName: "\(title).wav")
        store.add(rec)
        return rec
    }

    /// Verbatim shape of `MilaApp.init`'s wiring.
    private func wireHook(_ recordings: RecordingStore,
                          _ snapshots: ObservedVoiceSnapshots,
                          _ profiles: SpeakerProfileStore,
                          _ settings: VoiceRecognitionSettings) {
        recordings.onSpeakerNamed = { recordingID, rawID, name in
            guard settings.isConfigured else { return }
            guard let observed = snapshots.observation(forSpeaker: rawID,
                                                      in: recordingID) else { return }
            profiles.updateProfile(name: name,
                                   embedding: observed.observedCentroid,
                                   sampleCount: observed.observedCount)
        }
    }

    private func alice(_ profiles: SpeakerProfileStore) -> VoiceProfile? {
        profiles.profile(named: "Alice")
    }

    /// Alice on disk; recording A where Alice actually spoke and was
    /// snapshotted; then recording B where a *stranger* took the
    /// `SPEAKER_00` slot and was snapshotted too. That is the collision.
    private func makeTwoRecordingWorld() -> (recordings: RecordingStore,
                                            profiles: SpeakerProfileStore,
                                            snapshots: ObservedVoiceSnapshots,
                                            diarizer: LiveSpeakerDiarizer,
                                            recA: Recording,
                                            recB: Recording) {
        let settings = makeSettings()
        let profiles = SpeakerProfileStore(directory: tempRoot, settings: settings)
        profiles.updateProfile(name: "Alice", embedding: aliceStored, sampleCount: 40)

        let recordings = RecordingStore(rootDirectory: tempRoot)
        let snapshots = ObservedVoiceSnapshots()
        wireHook(recordings, snapshots, profiles, settings)

        let diarizer = makeDiarizer()

        // --- Recording A: Alice speaks, matching her seeded profile.
        let recA = addRecording("A", to: recordings)
        diarizer.reset()
        diarizer.seedPool(with: profiles.seedEntries())
        XCTAssertEqual(diarizer.assign(embedding: aliceSpeaking), "SPEAKER_00")
        snapshots.record(diarizer.currentProfiles(), for: recA.id)

        // --- Recording B: not seeded, and someone else entirely speaks, so
        // the stranger takes the SPEAKER_00 slot.
        let recB = addRecording("B", to: recordings)
        diarizer.reset()
        XCTAssertEqual(diarizer.assign(embedding: strangerSpeaking), "SPEAKER_00",
                       "the stranger must land on the same raw id — that is the collision")
        snapshots.record(diarizer.currentProfiles(), for: recB.id)

        return (recordings, profiles, snapshots, diarizer, recA, recB)
    }

    // MARK: - 1. A name on an older recording uses that recording's voice

    func test_naming_an_older_recording_persists_its_own_voice_not_a_later_ones() {
        let w = makeTwoRecordingWorld()

        // The user goes back to recording A in the sidebar and names
        // SPEAKER_00 "Alice" — after B has already reset the pool.
        w.recordings.setSpeakerName("Alice", forSpeaker: "SPEAKER_00", recordingID: w.recA.id)

        XCTAssertEqual(alice(w.profiles)?.sampleCount, 41, "40 stored + A's 1 observation")
        // Alice's centroid must still point at Alice. The stranger is
        // [0, 1, 0, 0], so a leak shows up as component 1 moving off zero.
        //
        // Unwrapped rather than defaulted to `[]`: if the write path ever
        // regresses and nothing is stored, an empty fallback would trap on the
        // subscript below and abort the whole runner, hiding *which* invariant
        // broke. Failing here names it instead.
        guard let embedding = alice(w.profiles)?.embedding, embedding.count >= 2 else {
            XCTFail("Alice was never written, or her embedding is too short to check for a leak")
            return
        }
        XCTAssertGreaterThan(embedding[0], 0.98, "still Alice")
        XCTAssertLessThan(embedding[1], 0.02, "the stranger's voice must not have leaked in")
        XCTAssertGreaterThan(cosineSimilarity(embedding, aliceStored), 0.99)
    }

    /// Negative control: resolve the name the old way — against the *live*
    /// pool by raw id — and confirm it does write the stranger into Alice.
    /// Without this the assertions above could pass for the wrong reason.
    func test_the_live_pool_lookup_would_have_leaked_the_stranger() {
        let w = makeTwoRecordingWorld()

        // The removed shape: ignore recordingID, read the current pool.
        let leaked = w.diarizer.currentProfiles().first { $0.id == "SPEAKER_00" }
        XCTAssertEqual(leaked?.observedCount, 1)
        w.profiles.updateProfile(name: "Alice",
                                 embedding: leaked?.observedCentroid ?? [],
                                 sampleCount: leaked?.observedCount ?? 0)

        // Same unwrap-don't-default reasoning as above: this control is only
        // meaningful if Alice was actually written, so say so rather than
        // trapping on an empty array.
        guard let embedding = alice(w.profiles)?.embedding, embedding.count >= 2 else {
            XCTFail("the control did not write Alice at all, so it cannot demonstrate the leak")
            return
        }
        XCTAssertGreaterThan(embedding[1], 0.02,
                             "the old lookup leaks the stranger — this is what the fix prevents")
    }

    /// Naming a recording that was never snapshotted persists nothing at all
    /// rather than falling back to whatever the pool currently holds. Its
    /// pool is gone; there is no embedding to learn from, and saying so is
    /// better than guessing.
    func test_naming_a_recording_with_no_snapshot_persists_nothing() {
        let settings = makeSettings()
        let profiles = SpeakerProfileStore(directory: tempRoot, settings: settings)
        profiles.updateProfile(name: "Alice", embedding: aliceStored, sampleCount: 40)
        let recordings = RecordingStore(rootDirectory: tempRoot)
        let snapshots = ObservedVoiceSnapshots()
        wireHook(recordings, snapshots, profiles, settings)

        let old = addRecording("Ancient", to: recordings)
        recordings.setSpeakerName("Alice", forSpeaker: "SPEAKER_00", recordingID: old.id)

        XCTAssertEqual(alice(profiles)?.sampleCount, 40, "untouched")
        XCTAssertEqual(alice(profiles)?.embedding, aliceStored, "untouched")
        // The label itself still applies — naming keeps working, it just
        // doesn't learn a voice it never heard.
        XCTAssertEqual(recordings.recordings.first(where: { $0.id == old.id })?
                        .speakerNames["SPEAKER_00"], "Alice")
    }

    /// Naming the newest recording still works — the fix must not break the
    /// common case of labelling the recording you just made.
    func test_naming_the_newest_recording_still_persists_its_voice() {
        let w = makeTwoRecordingWorld()

        w.recordings.setSpeakerName("Stranger", forSpeaker: "SPEAKER_00", recordingID: w.recB.id)

        let stranger = w.profiles.profile(named: "Stranger")
        XCTAssertEqual(stranger?.sampleCount, 1)
        XCTAssertGreaterThan(cosineSimilarity(stranger?.embedding ?? [], strangerSpeaking), 0.99)
        XCTAssertEqual(alice(w.profiles)?.sampleCount, 40, "Alice untouched")
    }

    // MARK: - 2. Automatic naming requires a confident match

    /// A borderline attachment leaves `observedCount` at zero: `assign`
    /// returns the existing speaker without folding the embedding in. This is
    /// the fact the auto-naming gate rests on.
    func test_a_borderline_attachment_does_not_count_as_an_observation() {
        let settings = makeSettings()
        let profiles = SpeakerProfileStore(directory: tempRoot, settings: settings)
        profiles.updateProfile(name: "Alice", embedding: aliceStored, sampleCount: 40)

        let diarizer = makeDiarizer()
        diarizer.reset()
        diarizer.seedPool(with: profiles.seedEntries())

        // cos([0.6, 0.8, 0, 0], [1, 0, 0, 0]) == 0.6 — above the 0.55 create
        // floor so it attaches, below the 0.7 match threshold so it is never
        // folded in.
        let borderline: [Float] = [0.6, 0.8, 0, 0]
        XCTAssertEqual(cosineSimilarity(borderline, aliceStored), 0.6, accuracy: 0.0001,
                       "fixture must actually be borderline")
        XCTAssertEqual(diarizer.assign(embedding: borderline), "SPEAKER_00",
                       "borderline utterances attach rather than fork")

        let entry = diarizer.currentProfiles().first { $0.id == "SPEAKER_00" }
        XCTAssertEqual(entry?.observedCount, 0, "attached, but never confidently matched")
        XCTAssertEqual(entry?.profileName, "Alice", "still a seeded entry")
    }

    /// Negative control for the gate: with the intervals-only condition the
    /// old code used, the same borderline-only speaker *is* named — which is
    /// what makes `RecognisedSpeakerAssignerTests`'
    /// `test_a_borderline_only_speaker_is_not_auto_named` discriminating.
    /// Necessarily a replica: the condition it reproduces no longer exists.
    func test_the_intervals_only_gate_would_have_named_a_borderline_speaker() {
        let settings = makeSettings()
        let profiles = SpeakerProfileStore(directory: tempRoot, settings: settings)
        profiles.updateProfile(name: "Alice", embedding: aliceStored, sampleCount: 40)
        let recordings = RecordingStore(rootDirectory: tempRoot)
        let rec = addRecording("Borderline", to: recordings)

        let diarizer = makeDiarizer()
        diarizer.reset()
        diarizer.seedPool(with: profiles.seedEntries())
        _ = diarizer.assign(embedding: [0.6, 0.8, 0, 0])

        let speakersWithIntervals: Set<String> = ["SPEAKER_00"]

        var namedCount = 0
        for entry in diarizer.currentProfiles() {
            guard let profileName = entry.profileName else { continue }
            // Intervals only — no observedCount check, as the old gate had.
            guard speakersWithIntervals.contains(entry.id) else { continue }
            recordings.setSpeakerName(profileName, forSpeaker: entry.id, recordingID: rec.id)
            namedCount += 1
        }

        XCTAssertEqual(namedCount, 1,
                       "the old gate names it — that misattribution is what the fix removes")
    }

    /// And a genuinely confident match still passes the gate, so the added
    /// condition hasn't simply switched auto-naming off.
    func test_a_confident_match_still_passes_the_gate() {
        let settings = makeSettings()
        let profiles = SpeakerProfileStore(directory: tempRoot, settings: settings)
        profiles.updateProfile(name: "Alice", embedding: aliceStored, sampleCount: 40)

        let diarizer = makeDiarizer()
        diarizer.reset()
        diarizer.seedPool(with: profiles.seedEntries())
        _ = diarizer.assign(embedding: aliceSpeaking)

        let entry = diarizer.currentProfiles().first { $0.id == "SPEAKER_00" }
        XCTAssertEqual(entry?.observedCount, 1)
        XCTAssertEqual(entry?.profileName, "Alice")
    }
}
