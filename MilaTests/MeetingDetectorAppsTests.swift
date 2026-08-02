import XCTest
@testable import Mila

/// Guards the shape of `MeetingDetector.supportedApps` — the table that
/// decides which apps get a meeting prompt. These are config invariants,
/// not behaviour: the state machine itself is covered by
/// `MeetingStopPromptTests`.
@MainActor
final class MeetingDetectorAppsTests: XCTestCase {

    func test_every_supported_app_declares_a_capture_prefix() {
        for app in MeetingDetector.supportedApps {
            XCTAssertFalse(
                app.captureBundlePrefixes.isEmpty,
                """
                \(app.displayName) has no captureBundlePrefixes, so the \
                primary signal (Core Audio per-process mic capture) can \
                never fire for it. Window titles are a fallback, never the \
                main detection path.
                """
            )
        }
    }

    func test_canonical_bundle_id_is_covered_by_its_own_capture_prefixes() {
        for app in MeetingDetector.supportedApps {
            XCTAssertTrue(
                app.captureBundlePrefixes.contains { app.bundleID.hasPrefix($0) },
                """
                \(app.displayName)'s canonical bundleID (\(app.bundleID)) \
                matches none of its captureBundlePrefixes — the app \
                capturing under its own bundle ID would go undetected.
                """
            )
        }
    }

    func test_bundle_ids_are_unique() {
        let ids = MeetingDetector.supportedApps.map(\.bundleID)
        XCTAssertEqual(ids.count, Set(ids).count,
                       "Duplicate bundleIDs would collide in the silence / snooze keys")
    }

    /// A title hint must identify a *meeting*, not the app merely being
    /// open. Zoom's "zoom meeting" does; a bare "microsoft teams" would
    /// not — every Teams window carries it, so the fallback would read a
    /// day-long idle Teams as a permanent call. Teams therefore ships with
    /// no hints at all.
    func test_title_hints_are_meeting_specific_not_just_the_app_name() {
        for app in MeetingDetector.supportedApps {
            for hint in app.meetingTitleHints {
                XCTAssertNotEqual(
                    hint, app.displayName.lowercased(),
                    """
                    \(app.displayName)'s title hint is just its name, which \
                    matches any window it has open — the fallback would \
                    report a meeting whenever the app is running. Use a \
                    meeting-specific title, or no hint at all.
                    """
                )
                XCTAssertEqual(hint, hint.lowercased(),
                               "Hints are compared against a lowercased title")
            }
        }
    }

    func test_microsoft_teams_is_detected_by_mic_capture_only() {
        guard let teams = MeetingDetector.supportedApps
            .first(where: { $0.bundleID == "com.microsoft.teams2" }) else {
            return XCTFail("Microsoft Teams (com.microsoft.teams2) is not a supported app")
        }
        XCTAssertEqual(teams.captureBundlePrefixes, ["com.microsoft.teams2"])
        XCTAssertTrue(teams.meetingTitleHints.isEmpty,
                      "No Teams window title distinguishes a call from the app being open")
    }
}
