import XCTest
import TranscriptionCore
import MilaKit
@testable import Mila

/// Guards the cross-process contract between the app's `Recording`
/// (what `RecordingStore.persist()` writes into recordings.json) and
/// MilaKit's read-only `StoredRecording` mirror (what mila-mcp decodes).
/// If a field is added to `Recording`'s encoder, this test is the tripwire
/// reminding you to mirror it in `StoredRecording`.
final class StoredRecordingDriftTests: XCTestCase {

    private func storeEncoder() -> JSONEncoder {
        // Must match RecordingStore.persist().
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private func storeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private let fixtureID = UUID()
    private let fixtureCreated = Date(timeIntervalSince1970: 1_700_000_000)
    private let fixtureDeleted = Date(timeIntervalSince1970: 1_700_000_500)

    /// One `Recording` with **every** persisted field set. Shared by the
    /// field-by-field test and the key-set test so a newly added field only
    /// has to be set here once.
    private func fullyPopulatedRecording() -> Recording {
        let id = fixtureID
        let created = fixtureCreated
        let deleted = fixtureDeleted
        return Recording(
            id: id,
            title: "Weekly sync",
            createdAt: created,
            duration: 123.5,
            source: .meeting,
            audioFileName: "Weekly sync.wav",
            status: .completed,
            language: "en",
            modelName: "large-v3",
            segments: [
                TranscriptSegment(start: 0, end: 2, text: "hello", speaker: "SPEAKER_00"),
                TranscriptSegment(start: 2, end: 4, text: "hi there", speaker: "SPEAKER_01"),
            ],
            fullText: "hello hi there",
            deletedAt: deleted,
            folder: "Work",
            appName: "zoom.us",
            summary: "A summary.",
            actionItems: [ActionItem(id: "a1", text: "Ship it", speaker: "SPEAKER_00",
                                     timestampSeconds: 3, source: .llmInferred,
                                     addedAt: created)],
            voiceMemoUniqueID: "VM-1",
            voiceMemoFolderUUID: "VMF-1",
            speakerNames: ["SPEAKER_00": "Daniel", "SPEAKER_01": "John Doe"]
        )
    }

    func test_fully_populated_recording_round_trips_into_stored_recording() throws {
        let id = fixtureID
        let created = fixtureCreated
        let deleted = fixtureDeleted
        let recording = fullyPopulatedRecording()

        let data = try storeEncoder().encode([recording])
        let stored = try storeDecoder().decode([StoredRecording].self, from: data)
        XCTAssertEqual(stored.count, 1)
        let s = try XCTUnwrap(stored.first)

        XCTAssertEqual(s.id, id)
        XCTAssertEqual(s.title, "Weekly sync")
        XCTAssertEqual(s.createdAt, created)
        XCTAssertEqual(s.duration, 123.5, accuracy: 0.001)
        XCTAssertEqual(s.source, RecordingSource.meeting.rawValue)
        XCTAssertEqual(s.audioFileName, "Weekly sync.wav")
        XCTAssertEqual(s.status, TranscriptionStatus.completed.rawValue)
        XCTAssertEqual(s.language, "en")
        XCTAssertEqual(s.modelName, "large-v3")
        XCTAssertEqual(s.segments.count, 2)
        XCTAssertEqual(s.segments[0].text, "hello")
        XCTAssertEqual(s.segments[0].speaker, "SPEAKER_00")
        XCTAssertEqual(s.segments[1].start, 2, accuracy: 0.001)
        XCTAssertEqual(s.segments[1].end, 4, accuracy: 0.001)
        XCTAssertEqual(s.deletedAt, deleted)
        XCTAssertTrue(s.isTrashed)
        XCTAssertEqual(s.folder, "Work")
        XCTAssertEqual(s.appName, "zoom.us")
        XCTAssertEqual(s.summary, "A summary.")
        XCTAssertEqual(s.actionItems?.count, 1)
        XCTAssertEqual(s.actionItems?.first?.text, "Ship it")
        XCTAssertEqual(s.actionItems?.first?.speaker, "SPEAKER_00")
        XCTAssertEqual(s.actionItems?.first?.timestampSeconds, 3)
        XCTAssertEqual(s.speakerNames, ["SPEAKER_00": "Daniel", "SPEAKER_01": "John Doe"])
        // fullText is deliberately NOT encoded by the app (sidecar .txt owns it).
        XCTAssertNil(s.legacyFullText)
        XCTAssertEqual(s.transcriptFileName, "Weekly sync.txt")
        XCTAssertEqual(s.summaryFileName, "Weekly sync.summary.txt")
        XCTAssertEqual(s.speakerDisplayNames, ["Daniel", "John Doe"])
    }

    /// The per-field assertions above only check fields somebody remembered
    /// to write an assertion for, and `JSONDecoder` ignores keys it doesn't
    /// know — so adding a persisted field to `Recording` and forgetting to
    /// mirror it in `StoredRecording` leaves every existing test green while
    /// mila-mcp silently stops seeing the new data. That is exactly the
    /// drift this file exists to catch.
    ///
    /// This compares the *key sets*: everything the app writes must be a key
    /// the mirror also round-trips, unless it's listed as a deliberate
    /// omission below.
    func test_every_persisted_key_is_mirrored() throws {
        // Deliberately not mirrored, with the reason. Adding to this list is
        // a decision; leaving a key out of it is a bug.
        let intentionallyUnmirrored: Set<String> = [
            // The sidecar .txt owns the transcript text; the mirror reads it
            // from disk rather than from the store.
            "fullText",
            // Bookkeeping for the Voice Memos importer: they tie a recording
            // back to the entry it was imported from, so re-import can skip
            // it. Opaque identifiers with no meaning to an MCP client, which
            // asks about content — not about import provenance. (Found by
            // this test when it was first written: both were already absent
            // from the mirror while the old round-trip assertions stayed
            // green, which is the drift this test exists to catch.)
            "voiceMemoUniqueID",
            "voiceMemoFolderUUID",
        ]

        let recording = fullyPopulatedRecording()
        let appJSON = try JSONSerialization.jsonObject(
            with: storeEncoder().encode(recording)) as? [String: Any] ?? [:]

        let stored = try storeDecoder().decode(StoredRecording.self,
                                               from: storeEncoder().encode(recording))
        let mirrorJSON = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(stored)) as? [String: Any] ?? [:]

        let missing = Set(appJSON.keys)
            .subtracting(mirrorJSON.keys)
            .subtracting(intentionallyUnmirrored)

        XCTAssertTrue(missing.isEmpty,
                      "Recording persists \(missing.sorted()) but MilaKit's StoredRecording "
                      + "does not mirror them, so mila-mcp will not see them. Add the "
                      + "field(s) to StoredRecording, or add them to "
                      + "`intentionallyUnmirrored` with a reason.")
    }

    func test_minimal_recording_decodes_with_defaults() throws {
        let recording = Recording(title: "Bare", source: .microphone,
                                  audioFileName: "bare.wav")
        let data = try storeEncoder().encode([recording])
        let s = try XCTUnwrap(storeDecoder().decode([StoredRecording].self, from: data).first)
        XCTAssertEqual(s.title, "Bare")
        XCTAssertEqual(s.status, TranscriptionStatus.pending.rawValue)
        // speakerNames is omitted from JSON when empty — mirror defaults to [:].
        XCTAssertEqual(s.speakerNames, [:])
        XCTAssertNil(s.deletedAt)
        XCTAssertFalse(s.isTrashed)
        XCTAssertEqual(s.segments.count, 0)
        XCTAssertNil(s.actionItems)
    }

    func test_legacy_inline_fulltext_decodes() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","title":"Old","createdAt":"2023-01-01T00:00:00Z",
        "duration":1,"source":"microphone","audioFileName":"old.wav","status":"completed",
        "language":"he","segments":[],"fullText":"inline legacy text"}]
        """
        let s = try XCTUnwrap(storeDecoder()
            .decode([StoredRecording].self, from: Data(json.utf8)).first)
        XCTAssertEqual(s.legacyFullText, "inline legacy text")
    }
}
