import XCTest
@testable import Mila

/// Guards the shape of `MeetingDetector.supportedApps` — the table that
/// decides which apps get a meeting prompt. These are config invariants,
/// not behaviour: the state machine itself is covered by
/// `MeetingStopPromptTests`.
@MainActor
final class MeetingDetectorAppsTests: XCTestCase {

    /// Every app must be reachable by the PRIMARY signal (Core Audio
    /// per-process mic capture). Window titles remain a fallback, never the
    /// main detection path — the same invariant this test has always held,
    /// widened only in *where* the bundle IDs may come from.
    ///
    /// Native apps (Zoom, Teams) declare `captureBundlePrefixes`. A
    /// browser-hosted entry (Google Meet) declares none, because it captures
    /// under a host browser's ID — so for it the primary signal is
    /// `appBundleIDs` plus `helperBundlePrefixes`. An entry with all three
    /// empty can only ever be detected on macOS < 14.4, which is not a
    /// feature anyone would ship on purpose.
    func test_every_supported_app_is_reachable_by_mic_capture() {
        for app in MeetingDetector.supportedApps {
            let micCaptureIDs =
                app.captureBundlePrefixes + app.appBundleIDs + app.helperBundlePrefixes
            XCTAssertFalse(
                micCaptureIDs.isEmpty,
                """
                \(app.displayName) declares no bundle IDs for the mic-capture \
                path, so the primary signal can never fire for it. Window \
                titles are a fallback (macOS < 14.4), never the main \
                detection path.
                """
            )
        }
    }

    /// Google Meet is not an app — it is a tab. The entry has to name the
    /// browsers that host it, or `isRunning` / the window-title fallback have
    /// nothing to look at, and the mic-capture path has no prefix to match.
    func test_google_meet_names_the_browsers_that_host_it() throws {
        let meet = try XCTUnwrap(
            MeetingDetector.supportedApps.first { $0.bundleID == "meet.google.com" },
            "Google Meet (meet.google.com) is not a supported app"
        )
        for browser in ["com.google.Chrome", "com.apple.Safari",
                        "company.thebrowser.Browser", "io.island.Island"] {
            XCTAssertTrue(meet.appBundleIDs.contains(browser),
                          "Google Meet does not list \(browser) as a host browser")
        }
        XCTAssertTrue(meet.captureBundlePrefixes.isEmpty,
                      "A browser-hosted entry captures under its host's ID, not its own")
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
