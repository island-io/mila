import XCTest
import TranscriptionCore
@testable import Mila

@MainActor
final class TranscriptExporterTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "TranscriptExporterTests")
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        super.tearDown()
    }

    private func makeRecording(segments: [TranscriptSegment]) -> Recording {
        Recording(
            title: "Demo",
            duration: 2.0,
            source: .systemAudio,
            audioFileName: "Demo.wav",
            status: .completed,
            language: "en",
            segments: segments,
            fullText: segments.map(\.text).joined()
        )
    }

    func test_srt_body_emits_one_entry_per_non_blank_segment() {
        let rec = makeRecording(segments: [
            .init(start: 0.0, end: 1.2, text: "Hello"),
            .init(start: 1.2, end: 2.4, text: " "),       // blank — must be skipped
            .init(start: 2.4, end: 3.6, text: " World")
        ])

        let body = TranscriptExporter.srtBody(for: rec)
        // Two non-blank segments -> two SRT entries, sequential numbering.
        XCTAssertTrue(body.contains("1\n00:00:00,000 --> 00:00:01,200\nHello"))
        XCTAssertTrue(body.contains("2\n00:00:02,400 --> 00:00:03,600\nWorld"))
        XCTAssertFalse(body.contains("3\n"))
    }

    func test_srt_body_uses_commas_for_decimal_separator() {
        let rec = makeRecording(segments: [
            .init(start: 1.5, end: 2.5, text: "Hi")
        ])
        let body = TranscriptExporter.srtBody(for: rec)
        // SRT spec uses commas, not periods, between seconds and milliseconds.
        XCTAssertTrue(body.contains("00:00:01,500 --> 00:00:02,500"))
        XCTAssertFalse(body.contains("00:00:01.500"))
    }

    func test_srt_body_prefixes_speaker_labels_when_present() {
        var seg1 = TranscriptSegment(start: 0, end: 1, text: "Hello")
        seg1.speaker = "SPEAKER_00"
        var seg2 = TranscriptSegment(start: 1, end: 2, text: "Hi")
        seg2.speaker = "SPEAKER_01"
        let rec = makeRecording(segments: [seg1, seg2])

        let body = TranscriptExporter.srtBody(for: rec)
        XCTAssertTrue(body.contains("SPEAKER_00: Hello"))
        XCTAssertTrue(body.contains("SPEAKER_01: Hi"))
    }

    func test_srt_body_is_empty_when_no_segments() {
        let rec = makeRecording(segments: [])
        XCTAssertTrue(TranscriptExporter.srtBody(for: rec).isEmpty)
    }

    func test_writeSRT_to_url_throws_when_recording_has_no_segments() {
        let rec = makeRecording(segments: [])
        let url = tempRoot.appendingPathComponent("out.srt")
        XCTAssertThrowsError(try TranscriptExporter.writeSRT(for: rec, to: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "No file should be created when there's nothing to write")
    }

    func test_writeSRT_to_url_writes_file_to_explicit_destination() throws {
        let rec = makeRecording(segments: [
            .init(start: 0.0, end: 1.0, text: "Line one"),
            .init(start: 1.0, end: 2.0, text: "Line two")
        ])
        let dest = tempRoot.appendingPathComponent("subtitles.srt")
        try TranscriptExporter.writeSRT(for: rec, to: dest)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        let written = try String(contentsOf: dest, encoding: .utf8)
        XCTAssertTrue(written.contains("Line one"))
        XCTAssertTrue(written.contains("Line two"))
    }

    func test_sidecar_writeSRT_removes_stale_file_for_empty_segments() throws {
        // Mimic the "re-transcription came back empty" path: there's an old
        // sidecar from a prior successful run, the new run produced no
        // segments, the exporter should erase the stale file rather than
        // leave it pointing at the previous transcript.
        let rec = makeRecording(segments: [])
        let sidecarURL = tempRoot.appendingPathComponent("Demo.srt")
        try "stale".write(to: sidecarURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))

        TranscriptExporter.writeSRT(for: rec, in: tempRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL.path))
    }
}
