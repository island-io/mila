import XCTest
import TranscriptionCore
@testable import Mila

/// The three transcript-level speaker corrections island-io/mila#237 asks
/// for — rename/un-name, move one line, merge two speakers — and the
/// invariants that keep them from writing the wrong voice into a profile.
///
/// **Why merge is not part of naming.** An earlier revision merged inside
/// `setSpeakerName` whenever the typed name matched another speaker's. Every
/// automatic caller inherited that: `RecognisedSpeakerAssigner.finish` and
/// the post-transcription auto-match both loop over `setSpeakerName`, and two
/// clusters that both match one stored profile — two similar voices, one
/// threshold — silently collapsed into one speaker. No user action, no
/// confirmation, no undo, and an unstable outcome (which cluster survives
/// depends on `Dictionary` iteration order).
/// `test_naming_a_speaker_a_name_already_in_use_does_not_merge` is the
/// regression pin; the rest of the merge tests exercise the explicit action
/// that replaced it.
///
/// Real `RecordingStore`, real `SpeakerProfileStore`, real
/// `ObservedVoiceSnapshots`, and the same hook wiring `MilaApp.init`
/// installs — reproduced here because closures in an `App` initializer are
/// unreachable from a test.
@MainActor
final class SpeakerCorrectionActionsTests: XCTestCase {

    private var tempRoot: URL!
    private var suiteNames: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "SpeakerCorrectionActionsTests")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        suiteNames.removeAll()
        try await super.tearDown()
    }

    // MARK: - Fixture

    private struct World {
        let store: RecordingStore
        let profiles: SpeakerProfileStore
        let snapshots: ObservedVoiceSnapshots
        let settings: VoiceRecognitionSettings
        let recordingID: UUID
    }

    private func makeSettings() -> VoiceRecognitionSettings {
        let name = "SpeakerCorrectionActionsTests.\(UUID())"
        suiteNames.append(name)
        let s = VoiceRecognitionSettings(defaults: UserDefaults(suiteName: name)!)
        s.diarizationReady = { true }
        s.isEnabled = true
        return s
    }

    private func segment(_ speaker: String?, _ start: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(start: start, end: start + 2, text: text, speaker: speaker)
    }

    /// A two-speaker recording with three lines, plus the `MilaApp.init`
    /// hooks. `snapshotEntries` seeds `ObservedVoiceSnapshots` so the profile
    /// bookkeeping has something to resolve through.
    private func makeWorld(
        segments: [TranscriptSegment],
        speakerNames: [String: String] = [:],
        snapshotEntries: [(String, [Float], Int)] = []
    ) -> World {
        // Its own directory, so a test that builds two worlds cannot have the
        // second load the first's profiles.json off disk.
        let root = tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let settings = makeSettings()
        let profiles = SpeakerProfileStore(directory: root, settings: settings)
        let store = RecordingStore(rootDirectory: root)
        let snapshots = ObservedVoiceSnapshots()

        let rec = Recording(title: "Meeting",
                            duration: 30,
                            source: .microphone,
                            audioFileName: "meeting.wav",
                            status: .completed,
                            segments: segments,
                            fullText: segments.map(\.text).joined(separator: " "),
                            speakerNames: speakerNames)
        store.add(rec)

        if !snapshotEntries.isEmpty {
            snapshots.record(snapshotEntries.map {
                (id: $0.0, observedCentroid: $0.1, observedCount: $0.2, profileName: nil as String?)
            }, for: rec.id)
        }

        // Verbatim shape of `MilaApp.init`'s wiring, minus the on-demand
        // extraction branch (no Python here — the snapshot always resolves or
        // the test does not care).
        store.onSpeakerNamed = { recordingID, rawID, name in
            guard settings.isConfigured else { return }
            guard let observed = snapshots.observation(forSpeaker: rawID, in: recordingID) else { return }
            profiles.updateProfile(name: name,
                                   embedding: observed.observedCentroid,
                                   sampleCount: observed.observedCount)
        }
        store.onSpeakerUnnamed = { recordingID, rawID, previousName in
            guard settings.isConfigured else { return }
            guard let observed = snapshots.observation(forSpeaker: rawID, in: recordingID) else { return }
            profiles.subtractObservation(name: previousName,
                                         embedding: observed.observedCentroid,
                                         sampleCount: observed.observedCount)
        }
        store.onSpeakerIDAbsorbed = { recordingID, sourceRawID, targetRawID in
            snapshots.absorb(speaker: sourceRawID, into: targetRawID, in: recordingID)
        }

        return World(store: store, profiles: profiles, snapshots: snapshots,
                     settings: settings, recordingID: rec.id)
    }

    private func row(_ w: World) -> Recording {
        w.store.recordings.first { $0.id == w.recordingID }!
    }

    private func speakers(_ w: World) -> [String?] {
        row(w).segments.map(\.speaker)
    }

    // MARK: - Naming is a pure label write

    /// The regression pin for the destructive auto-merge. Two speakers may
    /// legitimately carry the same display name; nothing may move a segment
    /// because of it.
    func test_naming_a_speaker_a_name_already_in_use_does_not_merge() {
        let w = makeWorld(segments: [segment("SPEAKER_00", 0, "one"),
                                     segment("SPEAKER_01", 2, "two"),
                                     segment("SPEAKER_00", 4, "three")],
                          speakerNames: ["SPEAKER_00": "Alice"])

        w.store.setSpeakerName("Alice", forSpeaker: "SPEAKER_01", recordingID: w.recordingID)

        XCTAssertEqual(speakers(w), ["SPEAKER_00", "SPEAKER_01", "SPEAKER_00"],
                       "typing a duplicate name must not reassign anybody's segments")
        XCTAssertEqual(row(w).speakerNames["SPEAKER_00"], "Alice")
        XCTAssertEqual(row(w).speakerNames["SPEAKER_01"], "Alice",
                       "both speakers simply display the same name")
    }

    /// The shape the auto-merge made reachable with no user action at all:
    /// an auto-matcher naming two clusters after one profile.
    func test_auto_naming_two_clusters_after_one_profile_keeps_them_separate() {
        let w = makeWorld(segments: [segment("SPEAKER_00", 0, "one"),
                                     segment("SPEAKER_01", 2, "two")])

        // What `OfflineVoiceEmbedder.matchAfterPass` does when both clusters
        // clear the similarity threshold against the same stored profile.
        for raw in ["SPEAKER_00", "SPEAKER_01"] {
            w.store.setSpeakerName("Alice", forSpeaker: raw, recordingID: w.recordingID)
        }

        XCTAssertEqual(speakers(w), ["SPEAKER_00", "SPEAKER_01"],
                       "a recogniser must never destroy the transcript's speaker structure")
    }

    // MARK: - Merge

    func test_merging_moves_every_segment_and_clears_the_source_name() {
        let w = makeWorld(segments: [segment("SPEAKER_00", 0, "one"),
                                     segment("SPEAKER_01", 2, "two"),
                                     segment("SPEAKER_01", 4, "three")],
                          speakerNames: ["SPEAKER_00": "Alice", "SPEAKER_01": "Bob"])

        w.store.mergeSpeakers(from: "SPEAKER_01", into: "SPEAKER_00", recordingID: w.recordingID)

        XCTAssertEqual(speakers(w), ["SPEAKER_00", "SPEAKER_00", "SPEAKER_00"])
        XCTAssertNil(row(w).speakerNames["SPEAKER_01"], "the source id is gone, so its name goes")
        XCTAssertEqual(row(w).speakerNames["SPEAKER_00"], "Alice")
    }

    /// The observation the source contributed does not vanish: the user has
    /// said it belongs to the target person, so it moves. Landing only the
    /// subtraction — which is what the auto-merge did — left Bob's profile
    /// poorer and Alice's no richer.
    func test_merging_moves_the_observation_from_the_old_profile_to_the_new() throws {
        let bobVoice: [Float] = [0, 1, 0, 0]
        let w = makeWorld(segments: [segment("SPEAKER_00", 0, "one"),
                                     segment("SPEAKER_01", 2, "two")],
                          speakerNames: ["SPEAKER_00": "Alice", "SPEAKER_01": "Bob"],
                          snapshotEntries: [("SPEAKER_01", bobVoice, 1)])
        // Both profiles as they would stand after each speaker was named.
        w.profiles.updateProfile(name: "Alice", embedding: [1, 0, 0, 0], sampleCount: 4)
        w.profiles.updateProfile(name: "Bob", embedding: bobVoice, sampleCount: 3)

        w.store.mergeSpeakers(from: "SPEAKER_01", into: "SPEAKER_00", recordingID: w.recordingID)

        let bob = try XCTUnwrap(w.profiles.profile(named: "Bob"))
        XCTAssertEqual(bob.sampleCount, 2, "Bob loses the observation that was not his")
        let alice = try XCTUnwrap(w.profiles.profile(named: "Alice"))
        XCTAssertEqual(alice.sampleCount, 5, "…and Alice gains it")
    }

    /// The degenerate case the old auto-merge always hit: same name on both
    /// sides. Subtract-then-add would delete a low-sample profile and
    /// recreate it, losing its identity and its history for no benefit.
    func test_merging_two_speakers_with_the_same_name_leaves_the_profile_alone() throws {
        let voice: [Float] = [0, 1, 0, 0]
        let w = makeWorld(segments: [segment("SPEAKER_00", 0, "one"),
                                     segment("SPEAKER_01", 2, "two")],
                          speakerNames: ["SPEAKER_00": "Alice", "SPEAKER_01": "Alice"],
                          snapshotEntries: [("SPEAKER_01", voice, 1)])
        w.profiles.updateProfile(name: "Alice", embedding: voice, sampleCount: 1)
        let before = try XCTUnwrap(w.profiles.profile(named: "Alice"))

        w.store.mergeSpeakers(from: "SPEAKER_01", into: "SPEAKER_00", recordingID: w.recordingID)

        let after = try XCTUnwrap(w.profiles.profile(named: "Alice"))
        XCTAssertEqual(after.id, before.id, "the profile must not be deleted and recreated")
        XCTAssertEqual(after.sampleCount, 1)
        XCTAssertEqual(speakers(w), ["SPEAKER_00", "SPEAKER_00"], "the segments still merge")
    }

    /// An unnamed source still retires its id, so a later split cannot be
    /// handed a number whose embedding is somebody else's. Its observation
    /// moves onto the target rather than being dropped — the audio is the
    /// target's now.
    func test_merging_retires_the_source_ids_observation() {
        let w = makeWorld(segments: [segment("SPEAKER_00", 0, "one"),
                                     segment("SPEAKER_01", 2, "two")],
                          snapshotEntries: [("SPEAKER_00", [1, 0], 1),
                                            ("SPEAKER_01", [0, 1], 1)])

        w.store.mergeSpeakers(from: "SPEAKER_01", into: "SPEAKER_00", recordingID: w.recordingID)

        XCTAssertNil(w.snapshots.observation(forSpeaker: "SPEAKER_01", in: w.recordingID),
                     "the retired id must not keep an embedding a reused number could find")
        XCTAssertEqual(w.snapshots.observation(forSpeaker: "SPEAKER_00", in: w.recordingID)?
                        .observedCount, 2,
                       "the target's observation accounts for both speakers now")
    }

    /// **The invariant, end to end: what a merge adds to a profile, an
    /// un-name takes back.**
    ///
    /// This is the one that catches the whole family of bugs where the
    /// snapshot ledger and the profile store drift apart. `mergeSpeakers`
    /// moves the source's contribution onto the target's profile; if the
    /// target's *snapshot* is not extended to match, un-naming the target
    /// subtracts only its original sample and leaves the absorbed voice in
    /// the profile with no way to reach it.
    func test_a_merge_then_un_naming_the_target_leaves_no_residue() throws {
        let aliceVoice: [Float] = [1, 0, 0, 0]
        let bobVoice: [Float] = [0, 1, 0, 0]
        let w = makeWorld(segments: [segment("SPEAKER_00", 0, "one"),
                                     segment("SPEAKER_01", 2, "two")],
                          snapshotEntries: [("SPEAKER_00", aliceVoice, 1),
                                            ("SPEAKER_01", bobVoice, 1)])
        // Both speakers named, so both observations are in Alice's profile
        // the way the app would have put them there.
        w.store.setSpeakerName("Alice", forSpeaker: "SPEAKER_00", recordingID: w.recordingID)
        w.store.setSpeakerName("Bob", forSpeaker: "SPEAKER_01", recordingID: w.recordingID)
        XCTAssertEqual(w.profiles.profile(named: "Alice")?.sampleCount, 1)
        XCTAssertEqual(w.profiles.profile(named: "Bob")?.sampleCount, 1)

        // The diarizer split one person in two; the user merges them.
        w.store.mergeSpeakers(from: "SPEAKER_01", into: "SPEAKER_00", recordingID: w.recordingID)
        XCTAssertNil(w.profiles.profile(named: "Bob"),
                     "Bob's only observation was not his — his profile goes with it")
        XCTAssertEqual(w.profiles.profile(named: "Alice")?.sampleCount, 2,
                       "Alice absorbed it")

        // …and now the user decides Alice was wrong too.
        w.store.setSpeakerName(nil, forSpeaker: "SPEAKER_00", recordingID: w.recordingID)

        XCTAssertNil(w.profiles.profile(named: "Alice"),
                     "both observations came back out; nothing of this recording is left behind")
    }

    func test_merging_a_speaker_into_itself_is_a_no_op() {
        let w = makeWorld(segments: [segment("SPEAKER_00", 0, "one")],
                          speakerNames: ["SPEAKER_00": "Alice"])

        w.store.mergeSpeakers(from: "SPEAKER_00", into: "SPEAKER_00", recordingID: w.recordingID)

        XCTAssertEqual(row(w).speakerNames["SPEAKER_00"], "Alice")
        XCTAssertEqual(speakers(w), ["SPEAKER_00"])
    }

    /// The same round trip across the **offline re-diarize**, pinning the one
    /// place this PR deliberately does NOT come out clean.
    ///
    /// A collapse carries only the dominant fragment's observation, so
    /// un-naming reverses that fragment exactly and leaves the other
    /// fragments' contributions in the profile as residue. That is chosen
    /// over folding them all in, because `finish` names only *some* fragments
    /// — a fold then claims more than the profile ever received, and
    /// un-naming subtracts the difference out of the profile's OTHER
    /// recordings, deleting it outright when its stored count is small.
    /// Residue can be undone by deleting the profile and letting it re-learn;
    /// a deleted profile cannot. See `ObservedVoiceSnapshots.remapSpeakerIDs`
    /// and island-io/mila#254.
    ///
    /// Discriminating in both directions: folding deletes Alice, carrying
    /// nothing leaves her at 2.
    func test_a_collapsed_speaker_leaves_residue_rather_than_over_subtracting() throws {
        let voice: [Float] = [1, 0, 0, 0]
        let w = makeWorld(segments: [segment("SPEAKER_00", 0, "one"),
                                     segment("SPEAKER_03", 2, "two")],
                          snapshotEntries: [("SPEAKER_00", voice, 1),
                                            ("SPEAKER_03", voice, 1)])
        // Both fragments named, so the profile received both.
        for raw in ["SPEAKER_00", "SPEAKER_03"] {
            w.store.setSpeakerName("Alice", forSpeaker: raw, recordingID: w.recordingID)
        }
        XCTAssertEqual(w.profiles.profile(named: "Alice")?.sampleCount, 2,
                       "precondition: two fragments, two contributions")

        // What `finalizeTail` does when the offline pass collapses them into
        // one speaker: swap the segments, remap the names, and carry the
        // observations on the same new-to-old mapping the names used.
        var rediarized = row(w)
        rediarized.segments = rediarized.segments.map {
            var seg = $0
            seg.speaker = "SPEAKER_00"
            return seg
        }
        rediarized.speakerNames = ["SPEAKER_00": "Alice"]
        w.store.update(rediarized)
        w.snapshots.remapSpeakerIDs(["SPEAKER_00": "SPEAKER_00"], in: w.recordingID)

        w.store.setSpeakerName(nil, forSpeaker: "SPEAKER_00", recordingID: w.recordingID)

        let alice = try XCTUnwrap(
            w.profiles.profile(named: "Alice"),
            "Alice must survive — folding both fragments into the snapshot would "
            + "subtract 2 from 2 and delete her, which is the failure this shape avoids")
        XCTAssertEqual(alice.sampleCount, 1,
                       "the dominant fragment came back out exactly; the other is residue")
    }

    // MARK: - Move one line

    func test_reassigning_moves_only_the_named_segment() {
        let segs = [segment("SPEAKER_00", 0, "one"),
                    segment("SPEAKER_01", 2, "two"),
                    segment("SPEAKER_01", 4, "three")]
        let w = makeWorld(segments: segs, speakerNames: ["SPEAKER_01": "Bob"])

        w.store.reassignSegmentSpeaker(segmentID: segs[1].id, toSpeaker: "SPEAKER_00",
                                       recordingID: w.recordingID)

        XCTAssertEqual(speakers(w), ["SPEAKER_00", "SPEAKER_00", "SPEAKER_01"])
        XCTAssertEqual(row(w).speakerNames["SPEAKER_01"], "Bob",
                       "SPEAKER_01 still has a line, so it keeps its name")
    }

    /// Moving a speaker's *last* line empties them out of the recording. The
    /// id is retired: name and observation both go, and the profile is
    /// corrected for an observation that turned out not to be theirs.
    func test_reassigning_the_last_segment_retires_the_emptied_speaker() throws {
        let bobVoice: [Float] = [0, 1, 0, 0]
        let segs = [segment("SPEAKER_00", 0, "one"), segment("SPEAKER_01", 2, "two")]
        let w = makeWorld(segments: segs,
                          speakerNames: ["SPEAKER_01": "Bob"],
                          snapshotEntries: [("SPEAKER_01", bobVoice, 1)])
        w.profiles.updateProfile(name: "Bob", embedding: bobVoice, sampleCount: 3)

        w.store.reassignSegmentSpeaker(segmentID: segs[1].id, toSpeaker: "SPEAKER_00",
                                       recordingID: w.recordingID)

        XCTAssertEqual(speakers(w), ["SPEAKER_00", "SPEAKER_00"])
        XCTAssertNil(row(w).speakerNames["SPEAKER_01"])
        XCTAssertNil(w.snapshots.observation(forSpeaker: "SPEAKER_01", in: w.recordingID))
        let bob = try XCTUnwrap(w.profiles.profile(named: "Bob"))
        XCTAssertEqual(bob.sampleCount, 2, "the observation is subtracted from Bob")
    }

    func test_reassigning_a_segment_to_its_current_speaker_is_a_no_op() {
        let segs = [segment("SPEAKER_00", 0, "one"), segment("SPEAKER_01", 2, "two")]
        let w = makeWorld(segments: segs, speakerNames: ["SPEAKER_00": "Alice"])

        w.store.reassignSegmentSpeaker(segmentID: segs[0].id, toSpeaker: "SPEAKER_00",
                                       recordingID: w.recordingID)

        XCTAssertEqual(speakers(w), ["SPEAKER_00", "SPEAKER_01"])
        XCTAssertEqual(row(w).speakerNames["SPEAKER_00"], "Alice")
    }

    // MARK: - Split

    /// The stranded-name bug. `used` was derived from the segments alone, so
    /// a name whose segments had all moved away left its `SPEAKER_NN` looking
    /// free — and the next split rendered an unrelated line under that name,
    /// in the transcript and in the regenerated `.srt`.
    func test_splitting_never_reuses_an_id_that_still_has_a_name() {
        let segs = [segment("SPEAKER_00", 0, "one"),
                    segment("SPEAKER_00", 2, "two"),
                    segment("SPEAKER_01", 4, "three")]
        let w = makeWorld(segments: segs, speakerNames: ["SPEAKER_01": "Bob"])

        // Bob's only line moves to SPEAKER_00, so SPEAKER_00 now owns
        // everything and `speakerNames` no longer mentions SPEAKER_01 either
        // — put the name back the way a rename-after-the-fact would.
        w.store.reassignSegmentSpeaker(segmentID: segs[2].id, toSpeaker: "SPEAKER_00",
                                       recordingID: w.recordingID)
        w.store.setSpeakerName("Bob", forSpeaker: "SPEAKER_01", recordingID: w.recordingID)
        XCTAssertEqual(row(w).speakerNames["SPEAKER_01"], "Bob",
                       "precondition: a name with no segments behind it")

        w.store.splitSegmentSpeaker(segmentID: segs[0].id, recordingID: w.recordingID)

        let minted = row(w).segments.first { $0.id == segs[0].id }?.speaker
        XCTAssertNotEqual(minted, "SPEAKER_01",
                          "the split must not be handed a number that still renders as Bob")
        XCTAssertEqual(minted, "SPEAKER_02")
    }

    func test_splitting_a_speakers_only_line_is_a_no_op() {
        let segs = [segment("SPEAKER_00", 0, "one"), segment("SPEAKER_01", 2, "two")]
        let w = makeWorld(segments: segs, speakerNames: ["SPEAKER_01": "Bob"])

        w.store.splitSegmentSpeaker(segmentID: segs[1].id, recordingID: w.recordingID)

        XCTAssertEqual(speakers(w), ["SPEAKER_00", "SPEAKER_01"],
                       "renaming the id would strand SPEAKER_01's name for nothing")
        XCTAssertEqual(row(w).speakerNames["SPEAKER_01"], "Bob")
    }

    func test_splitting_moves_only_that_line_to_a_fresh_id() {
        let segs = [segment("SPEAKER_00", 0, "one"),
                    segment("SPEAKER_00", 2, "two"),
                    segment("SPEAKER_00", 4, "three")]
        let w = makeWorld(segments: segs)

        w.store.splitSegmentSpeaker(segmentID: segs[1].id, recordingID: w.recordingID)

        XCTAssertEqual(speakers(w), ["SPEAKER_00", "SPEAKER_01", "SPEAKER_00"])
    }

    func test_splitting_a_segment_with_no_speaker_is_a_no_op() {
        let segs = [segment(nil, 0, "dictation"), segment(nil, 2, "more")]
        let w = makeWorld(segments: segs)

        w.store.splitSegmentSpeaker(segmentID: segs[0].id, recordingID: w.recordingID)

        XCTAssertEqual(speakers(w), [nil, nil])
    }
}
