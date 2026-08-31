import XCTest
@testable import Mila

final class MeetingAppTests: XCTestCase {
    func test_every_case_has_non_empty_info() {
        for app in MeetingApp.allCases {
            XCTAssertFalse(app.info.displayName.isEmpty, "Missing displayName for \(app)")
            XCTAssertFalse(app.info.matchSubstring.isEmpty, "Missing matchSubstring for \(app)")
            XCTAssertFalse(app.info.bundleIDPrefixes.isEmpty,
                           "Missing bundleIDPrefixes for \(app) — the authoritative signal")
            for prefix in app.info.bundleIDPrefixes {
                XCTAssertEqual(prefix, prefix.lowercased(),
                               "bundleIDPrefixes are compared against a lowercased bundle ID")
            }
            XCTAssertEqual(app.info.matchSubstring, app.info.matchSubstring.lowercased(),
                           "matchSubstring is compared against lowercased text")
        }
    }

    func test_matching_bundle_id_is_prefix_based_and_case_insensitive() {
        XCTAssertEqual(MeetingApp.matching(bundleID: "com.microsoft.teams2"), .teams)
        XCTAssertEqual(MeetingApp.matching(bundleID: "COM.MICROSOFT.TEAMS2"), .teams)
        XCTAssertEqual(MeetingApp.matching(bundleID: "us.zoom.xos"), .zoom)
        // Zoom captures under a helper bundle ID rather than us.zoom.xos —
        // the same reason MeetingDetector matches capture IDs by prefix.
        XCTAssertEqual(MeetingApp.matching(bundleID: "us.zoom.CptHost"), .zoom)
    }

    /// The bundle-ID match must anchor at the start. A `contains` match would
    /// let anything merely embedding a known ID (`net.us.zoom.fake`) or
    /// merely resembling one (`com.microsoftteams.clone`) through.
    func test_matching_bundle_id_rejects_lookalike_identifiers() {
        for bundleID in ["com.teamspeak.TeamSpeak",
                         "com.example.teams",
                         "com.microsoftteams.clone",
                         "net.us.zoom.fake",
                         "com.apple.Safari"] {
            XCTAssertNil(MeetingApp.matching(bundleID: bundleID),
                         "\(bundleID) is not a known meeting app")
        }
    }

    /// The substring fallbacks are the loosest signal in
    /// `Recording.detectedMeetingApp`, so each one has to be specific enough
    /// that an unrelated app name can't collide with it.
    func test_match_substrings_do_not_collide_with_unrelated_app_names() {
        for name in ["TeamSpeak", "Dream Teams", "teams sync notes",
                     "Steam", "Safari", "Notes"] {
            XCTAssertNil(MeetingApp.matching(text: name),
                         "\(name) must not be read as a meeting app")
        }
    }

    func test_matching_text_finds_real_app_names_case_insensitively() {
        XCTAssertEqual(MeetingApp.matching(text: "Microsoft Teams"), .teams)
        XCTAssertEqual(MeetingApp.matching(text: "microsoft teams (work)"), .teams)
        XCTAssertEqual(MeetingApp.matching(text: "zoom.us"), .zoom)
        XCTAssertEqual(MeetingApp.matching(text: "Zoom Workplace"), .zoom)
    }

    func test_match_substrings_are_unique() {
        let substrings = MeetingApp.allCases.map(\.info.matchSubstring)
        XCTAssertEqual(substrings.count, Set(substrings).count,
                       "Duplicate matchSubstring values would make detectedMeetingApp ambiguous")
    }

    func test_zoom_and_teams_cases_exist_with_expected_display_names() {
        XCTAssertEqual(MeetingApp.zoom.info.displayName, "Zoom")
        XCTAssertEqual(MeetingApp.teams.info.displayName, "Microsoft Teams")
        XCTAssertEqual(MeetingApp.googleMeet.info.displayName, "Google Meet")
    }

    /// Google Meet's only bundle-ID prefix is the detector's synthetic
    /// `meet.google.com`, so a recording that came from a detected Meet call
    /// still gets the Meet badge.
    func test_matching_bundle_id_finds_google_meet_by_its_synthetic_id() {
        XCTAssertEqual(MeetingApp.matching(bundleID: "meet.google.com"), .googleMeet)
        XCTAssertEqual(MeetingApp.matching(bundleID: "MEET.GOOGLE.COM"), .googleMeet)
    }

    /// The browsers that *host* Meet must never be listed as Meet's bundle-ID
    /// prefixes. A browser's bundle ID says the recording came from a browser,
    /// not that it came from a Google Meet call, so listing them would badge
    /// every Chrome or Safari system-audio capture as a Meet meeting — and
    /// `io.island` would badge one as Meet because Mila's own bundle ID
    /// (`io.island.whisper.IslandWhisper`) starts with it.
    ///
    /// `test_matching_bundle_id_rejects_lookalike_identifiers` above already
    /// pins Safari; this covers the rest of the browsers and Mila itself.
    func test_host_browsers_are_not_badged_as_google_meet() {
        for bundleID in ["com.google.Chrome", "com.apple.Safari",
                         "company.thebrowser.Browser", "io.island.Island",
                         "io.island.whisper.IslandWhisper"] {
            XCTAssertNil(
                MeetingApp.matching(bundleID: bundleID),
                """
                \(bundleID) is a browser (or Mila itself), not evidence of a \
                Google Meet call — it must not carry the Meet badge.
                """
            )
        }
    }
}
