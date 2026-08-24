import XCTest
@testable import Mila

@MainActor
final class SpeakerProfileStoreTests: XCTestCase {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerProfileStoreTests-\(UUID().uuidString)")
    }

    func test_updateProfile_creates_new_profile() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SpeakerProfileStore(directory: dir)

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
        let store = SpeakerProfileStore(directory: dir)

        store.updateProfile(name: "Alice", embedding: [1, 0], sampleCount: 1)
        store.updateProfile(name: "Alice", embedding: [0, 1], sampleCount: 1)

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].sampleCount, 2)
        // Weighted average: (1*1 + 0*1)/2 = 0.5, (0*1 + 1*1)/2 = 0.5
        XCTAssertEqual(store.profiles[0].embedding[0], 0.5, accuracy: 0.001)
        XCTAssertEqual(store.profiles[0].embedding[1], 0.5, accuracy: 0.001)
    }

    func test_updateProfile_rejects_dimension_mismatch() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SpeakerProfileStore(directory: dir)

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
        let store = SpeakerProfileStore(directory: dir)

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
        let store = SpeakerProfileStore(directory: dir)

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
        let store = SpeakerProfileStore(directory: dir)

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
        let store = SpeakerProfileStore(directory: dir)

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
            let store = SpeakerProfileStore(directory: dir)
            store.updateProfile(name: "Alice", embedding: [1, 2, 3], sampleCount: 5)
        }

        let reloaded = SpeakerProfileStore(directory: dir)
        XCTAssertEqual(reloaded.profiles.count, 1)
        XCTAssertEqual(reloaded.profiles[0].name, "Alice")
        XCTAssertEqual(reloaded.profiles[0].embedding, [1, 2, 3])
        XCTAssertEqual(reloaded.profiles[0].sampleCount, 5)
    }

    func test_seedEntries_returns_all_profiles() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SpeakerProfileStore(directory: dir)

        store.updateProfile(name: "Alice", embedding: [1], sampleCount: 3)
        store.updateProfile(name: "Bob", embedding: [2], sampleCount: 5)

        let entries = store.seedEntries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].name, "Alice")
        XCTAssertEqual(entries[1].name, "Bob")
    }
}
