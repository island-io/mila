import XCTest
import TranscriptionCore
@testable import Mila

/// The `.milashare` manifest is a cross-version contract between two
/// different installs of Mila. These tests pin its shape, its version gate,
/// the entry-name allowlist that stands in for input sanitising, and the
/// mapping to and from the app's `Recording` — including a key-set tripwire
/// so a new `Recording` field forces a decision here, the way
/// `StoredRecordingDriftTests` does for recordings.json.
final class ShareManifestTests: XCTestCase {

    private let created = Date(timeIntervalSince1970: 1_700_000_000)
    private let exported = Date(timeIntervalSince1970: 1_700_100_000)
    private let sha = String(repeating: "ab", count: 32)

    private func sampleManifest(audioName: String = "audio.m4a",
                                format: String = "m4a",
                                version: Int = ShareManifest.currentVersion) -> ShareManifest {
        ShareManifest(
            version: version,
            bundleID: UUID(),
            exportedAt: exported,
            exportedBy: .init(name: "Ada Lovelace"),
            app: .init(version: "1.9.6", build: "68"),
            recording: .init(
                id: UUID(), title: "Weekly sync", createdAt: created, duration: 123.5,
                source: "meeting", language: "en", modelName: "large-v3",
                appName: "zoom.us", appBundleID: "us.zoom.xos",
                segments: [.init(start: 0, end: 2, text: "hello", speaker: "SPEAKER_00")],
                speakerNames: ["SPEAKER_00": "Daniel"],
                summary: "A summary.",
                actionItems: [.init(id: "a1", text: "Ship it", speaker: "SPEAKER_00",
                                    timestampSeconds: 3, source: "inferred", addedAt: created)]),
            audio: .init(fileName: audioName, format: format, byteCount: 1234, sha256: sha),
            transcript: .init(fileName: "transcript.txt"),
            speakerProfiles: nil)
    }

    // MARK: - Coding and version gate

    func test_round_trips_through_its_own_encoder() throws {
        let manifest = sampleManifest()
        let data = try ShareManifest.encoder().encode(manifest)
        let decoded = try ShareManifest.decode(data)
        XCTAssertEqual(decoded, manifest)
        XCTAssertNil(decoded.speakerProfiles)
    }

    func test_speaker_profiles_round_trip_when_present() throws {
        var manifest = sampleManifest()
        manifest.speakerProfiles = [
            SharedSpeakerProfile(name: "Daniel", embedding: [0.1, 0.2], sampleCount: 3,
                                 embeddingModel: SpeakerEmbeddingModel.current.id)
        ]
        let decoded = try ShareManifest.decode(try ShareManifest.encoder().encode(manifest))
        XCTAssertEqual(decoded.speakerProfiles?.count, 1)
        XCTAssertEqual(decoded.speakerProfiles?.first?.name, "Daniel")
        XCTAssertEqual(decoded.speakerProfiles?.first?.embeddingModel, SpeakerEmbeddingModel.current.id)
    }

    func test_missing_version_is_malformed() {
        let json = #"{ "bundleID": "11111111-2222-3333-4444-555555555555" }"#.data(using: .utf8)!
        XCTAssertThrowsError(try ShareManifest.decode(json)) { error in
            guard case ShareManifest.LoadError.malformed = error else {
                return XCTFail("expected .malformed, got \(error)")
            }
        }
    }

    func test_zero_version_is_malformed_and_future_version_is_unsupported() throws {
        var zero = try JSONSerialization.jsonObject(
            with: ShareManifest.encoder().encode(sampleManifest())) as! [String: Any]
        zero["version"] = 0
        XCTAssertThrowsError(try ShareManifest.decode(try JSONSerialization.data(withJSONObject: zero))) {
            guard case ShareManifest.LoadError.malformed = $0 else { return XCTFail("\($0)") }
        }

        var future = zero
        future["version"] = 99
        XCTAssertThrowsError(try ShareManifest.decode(try JSONSerialization.data(withJSONObject: future))) {
            guard case ShareManifest.LoadError.unsupportedVersion(let found, let supported) = $0 else {
                return XCTFail("\($0)")
            }
            XCTAssertEqual(found, 99)
            XCTAssertEqual(supported, ShareManifest.currentVersion)
        }
    }

    func test_unknown_keys_are_ignored_for_forward_compatibility() throws {
        var obj = try JSONSerialization.jsonObject(
            with: ShareManifest.encoder().encode(sampleManifest())) as! [String: Any]
        obj["somethingFromTheFuture"] = ["nested": true]
        var rec = obj["recording"] as! [String: Any]
        rec["mood"] = "cheerful"
        obj["recording"] = rec
        let decoded = try ShareManifest.decode(try JSONSerialization.data(withJSONObject: obj))
        XCTAssertEqual(decoded.recording.title, "Weekly sync")
    }

    func test_garbage_is_malformed() {
        XCTAssertThrowsError(try ShareManifest.decode(Data("not json".utf8))) {
            guard case ShareManifest.LoadError.malformed = $0 else { return XCTFail("\($0)") }
        }
    }

    // MARK: - Entry-name allowlist

    func test_audio_entry_name_allowlist() {
        XCTAssertTrue(ShareManifest.isAllowedAudioEntryName("audio.wav"))
        XCTAssertTrue(ShareManifest.isAllowedAudioEntryName("audio.m4a"))
        for bad in ["../audio.wav", "/tmp/x.m4a", "audio.mp3", "Audio.WAV", "audio.wav/", "",
                    "audio", "sub/audio.wav", "audio.wav\u{0}"] {
            XCTAssertFalse(ShareManifest.isAllowedAudioEntryName(bad), "accepted \(bad.debugDescription)")
        }
    }

    func test_validated_rejects_a_hostile_audio_entry_name() {
        XCTAssertThrowsError(try sampleManifest(audioName: "../../evil.wav", format: "wav").validated()) {
            guard case ShareManifest.LoadError.malformed = $0 else { return XCTFail("\($0)") }
        }
    }

    func test_validated_rejects_a_format_that_disagrees_with_the_entry() {
        XCTAssertThrowsError(try sampleManifest(audioName: "audio.m4a", format: "wav").validated())
    }

    func test_validated_rejects_a_bad_digest_or_empty_audio() {
        var m = sampleManifest()
        m.audio.sha256 = "nope"
        XCTAssertThrowsError(try m.validated())
        var e = sampleManifest()
        e.audio.byteCount = 0
        XCTAssertThrowsError(try e.validated())
    }

    func test_validated_rejects_an_unexpected_transcript_entry_name() {
        var m = sampleManifest()
        m.transcript = .init(fileName: "../transcript.txt")
        XCTAssertThrowsError(try m.validated())
    }

    // MARK: - Segment and value validation

    func test_validated_drops_bad_segments_individually_and_keeps_the_rest() throws {
        var m = sampleManifest()
        m.recording.segments = [
            .init(start: 0, end: 1, text: "good", speaker: nil),
            .init(start: .nan, end: 1, text: "nan start", speaker: nil),
            .init(start: 5, end: 2, text: "inverted", speaker: nil),
            .init(start: -1, end: 1, text: "negative", speaker: nil),
            .init(start: 2, end: .infinity, text: "inf end", speaker: nil),
            .init(start: 3, end: 3, text: "zero length is fine", speaker: nil),
        ]
        let v = try m.validated()
        XCTAssertEqual(v.recording.segments.map(\.text), ["good", "zero length is fine"])
    }

    func test_validated_rejects_a_non_finite_duration_and_fills_an_empty_title() throws {
        var bad = sampleManifest()
        bad.recording.duration = .nan
        XCTAssertThrowsError(try bad.validated())

        var blank = sampleManifest()
        blank.recording.title = "   "
        blank.exportedBy.name = ""
        let v = try blank.validated()
        XCTAssertEqual(v.recording.title, "Shared recording")
        XCTAssertEqual(v.exportedBy.name, "Unknown sender")
    }

    func test_lenient_segment_decoding_turns_a_missing_time_into_a_droppable_segment() throws {
        let json = """
        { "version": 1, "bundleID": "11111111-2222-3333-4444-555555555555",
          "exportedAt": "2026-10-06T00:00:00Z", "exportedBy": { "name": "A" },
          "recording": { "id": "22222222-2222-3333-4444-555555555555",
                         "createdAt": "2026-10-01T00:00:00Z",
                         "segments": [ { "text": "no times" }, { "start": 0, "end": 1, "text": "ok" } ] },
          "audio": { "fileName": "audio.wav", "format": "wav", "byteCount": 10,
                     "sha256": "\(sha)" } }
        """.data(using: .utf8)!
        let v = try ShareManifest.decode(json).validated()
        XCTAssertEqual(v.recording.segments.map(\.text), ["ok"])
        XCTAssertEqual(v.recording.title, "Shared recording")
        XCTAssertEqual(v.recording.language, "he")
    }

    // MARK: - Mapping to and from Recording

    private func fullyPopulatedRecording() -> Recording {
        Recording(
            id: UUID(), title: "Weekly sync", createdAt: created, duration: 123.5,
            source: .meeting, audioFileName: "Weekly sync.m4a", status: .completed,
            language: "en", modelName: "large-v3",
            segments: [TranscriptSegment(start: 0, end: 2, text: "hello", speaker: "SPEAKER_00"),
                       TranscriptSegment(start: 2, end: 4, text: "hi there", speaker: "SPEAKER_01")],
            fullText: "hello hi there", deletedAt: created, folder: "Work",
            appName: "zoom.us", appBundleID: "us.zoom.xos", summary: "A summary.",
            actionItems: [ActionItem(id: "a1", text: "Ship it", speaker: "SPEAKER_00",
                                     timestampSeconds: 3, source: .voiceCommand, addedAt: created)],
            voiceMemoUniqueID: "VM-1", voiceMemoFolderUUID: "VMF-1",
            speakerNames: ["SPEAKER_00": "Daniel", "SPEAKER_01": "John Doe"],
            sharedBy: "Someone Else", sharedAt: created)
    }

    func test_payload_strips_machine_specific_fields_and_keeps_content() throws {
        let recording = fullyPopulatedRecording()
        let payload = ShareManifest.RecordingPayload(sharing: recording)
        XCTAssertEqual(payload.id, recording.id)
        XCTAssertEqual(payload.title, "Weekly sync")
        XCTAssertEqual(payload.source, "meeting")
        XCTAssertEqual(payload.segments.map(\.text), ["hello", "hi there"])
        XCTAssertEqual(payload.segments.map(\.speaker), ["SPEAKER_00", "SPEAKER_01"])
        XCTAssertEqual(payload.speakerNames, ["SPEAKER_00": "Daniel", "SPEAKER_01": "John Doe"])
        XCTAssertEqual(payload.summary, "A summary.")
        XCTAssertEqual(payload.actionItems?.first?.source, "voice_command")
        XCTAssertEqual(payload.appBundleID, "us.zoom.xos")

        let json = try JSONSerialization.jsonObject(
            with: ShareManifest.encoder().encode(payload)) as! [String: Any]
        for stripped in ["status", "audioFileName", "fullText", "deletedAt", "folder",
                         "voiceMemoUniqueID", "voiceMemoFolderUUID", "sharedBy", "sharedAt"] {
            XCTAssertNil(json[stripped], "\(stripped) must not travel in a share")
        }
        let segment = (json["segments"] as! [[String: Any]]).first!
        XCTAssertNil(segment["id"], "segment ids are regenerated on import")
    }

    func test_makeRecording_builds_a_completed_untrashed_attributed_recording() {
        let payload = ShareManifest.RecordingPayload(sharing: fullyPopulatedRecording())
        let made = payload.makeRecording(audioFileName: "Weekly sync 2026.m4a",
                                         fullText: "hello hi there",
                                         sharedBy: "Ada Lovelace", sharedAt: exported,
                                         folder: "Kept")
        XCTAssertEqual(made.id, payload.id)
        XCTAssertEqual(made.status, .completed)
        XCTAssertNil(made.deletedAt)
        XCTAssertEqual(made.folder, "Kept")
        XCTAssertEqual(made.source, .meeting)
        XCTAssertEqual(made.audioFileName, "Weekly sync 2026.m4a")
        XCTAssertEqual(made.fullText, "hello hi there")
        XCTAssertEqual(made.sharedBy, "Ada Lovelace")
        XCTAssertEqual(made.sharedAt, exported)
        XCTAssertEqual(made.segments.count, 2)
        XCTAssertEqual(made.actionItems?.first?.source, .voiceCommand)
        XCTAssertEqual(made.speakerNames["SPEAKER_01"], "John Doe")
        XCTAssertNil(made.voiceMemoUniqueID)
    }

    func test_unknown_source_and_action_source_fall_back_instead_of_failing() {
        var payload = ShareManifest.RecordingPayload(sharing: fullyPopulatedRecording())
        payload.source = "hologram"
        payload.actionItems = [.init(id: "x", text: "t", speaker: nil, timestampSeconds: 0,
                                     source: "telepathy", addedAt: nil)]
        let made = payload.makeRecording(audioFileName: "a.wav", fullText: "", sharedBy: "A",
                                         sharedAt: exported, folder: nil)
        XCTAssertEqual(made.source, .microphone)
        XCTAssertEqual(made.actionItems?.first?.source, .llmInferred)
        XCTAssertEqual(made.actionItems?.first?.addedAt, exported)
    }

    /// The share-format twin of `StoredRecordingDriftTests
    /// .test_every_persisted_key_is_mirrored`: every key `Recording`
    /// persists is either carried by the payload or listed here with a
    /// reason. Adding to the list is a decision; leaving a key out is a bug.
    func test_every_recording_key_is_shared_or_deliberately_excluded() throws {
        let deliberatelyNotShared: Set<String> = [
            // (`fullText` is not listed: `Recording` never encodes it either —
            // the .txt sidecar owns it locally, `transcript.txt` in a share.)
            "status",               // the receiver derives it: imports are always completed
            "audioFileName",        // the receiver mints its own library filename
            "deletedAt",            // the sender's trash is not the receiver's
            "folder",               // the sender's filing is not the receiver's
            "voiceMemoUniqueID",    // iPhone import bookkeeping on the sender's account
            "voiceMemoFolderUUID",
            "sharedBy",             // a re-share attributes to the re-sharer
            "sharedAt",
        ]
        let storeEncoder = JSONEncoder()
        storeEncoder.dateEncodingStrategy = .iso8601
        let recording = fullyPopulatedRecording()
        let recordingKeys = Set((try JSONSerialization.jsonObject(
            with: storeEncoder.encode(recording)) as! [String: Any]).keys)
        let payloadKeys = Set((try JSONSerialization.jsonObject(
            with: ShareManifest.encoder().encode(ShareManifest.RecordingPayload(sharing: recording)))
            as! [String: Any]).keys)

        let missing = recordingKeys.subtracting(payloadKeys).subtracting(deliberatelyNotShared)
        XCTAssertTrue(missing.isEmpty,
                      "Recording persists \(missing.sorted()) but ShareManifest.RecordingPayload "
                      + "does not carry them. Add them to the payload, or to this test's "
                      + "allowlist with a reason.")
        let stale = deliberatelyNotShared.subtracting(recordingKeys)
        XCTAssertTrue(stale.isEmpty, "stale allowlist entries: \(stale.sorted())")
    }

    // MARK: - Log safety

    func test_logDescription_withholds_user_content_but_passes_the_version_through() {
        let path = "/Users/ada/Downloads/Acme acquisition call.milashare"
        for error in [ShareManifest.LoadError.unreadable("The file “\(path)” couldn't be opened."),
                      .malformed("No value associated with key endpoint (\"\(path)\")."),
                      .integrity("audio.m4a in \(path) is 3 bytes short")] {
            XCTAssertFalse(error.logDescription.contains("Acme"), error.logDescription)
            XCTAssertTrue(error.errorDescription?.contains("Acme") == true,
                          "the user-facing text must keep the detail")
        }
        let version = ShareManifest.LoadError.unsupportedVersion(found: 7, supported: 1)
        XCTAssertEqual(version.logDescription, version.errorDescription)
    }
}
