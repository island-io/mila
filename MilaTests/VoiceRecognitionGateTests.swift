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
