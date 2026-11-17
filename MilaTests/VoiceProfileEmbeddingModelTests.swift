import XCTest
@testable import Mila

/// `VoiceProfile` gained a model stamp and import tokens for `.milashare`.
/// Both are additive: a legacy `speaker-profiles.json` must decode with
/// sensible defaults, and a profile that carries neither must encode
/// exactly as before.
@MainActor
final class VoiceProfileEmbeddingModelTests: XCTestCase {

    private var dir: URL!
    private var suiteNames: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        dir = TestSupport.makeTempRoot(label: "VoiceProfileEmbeddingModelTests")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        try await super.tearDown()
    }

    private func makeStore() -> SpeakerProfileStore {
        let name = "VoiceProfileEmbeddingModelTests.\(UUID())"
        suiteNames.append(name)
        let settings = VoiceRecognitionSettings(defaults: UserDefaults(suiteName: name)!)
        settings.diarizationReady = { true }
        settings.isEnabled = true
        return SpeakerProfileStore(directory: dir, settings: settings)
    }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    func test_a_legacy_row_decodes_with_the_current_model_and_no_tokens() throws {
        let legacy = """
        { "id": "11111111-2222-3333-4444-555555555555", "name": "Dan", "embedding": [1, 0],
          "sampleCount": 3, "createdAt": "2026-01-01T00:00:00Z", "lastSeenAt": "2026-01-02T00:00:00Z" }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let profile = try decoder.decode(VoiceProfile.self, from: legacy)
        XCTAssertNil(profile.embeddingModel)
        XCTAssertEqual(profile.effectiveEmbeddingModel, SpeakerEmbeddingModel.current.id)
        XCTAssertEqual(profile.importedShares, [])
    }

    func test_a_profile_without_stamp_or_tokens_encodes_without_the_new_keys() throws {
        let profile = VoiceProfile(id: UUID(), name: "Dan", embedding: [1, 0], sampleCount: 3,
                                   createdAt: Date(timeIntervalSince1970: 0), lastSeenAt: Date(timeIntervalSince1970: 0))
        let json = String(decoding: try encoder.encode(profile), as: UTF8.self)
        XCTAssertFalse(json.contains("embeddingModel"))
        XCTAssertFalse(json.contains("importedShares"))

        var stamped = profile
        stamped.embeddingModel = SpeakerEmbeddingModel.current.id
        stamped.importedShares = [ImportedShareToken(bundleKey: "b", sharedName: "Daniel")]
        let stampedJSON = String(decoding: try encoder.encode(stamped), as: UTF8.self)
        XCTAssertTrue(stampedJSON.contains("embeddingModel"))
        XCTAssertTrue(stampedJSON.contains("importedShares"))
    }

    func test_updateProfile_stamps_new_profiles_and_refuses_a_model_mismatch() {
        let store = makeStore()
        store.updateProfile(name: "Dan", embedding: [1, 0], sampleCount: 2)
        XCTAssertEqual(store.profiles[0].embeddingModel, SpeakerEmbeddingModel.current.id)

        store.updateProfile(name: "Dan", embedding: [0, 1], sampleCount: 2, embeddingModel: "other-model")
        XCTAssertEqual(store.profiles[0].sampleCount, 2, "the fold must be refused")
        XCTAssertEqual(store.profiles[0].embedding, [1, 0])

        store.updateProfile(name: "Dan", embedding: [0, 1], sampleCount: 2)
        XCTAssertEqual(store.profiles[0].sampleCount, 4, "same model folds as before")
    }

    func test_mergeProfiles_unions_tokens_and_refuses_a_model_mismatch() {
        let store = makeStore()
        store.updateProfile(name: "A", embedding: [1, 0], sampleCount: 1)
        store.updateProfile(name: "B", embedding: [0, 1], sampleCount: 1)
        store.recordImport(token: ImportedShareToken(bundleKey: "b1", sharedName: "A"), onProfileNamed: "A")
        store.recordImport(token: ImportedShareToken(bundleKey: "b2", sharedName: "B"), onProfileNamed: "B")
        XCTAssertEqual(store.importedShareTokens.count, 2)

        let merged = store.mergeProfiles(keep: "A", absorb: "B")
        XCTAssertEqual(merged?.importedShares.count, 2)
        XCTAssertEqual(store.importedShareTokens.count, 2)

        store.updateProfile(name: "C", embedding: [1, 1], sampleCount: 1, embeddingModel: "other-model")
        XCTAssertNil(store.mergeProfiles(keep: "A", absorb: "C"))
        XCTAssertEqual(store.profiles.count, 2)
    }

    func test_deleting_a_profile_forgets_its_imports() {
        let store = makeStore()
        store.updateProfile(name: "A", embedding: [1, 0], sampleCount: 1)
        let token = ImportedShareToken(bundleKey: "b1", sharedName: "A")
        store.recordImport(token: token, onProfileNamed: "A")
        XCTAssertTrue(store.importedShareTokens.contains(token))
        store.deleteProfile(name: "A")
        XCTAssertTrue(store.importedShareTokens.isEmpty, "re-importing the bundle is legitimately possible again")
    }

    func test_profiles_named_is_an_exact_sorted_read_gated_on_enabled() {
        let store = makeStore()
        store.updateProfile(name: "Zed", embedding: [1, 0], sampleCount: 1)
        store.updateProfile(name: "Ada", embedding: [1, 0], sampleCount: 1)
        store.updateProfile(name: "Bob", embedding: [1, 0], sampleCount: 1)
        XCTAssertEqual(store.profiles(named: ["Zed", " Ada ", "nobody"]).map(\.name), ["Ada", "Zed"])
        store.settings.isEnabled = false
        XCTAssertEqual(store.profiles(named: ["Zed"]), [])
    }
}
