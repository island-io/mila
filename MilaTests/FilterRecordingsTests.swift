import XCTest
@testable import Mila

final class FilterRecordingsTests: XCTestCase {
    private func rec(_ title: String, _ text: String = "") -> Recording {
        Recording(title: title, source: .microphone, audioFileName: "\(UUID()).wav", fullText: text)
    }

    func test_empty_or_blank_query_returns_everything() {
        let all = [rec("A"), rec("B")]
        XCTAssertEqual(filterRecordings(all, search: "").count, 2)
        XCTAssertEqual(filterRecordings(all, search: "   ").count, 2)
    }

    func test_matches_title_or_transcript_case_insensitively() {
        let a = rec("Budget sync", "nothing relevant")
        let b = rec("Standup", "we discussed the BUDGET today")
        let c = rec("Lunch", "pizza")
        let hits = filterRecordings([a, b, c], search: "budget")
        XCTAssertEqual(Set(hits.map(\.id)), [a.id, b.id])
    }

    func test_diacritics_do_not_hide_a_match() {
        let a = rec("Café planning")
        XCTAssertEqual(filterRecordings([a], search: "cafe").count, 1)
        XCTAssertEqual(filterRecordings([a], search: "CAFÉ").count, 1)
    }

    func test_query_is_trimmed_and_non_matches_are_dropped() {
        let a = rec("Roadmap")
        XCTAssertEqual(filterRecordings([a], search: "  road ").count, 1)
        XCTAssertTrue(filterRecordings([a], search: "zzz").isEmpty)
    }
}
