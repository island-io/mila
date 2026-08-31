import XCTest
@testable import Mila

/// Behaviour tests for the two signals that decide "you are in a meeting",
/// driven directly through the pure matchers
/// (`MeetingDetector.micCaptureIndicatesMeeting` /
/// `.titleIndicatesMeeting`) so no Core Audio, browser, microphone or Screen
/// Recording permission is involved.
///
/// `MeetingDetectorAppsTests` guards the *shape* of the app table and
/// `MeetingStopPromptTests` the start/end state machine; this file covers the
/// step between them — turning a set of mic-capturing bundle IDs, or a list of
/// window titles, into a detection.
///
/// Google Meet is the reason this file exists. Meet has no app of its own, so
/// its entry matches four host browsers and their helper processes, and both
/// the matching and the *non*-matching cases need pinning: a prefix broad
/// enough to catch a browser's helper is also broad enough to catch the wrong
/// app entirely.
@MainActor
final class MeetingDetectorBrowserDetectionTests: XCTestCase {

    // MARK: - Fixtures

    private static let meetID = "meet.google.com"
    private static let zoomID = "us.zoom.xos"
    private static let teamsID = "com.microsoft.teams2"

    /// Mila's own bundle ID (`project.yml`: `PRODUCT_BUNDLE_IDENTIFIER`).
    /// Hard-coded rather than read from `Bundle.main`, whose identifier under
    /// the test host is the host app's — the point is to pin the literal
    /// string the shipping app runs as.
    private static let milaBundleID = "io.island.whisper.IslandWhisper"

    private func supportedApp(_ bundleID: String) throws -> MeetingDetector.App {
        try XCTUnwrap(
            MeetingDetector.supportedApps.first { $0.bundleID == bundleID },
            "\(bundleID) is not in MeetingDetector.supportedApps"
        )
    }

    /// The bundle ID each browser's mic capture actually surfaces under.
    /// Browsers hand capture to a helper subprocess, so these are the IDs
    /// Core Audio reports — not the browsers' own.
    private let browserCaptureIDs: [(browser: String, capturingBundleID: String)] = [
        ("Chrome", "com.google.Chrome.helper (Renderer)"),
        ("Safari", "com.apple.WebKit.GPU"),
        ("Arc", "company.thebrowser.browser.helper"),
        ("Island", "io.island.Island.helper"),
    ]

    /// A Google Meet call as each browser titles its window: Chromium-based
    /// browsers append their own name, Safari and Arc show the page title
    /// alone. `Meet - <meeting code>` is the in-call title; the raw URL shows
    /// up in place of a title while the page is still loading.
    private let meetWindowTitles: [(browser: String, title: String)] = [
        ("Chrome", "Meet - abc-defg-hij - Google Chrome"),
        ("Safari", "Meet - abc-defg-hij"),
        ("Arc", "Meet - abc-defg-hij"),
        ("Island", "Meet - abc-defg-hij - Island"),
        ("Chrome, still loading", "meet.google.com/abc-defg-hij - Google Chrome"),
    ]

    // MARK: - Mic capture: Google Meet in each browser

    /// The primary path on macOS 14.4+. Each supported browser, capturing
    /// under its real helper bundle ID, must read as a Meet meeting.
    func test_google_meet_is_detected_when_any_supported_browser_captures_the_mic() throws {
        let meet = try supportedApp(Self.meetID)
        for (browser, capturingBundleID) in browserCaptureIDs {
            XCTAssertTrue(
                MeetingDetector.micCaptureIndicatesMeeting(
                    meet, capturing: [capturingBundleID]),
                """
                \(browser) capturing the mic as \(capturingBundleID) was not \
                read as a Google Meet call — Meet in \(browser) would never \
                prompt.
                """
            )
        }
    }

    /// A browser capturing under its own bundle ID (rather than a helper)
    /// counts too — which one is used varies by browser and version.
    func test_google_meet_is_detected_when_the_browser_itself_captures() throws {
        let meet = try supportedApp(Self.meetID)
        for bundleID in ["com.google.Chrome", "com.apple.Safari",
                         "company.thebrowser.Browser", "io.island.Island"] {
            XCTAssertTrue(
                MeetingDetector.micCaptureIndicatesMeeting(meet, capturing: [bundleID]),
                "\(bundleID) capturing the mic should read as a Google Meet call"
            )
        }
    }

    /// The regression that matters most, and the reason this file exists.
    ///
    /// Mila captures the microphone itself — while recording, and also while
    /// the Settings ▸ Audio Input VU meter is live (`InputLevelMonitor` opens
    /// its own `AVAudioEngine` input tap when Mila is *not* recording). Its
    /// bundle ID is `io.island.whisper.IslandWhisper`, so a Meet helper prefix
    /// of `io.island` — rather than `io.island.Island` for the Island browser
    /// — makes Mila detect *itself*: opening Mila's own audio settings pops a
    /// "Google Meet meeting detected — start transcribing?" prompt, and a mic
    /// drop mid-recording pops "meeting ended — stop recording?".
    ///
    /// No entry may claim Mila, by any of its three prefix lists.
    func test_mila_capturing_its_own_mic_is_never_a_meeting() {
        for app in MeetingDetector.supportedApps {
            XCTAssertFalse(
                MeetingDetector.micCaptureIndicatesMeeting(
                    app, capturing: [Self.milaBundleID]),
                """
                \(app.displayName) claims Mila's own bundle ID \
                (\(Self.milaBundleID)) as a meeting. Mila captures the mic \
                while recording and while the Settings VU meter runs, so this \
                prompts the user about their own audio settings pane. Narrow \
                the prefix (`io.island.Island`, not `io.island`).
                """
            )
        }
    }

    /// Nothing capturing ⇒ nothing detected. The empty set is the state the
    /// poll sees most of the time, so it must not match a zero-length prefix
    /// or an empty prefix list.
    func test_nothing_capturing_detects_nothing() {
        for app in MeetingDetector.supportedApps {
            XCTAssertFalse(
                MeetingDetector.micCaptureIndicatesMeeting(app, capturing: []),
                "\(app.displayName) detected a meeting with no process capturing audio"
            )
        }
    }

    /// Negative control on the *host* dimension: a browser capturing the mic
    /// must not be read as a Zoom or Teams call, and the native apps must not
    /// be read as Meet. Without this, "is anything capturing?" would pass the
    /// browser tests above just as well.
    func test_capture_by_one_app_is_not_attributed_to_another() throws {
        let meet = try supportedApp(Self.meetID)
        let zoom = try supportedApp(Self.zoomID)
        let teams = try supportedApp(Self.teamsID)

        for (browser, capturingBundleID) in browserCaptureIDs {
            XCTAssertFalse(
                MeetingDetector.micCaptureIndicatesMeeting(
                    zoom, capturing: [capturingBundleID]),
                "\(browser) (\(capturingBundleID)) was read as a Zoom meeting"
            )
            XCTAssertFalse(
                MeetingDetector.micCaptureIndicatesMeeting(
                    teams, capturing: [capturingBundleID]),
                "\(browser) (\(capturingBundleID)) was read as a Teams meeting"
            )
        }

        for nativeID in ["us.zoom.CptHost", "com.microsoft.teams2"] {
            XCTAssertFalse(
                MeetingDetector.micCaptureIndicatesMeeting(meet, capturing: [nativeID]),
                "\(nativeID) was read as a Google Meet call"
            )
        }
    }

    /// Unrelated mic users must not register as any meeting — including apps
    /// whose IDs merely *resemble* a supported one. `net.us.zoom.fake` and
    /// `io.islandapp.Browser` are the prefix-anchoring cases: a `contains`
    /// match would let the first through, and an `io.island` prefix (the bug
    /// pinned above) would let the second through. A Slack huddle is the
    /// realistic non-Meet call — a live audio session that is emphatically
    /// not Google Meet.
    func test_unrelated_mic_users_are_not_meetings() {
        let strangers: Set<String> = [
            "com.apple.Terminal",
            "com.tinyspeck.slackmacgap",
            "net.us.zoom.fake",
            "com.google.GoogleDrive",
            "com.island.something.else",
            "io.islandapp.Browser",
            "com.brave.Browser",
        ]
        for app in MeetingDetector.supportedApps {
            XCTAssertFalse(
                MeetingDetector.micCaptureIndicatesMeeting(app, capturing: strangers),
                "\(app.displayName) matched one of: \(strangers.sorted().joined(separator: ", "))"
            )
        }
    }

    /// Matching is case-insensitive on both sides: bundle IDs are
    /// conventionally lowercase, nothing enforces it, and the helper prefixes
    /// are written lowercase.
    func test_capture_matching_is_case_insensitive() throws {
        let meet = try supportedApp(Self.meetID)
        let zoom = try supportedApp(Self.zoomID)
        XCTAssertTrue(
            MeetingDetector.micCaptureIndicatesMeeting(
                meet, capturing: ["COM.GOOGLE.CHROME.HELPER"]),
            "An upper-cased Chrome helper ID should still match"
        )
        XCTAssertTrue(
            MeetingDetector.micCaptureIndicatesMeeting(zoom, capturing: ["US.ZOOM.XOS"]),
            "An upper-cased Zoom ID should still match"
        )
    }

    /// The pre-existing signal still works — this feature must not have
    /// narrowed it while widening the table.
    func test_native_apps_are_still_detected_by_their_own_capture() throws {
        let zoom = try supportedApp(Self.zoomID)
        let teams = try supportedApp(Self.teamsID)
        XCTAssertTrue(
            MeetingDetector.micCaptureIndicatesMeeting(zoom, capturing: ["us.zoom.CptHost"]),
            "Zoom's helper process must still be detected"
        )
        XCTAssertTrue(
            MeetingDetector.micCaptureIndicatesMeeting(teams, capturing: ["com.microsoft.teams2"]),
            "Teams must still be detected by mic capture"
        )
    }

    // MARK: - Window titles: the macOS < 14.4 fallback

    /// The fallback path. A Meet call in each browser, titled the way that
    /// browser titles it, must be recognised.
    func test_google_meet_is_detected_from_each_browsers_window_title() throws {
        let meet = try supportedApp(Self.meetID)
        for (browser, title) in meetWindowTitles {
            XCTAssertTrue(
                MeetingDetector.titleIndicatesMeeting(meet, titles: [title]),
                "\(browser)'s in-call window title \"\(title)\" was not recognised as Meet"
            )
        }
    }

    /// A Meet call in one window among several ordinary ones still counts —
    /// the user has other windows open.
    func test_a_meet_window_among_other_windows_is_detected() throws {
        let meet = try supportedApp(Self.meetID)
        let titles = [
            "Inbox (12) - name@example.com - Google Chrome",
            "Meet - abc-defg-hij - Google Chrome",
            "Untitled - TextEdit",
        ]
        XCTAssertTrue(
            MeetingDetector.titleIndicatesMeeting(meet, titles: titles),
            "A Meet window alongside other windows should still be detected"
        )
    }

    /// Negative control for the title path: ordinary browsing must not read
    /// as a call. "Meet the team" is the deliberately deceptive one — a page
    /// whose title starts with the word *meet* — and it must not match,
    /// because the hint is `meet -` (the `Meet - <code>` in-call shape), not
    /// a bare `meet`. Nor may a support article *about* Meet match.
    func test_ordinary_browser_windows_are_not_meetings() throws {
        let meet = try supportedApp(Self.meetID)
        let innocent = [
            "Inbox (12) - name@example.com - Google Chrome",
            "Meet the team - Acme Corp - Google Chrome",
            "Meeting notes.md - Obsidian",
            "google.com - Google Chrome",
            "YouTube - Google Chrome",
            "New Tab - Google Chrome",
            "Google Meet: how to join a call - Support - Safari",
        ]
        for title in innocent {
            XCTAssertFalse(
                MeetingDetector.titleIndicatesMeeting(meet, titles: [title]),
                "\"\(title)\" was read as an active Google Meet call"
            )
        }
        XCTAssertFalse(
            MeetingDetector.titleIndicatesMeeting(meet, titles: innocent),
            "No window in an ordinary browsing session is a Meet call"
        )
    }

    /// No windows at all (the Screen Recording permission is missing, so
    /// titles come back empty) must read as "no meeting", never as a match.
    func test_no_window_titles_detects_nothing() {
        for app in MeetingDetector.supportedApps {
            XCTAssertFalse(
                MeetingDetector.titleIndicatesMeeting(app, titles: []),
                """
                \(app.displayName) reported a meeting from an empty title \
                list — that is the no-Screen-Recording-permission case, and \
                it must fail closed.
                """
            )
        }
    }

    /// An app that declares no hints opts out of the title path entirely, and
    /// an empty hint list must never be read as "match anything". Teams is
    /// the case: every Teams window is titled "… | Microsoft Teams", so no
    /// hint can tell a call from the app merely being open.
    func test_teams_opts_out_of_title_detection() throws {
        let teams = try supportedApp(Self.teamsID)
        XCTAssertTrue(teams.meetingTitleHints.isEmpty,
                      "Teams is deliberately title-hint-free")
        XCTAssertFalse(
            MeetingDetector.titleIndicatesMeeting(
                teams,
                titles: ["Chat | Microsoft Teams", "Calendar | Microsoft Teams"]),
            "Teams must not be detected from a window title"
        )
    }

    /// Zoom's own title hint still works, and is still specific to a meeting
    /// window rather than the app being open.
    func test_zoom_title_detection_is_unchanged() throws {
        let zoom = try supportedApp(Self.zoomID)
        XCTAssertTrue(
            MeetingDetector.titleIndicatesMeeting(zoom, titles: ["Zoom Meeting"]),
            "Zoom's meeting window title must still be recognised"
        )
        XCTAssertFalse(
            MeetingDetector.titleIndicatesMeeting(zoom, titles: ["Zoom Workplace"]),
            "Zoom's idle window must not read as a meeting"
        )
    }

    // MARK: - Browser-hosted flag

    /// `isBrowserHosted` drives whether minimized windows are searched. Meet
    /// needs them (minimizing the browser mid-call must not end the meeting);
    /// the native apps keep the narrower on-screen-only search they had.
    func test_only_browser_hosted_entries_search_minimized_windows() throws {
        XCTAssertTrue(try supportedApp(Self.meetID).isBrowserHosted,
                      "Google Meet is hosted in a browser, so minimized windows must count")
        XCTAssertFalse(try supportedApp(Self.zoomID).isBrowserHosted)
        XCTAssertFalse(try supportedApp(Self.teamsID).isBrowserHosted)
    }
}
