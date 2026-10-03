import XCTest
@testable import Mila

final class PlaybackSpeedTests: XCTestCase {

    /// Pins the range and resolution the feature was specified with:
    /// 0.5× to 2×, in 0.25 steps.
    func test_allCases_cover0_5To2InQuarterSteps() {
        XCTAssertEqual(PlaybackSpeed.allCases.map(\.rawValue),
                       [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0])
    }

    func test_label_dropsFractionalPartForWholeRates() {
        XCTAssertEqual(PlaybackSpeed.normal.label, "1×")
        XCTAssertEqual(PlaybackSpeed.double.label, "2×")
    }

    func test_label_keepsFractionalPart() {
        XCTAssertEqual(PlaybackSpeed.half.label, "0.5×")
        XCTAssertEqual(PlaybackSpeed.threeQuarters.label, "0.75×")
        XCTAssertEqual(PlaybackSpeed.oneAndAQuarter.label, "1.25×")
        XCTAssertEqual(PlaybackSpeed.oneAndThreeQuarters.label, "1.75×")
    }

    func test_nearest_returnsExactMatches() {
        for speed in PlaybackSpeed.allCases {
            XCTAssertEqual(PlaybackSpeed.nearest(to: speed.rawValue), speed)
        }
    }

    func test_nearest_snapsBetweenSteps() {
        XCTAssertEqual(PlaybackSpeed.nearest(to: 1.3), .oneAndAQuarter)
        XCTAssertEqual(PlaybackSpeed.nearest(to: 0.9), .normal)
        XCTAssertEqual(PlaybackSpeed.nearest(to: 1.6), .oneAndAHalf)
    }

    func test_nearest_clampsOutOfRangeValues() {
        XCTAssertEqual(PlaybackSpeed.nearest(to: 0.0), .half)
        XCTAssertEqual(PlaybackSpeed.nearest(to: -4.0), .half)
        XCTAssertEqual(PlaybackSpeed.nearest(to: 3.0), .double)
        XCTAssertEqual(PlaybackSpeed.nearest(to: 100.0), .double)
    }

    /// A corrupted default must not leave the menu with an unlabelled selection.
    func test_nearest_fallsBackToNormalForNonFiniteValues() {
        XCTAssertEqual(PlaybackSpeed.nearest(to: .nan), .normal)
        XCTAssertEqual(PlaybackSpeed.nearest(to: .infinity), .normal)
        XCTAssertEqual(PlaybackSpeed.nearest(to: -.infinity), .normal)
    }
}
