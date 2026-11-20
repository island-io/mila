import XCTest
import TranscriptionCore
@testable import Mila

/// Improvement plan item 4: `persist()` re-encodes the whole library on every
/// mutation. These tests pin the encoding (compact, still readable) and print
/// the measured cost so the coalescing decision rests on numbers.
@MainActor
final class RecordingStorePersistCostTests: XCTestCase {

    private func library(recordings: Int, segments: Int) -> [Recording] {
        (0..<recordings).map { i in
            var r = Recording(title: "Meeting \(i)", source: .microphone, audioFileName: "m\(i).wav")
            r.segments = (0..<segments).map { j in
                TranscriptSegment(start: Double(j) * 3, end: Double(j) * 3 + 2.5,
                                  text: "This is a realistic sentence number \(j) of the transcript.",
                                  speaker: j % 2 == 0 ? "Speaker 1" : "Speaker 2")
            }
            return r
        }
    }

    func test_encoding_is_compact_and_round_trips() throws {
        let recs = library(recordings: 3, segments: 5)
        let data = try RecordingStore.encodeLibrary(recs)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("\n"), "recordings.json should not be pretty-printed")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([Recording].self, from: data)
        XCTAssertEqual(decoded.map(\.id), recs.map(\.id))
        XCTAssertEqual(decoded.first?.segments.count, 5)
    }

    func test_encoding_is_byte_stable() throws {
        let recs = library(recordings: 4, segments: 4)
        XCTAssertEqual(try RecordingStore.encodeLibrary(recs), try RecordingStore.encodeLibrary(recs))
    }

    /// Not an assertion on speed (CI machines vary): it records, in the test
    /// log, what one `persist()` costs at realistic library sizes.
    func test_measure_encode_cost_at_realistic_sizes() throws {
        for (count, segs) in [(500, 600), (2000, 600)] {
            let recs = library(recordings: count, segments: segs)
            let clock = ContinuousClock()
            var compact = Data()
            let compactTime = try clock.measure { compact = try RecordingStore.encodeLibrary(recs) }
            let pretty = JSONEncoder()
            pretty.dateEncodingStrategy = .iso8601
            pretty.outputFormatting = [.prettyPrinted, .sortedKeys]
            var prettyData = Data()
            let prettyTime = try clock.measure { prettyData = try pretty.encode(recs) }
            print("PERSIST-COST \(count) recordings x \(segs) segments: "
                  + "compact \(compactTime) / \(compact.count / 1_000_000) MB, "
                  + "pretty \(prettyTime) / \(prettyData.count / 1_000_000) MB")
            XCTAssertLessThan(compact.count, prettyData.count)
        }
    }
}
