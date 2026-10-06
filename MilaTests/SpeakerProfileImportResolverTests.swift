import XCTest
@testable import Mila

/// The resolver is pure, so these run with no store and no settings suite.
final class SpeakerProfileImportResolverTests: XCTestCase {

    private let model = SpeakerEmbeddingModel.current

    private func vector(_ head: [Float]) -> [Float] {
        head + [Float](repeating: 0, count: model.dimension - head.count)
    }

    private func local(_ name: String, _ head: [Float], samples: Int = 3,
                       tokens: [ImportedShareToken] = []) -> VoiceProfile {
        VoiceProfile(id: UUID(), name: name, embedding: vector(head), sampleCount: samples,
                     createdAt: Date(), lastSeenAt: Date(), embeddingModel: model.id,
                     importedShares: tokens)
    }

    private func incoming(_ name: String, _ head: [Float], samples: Int = 2,
                          modelID: String? = nil) -> SharedSpeakerProfile {
        SharedSpeakerProfile(name: name, embedding: vector(head), sampleCount: samples,
                             embeddingModel: modelID ?? model.id)
    }

    private func context(_ locals: [VoiceProfile], enabled: Bool = true, configured: Bool = true,
                         threshold: Double = 0.55, sender: String? = "Daniel Solomon",
                         imported: Set<ImportedShareToken> = []) -> SpeakerProfileImportResolver.Context {
        .init(localProfiles: locals, isEnabled: enabled, isConfigured: configured,
              similarityThreshold: threshold, senderDisplayName: sender, alreadyImported: imported)
    }

    private func resolve(_ shared: [SharedSpeakerProfile],
                         names: [String: String] = [:],
                         bundleKey: String = "bundle-1",
                         _ ctx: SpeakerProfileImportResolver.Context) -> SpeakerProfileImportPlan {
        SpeakerProfileImportResolver.resolve(incoming: shared, speakerNames: names,
                                             bundleKey: bundleKey, context: ctx)
    }

    // MARK: - Suggestions

    func test_a_voice_match_above_threshold_wins_over_a_different_name() {
        let dan = local("Dan", [1, 0])
        let plan = resolve([incoming("Daniel", [0.99, 0.01])], context([dan, local("Grace", [0, 1])]))
        let row = plan.rows[0]
        XCTAssertEqual(row.target, .merge(into: dan.id))
        XCTAssertFalse(row.suggestionWarns)
        XCTAssertTrue(row.suggestionReason.contains("Dan"), row.suggestionReason)
        XCTAssertTrue(row.suggestionReason.contains("%"), row.suggestionReason)
    }

    func test_a_same_name_profile_below_threshold_is_suggested_with_a_warning() {
        let alex = local("Alex", [1, 0])
        let plan = resolve([incoming("alex", [0, 1])], context([alex]))
        let row = plan.rows[0]
        XCTAssertEqual(row.target, .merge(into: alex.id))
        XCTAssertTrue(row.suggestionWarns)
        XCTAssertTrue(row.suggestionReason.contains("Same name"), row.suggestionReason)
        XCTAssertTrue(row.candidates[0].nameMatches)
    }

    func test_no_match_adds_as_new_under_the_senders_name_when_it_is_free() {
        let plan = resolve([incoming("Ada", [0, 1])], context([local("Dan", [1, 0])]))
        let row = plan.rows[0]
        XCTAssertEqual(row.target, .addAsNew(name: "Ada"))
        XCTAssertEqual(row.suggestedNewName, "Ada")
        XCTAssertFalse(row.suggestionWarns)
    }

    func test_every_non_blocked_row_offers_every_local_profile_sorted_by_similarity() {
        let locals = [local("Far", [0, 1]), local("Near", [1, 0.1]), local("Nearest", [1, 0])]
        let plan = resolve([incoming("Someone", [1, 0]), incoming("Nobody", [0, 0, 1])], context(locals))
        for row in plan.rows {
            XCTAssertEqual(row.candidates.count, 3, "\(row.id) must list every local profile")
        }
        XCTAssertEqual(plan.rows.first { $0.id == "Someone" }?.candidates.map(\.profile.name),
                       ["Nearest", "Near", "Far"])
        // "Nobody" matched nothing, yet can still be merged anywhere.
        let nobody = plan.rows.first { $0.id == "Nobody" }!
        XCTAssertEqual(nobody.target, .addAsNew(name: "Nobody"))
        XCTAssertFalse(nobody.isBlocked)
    }

    func test_local_profiles_of_another_model_or_width_are_not_candidates() {
        var otherModel = local("Other", [1, 0])
        otherModel.embeddingModel = "some-future-model"
        let narrow = VoiceProfile(id: UUID(), name: "Narrow", embedding: [1, 0], sampleCount: 1,
                                  createdAt: Date(), lastSeenAt: Date())
        let legacyUnstamped = VoiceProfile(id: UUID(), name: "Legacy", embedding: vector([1, 0]),
                                           sampleCount: 1, createdAt: Date(), lastSeenAt: Date())
        let plan = resolve([incoming("X", [1, 0])], context([otherModel, narrow, legacyUnstamped]))
        XCTAssertEqual(plan.rows[0].candidates.map(\.profile.name), ["Legacy"],
                       "an unstamped legacy row counts as the current model; the others cannot be folded into")
    }

    // MARK: - New-name suggestions

    func test_suggested_new_name_is_de_collided_against_locals_and_other_rows() {
        let locals = [local("Alex", [1, 0]), local("Alex (from Daniel)", [0, 1])]
        // Two incoming rows that both end up wanting "Alex …" — spelled with
        // different case so they are distinct rows but collide on name.
        let plan = resolve([incoming("Alex", [0, 0, 1]), incoming("ALEX", [0, 0, 0, 1])],
                           context(locals, threshold: 0.99))
        let names = plan.rows.map(\.suggestedNewName)
        XCTAssertEqual(Set(names).count, 2, "rows must not share a new name: \(names)")
        for name in names {
            XCTAssertFalse(locals.map { $0.name.lowercased() }.contains(name.lowercased()), name)
            XCTAssertTrue(name.hasPrefix("Alex (from Daniel)") || name.hasPrefix("ALEX (from Daniel)"), name)
        }
    }

    func test_suggested_new_name_without_a_sender_uses_shared() {
        XCTAssertEqual(SpeakerProfileImportResolver.suggestedNewName(
            for: "Alex", sender: nil, localNames: ["Alex"], taken: []), "Alex (shared)")
        XCTAssertEqual(SpeakerProfileImportResolver.suggestedNewName(
            for: "Alex", sender: "  ", localNames: ["alex", "Alex (shared)"], taken: []), "Alex (shared) 2")
    }

    // MARK: - Blockers and "already imported"

    func test_voice_recognition_off_blocks_every_row() {
        let plan = resolve([incoming("A", [1, 0]), incoming("B", [0, 1])],
                           context([local("Dan", [1, 0])], enabled: false))
        for row in plan.rows {
            XCTAssertEqual(row.blocker, .voiceRecognitionOff)
            XCTAssertEqual(row.target, .skip)
            XCTAssertTrue(row.isBlocked)
        }
    }

    func test_enabled_but_not_configured_blocks_with_not_ready() {
        let plan = resolve([incoming("A", [1, 0])], context([], enabled: true, configured: false))
        XCTAssertEqual(plan.rows[0].blocker, .voiceRecognitionNotReady)
    }

    func test_unknown_model_wrong_width_and_invalid_profiles_are_blocked() {
        let unknown = incoming("U", [1, 0], modelID: "model-from-the-future")
        let narrow = SharedSpeakerProfile(name: "N", embedding: [1, 0], sampleCount: 1, embeddingModel: model.id)
        let zeroSamples = incoming("Z", [1, 0], samples: 0)
        let blank = incoming("   ", [1, 0])
        let plan = resolve([unknown, narrow, zeroSamples, blank], context([local("Dan", [1, 0])]))

        let byName = Dictionary(uniqueKeysWithValues: plan.rows.map { ($0.id, $0) })
        XCTAssertEqual(byName["U"]?.blocker, .unknownEmbeddingModel("model-from-the-future"))
        XCTAssertEqual(byName["N"]?.blocker, .dimensionMismatch(found: 2, expected: model.dimension))
        if case .invalidProfile = byName["Z"]?.blocker {} else { XCTFail("\(String(describing: byName["Z"]?.blocker))") }
        if case .invalidProfile = byName[""]?.blocker {} else { XCTFail("\(String(describing: byName[""]?.blocker))") }
        XCTAssertTrue(plan.rows.allSatisfy { $0.target == .skip })
    }

    func test_already_imported_defaults_to_skip_but_is_not_blocked() {
        let dan = local("Dan", [1, 0])
        let token = ImportedShareToken(bundleKey: "bundle-1", sharedName: "Daniel")
        let plan = resolve([incoming("Daniel", [1, 0])], bundleKey: "bundle-1",
                           context([dan], imported: [token]))
        let row = plan.rows[0]
        XCTAssertTrue(row.alreadyImported)
        XCTAssertEqual(row.target, .skip)
        XCTAssertFalse(row.isBlocked, "the user may still merge or add")
        XCTAssertEqual(row.candidates.map(\.id), [dan.id])

        let other = resolve([incoming("Daniel", [1, 0])], bundleKey: "bundle-2",
                            context([dan], imported: [token]))
        XCTAssertFalse(other.rows[0].alreadyImported, "a different bundle is a different import")
    }

    // MARK: - Shape

    func test_rows_are_sorted_deduped_and_carry_their_raw_ids() {
        let plan = resolve([incoming("zed", [1, 0]), incoming("Ada", [0, 1]), incoming("Ada", [0, 1])],
                           names: ["SPEAKER_02": "Ada", "SPEAKER_00": "Ada", "SPEAKER_01": "Bob"],
                           context([]))
        XCTAssertEqual(plan.rows.map(\.id), ["Ada", "zed"])
        XCTAssertEqual(plan.rows[0].rawIDs, ["SPEAKER_00", "SPEAKER_02"])
        XCTAssertEqual(plan.rows[1].rawIDs, [])
        XCTAssertEqual(plan.bundleKey, "bundle-1")
        XCTAssertEqual(plan.similarityThreshold, 0.55)
    }
}
