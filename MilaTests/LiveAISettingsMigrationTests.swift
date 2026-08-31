import XCTest
@testable import Mila

/// Regression tests for `LiveAISettings.init`'s persisted-value migrations.
///
/// Two init-time "migrate the old default" rules were written against value
/// RANGES that the current Settings sliders legitimately offer, so they
/// silently discarded the user's chosen value on every launch:
///
///  * `chunkSeconds`: the pre-1.6.1 migration treated anything below 25s as
///    stale — but the tick-frequency slider offers 15–60s, so a chosen 15
///    or 20 reverted to 30 on relaunch, forever.
///  * `speakerSimilarityThreshold`: the "old 0.75 default" migration treated
///    anything ≥ 0.7 as stale on EVERY launch — but the slider offers up to
///    0.95, so a chosen 0.8 reverted to 0.55 on relaunch, forever. (Worse:
///    `didSet` doesn't fire in init, so defaults kept the 0.8 while the app
///    ran with 0.55 — UI and persisted state permanently disagreed.)
@MainActor
final class LiveAISettingsMigrationTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "LiveAISettingsMigrationTests.\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        if let suiteName { defaults.removePersistentDomain(forName: suiteName) }
        try await super.tearDown()
    }

    // MARK: - chunkSeconds

    func test_chunkSeconds_slider_minimum_survives_relaunch() {
        // 15s is the minimum the Settings slider (15...60) offers.
        defaults.set(15.0, forKey: "liveAI.chunkSeconds")
        let settings = LiveAISettings(defaults: defaults)
        XCTAssertEqual(settings.chunkSeconds, 15.0,
                       "A value the slider offers must round-trip a relaunch, not be 'migrated' back to 30")
    }

    func test_chunkSeconds_20_survives_relaunch() {
        defaults.set(20.0, forKey: "liveAI.chunkSeconds")
        let settings = LiveAISettings(defaults: defaults)
        XCTAssertEqual(settings.chunkSeconds, 20.0)
    }

    func test_chunkSeconds_pre161_value_still_migrates_to_30() {
        // The old default (5s) predates the 15s slider minimum — it must
        // still be migrated.
        defaults.set(5.0, forKey: "liveAI.chunkSeconds")
        let settings = LiveAISettings(defaults: defaults)
        XCTAssertEqual(settings.chunkSeconds, 30.0)
    }

    func test_chunkSeconds_unset_defaults_to_30() {
        let settings = LiveAISettings(defaults: defaults)
        XCTAssertEqual(settings.chunkSeconds, 30.0)
    }

    // MARK: - speakerSimilarityThreshold

    func test_simThreshold_user_choice_above_070_survives_relaunch() {
        // First launch on this suite: runs the one-shot legacy migration
        // (and records that it ran).
        let first = LiveAISettings(defaults: defaults)
        XCTAssertEqual(first.speakerSimilarityThreshold, 0.55, accuracy: 0.0001)

        // The user drags the slider (0.5...0.95) to 0.8; didSet persists it.
        first.speakerSimilarityThreshold = 0.8

        // Relaunch: the choice must stick.
        let second = LiveAISettings(defaults: defaults)
        XCTAssertEqual(second.speakerSimilarityThreshold, 0.8, accuracy: 0.0001,
                       "A slider value ≥ 0.7 chosen after the one-shot migration must survive a relaunch")
    }

    func test_simThreshold_legacy_075_default_migrates_once_to_055() {
        // A pre-migration suite carrying the old 0.75 default.
        defaults.set(0.75, forKey: "liveAI.speakerSimilarityThreshold")
        let settings = LiveAISettings(defaults: defaults)
        XCTAssertEqual(settings.speakerSimilarityThreshold, 0.55, accuracy: 0.0001,
                       "The legacy 0.75 default must still be migrated on first launch")
        // And the migration is recorded + written back, so it never re-runs.
        XCTAssertTrue(defaults.bool(forKey: "liveAI.speakerSimilarityThreshold.migrated"))
        XCTAssertEqual(defaults.double(forKey: "liveAI.speakerSimilarityThreshold"), 0.55,
                       accuracy: 0.0001)
    }

    func test_simThreshold_legacy_sub_070_value_is_preserved_by_migration() {
        defaults.set(0.6, forKey: "liveAI.speakerSimilarityThreshold")
        let settings = LiveAISettings(defaults: defaults)
        XCTAssertEqual(settings.speakerSimilarityThreshold, 0.6, accuracy: 0.0001)
    }

    func test_simThreshold_unset_defaults_to_055() {
        let settings = LiveAISettings(defaults: defaults)
        XCTAssertEqual(settings.speakerSimilarityThreshold, 0.55, accuracy: 0.0001)
    }

    // MARK: - summaryPrompt

    func test_summaryPrompt_unset_uses_new_default() {
        let settings = LiveAISettings(defaults: defaults)
        XCTAssertEqual(settings.summaryPrompt, LiveAISettings.defaultSummaryPrompt)
    }

    /// A user still carrying the pre-1.8.x concise default must be migrated
    /// up to the richer default so the summary regains its pre-#87 depth.
    func test_summaryPrompt_legacy_default_migrates_to_new_default() {
        defaults.set(LiveAISettings.legacySummaryPromptV1, forKey: "liveAI.summaryPrompt")
        let settings = LiveAISettings(defaults: defaults)
        XCTAssertEqual(settings.summaryPrompt, LiveAISettings.defaultSummaryPrompt,
                       "The legacy concise default must be migrated to the richer default")
    }

    /// A genuinely customised prompt must never be clobbered by the migration.
    func test_summaryPrompt_custom_value_is_preserved() {
        let custom = "Summarise in exactly three bullet points."
        defaults.set(custom, forKey: "liveAI.summaryPrompt")
        let settings = LiveAISettings(defaults: defaults)
        XCTAssertEqual(settings.summaryPrompt, custom,
                       "A user's customised summary prompt must survive the migration")
    }

    /// A user already on the new default keeps it (no spurious reset).
    func test_summaryPrompt_new_default_is_preserved() {
        defaults.set(LiveAISettings.defaultSummaryPrompt, forKey: "liveAI.summaryPrompt")
        let settings = LiveAISettings(defaults: defaults)
        XCTAssertEqual(settings.summaryPrompt, LiveAISettings.defaultSummaryPrompt)
    }
}
