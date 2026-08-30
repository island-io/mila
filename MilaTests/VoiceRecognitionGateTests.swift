import XCTest
@testable import Mila

/// Tests for the **opt-in gate** on cross-recording voice recognition —
/// separate from `SpeakerProfileStoreTests`, which covers the storage
/// mechanics with the feature already on.
///
/// The thing under test here is the off state, because that's the state a
/// user who never opts in lives in forever, and it's the one that silently
/// regresses: the feature keeps working, so nothing fails, and voice
/// fingerprints quietly start appearing on disk anyway. The promise is
/// stronger than "stored but unused" — while off, nothing is written,
/// nothing is read back, and the diarizer is seeded with nothing.
@MainActor
final class VoiceRecognitionGateTests: XCTestCase {

    private var tempRoot: URL!
    private var suiteNames: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "VoiceRecognitionGateTests")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        // Never `.standard`: each settings object gets a throwaway suite.
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        suiteNames.removeAll()
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func isolatedDefaults() -> UserDefaults {
        let name = "VoiceRecognitionGateTests.\(UUID())"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    /// `diarizationReady` defaults to true so a test that flips `isEnabled`
    /// is testing *only* the opt-in half of the gate.
    private func makeSettings(diarizationReady: Bool = true,
                              defaults: UserDefaults? = nil) -> VoiceRecognitionSettings {
        let settings = VoiceRecognitionSettings(defaults: defaults ?? isolatedDefaults())
        settings.diarizationReady = { diarizationReady }
        return settings
    }

    private var profilesFile: URL {
        tempRoot.appendingPathComponent("speaker-profiles.json")
    }

    /// Write a profiles file directly, as a previous opt-in would have left
    /// behind, without going through the store.
    private func seedProfilesFileOnDisk() throws {
        let profile = VoiceProfile(id: UUID(),
                                   name: "Alice",
                                   embedding: [1, 0, 0],
                                   sampleCount: 4,
                                   createdAt: Date(),
                                   lastSeenAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([profile]).write(to: profilesFile)
    }

    // MARK: - Default state

    /// The headline requirement: a fresh install has the feature off.
    func test_disabled_by_default_on_a_fresh_install() {
        let settings = makeSettings()
        XCTAssertFalse(settings.isEnabled)
        XCTAssertFalse(settings.isConfigured)
    }

    /// The key is namespaced per the repo convention, and its absence — not
    /// merely a stored `false` — is what yields the off default. Asserted on
    /// the literal so a rename has to be deliberate: the persisted key is
    /// what decides whether an existing user's choice survives an upgrade.
    func test_persisted_key_is_namespaced_and_unset_by_default() {
        let defaults = isolatedDefaults()
        XCTAssertNil(defaults.object(forKey: "speakers.voiceRecognition.enabled"))

        let settings = makeSettings(defaults: defaults)
        XCTAssertFalse(settings.isEnabled)

        settings.isEnabled = true
        XCTAssertEqual(defaults.object(forKey: "speakers.voiceRecognition.enabled") as? Bool, true)
    }

    /// A persisted opt-in survives a relaunch (same suite, new object).
    func test_opt_in_persists_across_relaunch() {
        let defaults = isolatedDefaults()
        makeSettings(defaults: defaults).isEnabled = true

        let relaunched = makeSettings(defaults: defaults)
        XCTAssertTrue(relaunched.isEnabled)
    }

    // MARK: - isConfigured: enabled AND ready, per .claude/rules/feature-gates.md

    func test_isConfigured_requires_both_halves() {
        let onAndReady = makeSettings(diarizationReady: true)
        onAndReady.isEnabled = true
        XCTAssertTrue(onAndReady.isConfigured)

        // Enabled, but the embedding pipeline can't produce anything.
        let onNotReady = makeSettings(diarizationReady: false)
        onNotReady.isEnabled = true
        XCTAssertFalse(onNotReady.isConfigured,
                       "enabled alone must never satisfy isConfigured")

        // Ready, but the user never opted in.
        let offButReady = makeSettings(diarizationReady: true)
        XCTAssertFalse(offButReady.isConfigured)
    }

    /// A forgotten `diarizationReady` injection must fail closed (nothing
    /// stored), not open.
    func test_isConfigured_fails_closed_when_readiness_is_unwired() {
        let settings = VoiceRecognitionSettings(defaults: isolatedDefaults())
        settings.isEnabled = true
        XCTAssertNil(settings.diarizationReady)
        XCTAssertFalse(settings.isConfigured)
    }

    // MARK: - While off: nothing is written

    /// Naming a speaker while off must not persist an embedding — not to
    /// memory, and above all not to disk.
    func test_while_off_updateProfile_writes_nothing() {
        let store = SpeakerProfileStore(directory: tempRoot, settings: makeSettings())

        store.updateProfile(name: "Alice", embedding: [1, 0, 0], sampleCount: 3)

        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: profilesFile.path),
                       "speaker-profiles.json must not exist for a user who never opted in")
    }

    /// The same guarantee via the real call path: `RecordingStore` fires
    /// `onSpeakerNamed` when the user names a speaker, wired here exactly as
    /// `MilaApp` wires it. With the feature off, that hook must not turn a
    /// rename into stored voice data.
    func test_while_off_naming_a_speaker_persists_no_embedding() {
        let settings = makeSettings()
        let profileStore = SpeakerProfileStore(directory: tempRoot, settings: settings)
        let recordings = RecordingStore(rootDirectory: tempRoot)
        let recording = Recording(title: "Standup",
                                  duration: 30,
                                  source: .microphone,
                                  audioFileName: "standup.wav")
        recordings.add(recording)

        // Same shape as MilaApp.init: gate at the call site, then persist.
        recordings.onSpeakerNamed = { _, _, name in
            guard settings.isConfigured else { return }
            profileStore.updateProfile(name: name, embedding: [1, 0, 0], sampleCount: 2)
        }

        recordings.setSpeakerName("Alice", forSpeaker: "SPEAKER_00", recordingID: recording.id)

        // The per-recording label is unaffected — naming speakers keeps
        // working with the feature off, it just doesn't learn voices.
        XCTAssertEqual(recordings.recordings.first?.speakerNames["SPEAKER_00"], "Alice")
        XCTAssertTrue(profileStore.profiles.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: profilesFile.path))
    }

    /// Enabled but diarization not ready is still off as far as storage is
    /// concerned — `isConfigured`, not `isEnabled`, guards the writes.
    func test_enabled_but_diarization_not_ready_writes_nothing() {
        let settings = makeSettings(diarizationReady: false)
        settings.isEnabled = true
        let store = SpeakerProfileStore(directory: tempRoot, settings: settings)

        store.updateProfile(name: "Alice", embedding: [1, 0, 0], sampleCount: 3)

        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: profilesFile.path))
    }

    // MARK: - While off: nothing is read, nothing is seeded

    /// A profiles file left over from an earlier opt-in is not even parsed
    /// while the feature is off, so no embedding reaches memory.
    func test_while_off_an_existing_profiles_file_is_not_loaded() throws {
        try seedProfilesFileOnDisk()

        let store = SpeakerProfileStore(directory: tempRoot, settings: makeSettings())

        XCTAssertTrue(store.profiles.isEmpty, "off must not read voice data back into memory")
        XCTAssertTrue(store.hasStoredProfilesOnDisk,
                      "…but Settings still needs to know the file is there, to offer deletion")
    }

    /// No seeding while off: the diarizer starts every recording from a
    /// blank pool.
    func test_while_off_seedEntries_and_match_return_nothing() throws {
        try seedProfilesFileOnDisk()
        let store = SpeakerProfileStore(directory: tempRoot, settings: makeSettings())

        XCTAssertTrue(store.seedEntries().isEmpty)
        XCTAssertNil(store.match(embedding: [1, 0, 0], threshold: 0.1))
    }

    /// And the diarizer end of that: seeding with nothing leaves the pool
    /// empty, so no pool entry carries a `profileName` and nothing can be
    /// auto-assigned.
    func test_seeding_an_empty_set_leaves_the_diarizer_pool_empty() {
        let diarizer = LiveSpeakerDiarizer()
        diarizer.reset()

        diarizer.seedPool(with: [])

        XCTAssertTrue(diarizer.currentProfiles().isEmpty)
    }

    // MARK: - Enable, then disable

    /// The decision on opting out: stored profiles are **kept on disk** (so
    /// re-enabling picks up where the user left off) but dropped out of
    /// memory immediately, so nothing can be seeded or matched from them.
    func test_disabling_drops_profiles_from_memory_but_keeps_the_file() {
        let settings = makeSettings()
        settings.isEnabled = true
        let store = SpeakerProfileStore(directory: tempRoot, settings: settings)
        store.updateProfile(name: "Alice", embedding: [1, 0, 0], sampleCount: 3)
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profilesFile.path))

        settings.isEnabled = false

        XCTAssertTrue(store.profiles.isEmpty, "opting out must unload the embeddings")
        XCTAssertTrue(store.seedEntries().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profilesFile.path),
                      "opting out is not a delete — the file stays until the user says otherwise")
        XCTAssertTrue(store.hasStoredProfilesOnDisk)
    }

    /// Re-enabling in the same session restores them without a relaunch.
    func test_re_enabling_restores_the_stored_profiles() {
        let settings = makeSettings()
        settings.isEnabled = true
        let store = SpeakerProfileStore(directory: tempRoot, settings: settings)
        store.updateProfile(name: "Alice", embedding: [1, 0, 0], sampleCount: 3)

        settings.isEnabled = false
        XCTAssertTrue(store.profiles.isEmpty)

        settings.isEnabled = true

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles.first?.name, "Alice")
        XCTAssertEqual(store.seedEntries().count, 1)
    }

    /// The trap on the other side of "keep the file": while off, `profiles`
    /// is empty, so any mutation that reaches `save()` would overwrite the
    /// stored file with `[]` and destroy exactly the data we promised to
    /// keep. `save()` refuses while off.
    func test_a_mutation_while_off_cannot_clobber_the_stored_file() throws {
        try seedProfilesFileOnDisk()
        let before = try Data(contentsOf: profilesFile)
        let store = SpeakerProfileStore(directory: tempRoot, settings: makeSettings())

        store.deleteProfile(name: "Alice")
        store.renameProfile(from: "Alice", to: "Alicia")

        XCTAssertEqual(try Data(contentsOf: profilesFile), before,
                       "an off-state mutation must not rewrite speaker-profiles.json")
    }

    // MARK: - Opting out *during* a recording

    /// Alice, as stored on disk.
    private var aliceStored: [Float] { [1, 0, 0, 0] }
    /// Close enough to Alice to be a confident match at threshold 0.7.
    private var aliceSpeaking: [Float] { [0.99, 0.01, 0, 0] }

    /// A recording already under way with Alice's stored profile seeded into
    /// the pool, exactly as `MilaApp` sets one up.
    ///
    /// `poolObserver` is the fix under test. It defaults to on — the
    /// shipping wiring — and the negative control below switches it off to
    /// reconstruct the pre-fix shape, so the assertions are provably
    /// discriminating rather than vacuously true.
    private func startedRecordingWithAliceSeeded(
        poolObserver: Bool = true
    ) -> (settings: VoiceRecognitionSettings,
          profiles: SpeakerProfileStore,
          snapshots: ObservedVoiceSnapshots,
          diarizer: LiveSpeakerDiarizer) {
        let settings = makeSettings()
        settings.isEnabled = true
        let profiles = SpeakerProfileStore(directory: tempRoot, settings: settings)
        profiles.updateProfile(name: "Alice", embedding: aliceStored, sampleCount: 40)

        let diarizer = LiveSpeakerDiarizer()
        diarizer.similarityThreshold = 0.7

        // Same wiring MilaApp.init installs, in the same order.
        let snapshots = ObservedVoiceSnapshots()
        snapshots.clearOnOptOut(of: settings)
        if poolObserver {
            settings.addEnabledObserver { [weak diarizer] nowEnabled in
                guard !nowEnabled else { return }
                diarizer?.forgetSeededProfiles()
            }
        }

        // Record-start: reset, then seed behind the gate.
        diarizer.reset()
        XCTAssertTrue(settings.isConfigured)
        diarizer.seedPool(with: profiles.seedEntries())
        XCTAssertEqual(diarizer.currentProfiles().first?.profileName, "Alice",
                       "precondition: the pool holds a copy of Alice's centroid")
        return (settings, profiles, snapshots, diarizer)
    }

    /// **The invariant.** Opting out mid-recording has to stop the *reads*,
    /// not just the writes.
    ///
    /// `seedPool` gave the diarizer its own copy of every stored centroid at
    /// record-start, so unloading `SpeakerProfileStore.profiles` and
    /// dropping the snapshots — the two things opting out used to do —
    /// leaves `assign` matching against stored voices for the rest of the
    /// recording. The persistence gates mean nothing is written back, but
    /// the user still watches their transcript fill with names produced by a
    /// feature they just switched off. Same shape as deleting a profile
    /// mid-recording, and it gets the same remedy.
    func test_opting_out_mid_recording_stops_the_pool_matching_a_stored_voice() {
        let w = startedRecordingWithAliceSeeded()

        w.settings.isEnabled = false

        // Alice speaks after the opt-out. Her seeded entry was never heard
        // in this recording, so it has nothing of its own to fall back to:
        // it is inert, `assign` skips it, and she is simply somebody new.
        XCTAssertNotEqual(w.diarizer.assign(embedding: aliceSpeaking), "SPEAKER_00",
                          "a stored voice must not be recognised after opting out")
        XCTAssertTrue(w.diarizer.currentProfiles().allSatisfy { $0.profileName == nil },
                      "no pool entry may still carry a stored profile name")
    }

    /// Negative control: the same scenario with the observer unwired, which
    /// is what shipped before this fix. Alice is still recognised, under her
    /// stored name. If this ever starts failing, the test above has stopped
    /// proving anything.
    func test_control_without_the_observer_a_stored_voice_survives_the_opt_out() {
        let w = startedRecordingWithAliceSeeded(poolObserver: false)

        w.settings.isEnabled = false

        XCTAssertEqual(w.diarizer.assign(embedding: aliceSpeaking), "SPEAKER_00",
                       "pre-fix shape: the pool goes on matching the stored centroid")
        XCTAssertEqual(w.diarizer.currentProfiles().first?.profileName, "Alice",
                       "pre-fix shape: and it still knows her name")
    }

    /// The other half of the opt-out, and the reason this neutralises rather
    /// than removes: a speaker who *was* heard before the switch flipped
    /// keeps their id for the rest of the recording, from what this
    /// recording itself observed. Diarization is not what was switched off —
    /// cross-recording recognition is — so the transcript stays coherent
    /// while the stored identity is gone.
    ///
    /// Do not "fix" this into minting a new id: it would fork one person
    /// across two speakers mid-transcript, and it is the name, not the
    /// separation, that opting out revokes.
    func test_opting_out_keeps_an_already_heard_speaker_coherent_but_nameless() {
        let w = startedRecordingWithAliceSeeded()
        XCTAssertEqual(w.diarizer.assign(embedding: aliceSpeaking), "SPEAKER_00",
                       "precondition: Alice matched while the feature was on")

        w.settings.isEnabled = false

        XCTAssertEqual(w.diarizer.assign(embedding: aliceSpeaking), "SPEAKER_00",
                       "in-recording continuity is deliberate")
        XCTAssertNil(w.diarizer.currentProfiles().first?.profileName,
                     "…but the stored name is gone, so nothing can auto-apply it")
        XCTAssertTrue(w.profiles.profiles.isEmpty)
        XCTAssertTrue(w.snapshots.heldRecordingCount == 0)
    }

    /// Ordering: a recording that stops *immediately* after the opt-out.
    ///
    /// `RecognisedSpeakerAssigner.finish` is gated on `isConfigured`, so it
    /// returns before naming anything or taking a snapshot — the opt-out
    /// wins whichever way the two land, and the three opt-out observers are
    /// independent removals from three different holders, so their order
    /// does not matter either.
    ///
    /// This one already held before the pool observer above existed, and it
    /// is pinned here precisely because it is what makes that observer's job
    /// small: stop is already safe, so the observer only has to cover the
    /// *rest of the recording*. If this ever regresses, the opt-out stops
    /// being fail-closed at both ends rather than one.
    func test_stopping_right_after_an_opt_out_names_nothing_and_stores_nothing() {
        let w = startedRecordingWithAliceSeeded()
        XCTAssertEqual(w.diarizer.assign(embedding: aliceSpeaking), "SPEAKER_00")

        let recordings = RecordingStore(rootDirectory: tempRoot)
        let recording = Recording(title: "Standup",
                                  duration: 30,
                                  source: .microphone,
                                  audioFileName: "standup.wav")
        recordings.add(recording)
        let assigner = RecognisedSpeakerAssigner(
            store: recordings,
            diarizer: w.diarizer,
            snapshots: w.snapshots,
            settings: w.settings,
            profileStillStored: { w.profiles.profileExists(name: $0) })

        w.settings.isEnabled = false
        assigner.finish(recording: recording.id)

        XCTAssertTrue(recordings.recordings.first?.speakerNames.isEmpty ?? false,
                      "no speaker may be auto-named from a feature just switched off")
        XCTAssertEqual(w.snapshots.heldRecordingCount, 0,
                       "and no embeddings may be retained for the stopped recording")
    }

    // MARK: - The explicit delete path

    /// Deletion is the one operation that must work *while off* — that's
    /// when somebody wants their voice data gone. It removes the file rather
    /// than writing an empty array, so nothing is left at rest.
    func test_deleteAllProfiles_works_while_off_and_removes_the_file() throws {
        try seedProfilesFileOnDisk()
        let store = SpeakerProfileStore(directory: tempRoot, settings: makeSettings())
        XCTAssertTrue(store.hasStoredProfilesOnDisk)

        store.deleteAllProfiles()

        XCTAssertFalse(FileManager.default.fileExists(atPath: profilesFile.path))
        XCTAssertFalse(store.hasStoredProfilesOnDisk)
        XCTAssertTrue(store.profiles.isEmpty)
    }

    /// And after deleting, re-enabling brings nothing back.
    func test_after_delete_re_enabling_restores_nothing() throws {
        try seedProfilesFileOnDisk()
        let settings = makeSettings()
        let store = SpeakerProfileStore(directory: tempRoot, settings: settings)

        store.deleteAllProfiles()
        settings.isEnabled = true

        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertTrue(store.seedEntries().isEmpty)
    }
}
