import XCTest
@testable import Mila

/// Guards the shape of `MeetingDetector.supportedApps` — the table that
/// decides which apps get a meeting prompt. These are config invariants,
/// not behaviour: the state machine itself is covered by
/// `MeetingStopPromptTests`.
@MainActor
final class MeetingDetectorAppsTests: XCTestCase {

    func test_every_supported_app_has_a_detection_path() {
        for app in MeetingDetector.supportedApps {
            // Native apps (Zoom, Teams) use captureBundlePrefixes.
            // Browser apps use their own bundleID for mic-capture
            // matching (case-insensitive prefix against helper
            // processes) plus title hints as a fallback on older macOS.
            let hasCapturePrefixes = !app.captureBundlePrefixes.isEmpty
            let hasTitleFallback = !app.meetingTitleHints.isEmpty
            XCTAssertTrue(
                hasCapturePrefixes || hasTitleFallback,
                """
                \(app.displayName) has neither captureBundlePrefixes nor \
                meetingTitleHints — it can never be detected by any path.
                """
            )
        }
    }

    /// The live detector (Core Audio bundle IDs) and the saved-recording
    /// badge (`MeetingApp`) are separate types by design, but they must
    /// agree on identity: a capture started from a detected meeting has to
    /// resolve back to a badge-able app from the very bundle ID the
    /// detection fired on. Otherwise Mila prompts "you're in a Teams
    /// meeting" and then saves the recording with a generic speaker icon.
    func test_every_supported_app_maps_back_to_a_meeting_app_badge() {
        for app in MeetingDetector.supportedApps {
            XCTAssertNotNil(
                MeetingApp.matching(bundleID: app.bundleID),
                "No MeetingApp owns \(app.displayName)'s bundleID (\(app.bundleID))"
            )
            for prefix in app.captureBundlePrefixes {
                XCTAssertNotNil(
                    MeetingApp.matching(bundleID: prefix),
                    "No MeetingApp owns \(app.displayName)'s capture prefix (\(prefix))"
                )
            }
        }
    }

    func test_canonical_bundle_id_is_covered_by_its_own_capture_prefixes() {
        for app in MeetingDetector.supportedApps {
            // Browser apps have empty captureBundlePrefixes — they use
            // their bundleID directly for case-insensitive mic matching.
            guard !app.captureBundlePrefixes.isEmpty else { continue }
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
