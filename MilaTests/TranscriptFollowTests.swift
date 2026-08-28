import XCTest
import TranscriptionCore
@testable import Mila

/// Pins the segment-lookup that drives BOTH the transcript highlight and the
/// auto-scroll target. The scroll animation itself is AppKit/SwiftUI
/// integration and isn't unit-testable, but this decision is.
final class TranscriptFollowTests: XCTestCase {

    /// 0–2s, 2–4s, then a deliberate gap, then 6–8s.
    private func makeSegments() -> [TranscriptSegment] {
        [
            TranscriptSegment(start: 0, end: 2, text: "first"),
            TranscriptSegment(start: 2, end: 4, text: "second"),
            TranscriptSegment(start: 6, end: 8, text: "third"),
        ]
    }

    func test_returnsSegmentCoveringTime() {
        let segments = makeSegments()
        XCTAssertEqual(RecordingDetailView.activeSegmentID(segments: segments, at: 1.0),
                       segments[0].id)
        XCTAssertEqual(RecordingDetailView.activeSegmentID(segments: segments, at: 3.5),
                       segments[1].id)
        XCTAssertEqual(RecordingDetailView.activeSegmentID(segments: segments, at: 7.9),
                       segments[2].id)
    }

    /// Intervals are half-open: `start` inclusive, `end` exclusive. At t=2 the
    /// second segment owns the time, not the first.
    func test_boundariesAreHalfOpen() {
        let segments = makeSegments()
        XCTAssertEqual(RecordingDetailView.activeSegmentID(segments: segments, at: 0),
                       segments[0].id)
        XCTAssertEqual(RecordingDetailView.activeSegmentID(segments: segments, at: 2.0),
                       segments[1].id)
        XCTAssertEqual(RecordingDetailView.activeSegmentID(segments: segments, at: 4.0),
                       nil, "4.0 is the exclusive end of segment 2 and before segment 3 starts")
    }

    /// Silence between segments must yield nil so the transcript holds position
    /// instead of scrolling to nowhere.
    func test_gapBetweenSegmentsHasNoActiveSegment() {
        let segments = makeSegments()
        XCTAssertNil(RecordingDetailView.activeSegmentID(segments: segments, at: 5.0))
    }

    func test_beforeFirstAndAfterLastAreNil() {
        let segments = makeSegments()
        XCTAssertNil(RecordingDetailView.activeSegmentID(segments: segments, at: -1.0))
        XCTAssertNil(RecordingDetailView.activeSegmentID(segments: segments, at: 8.0))
        XCTAssertNil(RecordingDetailView.activeSegmentID(segments: segments, at: 99.0))
    }

    func test_emptyTranscriptIsNil() {
        XCTAssertNil(RecordingDetailView.activeSegmentID(segments: [], at: 1.0))
    }
}
