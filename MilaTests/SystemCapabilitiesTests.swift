import XCTest
@testable import Mila

/// Unit tests for the MacBook Air hardware gate that suppresses the
/// Live AI live-transcript pane on Air-class chips. The bulk of the
/// surface is `SystemCapabilities`'s predicates and the
/// `LiveAISettings.isLiveAIAvailable` derivation built on top.
final class SystemCapabilitiesTests: XCTestCase {

    // MARK: - Live host-machine detection

    /// `SystemCapabilities.live` is whatever the sysctl/IOKit calls
    /// return on the host running the tests. We can't assert specific
    /// fields (CI runs on a variety of machines), but we can assert
    /// that the detection doesn't crash and returns something coherent
    /// — non-empty model id, plausible RAM, at least one CPU core.
    func test_live_detection_returns_coherent_values() {
        let caps = SystemCapabilities.live
        XCTAssertFalse(caps.modelIdentifier.isEmpty,
                       "hw.model should be non-empty on a real macOS host")
        XCTAssertGreaterThan(caps.physicalRamGB, 0,
                             "physical RAM should be > 0 GB")
        XCTAssertGreaterThan(caps.performanceCoreCount, 0,
                             "performance core count should be > 0")
    }

    /// Sanity check that the live detector returns the SAME value on
    /// repeated reads — hardware doesn't change at runtime, and any
    /// drift here would mean we're observing transient sysctl state.
    func test_live_detection_is_stable() {
        let a = SystemCapabilities.readFromHardware()
        let b = SystemCapabilities.readFromHardware()
        XCTAssertEqual(a, b)
    }

    // MARK: - isLiveAIRecommended predicate

    func test_isLiveAIRecommended_false_on_macbook_air() {
        let caps = SystemCapabilities(
            modelIdentifier: "Mac15,12",
            marketingName: "MacBook Air",
            isMacBookAir: true,
            physicalRamGB: 16,
            performanceCoreCount: 4
        )
        XCTAssertFalse(caps.isLiveAIRecommended)
    }

    func test_isLiveAIRecommended_true_on_macbook_pro() {
        let caps = SystemCapabilities(
            modelIdentifier: "Mac15,3",
            marketingName: "MacBook Pro",
            isMacBookAir: false,
            physicalRamGB: 32,
            performanceCoreCount: 8
        )
        XCTAssertTrue(caps.isLiveAIRecommended)
    }

    func test_isLiveAIRecommended_true_on_mac_mini() {
        let caps = SystemCapabilities(
            modelIdentifier: "Mac16,10",
            marketingName: "Mac mini",
            isMacBookAir: false,
            physicalRamGB: 16,
            performanceCoreCount: 6
        )
        XCTAssertTrue(caps.isLiveAIRecommended)
    }

    // MARK: - LiveAISettings.isLiveAIAvailable

    /// Off on MBA even when the LLM is configured AND the toggle is
    /// on. The hardware gate beats user preference because the
    /// pipeline simply doesn't keep up on Air-class chips.
    @MainActor
    func test_liveAISettings_isLiveAIAvailable_false_on_air() {
        let defaults = UserDefaults(suiteName: "test_liveAISettings_air.\(UUID())")!
        let air = SystemCapabilities(
            modelIdentifier: "Mac15,12",
            marketingName: "MacBook Air",
            isMacBookAir: true,
            physicalRamGB: 16,
            performanceCoreCount: 4
        )
        let settings = LiveAISettings(defaults: defaults, capabilities: air)
        settings.enabled = true
        XCTAssertFalse(settings.isLiveAIAvailable)
        XCTAssertFalse(settings.isLiveAIReady(llmConfigured: true))
    }

    /// On non-Air with LLM configured → ready. With LLM unconfigured →
    /// not ready (but available, since hardware is fine). The toggle
    /// is intentionally NOT part of the readiness signal; callers
    /// compose `isLiveAIReady && enabled` themselves.
    @MainActor
    func test_liveAISettings_isLiveAIReady_composes_hardware_and_llm() {
        let defaults = UserDefaults(suiteName: "test_liveAISettings_pro.\(UUID())")!
        let pro = SystemCapabilities(
            modelIdentifier: "Mac15,3",
            marketingName: "MacBook Pro",
            isMacBookAir: false,
            physicalRamGB: 32,
            performanceCoreCount: 10
        )
        let settings = LiveAISettings(defaults: defaults, capabilities: pro)
        XCTAssertTrue(settings.isLiveAIAvailable)
        XCTAssertTrue(settings.isLiveAIReady(llmConfigured: true),
                      "Pro + LLM configured → ready")
        XCTAssertFalse(settings.isLiveAIReady(llmConfigured: false),
                       "Pro + no LLM → not ready (but hardware is fine)")
    }

    /// `enabled` MUST round-trip across re-launches even on a Mac
    /// where Live AI isn't available — so taking the user's settings
    /// from an Air to a Pro restores the prior preference instead of
    /// silently flipping it off.
    @MainActor
    func test_liveAISettings_enabled_roundtrips_even_when_unavailable() {
        let suite = "test_liveAISettings_roundtrip.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let air = SystemCapabilities(
            modelIdentifier: "Mac15,12",
            marketingName: "MacBook Air",
            isMacBookAir: true,
            physicalRamGB: 16,
            performanceCoreCount: 4
        )
        do {
            let s = LiveAISettings(defaults: defaults, capabilities: air)
            s.enabled = true
        }
        // Re-open with the same suite — the bool should have persisted
        // regardless of the hardware availability gate.
        let reopened = LiveAISettings(defaults: defaults, capabilities: air)
        XCTAssertTrue(reopened.enabled,
                      "user's toggle preference should survive across launches even on Air")
        XCTAssertFalse(reopened.isLiveAIAvailable,
                       "...but availability is still false on Air")
    }
}
