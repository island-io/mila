import XCTest
@testable import Mila

@MainActor
final class SpeakerProfileStoreTests: XCTestCase {

    private var suiteNames: [String] = []

    override func tearDown() async throws {
        // Every settings object below gets its own UserDefaults suite so the
        // opt-in flag never touches `.standard` (and never leaks between
        // tests). Tear them all down.
        for name in suiteNames {
            UserDefaults().removePersistentDomain(forName: name)
        }
        suiteNames.removeAll()
        try await super.tearDown()
    }

    private func tempDir() -> URL {
        TestSupport.makeTempRoot(label: "SpeakerProfileStoreTests")
    }

    /// A `VoiceRecognitionSettings` on its own throwaway suite, never
    /// `.standard`. The setting itself is off out of the box — the point of
    /// the feature — so `enabled` is explicit here: these tests exercise the
    /// storage mechanics with the feature on, and
    /// `VoiceRecognitionGateTests` covers the off state.
    private func makeSettings(enabled: Bool, diarizationReady: Bool = true) -> VoiceRecognitionSettings {
        let name = "SpeakerProfileStoreTests.\(UUID())"
        suiteNames.append(name)
        let settings = VoiceRecognitionSettings(defaults: UserDefaults(suiteName: name)!)
        settings.diarizationReady = { diarizationReady }
        settings.isEnabled = enabled
        return settings
    }

    /// An opted-in store rooted at `dir`. Keeps the settings object alive for
    /// the store's lifetime by handing it back to the caller via the store's
    /// own `settings` property.
    private func makeStore(in dir: URL, enabled: Bool = true, diarizationReady: Bool = true) -> SpeakerProfileStore {
        SpeakerProfileStore(directory: dir,
                            settings: makeSettings(enabled: enabled,
                                                   diarizationReady: diarizationReady))
    }

    func test_updateProfile_creates_new_profile() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)

        store.updateProfile(name: "Alice", embedding: [1, 0, 0], sampleCount: 1)

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].name, "Alice")
        XCTAssertEqual(store.profiles[0].embedding, [1, 0, 0])
        XCTAssertEqual(store.profiles[0].sampleCount, 1)
    }

    func test_updateProfile_merges_centroids() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)

        store.updateProfile(name: "Alice", embedding: [1, 0], sampleCount: 1)
        store.updateProfile(name: "Alice", embedding: [0, 1], sampleCount: 1)

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].sampleCount, 2)
        // Weighted average: (1*1 + 0*1)/2 = 0.5, (0*1 + 1*1)/2 = 0.5
        XCTAssertEqual(store.profiles[0].embedding[0], 0.5, accuracy: 0.001)
        XCTAssertEqual(store.profiles[0].embedding[1], 0.5, accuracy: 0.001)
    }

    /// The clamp that keeps `sampleCount` inside `maxSampleCount` must apply
    /// to the **stored count only**, never to the divisor of the weighted
    /// mean. Both folds weight their numerator by the true counts, so a
    /// clamped divisor stops producing a mean and starts scaling the whole
    /// centroid by `rawTotal / maxSampleCount`.
    ///
    /// Two ceiling-count profiles is the worst case — `rawTotal` is very
    /// nearly `Int.max`, i.e. twice the clamp — so the wrong shape yields
    /// `[1, 1]` where the mean is `[0.5, 0.5]`. The `accuracy: 0.001`
    /// assertions below are therefore discriminating rather than decorative:
    /// dividing by the clamped total fails them by 0.5.
    func test_updateProfile_divides_by_true_total_when_stored_count_saturates() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)

        let ceiling = VoiceProfile.maxSampleCount
        store.updateProfile(name: "Alice", embedding: [1, 0], sampleCount: ceiling)
        store.updateProfile(name: "Alice", embedding: [0, 1], sampleCount: ceiling)

        XCTAssertEqual(store.profiles.count, 1)
        // (1*c + 0*c) / 2c = 0.5 — NOT (1*c + 0*c) / c = 1.0.
        XCTAssertEqual(store.profiles[0].embedding[0], 0.5, accuracy: 0.001)
        XCTAssertEqual(store.profiles[0].embedding[1], 0.5, accuracy: 0.001)
        // The stored count saturates rather than overflowing…
        XCTAssertEqual(store.profiles[0].sampleCount, ceiling)
        // …and stays something `load` will hand back, which is the whole
        // point of having a ceiling.
        XCTAssertNil(store.profiles[0].unusableReason)
    }

    /// The control for the case above: a sum that lands exactly *on* the
    /// ceiling is not clamped at all, so the two divisors coincide and the
    /// mean is unaffected. Fixing the fold must not disturb this.
    func test_updateProfile_sum_exactly_at_ceiling_is_not_clamped() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)

        let ceiling = VoiceProfile.maxSampleCount
        store.updateProfile(name: "Alice", embedding: [1, 0], sampleCount: ceiling - 1)
        store.updateProfile(name: "Alice", embedding: [0, 1], sampleCount: 1)

        XCTAssertEqual(store.profiles[0].sampleCount, ceiling)
        // The lone new sample is a ~10⁻¹⁹ share, so the centroid barely moves.
        XCTAssertEqual(store.profiles[0].embedding[0], 1.0, accuracy: 0.001)
        XCTAssertEqual(store.profiles[0].embedding[1], 0.0, accuracy: 0.001)
        XCTAssertNil(store.profiles[0].unusableReason)
    }

    /// Same invariant on the other fold. `mergeProfiles` had the identical
    /// clamped-divisor shape, so it needs its own guard — a fix applied to
    /// one call site and not the other is exactly the failure mode here.
    func test_mergeProfiles_divides_by_true_total_when_stored_count_saturates() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)

        let ceiling = VoiceProfile.maxSampleCount
        store.updateProfile(name: "Alice", embedding: [1, 0], sampleCount: ceiling)
        store.updateProfile(name: "Bob", embedding: [0, 1], sampleCount: ceiling)

        let merged = store.mergeProfiles(keep: "Alice", absorb: "Bob")

        XCTAssertEqual(store.profiles.count, 1)
        // Same discrimination as above: the clamped divisor gives [1, 1].
        XCTAssertEqual(merged?.embedding[0] ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(merged?.embedding[1] ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(merged?.sampleCount, ceiling)
        XCTAssertNil(merged?.unusableReason)
    }

    func test_updateProfile_rejects_dimension_mismatch() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)

        store.updateProfile(name: "Alice", embedding: [1, 0, 0], sampleCount: 1)
        store.updateProfile(name: "Alice", embedding: [1, 0], sampleCount: 1)

        // Should not merge — dimension mismatch
        XCTAssertEqual(store.profiles[0].sampleCount, 1)
        XCTAssertEqual(store.profiles[0].embedding.count, 3)
    }

    func test_updateProfile_refuses_an_embedding_beyond_the_magnitude_bound() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)

        store.updateProfile(name: "Alice", embedding: [1, 0, 0], sampleCount: 2)
        // Finite and decodable — and, multiplied by a sample count in the
        // fold, enough to overflow `Float` to infinity, which `save()` could
        // not encode. Refused outright, for a merge and for a new profile.
        store.updateProfile(name: "Alice", embedding: [1e30, 0, 0], sampleCount: VoiceProfile.maxSampleCount)
        store.updateProfile(name: "Mallory", embedding: [0, 1e30, 0], sampleCount: 1)

        XCTAssertEqual(store.profiles.map(\.name), ["Alice"])
        XCTAssertEqual(store.profiles[0].sampleCount, 2, "the fold was refused, not clamped")
        XCTAssertEqual(store.profiles[0].embedding, [1, 0, 0])
    }

    func test_deleteProfile_by_name() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)

        store.updateProfile(name: "Alice", embedding: [1], sampleCount: 1)
        store.updateProfile(name: "Bob", embedding: [2], sampleCount: 1)

        XCTAssertEqual(store.deleteProfile(name: "Alice"), .deleted)

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].name, "Bob")
    }

    /// Removing a name from Settings → Known speakers used to leave its voice
    /// profile behind, and recognition kept labelling that voice with the
    /// removed name in every new recording. Case-insensitive, like
    /// `SpeakerDirectory.remove`, and persisted.
    func test_forgetSpeaker_deletes_the_profile_and_persists() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)
        store.updateProfile(name: "Daniel Solomon (from Daniel)", embedding: [1], sampleCount: 1)
        store.updateProfile(name: "Bob", embedding: [2], sampleCount: 1)

        XCTAssertEqual(store.storedVoice(forSpeakerNamed: "daniel solomon (FROM daniel)"), .stored)
        XCTAssertEqual(store.storedVoice(forSpeakerNamed: "Nobody"), .notStored)

        var seen: [SpeakerProfileStore.Deletion] = []
        store.addDeletionObserver { seen.append($0) }
        XCTAssertEqual(store.forgetSpeaker(named: "daniel solomon (FROM daniel)"), .deleted)

        XCTAssertEqual(store.profiles.map(\.name), ["Bob"])
        XCTAssertEqual(seen, [.named(["Daniel Solomon (from Daniel)"])])
        XCTAssertEqual(makeStore(in: dir).profiles.map(\.name), ["Bob"])
    }

    /// While the feature is off the profiles aren't in memory, so the delete
    /// has to reach the file — otherwise turning recognition back on would
    /// bring the forgotten voice back.
    func test_forgetSpeaker_while_off_deletes_from_disk() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let store = makeStore(in: dir)
            store.updateProfile(name: "Alice", embedding: [1], sampleCount: 1)
            store.updateProfile(name: "Bob", embedding: [2], sampleCount: 3)
        }

        let off = makeStore(in: dir, enabled: false)
        XCTAssertEqual(off.storedVoice(forSpeakerNamed: "alice"), .stored)
        XCTAssertEqual(off.storedVoice(forSpeakerNamed: "Nobody"), .notStored)
        XCTAssertTrue(off.profiles.isEmpty, "asking loads nothing into memory")
        var seen: [SpeakerProfileStore.Deletion] = []
        off.addDeletionObserver { seen.append($0) }
        XCTAssertEqual(off.forgetSpeaker(named: "Alice"), .deleted)

        XCTAssertTrue(off.profiles.isEmpty, "nothing is loaded into memory while off")
        XCTAssertTrue(off.hasStoredProfilesOnDisk, "Bob is still stored")
        XCTAssertEqual(seen, [.named(["Alice"])])
        let reloaded = makeStore(in: dir)
        XCTAssertEqual(reloaded.profiles.map(\.name), ["Bob"])
        XCTAssertEqual(reloaded.profiles.first?.sampleCount, 3, "the surviving row is intact")
    }

    func test_forgetSpeaker_without_a_profile_is_a_no_op() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)
        store.updateProfile(name: "Alice", embedding: [1], sampleCount: 1)

        var seen: [SpeakerProfileStore.Deletion] = []
        store.addDeletionObserver { seen.append($0) }
        XCTAssertEqual(store.forgetSpeaker(named: "Nobody"), .nothingToDelete)
        XCTAssertEqual(makeStore(in: dir, enabled: false).forgetSpeaker(named: "Nobody"), .nothingToDelete)

        XCTAssertTrue(seen.isEmpty)
        XCTAssertEqual(makeStore(in: dir).profiles.map(\.name), ["Alice"])
    }

    /// With recognition on and `speaker-profiles.json` unreadable, the
    /// voices it holds are not in memory, so there is nothing to delete
    /// there — and the file is the user's unrecovered data, never written
    /// over. The delete must say it could not happen, not report success.
    func test_forgetSpeaker_with_an_unreadable_file_reports_it_and_leaves_the_file_alone() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("speaker-profiles.json")
        let damaged = Data("[{\"name\": \"Alice\", \"embedding\": [1, 0,".utf8)
        try damaged.write(to: fileURL)
        let store = makeStore(in: dir)
        XCTAssertTrue(store.loadedFromDamagedFile)
        var seen: [SpeakerProfileStore.Deletion] = []
        store.addDeletionObserver { seen.append($0) }

        XCTAssertEqual(store.storedVoice(forSpeakerNamed: "Alice"), .unknown)
        XCTAssertEqual(store.forgetSpeaker(named: "Alice"), .profileFileUnreadable)

        XCTAssertEqual(try Data(contentsOf: fileURL), damaged, "not rewritten")
        XCTAssertEqual(try backups(in: dir), [], "not moved aside either: nothing was written")
        XCTAssertTrue(store.loadedFromDamagedFile)
        XCTAssertTrue(seen.isEmpty, "nothing was in memory to drop")
    }

    /// A voice still in memory from an earlier good read stops being used
    /// even though the now-unreadable file cannot be touched.
    func test_forgetSpeaker_with_an_unreadable_file_still_drops_the_voice_from_memory() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("speaker-profiles.json")
        let store = makeStore(in: dir)
        store.updateProfile(name: "Alice", embedding: [1, 0, 0], sampleCount: 1)
        store.updateProfile(name: "Bob", embedding: [0, 0, 1], sampleCount: 1)
        let damaged = Data("not json".utf8)
        try damaged.write(to: fileURL)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                              ofItemAtPath: fileURL.path)
        store.recheckDamagedProfiles()
        XCTAssertTrue(store.loadedFromDamagedFile)
        XCTAssertEqual(store.profiles.map(\.name), ["Alice", "Bob"], "precondition: a failed re-read keeps memory")
        var seen: [SpeakerProfileStore.Deletion] = []
        store.addDeletionObserver { seen.append($0) }

        XCTAssertEqual(store.forgetSpeaker(named: "alice"), .profileFileUnreadable)

        XCTAssertEqual(store.profiles.map(\.name), ["Bob"])
        XCTAssertEqual(seen, [.named(["Alice"])])
        XCTAssertEqual(try Data(contentsOf: fileURL), damaged)
        XCTAssertEqual(try backups(in: dir), [])
    }

    /// While off, a file that does not parse is left exactly as it is.
    func test_forgetSpeaker_while_off_leaves_an_unreadable_file_alone() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("speaker-profiles.json")
        let damaged = Data("not json".utf8)
        try damaged.write(to: fileURL)
        let off = makeStore(in: dir, enabled: false)

        XCTAssertEqual(off.storedVoice(forSpeakerNamed: "Alice"), .unknown)
        XCTAssertEqual(off.forgetSpeaker(named: "Alice"), .profileFileUnreadable)

        XCTAssertEqual(try Data(contentsOf: fileURL), damaged)
        XCTAssertEqual(try backups(in: dir), [])
        XCTAssertTrue(off.hasStoredProfilesOnDisk)
    }

    /// The off-state delete must read the file exactly as `load()` does. This
    /// one is valid JSON that `JSONSerialization` takes happily, but Bob's
    /// date is not ISO 8601, so `load()` rejects the whole file as damaged.
    /// A more lenient reader would rewrite it — dropping Alice and keeping a
    /// Bob that still cannot load — where `load()` had left it for repair.
    func test_forgetSpeaker_while_off_reads_the_file_as_load_does() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("speaker-profiles.json")
        let json = """
        [
          {"id": "\(UUID().uuidString)", "name": "Alice", "embedding": [1], "sampleCount": 1,
           "createdAt": "2026-01-01T00:00:00Z", "lastSeenAt": "2026-01-01T00:00:00Z"},
          {"id": "\(UUID().uuidString)", "name": "Bob", "embedding": [2], "sampleCount": 1,
           "createdAt": "last tuesday", "lastSeenAt": "2026-01-01T00:00:00Z"}
        ]
        """
        let original = Data(json.utf8)
        try original.write(to: fileURL)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: original), "precondition: valid JSON")
        XCTAssertTrue(makeStore(in: dir).loadedFromDamagedFile, "precondition: load() rejects it")

        let off = makeStore(in: dir, enabled: false)
        XCTAssertEqual(off.forgetSpeaker(named: "Alice"), .profileFileUnreadable)

        XCTAssertEqual(try Data(contentsOf: fileURL), original, "left for repair, byte for byte")
    }

    /// While off, forgetting the last voice removes the file rather than
    /// leaving `[]` behind — as `deleteAllProfiles` does — so Settings stops
    /// offering to delete stored voice data that is no longer there.
    func test_forgetSpeaker_while_off_removes_the_file_with_its_last_voice() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("speaker-profiles.json")
        do {
            let store = makeStore(in: dir)
            store.updateProfile(name: "Alice", embedding: [1], sampleCount: 1)
        }
        let off = makeStore(in: dir, enabled: false)
        XCTAssertTrue(off.hasStoredProfilesOnDisk)

        XCTAssertEqual(off.forgetSpeaker(named: "alice"), .deleted)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(off.hasStoredProfilesOnDisk)
    }

    /// While off, a file that cannot be rewritten keeps the voice — and the
    /// delete says so instead of reporting it gone.
    func test_forgetSpeaker_while_off_reports_a_failed_write() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let fileURL = dir.appendingPathComponent("speaker-profiles.json")
        do {
            let store = makeStore(in: dir)
            store.updateProfile(name: "Alice", embedding: [1], sampleCount: 1)
            store.updateProfile(name: "Bob", embedding: [2], sampleCount: 1)
        }
        let before = try Data(contentsOf: fileURL)
        let off = makeStore(in: dir, enabled: false)
        var seen: [SpeakerProfileStore.Deletion] = []
        off.addDeletionObserver { seen.append($0) }
        // A read-only folder: the atomic write cannot replace the file.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)

        XCTAssertEqual(off.forgetSpeaker(named: "Alice"), .notDeleted)

        XCTAssertEqual(try Data(contentsOf: fileURL), before)
        XCTAssertTrue(seen.isEmpty)
    }

    /// With recognition on, a delete whose save fails still takes the voice
    /// out of the running session (and tells a recording in flight), but
    /// reports that it did not persist — it would otherwise undo itself on
    /// the next launch while the UI said it was gone.
    func test_forgetSpeaker_reports_a_failed_save_but_keeps_the_in_memory_removal() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let fileURL = dir.appendingPathComponent("speaker-profiles.json")
        let store = makeStore(in: dir)
        store.updateProfile(name: "Alice", embedding: [1, 0, 0], sampleCount: 1)
        store.updateProfile(name: "Bob", embedding: [0, 0, 1], sampleCount: 1)
        let before = try Data(contentsOf: fileURL)
        var seen: [SpeakerProfileStore.Deletion] = []
        store.addDeletionObserver { seen.append($0) }
        // A read-only folder: the atomic write cannot replace the file.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)

        XCTAssertEqual(store.forgetSpeaker(named: "Alice"), .deletedForThisSessionOnly)

        XCTAssertEqual(store.profiles.map(\.name), ["Bob"], "the running session stops using the voice")
        XCTAssertEqual(seen, [.named(["Alice"])])
        XCTAssertEqual(try Data(contentsOf: fileURL), before, "nothing persisted")
    }

    /// A voice whose delete did not persist is still on disk, so Known
    /// speakers must still see it — not drop the name in one click — and
    /// asking again must retry the save rather than find nothing in memory
    /// and write nothing, leaving the voice to be reseeded on next launch.
    func test_a_delete_whose_save_failed_is_still_reported_and_a_retry_persists_it() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let store = makeStore(in: dir)
        store.updateProfile(name: "Alice", embedding: [1, 0, 0], sampleCount: 1)
        store.updateProfile(name: "Bob", embedding: [0, 0, 1], sampleCount: 1)
        var seen: [SpeakerProfileStore.Deletion] = []
        store.addDeletionObserver { seen.append($0) }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        XCTAssertEqual(store.forgetSpeaker(named: "Alice"), .deletedForThisSessionOnly)

        XCTAssertEqual(store.storedVoice(forSpeakerNamed: "alice"), .stored, "still on disk")
        XCTAssertEqual(store.forgetSpeaker(named: "Alice"), .deletedForThisSessionOnly, "still failing")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        XCTAssertEqual(store.forgetSpeaker(named: "Alice"), .deleted, "the retry is the save")

        XCTAssertEqual(store.storedVoice(forSpeakerNamed: "Alice"), .notStored)
        XCTAssertEqual(store.forgetSpeaker(named: "Alice"), .nothingToDelete)
        XCTAssertEqual(makeStore(in: dir).profiles.map(\.name), ["Bob"])
        XCTAssertEqual(seen, [.named(["Alice"])], "observers are told once")
    }

    func test_renameProfile() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)

        store.updateProfile(name: "Alice", embedding: [1], sampleCount: 1)
        store.renameProfile(from: "Alice", to: "Alicia")

        XCTAssertEqual(store.profiles[0].name, "Alicia")
        XCTAssertFalse(store.profileExists(name: "Alice"))
        XCTAssertTrue(store.profileExists(name: "Alicia"))
    }

    func test_match_returns_best_above_threshold() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)

        store.updateProfile(name: "Alice", embedding: [1, 0, 0], sampleCount: 1)
        store.updateProfile(name: "Bob", embedding: [0, 1, 0], sampleCount: 1)

        // Exact match for Alice
        let match = store.match(embedding: [1, 0, 0], threshold: 0.9)
        XCTAssertEqual(match?.name, "Alice")

        // No match above threshold
        let noMatch = store.match(embedding: [0.5, 0.5, 0.5], threshold: 0.99)
        XCTAssertNil(noMatch)
    }

    func test_mergeProfiles() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)

        store.updateProfile(name: "Alice", embedding: [1, 0], sampleCount: 2)
        store.updateProfile(name: "Bob", embedding: [0, 1], sampleCount: 2)

        let merged = store.mergeProfiles(keep: "Alice", absorb: "Bob")

        XCTAssertNotNil(merged)
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(merged?.name, "Alice")
        XCTAssertEqual(merged?.sampleCount, 4)
        // Weighted average: (1*2 + 0*2)/4 = 0.5, (0*2 + 1*2)/4 = 0.5
        XCTAssertEqual(merged?.embedding[0] ?? 0, 0.5, accuracy: 0.001)
    }

    func test_persistence_round_trip() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            let store = makeStore(in: dir)
            store.updateProfile(name: "Alice", embedding: [1, 2, 3], sampleCount: 5)
        }

        let reloaded = makeStore(in: dir)
        XCTAssertEqual(reloaded.profiles.count, 1)
        XCTAssertEqual(reloaded.profiles[0].name, "Alice")
        XCTAssertEqual(reloaded.profiles[0].embedding, [1, 2, 3])
        XCTAssertEqual(reloaded.profiles[0].sampleCount, 5)
    }

    // MARK: - Staged writes

    /// `staged(_:)` exists for `RecordingShareImporter`: it folds a
    /// bundle's voice profiles in BEFORE the recording row, and the file
    /// must not change until the row has been saved — or a crash in between
    /// leaves voice data and import tokens for a recording that is not in
    /// the library (#319, #329).
    func test_staged_writes_change_memory_only_until_committed() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("speaker-profiles.json")
        let store = makeStore(in: dir)
        store.updateProfile(name: "Alice", embedding: [1, 0, 0], sampleCount: 1)
        let before = try Data(contentsOf: fileURL)

        let (_, changes) = store.staged {
            store.updateProfile(name: "Alice", embedding: [0, 1, 0], sampleCount: 1)
            store.updateProfile(name: "Bob", embedding: [0, 0, 1], sampleCount: 3)
            store.recordImport(token: ImportedShareToken(bundleKey: "bundle", sharedName: "Al"),
                               onProfileNamed: "Alice")
        }
        XCTAssertEqual(store.profiles.map(\.name), ["Alice", "Bob"], "memory sees the staged writes")
        XCTAssertEqual(store.importedShareTokens.count, 1)
        XCTAssertEqual(try Data(contentsOf: fileURL), before, "the file does not, yet")

        store.commit(changes)
        let reloaded = makeStore(in: dir)
        XCTAssertEqual(reloaded.profiles.map(\.name), ["Alice", "Bob"])
        XCTAssertEqual(reloaded.profile(named: "Alice")?.sampleCount, 2)
        XCTAssertEqual(reloaded.importedShareTokens.count, 1)
    }

    /// Discarding puts memory back and never touches the file — including
    /// the no-file case, where a `[]` left behind would make Settings offer
    /// to delete voice profiles the user never stored.
    func test_discarding_staged_writes_restores_memory_and_never_writes() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("speaker-profiles.json")
        let store = makeStore(in: dir)

        let (_, empty) = store.staged {
            store.updateProfile(name: "Alice", embedding: [1, 0, 0], sampleCount: 1)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        store.discard(empty)
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(store.hasStoredProfilesOnDisk)

        store.updateProfile(name: "Alice", embedding: [1, 0, 0], sampleCount: 1)
        let before = try Data(contentsOf: fileURL)
        let (_, changes) = store.staged {
            store.updateProfile(name: "Alice", embedding: [0, 1, 0], sampleCount: 1)
            store.updateProfile(name: "Bob", embedding: [0, 0, 1], sampleCount: 3)
        }
        store.discard(changes)
        XCTAssertEqual(store.profiles.map(\.name), ["Alice"])
        XCTAssertEqual(store.profiles[0].embedding, [1, 0, 0])
        XCTAssertEqual(try Data(contentsOf: fileURL), before)

        // And writes after a staging run persist as usual.
        store.updateProfile(name: "Carol", embedding: [0, 0, 1], sampleCount: 1)
        XCTAssertEqual(makeStore(in: dir).profiles.map(\.name), ["Alice", "Carol"])
    }

    // MARK: - Damaged file

    /// A file `load()` cannot parse is the user's voice data in a state
    /// they can still repair. The next write must not destroy it: it is
    /// moved aside under a timestamped name, byte for byte, and the new
    /// profiles go to a fresh `speaker-profiles.json` (#329).
    func test_a_write_after_a_failed_load_moves_the_damaged_file_aside() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("speaker-profiles.json")
        let damaged = Data("[{\"name\": \"Alice\", \"embedding\": [1, 0,".utf8)
        try damaged.write(to: fileURL)
        let store = makeStore(in: dir)
        XCTAssertTrue(store.profiles.isEmpty, "the file does not parse")
        XCTAssertTrue(store.loadedFromDamagedFile)

        store.updateProfile(name: "Bob", embedding: [0, 0, 1], sampleCount: 3)

        let aside = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("speaker-profiles.damaged-") && $0.hasSuffix(".json") }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(aside[0])), damaged,
                       "every byte of the damaged file survives")
        XCTAssertFalse(store.loadedFromDamagedFile)
        XCTAssertEqual(makeStore(in: dir).profiles.map(\.name), ["Bob"])
        XCTAssertNotEqual(try Data(contentsOf: fileURL), damaged)

        // Once moved, later writes are ordinary ones: no second copy.
        store.updateProfile(name: "Carol", embedding: [0, 1, 0], sampleCount: 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("speaker-profiles.damaged-") }.count, 1)
    }

    /// The moved-aside copy is voice data like the live file: it keeps
    /// "Delete Voice Profiles" on offer, and that button removes it too.
    func test_delete_all_removes_the_moved_aside_copies_as_well() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("speaker-profiles.json")
        try Data("not json".utf8).write(to: fileURL)
        let store = makeStore(in: dir)
        store.updateProfile(name: "Bob", embedding: [0, 0, 1], sampleCount: 3)
        try FileManager.default.removeItem(at: fileURL)
        XCTAssertTrue(makeStore(in: dir).hasStoredProfilesOnDisk,
                      "a damaged copy alone still counts as stored voice data")

        store.deleteAllProfiles()

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("speaker-profiles") }, [])
        XCTAssertFalse(store.hasStoredProfilesOnDisk)
    }

    /// A `StagedChanges` ends its run once: a second discard, or one after
    /// an ordinary save already persisted the staged profiles, must not
    /// revert memory.
    func test_staged_changes_can_be_ended_only_once() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)

        let (_, changes) = store.staged {
            store.updateProfile(name: "Alice", embedding: [1, 0, 0], sampleCount: 1)
        }
        store.updateProfile(name: "Bob", embedding: [0, 0, 1], sampleCount: 3)  // persists both
        store.discard(changes)
        XCTAssertEqual(store.profiles.map(\.name), ["Alice", "Bob"], "overtaken: nothing reverted")
        XCTAssertFalse(store.commit(changes))
        XCTAssertEqual(makeStore(in: dir).profiles.map(\.name), ["Alice", "Bob"])
    }

    /// If the damaged file cannot be moved, nothing is written over it.
    func test_a_damaged_file_that_cannot_be_moved_is_not_overwritten() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let fileURL = dir.appendingPathComponent("speaker-profiles.json")
        let damaged = Data("not json".utf8)
        try damaged.write(to: fileURL)
        let store = makeStore(in: dir)
        XCTAssertTrue(store.loadedFromDamagedFile)
        // A read-only folder: neither the rename nor an atomic write can happen.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)

        store.updateProfile(name: "Bob", embedding: [0, 0, 1], sampleCount: 3)

        XCTAssertEqual(try Data(contentsOf: fileURL), damaged)
        XCTAssertTrue(store.loadedFromDamagedFile, "the next write tries again")
    }

    // MARK: - Damaged-file notice (#336)

    private func backups(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("speaker-profiles.damaged-") && $0.hasSuffix(".json") }
            .sorted()
    }

    /// A readable file, or none at all, raises no notice.
    func test_no_notice_without_a_damaged_file() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)
        XCTAssertNil(store.damagedProfilesNotice)
        store.updateProfile(name: "Alice", embedding: [1, 0, 0], sampleCount: 1)
        XCTAssertNil(makeStore(in: dir).damagedProfilesNotice)
    }

    /// The profiles stop being used the moment the load fails, not when the
    /// file is moved — so the notice starts there, pointing at the live
    /// file, and switches to the backup once it has been set aside.
    func test_notice_follows_the_damaged_file_from_unreadable_to_set_aside() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("speaker-profiles.json")
        try Data("not json".utf8).write(to: fileURL)
        let store = makeStore(in: dir)
        XCTAssertEqual(store.damagedProfilesNotice, .unreadable(fileURL))

        store.dismissDamagedProfilesNotice()
        XCTAssertEqual(store.damagedProfilesNotice, .unreadable(fileURL),
                       "an unreadable live file cannot be dismissed")

        store.updateProfile(name: "Bob", embedding: [0, 0, 1], sampleCount: 3)

        let names = try backups(in: dir)
        XCTAssertEqual(names.count, 1)
        XCTAssertEqual(store.damagedProfilesNotice?.fileURL.lastPathComponent, names[0])
        if case .setAside = store.damagedProfilesNotice {} else {
            XCTFail("expected .setAside, got \(String(describing: store.damagedProfilesNotice))")
        }
        // After a relaunch the live file is fine, but the backup is still news.
        XCTAssertEqual(makeStore(in: dir).damagedProfilesNotice?.fileURL.lastPathComponent, names[0])
    }

    /// Dismissing is remembered per backup across relaunches, and does not
    /// hide a later, different backup.
    func test_dismissing_a_backup_notice_persists_but_a_newer_backup_still_shows() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = makeSettings(enabled: true)
        let first = dir.appendingPathComponent("speaker-profiles.damaged-20260101T000000Z.json")
        try Data("old".utf8).write(to: first)

        let store = SpeakerProfileStore(directory: dir, settings: settings)
        XCTAssertEqual(store.damagedProfilesNotice, .setAside(first))
        store.dismissDamagedProfilesNotice()
        XCTAssertNil(store.damagedProfilesNotice)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path), "dismissing keeps the backup")
        XCTAssertNil(SpeakerProfileStore(directory: dir, settings: settings).damagedProfilesNotice)

        let second = dir.appendingPathComponent("speaker-profiles.damaged-20260201T000000Z.json")
        try Data("newer".utf8).write(to: second)
        XCTAssertEqual(SpeakerProfileStore(directory: dir, settings: settings).damagedProfilesNotice,
                       .setAside(second))
    }

    /// A same-second collision suffix sorts after the base name, and by
    /// number (`-10` after `-2`); Dismiss hides every backup present.
    func test_newest_backup_is_ordered_by_stamp_then_suffix_and_dismiss_covers_all() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = makeSettings(enabled: true)
        for suffix in ["", "-2", "-10"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(
                "speaker-profiles.damaged-20261013T120000Z\(suffix).json"))
        }
        try Data("x".utf8).write(to: dir.appendingPathComponent(
            "speaker-profiles.damaged-20261012T120000Z-99.json"))

        let store = SpeakerProfileStore(directory: dir, settings: settings)
        XCTAssertEqual(store.damagedProfilesNotice?.fileURL.lastPathComponent,
                       "speaker-profiles.damaged-20261013T120000Z-10.json")
        store.dismissDamagedProfilesNotice()
        XCTAssertNil(store.damagedProfilesNotice, "one click dismisses every backup present")
    }

    // MARK: - Main-window announcement (#342)

    /// An unreadable file is announced in the main window at launch, and
    /// only once: a relaunch with the same broken file stays quiet, while
    /// Settings keeps its notice.
    func test_announcement_shows_once_for_an_unreadable_file() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("speaker-profiles.json")
        try Data("not json".utf8).write(to: fileURL)
        let settings = makeSettings(enabled: true)

        let first = SpeakerProfileStore(directory: dir, settings: settings)
        XCTAssertEqual(first.damagedProfilesAnnouncement, .unreadable(fileURL))
        first.noteDamagedProfilesAnnouncementShown()  // the banner appeared
        first.recheckDamagedProfiles()
        XCTAssertEqual(first.damagedProfilesAnnouncement, .unreadable(fileURL),
                       "still up for the rest of the session")

        let relaunched = SpeakerProfileStore(directory: dir, settings: settings)
        XCTAssertNil(relaunched.damagedProfilesAnnouncement, "no nag on the next launch")
        XCTAssertEqual(relaunched.damagedProfilesNotice, .unreadable(fileURL))
    }

    /// It counts as announced only once it has been on screen: a launch
    /// that computed it but never showed it (no main window, quit at once)
    /// does not use it up.
    func test_an_announcement_never_shown_comes_back_on_relaunch() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backup = dir.appendingPathComponent("speaker-profiles.damaged-20260101T000000Z.json")
        try Data("old".utf8).write(to: backup)
        let settings = makeSettings(enabled: true)

        XCTAssertEqual(SpeakerProfileStore(directory: dir, settings: settings).damagedProfilesAnnouncement,
                       .setAside(backup))
        XCTAssertTrue(settings.announcedDamagedProfiles.isEmpty)
        XCTAssertEqual(SpeakerProfileStore(directory: dir, settings: settings).damagedProfilesAnnouncement,
                       .setAside(backup))
    }

    /// Switching voice recognition off takes the banner down; switching it
    /// back on in the same session brings back one the user never closed.
    func test_toggling_off_and_on_keeps_an_unclosed_announcement() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backup = dir.appendingPathComponent("speaker-profiles.damaged-20260101T000000Z.json")
        try Data("old".utf8).write(to: backup)
        let settings = makeSettings(enabled: true)
        let store = SpeakerProfileStore(directory: dir, settings: settings)
        store.noteDamagedProfilesAnnouncementShown()

        settings.isEnabled = false
        XCTAssertNil(store.damagedProfilesAnnouncement)
        settings.isEnabled = true
        XCTAssertEqual(store.damagedProfilesAnnouncement, .setAside(backup))
    }

    /// Settings showing the same notice hides the banner for the session,
    /// but does not use the incident up: the section may be below the fold.
    func test_hiding_for_settings_does_not_count_as_announced() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backup = dir.appendingPathComponent("speaker-profiles.damaged-20260101T000000Z.json")
        try Data("old".utf8).write(to: backup)
        let settings = makeSettings(enabled: true)

        let store = SpeakerProfileStore(directory: dir, settings: settings)
        store.hideDamagedProfilesAnnouncement()
        XCTAssertNil(store.damagedProfilesAnnouncement)
        store.recheckDamagedProfiles()  // Settings does this on appear and activation
        XCTAssertNil(store.damagedProfilesAnnouncement, "hidden for the rest of the session")
        XCTAssertEqual(SpeakerProfileStore(directory: dir, settings: settings).damagedProfilesAnnouncement,
                       .setAside(backup))
    }

    /// A file edited since it was announced (and still broken) is a new
    /// incident: its backup does not inherit the old announcement.
    func test_a_file_edited_since_it_was_announced_is_news_when_moved() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("speaker-profiles.json")
        try Data("not json".utf8).write(to: fileURL)
        let settings = makeSettings(enabled: true)
        let store = SpeakerProfileStore(directory: dir, settings: settings)
        store.acknowledgeDamagedProfilesAnnouncement()

        try Data("still not json".utf8).write(to: fileURL)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)],
                                              ofItemAtPath: fileURL.path)
        store.updateProfile(name: "Bob", embedding: [0, 0, 1], sampleCount: 3)  // moves it aside

        let names = try backups(in: dir)
        XCTAssertEqual(names.count, 1)
        XCTAssertEqual(store.damagedProfilesAnnouncement?.fileURL.lastPathComponent, names[0])
    }

    /// The banner stays up while the user edits the file in Finder and it
    /// is still broken: that new incident is the one they are looking at,
    /// so it is recorded too and the next launch stays quiet.
    func test_a_file_edited_while_its_banner_is_up_is_recorded() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("speaker-profiles.json")
        try Data("not json".utf8).write(to: fileURL)
        let settings = makeSettings(enabled: true)
        let store = SpeakerProfileStore(directory: dir, settings: settings)
        store.noteDamagedProfilesAnnouncementShown()

        try Data("still not json".utf8).write(to: fileURL)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)],
                                              ofItemAtPath: fileURL.path)
        store.recheckDamagedProfiles()
        XCTAssertEqual(store.damagedProfilesAnnouncement, .unreadable(fileURL))

        XCTAssertNil(SpeakerProfileStore(directory: dir, settings: settings).damagedProfilesAnnouncement)
    }

    /// A backup announcement covers every backup present, so deleting the
    /// newest one does not raise a banner about an older one.
    func test_deleting_the_announced_backup_does_not_announce_an_older_one() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let older = dir.appendingPathComponent("speaker-profiles.damaged-20260101T000000Z.json")
        let newer = dir.appendingPathComponent("speaker-profiles.damaged-20260201T000000Z.json")
        try Data("old".utf8).write(to: older)
        try Data("newer".utf8).write(to: newer)
        let settings = makeSettings(enabled: true)
        let store = SpeakerProfileStore(directory: dir, settings: settings)
        XCTAssertEqual(store.damagedProfilesAnnouncement, .setAside(newer))
        store.acknowledgeDamagedProfilesAnnouncement()

        try FileManager.default.removeItem(at: newer)
        store.recheckDamagedProfiles()
        XCTAssertEqual(store.damagedProfilesNotice, .setAside(older), "Settings still says so")
        XCTAssertNil(store.damagedProfilesAnnouncement)
    }

    /// No damaged file, no announcement.
    func test_no_announcement_without_a_damaged_file() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)
        store.updateProfile(name: "Alice", embedding: [1, 0, 0], sampleCount: 1)
        XCTAssertNil(store.damagedProfilesAnnouncement)
        XCTAssertNil(makeStore(in: dir).damagedProfilesAnnouncement)
    }

    /// Closing it takes it down for the session; it does not come back on
    /// relaunch either.
    func test_acknowledged_announcement_stays_down() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backup = dir.appendingPathComponent("speaker-profiles.damaged-20260101T000000Z.json")
        try Data("old".utf8).write(to: backup)
        let settings = makeSettings(enabled: true)

        let store = SpeakerProfileStore(directory: dir, settings: settings)
        XCTAssertEqual(store.damagedProfilesAnnouncement, .setAside(backup))
        store.acknowledgeDamagedProfilesAnnouncement()
        XCTAssertNil(store.damagedProfilesAnnouncement)
        store.recheckDamagedProfiles()
        XCTAssertNil(store.damagedProfilesAnnouncement, "a recheck does not bring it back")
        XCTAssertEqual(store.damagedProfilesNotice, .setAside(backup), "Settings still says so")
        XCTAssertNil(SpeakerProfileStore(directory: dir, settings: settings).damagedProfilesAnnouncement)
    }

    /// A backup dismissed in Settings (#337) is never announced, and
    /// dismissing takes a showing announcement down.
    func test_a_dismissed_backup_is_never_announced() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backup = dir.appendingPathComponent("speaker-profiles.damaged-20260101T000000Z.json")
        try Data("old".utf8).write(to: backup)
        let settings = makeSettings(enabled: true)
        settings.setDismissedDamagedBackups([backup.lastPathComponent])
        XCTAssertNil(SpeakerProfileStore(directory: dir, settings: settings).damagedProfilesAnnouncement)

        // Dismissed while the announcement is showing.
        let other = dir.appendingPathComponent("speaker-profiles.damaged-20260201T000000Z.json")
        try Data("newer".utf8).write(to: other)
        let store = SpeakerProfileStore(directory: dir, settings: settings)
        XCTAssertEqual(store.damagedProfilesAnnouncement, .setAside(other))
        store.dismissDamagedProfilesNotice()
        XCTAssertNil(store.damagedProfilesAnnouncement)
    }

    /// Off means the user is not expecting recognition: nothing is
    /// announced, and nothing is recorded as announced, so opting in later
    /// still tells them.
    func test_no_announcement_while_voice_recognition_is_off() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backup = dir.appendingPathComponent("speaker-profiles.damaged-20260101T000000Z.json")
        try Data("old".utf8).write(to: backup)
        let settings = makeSettings(enabled: false)

        let store = SpeakerProfileStore(directory: dir, settings: settings)
        XCTAssertNotNil(store.damagedProfilesNotice, "Settings still shows its notice")
        XCTAssertNil(store.damagedProfilesAnnouncement)
        XCTAssertNil(SpeakerProfileStore(directory: dir, settings: settings).damagedProfilesAnnouncement)

        settings.isEnabled = true
        XCTAssertEqual(store.damagedProfilesAnnouncement, .setAside(backup))
    }

    /// The unreadable file and the backup it is moved to are one incident:
    /// a showing announcement follows the file, and a closed one is not
    /// raised again by the move or by a relaunch.
    func test_moving_the_file_aside_is_not_a_second_announcement() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("speaker-profiles.json")
        try Data("not json".utf8).write(to: fileURL)
        let settings = makeSettings(enabled: true)

        let store = SpeakerProfileStore(directory: dir, settings: settings)
        XCTAssertEqual(store.damagedProfilesAnnouncement, .unreadable(fileURL))
        store.noteDamagedProfilesAnnouncementShown()
        store.updateProfile(name: "Bob", embedding: [0, 0, 1], sampleCount: 3)  // moves it aside
        let names = try backups(in: dir)
        XCTAssertEqual(names.count, 1)
        XCTAssertEqual(store.damagedProfilesAnnouncement?.fileURL.lastPathComponent, names[0],
                       "the showing announcement now points at the backup")
        store.noteDamagedProfilesAnnouncementShown()
        XCTAssertNil(SpeakerProfileStore(directory: dir, settings: settings).damagedProfilesAnnouncement,
                     "the backup inherited the announcement")

        // Same again, but closed before the move.
        try FileManager.default.removeItem(at: dir.appendingPathComponent(names[0]))
        try FileManager.default.removeItem(at: fileURL)
        try Data("still not json".utf8).write(to: fileURL)
        // A different modification date is what makes it a new incident;
        // do not leave that to the clock's resolution.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)],
                                              ofItemAtPath: fileURL.path)
        let again = SpeakerProfileStore(directory: dir, settings: settings)
        XCTAssertEqual(again.damagedProfilesAnnouncement, .unreadable(fileURL), "a new incident")
        again.acknowledgeDamagedProfilesAnnouncement()
        again.updateProfile(name: "Carol", embedding: [0, 1, 0], sampleCount: 1)
        XCTAssertEqual(try backups(in: dir).count, 1)
        XCTAssertNil(again.damagedProfilesAnnouncement)
    }

    /// A newer backup is a new incident even after an older one was
    /// announced; and an announced backup removed by hand is forgotten, so
    /// a later file reusing its name is still announced.
    func test_a_newer_or_reused_backup_is_announced() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = makeSettings(enabled: true)
        let first = dir.appendingPathComponent("speaker-profiles.damaged-20260101T000000Z.json")
        try Data("old".utf8).write(to: first)
        let shown = SpeakerProfileStore(directory: dir, settings: settings)
        XCTAssertEqual(shown.damagedProfilesAnnouncement, .setAside(first))
        shown.noteDamagedProfilesAnnouncementShown()

        let second = dir.appendingPathComponent("speaker-profiles.damaged-20260201T000000Z.json")
        try Data("newer".utf8).write(to: second)
        XCTAssertEqual(SpeakerProfileStore(directory: dir, settings: settings).damagedProfilesAnnouncement,
                       .setAside(second))

        try FileManager.default.removeItem(at: first)
        try FileManager.default.removeItem(at: second)
        let store = SpeakerProfileStore(directory: dir, settings: settings)
        XCTAssertNil(store.damagedProfilesAnnouncement)
        XCTAssertTrue(settings.announcedDamagedProfiles.isEmpty, "names of removed backups are forgotten")
        try Data("reused".utf8).write(to: second)
        store.recheckDamagedProfiles()
        XCTAssertEqual(store.damagedProfilesAnnouncement, .setAside(second))
    }

    /// Turning the feature off does not make an unreadable file readable:
    /// the notice stays, so the user is not left believing the profiles
    /// come back on opt-in. Nothing is written over the file meanwhile.
    func test_opting_out_keeps_the_unreadable_notice() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("speaker-profiles.json")
        try Data("not json".utf8).write(to: fileURL)
        let store = makeStore(in: dir)
        XCTAssertEqual(store.damagedProfilesNotice, .unreadable(fileURL))

        store.settings.isEnabled = false
        XCTAssertEqual(store.damagedProfilesNotice, .unreadable(fileURL))
        store.settings.isEnabled = true
        XCTAssertEqual(store.damagedProfilesNotice, .unreadable(fileURL))
        XCTAssertEqual(try Data(contentsOf: fileURL), Data("not json".utf8))
    }

    /// A backup the user repaired and put back over the file `save()` wrote
    /// is loaded on recheck, not overwritten by the next save.
    func test_recheck_loads_a_live_file_replaced_by_hand_after_the_move() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("speaker-profiles.json")
        let writer = makeStore(in: dir)
        writer.updateProfile(name: "Alice", embedding: [1, 0, 0], sampleCount: 1)
        let repaired = try Data(contentsOf: fileURL)
        try FileManager.default.removeItem(at: fileURL)

        try Data("not json".utf8).write(to: fileURL)
        let store = makeStore(in: dir)
        store.updateProfile(name: "Bob", embedding: [0, 0, 1], sampleCount: 3)  // moves it aside
        XCTAssertEqual(store.profiles.map(\.name), ["Bob"])
        store.recheckDamagedProfiles()
        XCTAssertEqual(store.profiles.map(\.name), ["Bob"], "an unchanged file is not re-read")

        try repaired.write(to: fileURL)
        // Make sure the date moves even on a coarse-grained clock.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                              ofItemAtPath: fileURL.path)
        store.recheckDamagedProfiles()
        XCTAssertEqual(store.profiles.map(\.name), ["Alice"], "the user's repair is loaded")
    }

    /// The notice sends the user to Finder; what they do there is picked up
    /// by a recheck. A repaired live file is loaded, a deleted backup stops
    /// being announced.
    func test_recheck_picks_up_a_repair_or_a_deleted_backup() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("speaker-profiles.json")
        // A good file to repair with, written through the store itself.
        let writer = makeStore(in: dir)
        writer.updateProfile(name: "Alice", embedding: [1, 0, 0], sampleCount: 1)
        let good = try Data(contentsOf: fileURL)

        try Data("not json".utf8).write(to: fileURL)
        let store = makeStore(in: dir)
        XCTAssertEqual(store.damagedProfilesNotice, .unreadable(fileURL))
        try good.write(to: fileURL)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                              ofItemAtPath: fileURL.path)
        store.recheckDamagedProfiles()
        XCTAssertNil(store.damagedProfilesNotice)
        XCTAssertEqual(store.profiles.map(\.name), ["Alice"], "the repair takes effect")

        let backup = dir.appendingPathComponent("speaker-profiles.damaged-20260101T000000Z.json")
        try Data("old".utf8).write(to: backup)
        store.recheckDamagedProfiles()
        XCTAssertEqual(store.damagedProfilesNotice, .setAside(backup))
        try FileManager.default.removeItem(at: backup)
        store.recheckDamagedProfiles()
        XCTAssertNil(store.damagedProfilesNotice)
    }

    /// A profile whose save failed lives only in memory; a recheck must
    /// not re-read the file over it.
    func test_recheck_does_not_reload_over_an_unsaved_profile() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let fileURL = dir.appendingPathComponent("speaker-profiles.json")
        let writer = makeStore(in: dir)
        writer.updateProfile(name: "Alice", embedding: [1, 0, 0], sampleCount: 1)
        let good = try Data(contentsOf: fileURL)

        try Data("not json".utf8).write(to: fileURL)
        let store = makeStore(in: dir)
        // Read-only folder: the move aside fails, so Bob is memory-only.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        store.updateProfile(name: "Bob", embedding: [0, 0, 1], sampleCount: 3)
        XCTAssertEqual(store.profiles.map(\.name), ["Bob"])

        try good.write(to: fileURL)  // the file itself stays writable
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                              ofItemAtPath: fileURL.path)
        store.recheckDamagedProfiles()
        XCTAssertEqual(store.profiles.map(\.name), ["Bob"], "the unsaved profile is not dropped")
    }

    /// A re-read that drops a profile reports it like a delete, so a
    /// seeded recording in flight does not write it back at stop.
    func test_recheck_reports_profiles_a_reread_removed() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("speaker-profiles.json")
        let writer = makeStore(in: dir)
        writer.updateProfile(name: "Alice", embedding: [1, 0, 0], sampleCount: 1)
        let onlyAlice = try Data(contentsOf: fileURL)
        writer.updateProfile(name: "Bob", embedding: [0, 0, 1], sampleCount: 3)

        let store = makeStore(in: dir)
        var deletions: [SpeakerProfileStore.Deletion] = []
        store.addDeletionObserver { deletions.append($0) }
        try onlyAlice.write(to: fileURL)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                              ofItemAtPath: fileURL.path)
        store.recheckDamagedProfiles()
        XCTAssertEqual(store.profiles.map(\.name), ["Alice"])
        XCTAssertEqual(deletions, [.named(["Bob"])])
    }

    /// A live file removed by hand takes its profiles out of memory too,
    /// reported like a delete, so the next save does not write them back.
    func test_recheck_after_the_file_is_removed_by_hand_drops_its_profiles() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("speaker-profiles.json")
        let store = makeStore(in: dir)
        store.updateProfile(name: "Alice", embedding: [1, 0, 0], sampleCount: 1)
        var deletions: [SpeakerProfileStore.Deletion] = []
        store.addDeletionObserver { deletions.append($0) }

        try FileManager.default.removeItem(at: fileURL)
        store.recheckDamagedProfiles()
        XCTAssertEqual(store.profiles.map(\.name), [])
        XCTAssertEqual(deletions, [.named(["Alice"])])
        XCTAssertFalse(store.hasStoredProfilesOnDisk)
    }

    /// Delete Voice Profiles forgets dismissed names along with the files,
    /// so a later backup that reuses a name is still announced.
    func test_delete_all_forgets_dismissed_backup_names() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = makeSettings(enabled: true)
        let backup = dir.appendingPathComponent("speaker-profiles.damaged-20260101T000000Z.json")
        try Data("old".utf8).write(to: backup)
        let store = SpeakerProfileStore(directory: dir, settings: settings)
        store.dismissDamagedProfilesNotice()
        XCTAssertEqual(settings.dismissedDamagedBackups, [backup.lastPathComponent])

        store.deleteAllProfiles()
        XCTAssertEqual(settings.dismissedDamagedBackups, [])
        try Data("old".utf8).write(to: backup)
        XCTAssertEqual(SpeakerProfileStore(directory: dir, settings: settings).damagedProfilesNotice,
                       .setAside(backup))
    }

    /// A backup is announced even while the feature is off: listing the
    /// folder reads no voice data.
    func test_backup_notice_shows_while_the_feature_is_off() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backup = dir.appendingPathComponent("speaker-profiles.damaged-20260101T000000Z.json")
        try Data("old".utf8).write(to: backup)
        XCTAssertEqual(makeStore(in: dir, enabled: false).damagedProfilesNotice, .setAside(backup))
    }

    /// "Delete Voice Profiles" removes the backups, so the notice goes too —
    /// in both states.
    func test_delete_all_clears_the_notice() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("speaker-profiles.json")
        try Data("not json".utf8).write(to: fileURL)
        let unreadable = makeStore(in: dir)
        unreadable.deleteAllProfiles()
        XCTAssertNil(unreadable.damagedProfilesNotice)

        try Data("not json".utf8).write(to: fileURL)
        let store = makeStore(in: dir)
        store.updateProfile(name: "Bob", embedding: [0, 0, 1], sampleCount: 3)
        XCTAssertNotNil(store.damagedProfilesNotice)
        store.deleteAllProfiles()
        XCTAssertNil(store.damagedProfilesNotice)
        XCTAssertEqual(try backups(in: dir), [])
    }

    // MARK: - Deletion observers

    /// Deleting is a privacy action, and the store is not the only place the
    /// data lives: `LiveSpeakerDiarizer` was seeded with these centroids at
    /// record-start and keeps its own copy. The notification is what lets a
    /// recording already in flight drop them — without it the deletion is
    /// undone at stop. `RecognisedSpeakerAssignerTests` drives the whole
    /// chain; these pin the store's half of it.
    func test_deleteAllProfiles_notifies_observers() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)
        store.updateProfile(name: "Alice", embedding: [1], sampleCount: 1)

        var seen: [SpeakerProfileStore.Deletion] = []
        store.addDeletionObserver { seen.append($0) }
        store.deleteAllProfiles()

        XCTAssertEqual(seen, [.all])
    }

    /// The case that most needs it. With the feature off the file is never
    /// parsed, so `profiles` is empty and the store cannot say *what* it
    /// deleted — `.all` is both the honest answer and the safe one. Firing
    /// only when something was in memory would skip exactly the user who
    /// switched the feature off and then deleted.
    func test_deleteAllProfiles_notifies_even_with_nothing_in_memory() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir, enabled: false)
        XCTAssertTrue(store.profiles.isEmpty, "precondition: nothing parsed while off")

        var seen: [SpeakerProfileStore.Deletion] = []
        store.addDeletionObserver { seen.append($0) }
        store.deleteAllProfiles()

        XCTAssertEqual(seen, [.all])
    }

    func test_deleteProfile_notifies_with_the_deleted_name() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)
        store.updateProfile(name: "Alice", embedding: [1], sampleCount: 1)
        store.updateProfile(name: "Bob", embedding: [2], sampleCount: 1)

        var seen: [SpeakerProfileStore.Deletion] = []
        store.addDeletionObserver { seen.append($0) }
        store.deleteProfile(name: "Alice")
        let bobID = try XCTUnwrap(store.profile(named: "Bob")?.id)
        store.deleteProfile(id: bobID)

        XCTAssertEqual(seen, [.named(["Alice"]), .named(["Bob"])])
    }

    /// A delete that removed nothing must not disturb an in-flight
    /// recording's pool.
    func test_a_delete_that_matches_nothing_does_not_notify() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)
        store.updateProfile(name: "Alice", embedding: [1], sampleCount: 1)

        var seen: [SpeakerProfileStore.Deletion] = []
        store.addDeletionObserver { seen.append($0) }
        XCTAssertEqual(store.deleteProfile(name: "Nobody"), .nothingToDelete)
        XCTAssertEqual(store.deleteProfile(id: UUID()), .nothingToDelete)

        XCTAssertTrue(seen.isEmpty)
        XCTAssertEqual(store.profiles.count, 1)
    }

    /// Two registrants, both heard — the mistake `addEnabledObserver`'s
    /// single-slot version made.
    func test_every_deletion_observer_is_called() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)

        var first = 0, second = 0
        store.addDeletionObserver { _ in first += 1 }
        store.addDeletionObserver { _ in second += 1 }
        store.deleteAllProfiles()

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 1)
    }

    func test_seedEntries_returns_all_profiles() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)

        store.updateProfile(name: "Alice", embedding: [1], sampleCount: 3)
        store.updateProfile(name: "Bob", embedding: [2], sampleCount: 5)

        let entries = store.seedEntries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].name, "Alice")
        XCTAssertEqual(entries[1].name, "Bob")
    }
}
