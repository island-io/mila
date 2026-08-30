import XCTest
@testable import Mila

/// **Invariant: the recording that finished is the one that gets snapshotted
/// and named — identified by the id it was handed, never inferred from the
/// store's ordering.**
///
/// The previous shape ran off `.onChange(of: actions.isRecording)`, which
/// carries no id, and recovered one with `store.recordings.first`. Two
/// separate reasons that is unsound:
///
///   * `RecordingStore.add` does `recordings.insert(_, at: 0)` and does
///     **not** re-sort, so *any* recording added afterwards becomes `first`.
///     The Voice Memos importer calls `add` from its own async flow, so a
///     memo landing between the meeting's `add` and SwiftUI delivering the
///     `.onChange` made the memo "the recording that just stopped".
///   * `load()` and `recoverOrphanRecordings()` sort by `createdAt`
///     descending, and imported memos carry their own dates — so ordering is
///     no proxy for recency of *finishing* either.
///
/// Getting the id wrong degrades safely, and that is deliberate: an unknown
/// recording has no snapshot, so the profile silently fails to learn rather
/// than merging a stranger's voice. `test_a_wrong_id_fails_closed` pins that
/// property so a future change can't quietly trade it away.
///
/// These tests drive the real `RecognisedSpeakerAssigner`, real
/// `LiveSpeakerDiarizer`, real `ObservedVoiceSnapshots`, real
/// `RecordingStore` and real `SpeakerProfileStore` — extracting the assigner
/// out of `MilaApp` is what makes the gate reachable at all.
@MainActor
final class RecognisedSpeakerAssignerTests: XCTestCase {

    private var tempRoot: URL!
    private var suiteNames: [String] = []

    private let aliceStored: [Float] = [1, 0, 0, 0]
    private let aliceSpeaking: [Float] = [0.99, 0.01, 0, 0]

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "RecognisedSpeakerAssignerTests")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        suiteNames.removeAll()
        try await super.tearDown()
    }

    // MARK: - Fixture

    private func makeSettings(enabled: Bool = true) -> VoiceRecognitionSettings {
        let name = "RecognisedSpeakerAssignerTests.\(UUID())"
        suiteNames.append(name)
        let s = VoiceRecognitionSettings(defaults: UserDefaults(suiteName: name)!)
        s.diarizationReady = { true }
        s.isEnabled = enabled
        return s
    }

    private struct World {
        let store: RecordingStore
        let profiles: SpeakerProfileStore
        let snapshots: ObservedVoiceSnapshots
        let diarizer: LiveSpeakerDiarizer
        let assigner: RecognisedSpeakerAssigner
        let settings: VoiceRecognitionSettings
    }

    /// Alice on disk and a seeded pool — everything the assigner needs.
    /// Deliberately creates no `Recording`: each test controls store contents.
    ///
    /// `deletionObserver` and `storedProfileGate` are the two locks that stop
    /// a mid-recording deletion being undone at stop. Both default to on —
    /// the shipping wiring — and the deletion tests below switch them off
    /// individually to show each one works alone, and off together to
    /// reconstruct the pre-fix shape as a negative control.
    private func makeWorld(enabled: Bool = true,
                           deletionObserver: Bool = true,
                           storedProfileGate: Bool = true) -> World {
        let settings = makeSettings(enabled: enabled)
        let profiles = SpeakerProfileStore(directory: tempRoot, settings: settings)
        profiles.updateProfile(name: "Alice", embedding: aliceStored, sampleCount: 40)

        let store = RecordingStore(rootDirectory: tempRoot)
        let snapshots = ObservedVoiceSnapshots()

        // Same wiring MilaApp.init installs.
        store.onSpeakerNamed = { recordingID, rawID, name in
            guard settings.isConfigured else { return }
            guard let observed = snapshots.observation(forSpeaker: rawID,
                                                      in: recordingID) else { return }
            profiles.updateProfile(name: name,
                                   embedding: observed.observedCentroid,
                                   sampleCount: observed.observedCount)
        }

        let diarizer = LiveSpeakerDiarizer()
        diarizer.similarityThreshold = 0.7
        // Same wiring MilaApp.init installs: a deletion has to reach the
        // pool of a recording that is already running.
        if deletionObserver {
            profiles.addDeletionObserver { [weak diarizer] deletion in
                switch deletion {
                case .all: diarizer?.forgetSeededProfiles()
                case .named(let names): diarizer?.forgetSeededProfiles(named: names)
                }
            }
        }
        diarizer.reset()
        diarizer.seedPool(with: profiles.seedEntries())

        let assigner = RecognisedSpeakerAssigner(
            store: store,
            diarizer: diarizer,
            snapshots: snapshots,
            settings: settings,
            // The `false` branch is the pre-gate shape, not a shortcut: the
            // tests that pass `storedProfileGate: false` need exactly it.
            profileStillStored: { name in
                storedProfileGate ? profiles.profileExists(name: name) : true
            })
        return World(store: store, profiles: profiles, snapshots: snapshots,
                     diarizer: diarizer, assigner: assigner, settings: settings)
    }

    /// Where `SpeakerProfileStore` keeps its file, so the tests can assert
    /// that a deleted one is not silently recreated.
    private var profilesFile: URL { tempRoot.appendingPathComponent("speaker-profiles.json") }

    private var profilesFileExists: Bool {
        FileManager.default.fileExists(atPath: profilesFile.path)
    }

    /// Alice speaks once, confidently.
    private func aliceSpeaksConfidently(_ w: World) {
        XCTAssertEqual(w.diarizer.assign(embedding: aliceSpeaking), "SPEAKER_00")
    }

    @discardableResult
    private func add(_ title: String,
                     createdAt: Date,
                     source: RecordingSource = .microphone,
                     to store: RecordingStore) -> Recording {
        let rec = Recording(title: title, createdAt: createdAt, source: source,
                            audioFileName: "\(title).wav")
        store.add(rec)
        return rec
    }

    private func alice(_ w: World) -> VoiceProfile? { w.profiles.profile(named: "Alice") }

    private func recording(_ id: UUID, in store: RecordingStore) -> Recording? {
        store.recordings.first { $0.id == id }
    }

    // MARK: - The invariant: the id is carried, not inferred

    /// A recording that is newer in the store — and `first` in it — must not
    /// steal the snapshot from the recording that actually finished.
    func test_a_newer_recording_in_the_store_does_not_steal_the_snapshot() {
        let w = makeWorld()
        aliceSpeaksConfidently(w)

        // The meeting finishes and is saved...
        let meeting = add("Meeting", createdAt: Date(), to: w.store)
        // ...then a Voice Memos import lands, carrying its own (newer) date.
        // `add` inserts at index 0 regardless, so it is now `first` on both
        // counts — insertion order *and* createdAt.
        let memo = add("Memo", createdAt: Date().addingTimeInterval(60),
                       source: .voiceMemo, to: w.store)
        XCTAssertEqual(w.store.recordings.first?.id, memo.id,
                       "precondition: the memo is what `recordings.first` would hand back")

        w.assigner.finish(recording: meeting.id)

        // Snapshot went to the meeting, not the memo.
        XCTAssertNotNil(w.snapshots.observation(forSpeaker: "SPEAKER_00", in: meeting.id))
        XCTAssertNil(w.snapshots.observation(forSpeaker: "SPEAKER_00", in: memo.id))
        // The name landed on the meeting, not the memo.
        XCTAssertEqual(recording(meeting.id, in: w.store)?.speakerNames["SPEAKER_00"], "Alice")
        XCTAssertNil(recording(memo.id, in: w.store)?.speakerNames["SPEAKER_00"])
        // And Alice learned exactly one sample from it.
        XCTAssertEqual(alice(w)?.sampleCount, 41)
    }

    /// Negative control: the `store.recordings.first` shape the old code used
    /// picks the memo, so the assertions above are discriminating. Also shows
    /// the consequence — snapshotting against the inferred id leaves the
    /// meeting with no snapshot at all.
    func test_the_recordings_first_shape_would_pick_the_wrong_recording() {
        let w = makeWorld()
        aliceSpeaksConfidently(w)

        let meeting = add("Meeting", createdAt: Date(), to: w.store)
        let memo = add("Memo", createdAt: Date().addingTimeInterval(60),
                       source: .voiceMemo, to: w.store)

        // The removed inference. Bound rather than force-unwrapped below:
        // `XCTAssertEqual` records a failure and carries on, so a nil here
        // would crash the runner on the next line and bury which of the two
        // fixture preconditions actually broke.
        guard let inferred = w.store.recordings.first?.id else {
            XCTFail("precondition: the store must have a recording to infer from")
            return
        }
        XCTAssertEqual(inferred, memo.id)
        XCTAssertNotEqual(inferred, meeting.id,
                          "inferring from store order picks the memo, not the meeting")

        // Its consequence: the meeting never gets a snapshot, so naming it
        // later learns nothing.
        w.snapshots.record(w.diarizer.currentProfiles(), for: inferred)
        XCTAssertNil(w.snapshots.observation(forSpeaker: "SPEAKER_00", in: meeting.id))
        w.store.setSpeakerName("Alice", forSpeaker: "SPEAKER_00", recordingID: meeting.id)
        XCTAssertEqual(alice(w)?.sampleCount, 40,
                       "learned nothing — the inference cost the update")
    }

    /// `add` inserting at index 0 with no re-sort is the mechanism, so pin it
    /// directly: an *older* recording added later is still `first`. Ordering
    /// cannot stand in for "finished most recently".
    func test_store_ordering_is_not_a_proxy_for_which_recording_finished() {
        let w = makeWorld()
        let newer = add("Newer", createdAt: Date(), to: w.store)
        let older = add("Older", createdAt: Date().addingTimeInterval(-3600), to: w.store)

        XCTAssertEqual(w.store.recordings.first?.id, older.id,
                       "add() inserts at index 0 and does not re-sort")
        XCTAssertNotEqual(w.store.recordings.first?.id, newer.id)
    }

    /// Being handed an id for a recording that isn't in the store snapshots
    /// against that id (harmless) and writes no voice data — the fail-closed
    /// property that makes a wrong id survivable. Worth pinning: a future
    /// "fall back to the newest recording" would silently undo it.
    func test_a_wrong_id_fails_closed() {
        let w = makeWorld()
        aliceSpeaksConfidently(w)
        let meeting = add("Meeting", createdAt: Date(), to: w.store)

        w.assigner.finish(recording: UUID())

        // Nothing was named on the real recording...
        XCTAssertNil(recording(meeting.id, in: w.store)?.speakerNames["SPEAKER_00"])
        // ...and no voice data was written for anybody.
        XCTAssertEqual(alice(w)?.sampleCount, 40, "no merge")
        // Naming the real recording afterwards also learns nothing, because
        // its snapshot went to the stray id. Silently not learning is the
        // acceptable failure; merging the wrong voice would not be.
        w.store.setSpeakerName("Alice", forSpeaker: "SPEAKER_00", recordingID: meeting.id)
        XCTAssertEqual(alice(w)?.sampleCount, 40)
    }

    // MARK: - The happy path still works

    func test_the_finished_recording_is_named_and_learns_one_sample() {
        let w = makeWorld()
        aliceSpeaksConfidently(w)
        let meeting = add("Meeting", createdAt: Date(), to: w.store)

        w.assigner.finish(recording: meeting.id)

        XCTAssertEqual(recording(meeting.id, in: w.store)?.speakerNames["SPEAKER_00"], "Alice")
        XCTAssertEqual(alice(w)?.sampleCount, 41)
        XCTAssertGreaterThan(cosineSimilarity(alice(w)?.embedding ?? [], aliceStored), 0.99)
    }

    /// Re-running for the same recording changes nothing: the name already
    /// matches, so `setSpeakerName` returns without firing the hook.
    func test_running_twice_for_the_same_recording_is_idempotent() {
        let w = makeWorld()
        aliceSpeaksConfidently(w)
        let meeting = add("Meeting", createdAt: Date(), to: w.store)

        w.assigner.finish(recording: meeting.id)
        w.assigner.finish(recording: meeting.id)
        w.assigner.finish(recording: meeting.id)

        XCTAssertEqual(alice(w)?.sampleCount, 41, "one recognition, one merge")
    }

    // MARK: - The opt-in gate still holds at this layer

    /// While off: no naming, and — the point of gating here rather than only
    /// inside the store — no snapshot either, so an opted-out user has no
    /// embeddings held in memory.
    func test_while_off_nothing_is_named_and_nothing_is_snapshotted() {
        let w = makeWorld(enabled: false)
        // Seeding was refused too (`seedEntries` returns nothing while off),
        // so this speaks into an unseeded pool.
        _ = w.diarizer.assign(embedding: aliceSpeaking)
        let meeting = add("Meeting", createdAt: Date(), to: w.store)

        w.assigner.finish(recording: meeting.id)

        XCTAssertEqual(w.snapshots.heldRecordingCount, 0, "no embeddings held while off")
        XCTAssertNil(recording(meeting.id, in: w.store)?.speakerNames["SPEAKER_00"])
    }

    // MARK: - Deleting voice profiles while a recording is in flight

    /// **The privacy invariant: deleting voice profiles during a recording
    /// must not be undone when that recording stops.**
    ///
    /// The pool was seeded from the profiles at record-start and holds its
    /// own copy of every centroid, so deleting the file and the in-memory
    /// list leaves the deletion two thirds done. Left alone, `finish` names
    /// the still-seeded speaker, `setSpeakerName` fires `onSpeakerNamed`, and
    /// `updateProfile` — which *creates* when the name is absent, because
    /// that is how hand-naming makes a profile — writes the deleted person
    /// straight back, recreating `speaker-profiles.json` in the process. See
    /// `test_without_either_lock_the_profile_comes_straight_back` for the
    /// measured before-state: the user is told their voice data is gone
    /// while it quietly returns.
    func test_deleting_profiles_mid_recording_does_not_bring_them_back() {
        let w = makeWorld()
        aliceSpeaksConfidently(w)
        let meeting = add("Meeting", createdAt: Date(), to: w.store)

        // Mid-recording: Settings ▸ Delete Voice Profiles.
        w.profiles.deleteAllProfiles()
        XCTAssertFalse(profilesFileExists, "precondition: the file is gone")

        // ...and now the recording stops.
        w.assigner.finish(recording: meeting.id)

        XCTAssertTrue(w.profiles.profiles.isEmpty, "nothing may be back in memory")
        XCTAssertNil(alice(w))
        XCTAssertFalse(profilesFileExists, "speaker-profiles.json must not be recreated")
        XCTAssertFalse(w.profiles.hasStoredProfilesOnDisk,
                       "and Settings must not start offering to delete it again")
        XCTAssertNil(recording(meeting.id, in: w.store)?.speakerNames["SPEAKER_00"],
                     "the deleted name must not be stamped on the transcript either")
    }

    /// Negative control — the pre-fix wiring, reconstructed from the same
    /// real objects: no deletion observer, and the assigner's stored-profile
    /// gate answering `true` unconditionally. It proves the assertions above
    /// discriminate, and records exactly what the resurrection looked like.
    ///
    /// Note *what* comes back. Not the profile that was deleted: a fresh
    /// `id`, a fresh `createdAt`, and `sampleCount` counting only this
    /// recording. But the name returns, the file returns, and the embedding —
    /// this recording's own centroid for the same person — sits at better
    /// than 0.999 cosine to the deleted one, so it recognises them just as
    /// well in every future recording. Partial by the numbers, complete in
    /// effect.
    func test_without_either_lock_the_profile_comes_straight_back() {
        let w = makeWorld(deletionObserver: false, storedProfileGate: false)
        aliceSpeaksConfidently(w)
        let meeting = add("Meeting", createdAt: Date(), to: w.store)
        let originalID = alice(w)?.id

        w.profiles.deleteAllProfiles()
        XCTAssertFalse(profilesFileExists, "precondition: the file is gone")

        w.assigner.finish(recording: meeting.id)

        guard let back = alice(w) else {
            return XCTFail("precondition for the tests above: unguarded, Alice returns")
        }
        XCTAssertNotEqual(back.id, originalID, "a new profile, not the deleted one")
        XCTAssertEqual(back.sampleCount, 1, "carrying only this recording's observation")
        XCTAssertGreaterThan(cosineSimilarity(back.embedding, aliceStored), 0.99,
                             "but the same voice, to within rounding")
        XCTAssertTrue(profilesFileExists, "and the deleted file is recreated")
    }

    /// Lock 1 alone — the store's deletion observer strips the seeded name
    /// out of the live pool, so `finish` has nothing to auto-name.
    func test_the_deletion_observer_alone_prevents_the_resurrection() {
        let w = makeWorld(deletionObserver: true, storedProfileGate: false)
        aliceSpeaksConfidently(w)
        let meeting = add("Meeting", createdAt: Date(), to: w.store)

        w.profiles.deleteAllProfiles()
        XCTAssertNil(w.diarizer.currentProfiles().first?.profileName,
                     "the pool entry stops carrying the deleted name")
        w.assigner.finish(recording: meeting.id)

        XCTAssertNil(alice(w))
        XCTAssertFalse(profilesFileExists)
    }

    /// Lock 2 alone — `finish` refuses to auto-apply the name of a profile
    /// that is no longer stored, even with the pool still carrying it. This
    /// is the lock that does not depend on a caller having wired the
    /// observer up.
    func test_the_stored_profile_gate_alone_prevents_the_resurrection() {
        let w = makeWorld(deletionObserver: false, storedProfileGate: true)
        aliceSpeaksConfidently(w)
        let meeting = add("Meeting", createdAt: Date(), to: w.store)

        w.profiles.deleteAllProfiles()
        XCTAssertEqual(w.diarizer.currentProfiles().first?.profileName, "Alice",
                       "precondition: with no observer the pool still carries it")
        w.assigner.finish(recording: meeting.id)

        XCTAssertNil(alice(w))
        XCTAssertFalse(profilesFileExists)
        XCTAssertNil(recording(meeting.id, in: w.store)?.speakerNames["SPEAKER_00"])
    }

    /// Deletion must stop *recognition* too, not merely persistence: a
    /// speaker whose profile the user has just erased is not recognised for
    /// the rest of the recording. The neutralised entry stays in the pool
    /// (ids are positional — removing it would collide the next mint), so
    /// the new speaker is `SPEAKER_01`, nameless.
    func test_after_deletion_the_erased_voice_is_no_longer_recognised() {
        let w = makeWorld()
        // Alice has not spoken yet, so the seeded entry holds nothing but
        // the profile that is about to be deleted.
        w.profiles.deleteAllProfiles()

        XCTAssertEqual(w.diarizer.assign(embedding: aliceSpeaking), "SPEAKER_01",
                       "a fresh speaker — the erased centroid must not match her")
        let entries = w.diarizer.currentProfiles()
        XCTAssertEqual(entries.count, 2, "the emptied entry stays, so ids cannot collide")
        XCTAssertTrue(entries.allSatisfy { $0.profileName == nil })
    }

    /// Deleting one profile by name reaches the pool the same way, and
    /// leaves the others seeded. (Only Alice is stored in this fixture; the
    /// selective half is pinned in `LiveSpeakerDiarizerPoolTests`.)
    func test_deleting_a_single_profile_mid_recording_also_reaches_the_pool() {
        let w = makeWorld()
        aliceSpeaksConfidently(w)
        let meeting = add("Meeting", createdAt: Date(), to: w.store)

        w.profiles.deleteProfile(name: "Alice")
        w.assigner.finish(recording: meeting.id)

        XCTAssertNil(alice(w), "one deleted profile must not come back either")
        XCTAssertNil(recording(meeting.id, in: w.store)?.speakerNames["SPEAKER_00"])
    }

    /// The same hole through a different door: a profile can also stop
    /// existing under its seeded name because the user *renamed* it
    /// mid-recording. Rename does not notify the pool, so this is lock 2's
    /// work alone — and it is why the gate is worth having as well as the
    /// observer. Not auto-naming is the conservative outcome: the recording
    /// is left unlabelled rather than labelled with a name that is no longer
    /// anybody's, and above all the old name is not recreated on disk.
    func test_a_renamed_profile_is_not_recreated_under_its_old_name() {
        let w = makeWorld()
        aliceSpeaksConfidently(w)
        let meeting = add("Meeting", createdAt: Date(), to: w.store)

        w.profiles.renameProfile(from: "Alice", to: "Alice Smith")
        w.assigner.finish(recording: meeting.id)

        XCTAssertNil(alice(w), "the old name must not reappear as a second profile")
        XCTAssertEqual(w.profiles.profiles.count, 1)
        XCTAssertEqual(w.profiles.profiles.first?.name, "Alice Smith")
        XCTAssertEqual(w.profiles.profiles.first?.sampleCount, 40, "and it learned nothing")
        XCTAssertNil(recording(meeting.id, in: w.store)?.speakerNames["SPEAKER_00"])
    }

    /// A borderline-only speaker is not auto-named — now asserted against the
    /// real assigner rather than a replica of its loop.
    func test_a_borderline_only_speaker_is_not_auto_named() {
        let w = makeWorld()
        // cos([0.6, 0.8, 0, 0], [1, 0, 0, 0]) == 0.6: above the 0.55 create
        // floor so it attaches to Alice's seeded entry, below the 0.7 match
        // threshold so it is never folded in.
        XCTAssertEqual(w.diarizer.assign(embedding: [0.6, 0.8, 0, 0]), "SPEAKER_00")
        XCTAssertEqual(w.diarizer.currentProfiles().first?.observedCount, 0)
        let meeting = add("Meeting", createdAt: Date(), to: w.store)

        w.assigner.finish(recording: meeting.id)

        XCTAssertNil(recording(meeting.id, in: w.store)?.speakerNames["SPEAKER_00"],
                     "attached but never confidently matched — must not be named")
        XCTAssertEqual(alice(w)?.sampleCount, 40, "and nothing learned")
    }
}
