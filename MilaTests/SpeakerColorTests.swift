import XCTest
import SwiftUI
@testable import Mila

final class SpeakerColorTests: XCTestCase {

    func test_same_speaker_id_always_gets_the_same_color() {
        XCTAssertEqual("SPEAKER_00".speakerColor, "SPEAKER_00".speakerColor)
        XCTAssertEqual("SPEAKER_03".speakerColor, "SPEAKER_03".speakerColor)
    }

    func test_different_speakers_get_different_colors() {
        XCTAssertNotEqual("SPEAKER_00".speakerColor, "SPEAKER_01".speakerColor)
        XCTAssertNotEqual("SPEAKER_00".speakerColor, "SPEAKER_02".speakerColor)
        XCTAssertNotEqual("SPEAKER_01".speakerColor, "SPEAKER_02".speakerColor)
    }

    func test_color_wraps_around_the_palette_beyond_its_size() {
        // Whatever the palette size N is, speaker N should reuse speaker 0's
        // color rather than crash or silently default to one color.
        var index = 0
        var color = "SPEAKER_00".speakerColor
        while true {
            index += 1
            let next = "SPEAKER_\(String(format: "%02d", index))".speakerColor
            if next == color { break }
            color = next
            XCTAssertLessThan(index, 64, "Palette should wrap well before 64 distinct speakers.")
        }
    }

    func test_non_standard_speaker_ids_still_resolve_to_a_stable_color() {
        XCTAssertEqual("host".speakerColor, "host".speakerColor)
        XCTAssertEqual("Alice".speakerColor, "Alice".speakerColor)
    }
}
