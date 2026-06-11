import XCTest
@testable import TranscriptionCore

final class TranscriptSegmentTests: XCTestCase {
    func test_segment_is_created_with_defaults() {
        let seg = TranscriptSegment(start: 0, end: 1, text: "hello")
        XCTAssertEqual(seg.text, "hello")
        XCTAssertNil(seg.speaker)
    }
}
