import XCTest
@testable import Mila

@MainActor
final class SpeakerProfileImportApplierTests: XCTestCase {

    private var dir: URL!
    private var suiteNames: [String] = []
    private let model = SpeakerEmbeddingModel.current

    override func setUp() async throws {
        try await super.setUp()
        dir = TestSupport.makeTempRoot(label: "SpeakerProfileImportApplierTests")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        try await super.tearDown()
    }

    private func makeStore(enabled: Bool = true) -> SpeakerProfileStore {
        let name = "SpeakerProfileImportApplierTests.\(UUID())"
        suiteNames.append(name)
        let settings = VoiceRecognitionSettings(defaults: UserDefaults(suiteName: name)!)
        settings.diarizationReady = { true }
        settings.isEnabled = enabled
        return SpeakerProfileStore(directory: dir, settings: settings)
    }

    private func vector(_ head: [Float]) -> [Float] {
        head + [Float](repeating: 0, count: model.dimension - head.count)
    }

    private func incoming(_ name: String, _ head: [Float], samples: Int) -> SharedSpeakerProfile {
        SharedSpeakerProfile(name: name, embedding: vector(head), sampleCount: samples,
                             embeddingModel: model.id)
    }

    private func plan(for store: SpeakerProfileStore, _ shared: [SharedSpeakerProfile],
                      bundleKey: String = "bundle-1") -> SpeakerProfileImportPlan {
        SpeakerProfileImportResolver.resolve(
            incoming: shared, speakerNames: [:], bundleKey: bundleKey,
            context: .init(localProfiles: store.profiles, isEnabled: store.settings.isEnabled,
                           isConfigured: store.settings.isConfigured, similarityThreshold: 0.55,
                           senderDisplayName: "Daniel", alreadyImported: store.importedShareTokens))
    }

    private var profilesFileBytes: Data? {
        try? Data(contentsOf: dir.appendingPathComponent("speaker-profiles.json"))
    }

    func test_merge_is_the_weighted_mean_and_stamps_a_token() {
        let store = makeStore()
        store.updateProfile(name: "Dan", embedding: vector([1, 0]), sampleCount: 2)
        let result = SpeakerProfileImportApplier.apply(
            plan(for: store, [incoming("Daniel", [0, 1], samples: 2)]).withTarget(.merge(into: store.profiles[0].id)),
            to: store)

        XCTAssertEqual(result.merged, 1)
        XCTAssertEqual(result.nameMapping, ["Daniel": "Dan"])
        let dan = store.profile(named: "Dan")!
        XCTAssertEqual(dan.sampleCount, 4)
        XCTAssertEqual(dan.embedding[0], 0.5, accuracy: 0.001)
        XCTAssertEqual(dan.embedding[1], 0.5, accuracy: 0.001)
        XCTAssertEqual(dan.importedShares, [ImportedShareToken(bundleKey: "bundle-1", sharedName: "Daniel")])
        XCTAssertEqual(store.profiles.count, 1)
    }

    func test_the_users_manual_pick_is_what_gets_merged() {
        let store = makeStore()
        store.updateProfile(name: "Close", embedding: vector([1, 0]), sampleCount: 1)
        store.updateProfile(name: "Far", embedding: vector([0, 1]), sampleCount: 1)
        var p = plan(for: store, [incoming("X", [1, 0], samples: 1)])
        XCTAssertEqual(p.rows[0].target, .merge(into: store.profile(named: "Close")!.id))
        p.rows[0].target = .merge(into: store.profile(named: "Far")!.id)   // the override

        let result = SpeakerProfileImportApplier.apply(p, to: store)
        XCTAssertEqual(result.nameMapping, ["X": "Far"])
        XCTAssertEqual(store.profile(named: "Far")?.sampleCount, 2)
        XCTAssertEqual(store.profile(named: "Close")?.sampleCount, 1)
    }

    func test_add_as_new_creates_a_profile_and_leaves_the_others_alone() {
        let store = makeStore()
        store.updateProfile(name: "Dan", embedding: vector([1, 0]), sampleCount: 2)
        let result = SpeakerProfileImportApplier.apply(
            plan(for: store, [incoming("Ada", [0, 1], samples: 3)]), to: store)
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.nameMapping, ["Ada": "Ada"])
        XCTAssertEqual(store.profiles.count, 2)
        let ada = store.profile(named: "Ada")!
        XCTAssertEqual(ada.sampleCount, 3)
        XCTAssertEqual(ada.embeddingModel, model.id)
        XCTAssertEqual(ada.importedShares.count, 1)
        XCTAssertEqual(store.profile(named: "Dan")?.sampleCount, 2)
    }

    func test_add_as_new_with_a_renamed_target_maps_the_label_to_the_new_name() {
        let store = makeStore()
        store.updateProfile(name: "Alex", embedding: vector([1, 0]), sampleCount: 2)
        var p = plan(for: store, [incoming("Alex", [0, 1], samples: 1)])
        XCTAssertTrue(p.rows[0].suggestionWarns, "same name, different voice")
        p.rows[0].target = .addAsNew(name: p.rows[0].suggestedNewName)   // keep both
        let result = SpeakerProfileImportApplier.apply(p, to: store)
        XCTAssertEqual(result.nameMapping, ["Alex": "Alex (from Daniel)"])
        XCTAssertNotNil(store.profile(named: "Alex (from Daniel)"))
        XCTAssertEqual(store.profile(named: "Alex")?.sampleCount, 2)
    }

    func test_skip_leaves_the_file_byte_identical() {
        let store = makeStore()
        store.updateProfile(name: "Dan", embedding: vector([1, 0]), sampleCount: 2)
        let before = profilesFileBytes
        var p = plan(for: store, [incoming("Daniel", [1, 0], samples: 5)])
        p.rows[0].target = .skip
        let result = SpeakerProfileImportApplier.apply(p, to: store)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.nameMapping, ["Daniel": "Daniel"])
        XCTAssertEqual(profilesFileBytes, before)
    }

    func test_re_applying_the_same_bundle_is_a_no_op() {
        let store = makeStore()
        store.updateProfile(name: "Dan", embedding: vector([1, 0]), sampleCount: 2)
        let shared = [incoming("Daniel", [1, 0], samples: 2), incoming("Ada", [0, 1], samples: 1)]
        _ = SpeakerProfileImportApplier.apply(plan(for: store, shared), to: store)
        let after = profilesFileBytes
        XCTAssertEqual(store.profile(named: "Dan")?.sampleCount, 4)

        let second = plan(for: store, shared)
        XCTAssertTrue(second.rows.allSatisfy { $0.alreadyImported && $0.target == .skip })
        let result = SpeakerProfileImportApplier.apply(second, to: store)
        XCTAssertEqual(result.skipped, 2)
        XCTAssertEqual(profilesFileBytes, after)
        XCTAssertEqual(store.profile(named: "Dan")?.sampleCount, 4, "no double count")
    }

    func test_a_merge_target_deleted_before_apply_is_skipped() {
        let store = makeStore()
        store.updateProfile(name: "Dan", embedding: vector([1, 0]), sampleCount: 2)
        let p = plan(for: store, [incoming("Daniel", [1, 0], samples: 1)])
        store.deleteProfile(name: "Dan")
        let result = SpeakerProfileImportApplier.apply(p, to: store)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.nameMapping, ["Daniel": "Daniel"])
        XCTAssertTrue(store.profiles.isEmpty)
    }

    func test_nothing_is_written_while_voice_recognition_is_off() {
        let store = makeStore(enabled: false)
        var p = plan(for: store, [incoming("Ada", [0, 1], samples: 1)])
        // Even a hand-forced target cannot get past the store's gate.
        p.rows[0].target = .addAsNew(name: "Ada")
        let result = SpeakerProfileImportApplier.apply(p, to: store)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertFalse(store.hasStoredProfilesOnDisk)
    }
}

private extension SpeakerProfileImportPlan {
    /// Set the first row's target — a test convenience.
    func withTarget(_ target: Target) -> SpeakerProfileImportPlan {
        var copy = self
        copy.rows[0].target = target
        return copy
    }
}
