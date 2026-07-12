import XCTest
@testable import Mila

final class MeetingAppTests: XCTestCase {
    func test_every_case_has_non_empty_info() {
        for app in MeetingApp.allCases {
            XCTAssertFalse(app.info.displayName.isEmpty, "Missing displayName for \(app)")
            XCTAssertFalse(app.info.matchSubstring.isEmpty, "Missing matchSubstring for \(app)")
        }
    }

    func test_match_substrings_are_unique() {
        let substrings = MeetingApp.allCases.map(\.info.matchSubstring)
        XCTAssertEqual(substrings.count, Set(substrings).count,
                       "Duplicate matchSubstring values would make detectedMeetingApp ambiguous")
    }

    func test_zoom_and_teams_cases_exist_with_expected_display_names() {
        XCTAssertEqual(MeetingApp.zoom.info.displayName, "Zoom")
        XCTAssertEqual(MeetingApp.teams.info.displayName, "Microsoft Teams")
    }
}
