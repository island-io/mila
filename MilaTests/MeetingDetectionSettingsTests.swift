import XCTest
import Combine
@testable import Mila

@MainActor
final class MeetingDetectionSettingsTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let suite = "MeetingDetectionSettingsTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func test_enabled_changes_delivers_revocation_before_the_setter_returns() {
        let settings = MeetingDetectionSettings(defaults: freshDefaults())
        var values: [Bool] = []
        let observation = settings.enabledChanges.sink { values.append($0) }
        defer { observation.cancel() }
        settings.enabled = false
        XCTAssertEqual(values, [true, false])
        XCTAssertFalse(settings.enabled)
    }

    func test_managed_detection_refuses_enable_without_publishing_or_persisting_it() {
        let defaults = freshDefaults()
        defaults.set(false, forKey: "meetingDetection.enabled")
        var managed = ManagedSettings.empty
        managed.meetingDetectionEnabled = false
        let settings = MeetingDetectionSettings(defaults: defaults, managed: managed)
        var values: [Bool] = []
        let observation = settings.enabledChanges.sink { values.append($0) }
        defer { observation.cancel() }
        settings.enabled = true
        XCTAssertEqual(values, [false])
        XCTAssertFalse(settings.enabled)
        XCTAssertFalse(defaults.bool(forKey: "meetingDetection.enabled"))
    }

    func test_enabled_defaults_on_for_first_launch() {
        let s = MeetingDetectionSettings(defaults: freshDefaults())
        XCTAssertTrue(s.enabled, "Detection should default ON so users discover it")
    }

    func test_disable_then_reenable_bundle_id() {
        let s = MeetingDetectionSettings(defaults: freshDefaults())
        XCTAssertFalse(s.isDisabled(forBundleID: "us.zoom.xos"))

        s.disable(bundleID: "us.zoom.xos")
        XCTAssertTrue(s.isDisabled(forBundleID: "us.zoom.xos"))

        s.reenable(bundleID: "us.zoom.xos")
        XCTAssertFalse(s.isDisabled(forBundleID: "us.zoom.xos"))
    }

    func test_disabled_bundle_ids_persist_across_re_init() {
        let defaults = freshDefaults()
        do {
            let s = MeetingDetectionSettings(defaults: defaults)
            s.disable(bundleID: "us.zoom.xos")
        }
        let reloaded = MeetingDetectionSettings(defaults: defaults)
        XCTAssertTrue(reloaded.isDisabled(forBundleID: "us.zoom.xos"),
                      "Silenced apps should survive a relaunch")
    }

    func test_disable_empty_bundle_id_is_noop() {
        let s = MeetingDetectionSettings(defaults: freshDefaults())
        s.disable(bundleID: "")
        XCTAssertFalse(s.isDisabled(forBundleID: ""))
        XCTAssertTrue(s.disabledBundleIDs.isEmpty)
    }

    // MARK: - Auto-start

    func test_autoStart_defaults_to_empty() {
        let s = MeetingDetectionSettings(defaults: freshDefaults())
        XCTAssertFalse(s.isAutoStart(forBundleID: "us.zoom.xos"))
        XCTAssertTrue(s.autoStartBundleIDs.isEmpty)
    }

    func test_autoStart_toggle_on_off() {
        let s = MeetingDetectionSettings(defaults: freshDefaults())
        s.setAutoStart(bundleID: "us.zoom.xos", enabled: true)
        XCTAssertTrue(s.isAutoStart(forBundleID: "us.zoom.xos"))

        s.setAutoStart(bundleID: "us.zoom.xos", enabled: false)
        XCTAssertFalse(s.isAutoStart(forBundleID: "us.zoom.xos"))
    }

    func test_autoStart_persists_across_reinit() {
        let defaults = freshDefaults()
        do {
            let s = MeetingDetectionSettings(defaults: defaults)
            s.setAutoStart(bundleID: "us.zoom.xos", enabled: true)
        }
        let reloaded = MeetingDetectionSettings(defaults: defaults)
        XCTAssertTrue(reloaded.isAutoStart(forBundleID: "us.zoom.xos"),
                      "Auto-start should survive a relaunch")
    }
}
