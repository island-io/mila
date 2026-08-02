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

    func test_speakerNames_round_trip_and_are_omitted_when_empty() throws {
        let named = Recording(
            title: "Named",
            source: .meeting,
            audioFileName: "named.wav",
            segments: [.init(start: 0, end: 1, text: "hi", speaker: "SPEAKER_00")],
            speakerNames: ["SPEAKER_00": "Daniel"]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(Recording.self, from: encoder.encode(named))
        XCTAssertEqual(decoded.speakerNames, ["SPEAKER_00": "Daniel"])

        // Recordings with no renames must not grow a noise key in
        // recordings.json.
        let unnamed = Recording(title: "Plain", source: .microphone, audioFileName: "p.wav")
        let json = String(data: try encoder.encode(unnamed), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("\"speakerNames\""))
    }

    func test_legacy_records_without_speakerNames_decode_to_empty_map() throws {
        let legacy = """
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "title": "Legacy",
          "createdAt": "2025-01-01T00:00:00Z",
          "duration": 1.0,
          "source": "microphone",
          "audioFileName": "Legacy.wav",
          "status": "completed",
          "language": "en"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Recording.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.speakerNames, [:])
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

    func test_detected_meeting_app_detects_zoom_by_app_name() {
        let zoomByApp = Recording(
            title: "Standup · Apr 1",
            source: .systemAudio,
            audioFileName: "x.wav",
            appName: "zoom.us"
        )
        XCTAssertEqual(zoomByApp.detectedMeetingApp, .zoom)

        let zoomByTitle = Recording(
            title: "Zoom · Yesterday",
            source: .systemAudio,
            audioFileName: "x.wav"
        )
        XCTAssertEqual(zoomByTitle.detectedMeetingApp, .zoom,
                      "Legacy recordings without appName should still match via title")

        let unrelated = Recording(
            title: "Voice Memo",
            source: .microphone,
            audioFileName: "x.wav"
        )
        XCTAssertNil(unrelated.detectedMeetingApp)
    }

    func test_detected_meeting_app_detects_teams_by_app_name() {
        let teamsByApp = Recording(
            title: "Standup · Apr 1",
            source: .systemAudio,
            audioFileName: "x.wav",
            appName: "Microsoft Teams"
        )
        XCTAssertEqual(teamsByApp.detectedMeetingApp, .teams)

        // Legacy titles were auto-derived from the captured app's display
        // name, so the full "Microsoft Teams" is what actually shows up on
        // disk — the bare word "Teams" deliberately does NOT match.
        let teamsByTitle = Recording(
            title: "Microsoft Teams · Yesterday",
            source: .systemAudio,
            audioFileName: "x.wav"
        )
        XCTAssertEqual(teamsByTitle.detectedMeetingApp, .teams,
                      "Legacy recordings without appName should still match via title")

        let teamsByBundleID = Recording(
            title: "Standup · Apr 1",
            source: .systemAudio,
            audioFileName: "x.wav",
            appName: "Microsoft Teams",
            appBundleID: "com.microsoft.teams2"
        )
        XCTAssertEqual(teamsByBundleID.detectedMeetingApp, .teams,
                       "A real Teams app-audio capture must still be detected")
    }

    /// The bundle ID is the authoritative signal — same key Core Audio uses
    /// for live detection — and must beat both weaker string signals.
    func test_detected_meeting_app_prefers_bundle_id_over_name_and_title() {
        let teamsBundleZoomStrings = Recording(
            title: "Zoom sync notes",
            source: .systemAudio,
            audioFileName: "x.wav",
            appName: "zoom.us",
            appBundleID: "com.microsoft.teams2"
        )
        XCTAssertEqual(teamsBundleZoomStrings.detectedMeetingApp, .teams,
                       "appBundleID must win over a conflicting appName and title")

        let zoomBundleTeamsStrings = Recording(
            title: "Microsoft Teams sync notes",
            source: .systemAudio,
            audioFileName: "x.wav",
            appName: "Microsoft Teams",
            appBundleID: "us.zoom.xos"
        )
        XCTAssertEqual(zoomBundleTeamsStrings.detectedMeetingApp, .zoom,
                       "appBundleID must win in both directions, not just by case order")
    }

    /// A bundle ID belonging to no known meeting app must not suppress the
    /// weaker passes — the three passes are ordered, not mutually exclusive.
    func test_detected_meeting_app_falls_back_when_bundle_id_unknown() {
        let unknownBundleTeamsName = Recording(
            title: "Standup",
            source: .systemAudio,
            audioFileName: "x.wav",
            appName: "Microsoft Teams",
            appBundleID: "com.apple.Safari"
        )
        XCTAssertEqual(unknownBundleTeamsName.detectedMeetingApp, .teams,
                       "An unrecognised appBundleID should still allow the appName pass")
    }

    /// `"teams"` on its own is a substring of plenty of unrelated app names.
    /// Only a Teams-specific match may light up the Teams badge.
    func test_detected_meeting_app_ignores_apps_that_merely_contain_teams() {
        let teamSpeak = Recording(
            title: "Standup · Apr 1",
            source: .systemAudio,
            audioFileName: "x.wav",
            appName: "TeamSpeak",
            appBundleID: "com.teamspeak.TeamSpeak"
        )
        XCTAssertNil(teamSpeak.detectedMeetingApp,
                     "TeamSpeak is not Microsoft Teams — neither its bundle ID nor its name may match")

        let dreamTeams = Recording(
            title: "Dream Teams · Apr 1",
            source: .systemAudio,
            audioFileName: "x.wav"
        )
        XCTAssertNil(dreamTeams.detectedMeetingApp,
                     "A title merely containing 'Teams' must not be read as Microsoft Teams")

        let syncNotes = Recording(
            title: "teams sync notes",
            source: .systemAudio,
            audioFileName: "x.wav"
        )
        XCTAssertNil(syncNotes.detectedMeetingApp,
                     "A bare 'teams' in a title is far too generic to badge as a meeting")
    }

    /// The title is user-editable and means nothing about where the audio
    /// came from on a source that never captured another app. Renaming a
    /// dictation or an imported Voice Memo must not badge it as a meeting.
    func test_detected_meeting_app_ignores_title_for_non_capture_sources() {
        for source in [RecordingSource.microphone, .voiceMemo] {
            let renamedTeams = Recording(
                title: "Microsoft Teams standup",
                source: source,
                audioFileName: "x.wav"
            )
            XCTAssertNil(renamedTeams.detectedMeetingApp,
                         "A \(source.rawValue) recording renamed to mention Teams is not a Teams meeting")

            let renamedZoom = Recording(
                title: "Zoom call with Dana",
                source: source,
                audioFileName: "x.wav"
            )
            XCTAssertNil(renamedZoom.detectedMeetingApp,
                         "A \(source.rawValue) recording renamed to mention Zoom is not a Zoom meeting")
        }

        // ...but the same title on a real capture source still matches.
        for source in [RecordingSource.systemAudio, .meeting] {
            let captured = Recording(
                title: "Microsoft Teams standup",
                source: source,
                audioFileName: "x.wav"
            )
            XCTAssertEqual(captured.detectedMeetingApp, .teams,
                           "The title fallback must survive for \(source.rawValue) captures")
        }
    }

    /// `appName` is the authoritative signal and must beat a conflicting
    /// title for EVERY app, not just the first `MeetingApp` case. Regression
    /// test for the interleaved single-pass match, where a Teams recording
    /// whose title mentioned Zoom was badged Zoom purely because `.zoom` is
    /// declared first in `allCases`.
    func test_detected_meeting_app_prefers_app_name_over_conflicting_title() {
        let teamsAppZoomTitle = Recording(
            title: "Zoom sync notes",
            source: .systemAudio,
            audioFileName: "x.wav",
            appName: "Microsoft Teams"
        )
        XCTAssertEqual(teamsAppZoomTitle.detectedMeetingApp, .teams,
                       "appName must win over a conflicting title regardless of case order")

        // ...and symmetrically, so this isn't just re-encoding the ordering.
        let zoomAppTeamsTitle = Recording(
            title: "Teams sync notes",
            source: .systemAudio,
            audioFileName: "x.wav",
            appName: "zoom.us"
        )
        XCTAssertEqual(zoomAppTeamsTitle.detectedMeetingApp, .zoom,
                       "appName must win over a conflicting title in both directions")
    }

    /// An `appName` that matches no known meeting app must not suppress the
    /// legacy title fallback — the two passes are ordered, not exclusive.
    func test_detected_meeting_app_falls_back_to_title_when_app_name_unknown() {
        let unknownAppZoomTitle = Recording(
            title: "Zoom · Yesterday",
            source: .systemAudio,
            audioFileName: "x.wav",
            appName: "Safari"
        )
        XCTAssertEqual(unknownAppZoomTitle.detectedMeetingApp, .zoom,
                       "An unrecognised appName should still allow the title fallback")
    }

    func test_appName_round_trips_through_codable() throws {
        let original = Recording(
            title: "Standup",
            source: .systemAudio,
            audioFileName: "x.wav",
            appName: "zoom.us",
            appBundleID: "us.zoom.xos"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Recording.self, from: data)
        XCTAssertEqual(decoded.appName, "zoom.us")
        XCTAssertEqual(decoded.appBundleID, "us.zoom.xos")
        XCTAssertEqual(decoded.detectedMeetingApp, .zoom)
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
        XCTAssertNil(decoded.appBundleID)
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
