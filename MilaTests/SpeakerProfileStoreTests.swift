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
