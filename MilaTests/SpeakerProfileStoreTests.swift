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

        store.deleteProfile(name: "Alice")

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].name, "Bob")
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
        store.deleteProfile(name: "Nobody")
        store.deleteProfile(id: UUID())

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
