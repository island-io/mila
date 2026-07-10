import XCTest
@testable import Mila

final class RecordingTests: XCTestCase {
    func test_recording_round_trips_through_codable() throws {
        let original = Recording(
            title: "Daily standup",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 612.3,
            source: .meeting,
            audioFileName: "Daily standup 2025-01-01.wav",
            status: .completed,
            language: "he",
            modelName: "ivrit.ai · large-v3-turbo",
            segments: [
                .init(start: 0.0, end: 2.4, text: "שלום וברוכים הבאים"),
                .init(start: 2.4, end: 4.0, text: " לפגישה שלנו")
            ],
            fullText: "שלום וברוכים הבאים לפגישה שלנו"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Recording.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.title, original.title)
        XCTAssertEqual(decoded.duration, original.duration, accuracy: 0.0001)
        XCTAssertEqual(decoded.source, .meeting)
        XCTAssertEqual(decoded.status, .completed)
        XCTAssertEqual(decoded.language, "he")
        XCTAssertEqual(decoded.segments.count, 2)
        XCTAssertEqual(decoded.segments[0].text, "שלום וברוכים הבאים")
        // fullText is no longer encoded into recordings.json — it lives in a
        // sidecar `.txt` file persisted by RecordingStore. The encoder must
        // drop it; the decoder leaves it empty so the store can re-hydrate.
        XCTAssertEqual(decoded.fullText, "")
        let asString = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(asString.contains("\"fullText\""),
                       "fullText key must not appear in the JSON-encoded blob")
    }

    func test_legacy_records_with_inline_fullText_still_decode() throws {
        // Records persisted under the pre-sidecar schema had `fullText`
        // inside the JSON. We have to keep decoding them so the first
        // launch after upgrade can migrate them to a sidecar.
        let legacy = """
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "title": "Legacy",
          "createdAt": "2025-01-01T00:00:00Z",
          "duration": 1.0,
          "source": "microphone",
          "audioFileName": "Legacy.wav",
          "status": "completed",
          "language": "en",
          "segments": [],
          "fullText": "old inline text"
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Recording.self, from: legacy)
        XCTAssertEqual(decoded.fullText, "old inline text")
    }

    func test_recording_source_display_names_are_all_set() {
        for source in RecordingSource.allCases {
            XCTAssertFalse(source.displayName.isEmpty, "Missing displayName for \(source)")
            XCTAssertFalse(source.sfSymbol.isEmpty, "Missing sfSymbol for \(source)")
        }
    }

    func test_is_zoom_recording_detects_app_name() {
        let zoomByApp = Recording(
            title: "Standup · Apr 1",
            source: .systemAudio,
            audioFileName: "x.wav",
            appName: "zoom.us"
        )
        XCTAssertTrue(zoomByApp.isZoomRecording)

        let zoomByTitle = Recording(
            title: "Zoom · Yesterday",
            source: .systemAudio,
            audioFileName: "x.wav"
        )
        XCTAssertTrue(zoomByTitle.isZoomRecording,
                      "Legacy recordings without appName should still match via title prefix")

        let unrelated = Recording(
            title: "Voice Memo",
            source: .microphone,
            audioFileName: "x.wav"
        )
        XCTAssertFalse(unrelated.isZoomRecording)
    }

    func test_appName_round_trips_through_codable() throws {
        let original = Recording(
            title: "Standup",
            source: .systemAudio,
            audioFileName: "x.wav",
            appName: "zoom.us"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Recording.self, from: data)
        XCTAssertEqual(decoded.appName, "zoom.us")
    }

    func test_legacy_records_without_appName_decode_with_nil() throws {
        // Existing on-disk recordings predate `appName`; decoding must
        // treat the missing key as nil rather than throwing.
        let legacy = """
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "title": "Old",
          "createdAt": "2025-01-01T00:00:00Z",
          "duration": 1.0,
          "source": "systemAudio",
          "audioFileName": "Old.wav",
          "status": "completed",
          "language": "en",
          "segments": []
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Recording.self, from: legacy)
        XCTAssertNil(decoded.appName)
    }

    func test_format_duration_pads_minutes_and_seconds() {
        XCTAssertEqual(formatDuration(0), "0:00")
        XCTAssertEqual(formatDuration(9), "0:09")
        XCTAssertEqual(formatDuration(61), "1:01")
        XCTAssertEqual(formatDuration(3_600), "1:00:00")
        XCTAssertEqual(formatDuration(3_661), "1:01:01")
    }

    /// The Voice-Memo source-folder field (issue #57) round-trips, and a legacy
    /// record without the key decodes to nil rather than throwing — so an
    /// upgrade never crashes on existing imports, and legacy-nil origins are
    /// left out of the un-select cleanup.
    func test_voiceMemoFolderUUID_round_trips_and_legacy_decodes_nil() throws {
        let original = Recording(
            title: "Imported memo",
            source: .voiceMemo,
            audioFileName: "memo.wav",
            voiceMemoUniqueID: "unique-1",
            voiceMemoFolderUUID: "FOLDER-42"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Recording.self, from: try encoder.encode(original))
        XCTAssertEqual(decoded.voiceMemoFolderUUID, "FOLDER-42")

        let legacy = """
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "title": "Legacy import",
          "createdAt": "2025-01-01T00:00:00Z",
          "duration": 1.0,
          "source": "voiceMemo",
          "audioFileName": "Legacy.wav",
          "status": "completed",
          "language": "en",
          "segments": [],
          "voiceMemoUniqueID": "unique-legacy"
        }
        """.data(using: .utf8)!
        let decodedLegacy = try decoder.decode(Recording.self, from: legacy)
        XCTAssertNil(decodedLegacy.voiceMemoFolderUUID)
    }
}
