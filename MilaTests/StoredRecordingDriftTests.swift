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
    private let fixtureDeferred = Date(timeIntervalSince1970: 1_700_000_250)

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
            appBundleID: "us.zoom.xos",
            summary: "A summary.",
            actionItems: [ActionItem(id: "a1", text: "Ship it", speaker: "SPEAKER_00",
                                     timestampSeconds: 3, source: .llmInferred,
                                     addedAt: created)],
            voiceMemoUniqueID: "VM-1",
            voiceMemoFolderUUID: "VMF-1",
            speakerNames: ["SPEAKER_00": "Daniel", "SPEAKER_01": "John Doe"],
            summaryLanguage: "en",
            sharedBy: "Ada Lovelace",
            sharedAt: created,
            transcriptionDeferredAt: fixtureDeferred,
            // Not a state a real row is ever in (a `.completed` row carries no
            // prior state) — this fixture is about every key being present.
            retranscriptionPriorState: .init(status: .completed, language: "he",
                                             modelName: "Earlier model",
                                             transcriptionDeferredAt: fixtureDeferred),
            speakerNameSuggestions: [
                SpeakerNameSuggestion(speaker: "SPEAKER_01", name: "John",
                                      evidence: "hi there, John here", origin: .transcript),
            ],
            untranscribedSpans: [UntranscribedSpan(start: 12, end: 15.5),
                                 UntranscribedSpan(start: 20, end: 21, unreadable: true)]
        )
    }

    /// Top-level keys `Recording` persists that `StoredRecording` deliberately
    /// does not mirror, with the reason. Adding to this list is a decision;
    /// leaving a key out of it is a bug. Shared by the top-level check and
    /// the nested one, which must not demand a mirrored element type for a
    /// container that is not mirrored at all.
    private static let intentionallyUnmirrored: Set<String> = [
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
        // Unconfirmed speaker-name SUGGESTIONS (#348): a model's guess the
        // user has not accepted. MCP exposes the names the user confirmed
        // (`speakerNames`); surfacing a pending guess there would let a
        // client present it as fact. Once accepted it IS a `speakerNames`
        // entry, which is mirrored.
        "speakerNameSuggestions",
    ]

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
        XCTAssertEqual(s.appBundleID, "us.zoom.xos")
        XCTAssertEqual(s.summary, "A summary.")
        XCTAssertEqual(s.actionItems?.count, 1)
        XCTAssertEqual(s.actionItems?.first?.text, "Ship it")
        XCTAssertEqual(s.actionItems?.first?.speaker, "SPEAKER_00")
        XCTAssertEqual(s.actionItems?.first?.timestampSeconds, 3)
        XCTAssertEqual(s.speakerNames, ["SPEAKER_00": "Daniel", "SPEAKER_01": "John Doe"])
        XCTAssertEqual(s.summaryLanguage, "en")
        XCTAssertEqual(s.sharedBy, "Ada Lovelace")
        XCTAssertEqual(s.sharedAt, created)
        XCTAssertEqual(s.transcriptionDeferredAt, fixtureDeferred)
        XCTAssertTrue(s.isTranscriptionDeferred)
        let prior = try XCTUnwrap(s.retranscriptionPriorState)
        XCTAssertEqual(prior.status, TranscriptionStatus.completed.rawValue)
        XCTAssertEqual(prior.language, "he")
        XCTAssertEqual(prior.modelName, "Earlier model")
        XCTAssertEqual(prior.transcriptionDeferredAt, fixtureDeferred)
        let span = try XCTUnwrap(s.untranscribedSpans?.first)
        XCTAssertEqual(s.untranscribedSpans?.count, 2)
        XCTAssertEqual(span.start, 12, accuracy: 0.001)
        XCTAssertEqual(span.end, 15.5, accuracy: 0.001)
        XCTAssertNil(span.unreadable)
        XCTAssertEqual(s.untranscribedSpans?.last?.unreadable, true)
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
        // Deliberately not mirrored — see `Self.intentionallyUnmirrored`.
        let intentionallyUnmirrored = Self.intentionallyUnmirrored

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

    /// The key-set check above stops at depth 1, and that is not enough.
    ///
    /// `segments` and `actionItems` encode as arrays of OBJECTS, so at the
    /// top level they are one key each: `"segments"` is present on both
    /// sides no matter how far the element types have drifted. That
    /// recreated, one level down, the exact blind spot the file exists to
    /// close — and it was not hypothetical. When this test was written it
    /// immediately found live drift: the app's `ActionItem` persists `id`,
    /// `source` and `addedAt`, and the mirror carried none of them, so
    /// mila-mcp could not tell a `voice_command` item (the speaker dictated
    /// it) from an `inferred` one (the model guessed). Every existing test
    /// stayed green throughout, because `JSONDecoder` ignores keys it does
    /// not know. (CodeRabbit on #183.)
    ///
    /// Each container gets its own allowlist for the same reason the
    /// top-level one has one: an omission has to be a decision somebody
    /// wrote down, not a field nobody noticed.
    func test_every_persisted_nested_key_is_mirrored() throws {
        // Keyed by the containing property so a reason is attached to the
        // container it belongs to. Same rule as `intentionallyUnmirrored`:
        // adding to this is a decision, leaving a key out of it is a bug.
        let intentionallyUnmirrored: [String: Set<String>] = [
            // `TranscriptSegment.id` is a UUID minted by the type's default
            // initializer purely to give SwiftUI lists a stable identity. A
            // re-transcription regenerates every one of them, and no MCP
            // tool accepts a segment id — segments are addressed by order
            // and by time. Mirroring it would advertise an addressability
            // the app does not offer.
            "segments": ["id"],
            // Nothing. `ActionItem` is mirrored in full — see the note above
            // for what the gap here used to cost.
            "actionItems": [],
            // Nothing. `RetranscriptionPriorState` is mirrored in full.
            "retranscriptionPriorState": [],
            // Nothing. `UntranscribedSpan` is mirrored in full.
            "untranscribedSpans": [],
        ]
        // Object-valued keys whose KEYS are data, not schema: the mirror
        // decodes them as a dictionary, so there is no element type to drift.
        // Declared rather than detected, so that a new map still has to be
        // classified here by someone — the pin below fails until it is.
        let dataKeyedMaps: Set<String> = [
            // Raw diarizer ID → display name. The round-trip test checks the
            // values; the keys are whatever the diarizer minted.
            "speakerNames",
        ]

        let recording = fullyPopulatedRecording()
        let appJSON = try JSONSerialization.jsonObject(
            with: storeEncoder().encode(recording)) as? [String: Any] ?? [:]
        let stored = try storeDecoder().decode(StoredRecording.self,
                                               from: storeEncoder().encode(recording))
        let mirrorJSON = try JSONSerialization.jsonObject(
            with: storeEncoder().encode(stored)) as? [String: Any] ?? [:]

        // Union across elements, not just `.first`: `encodeIfPresent` drops
        // a nil optional, so one element that happens to leave a field unset
        // would hide that field from the comparison.
        func keyUnion(_ elements: [[String: Any]]) -> Set<String> {
            elements.reduce(into: Set<String>()) { $0.formUnion($1.keys) }
        }
        // A container is either an array of objects or one object; both are
        // compared as a list of elements. nil for anything else.
        func elements(of value: Any?) -> [[String: Any]]? {
            if let array = value as? [[String: Any]] { return array }
            if let object = value as? [String: Any] { return [object] }
            return nil
        }

        // Derive the containers from what the app actually encoded — every
        // top-level key whose value is a non-empty array of objects, or a
        // single object (a nested struct such as `retranscriptionPriorState`,
        // which an arrays-only rule used to skip, leaving its keys free to
        // drift unseen). Driving the loop off `intentionallyUnmirrored`
        // instead would leave this test with the same hole it exists to
        // close: a NEW nested container nobody listed would simply not be
        // checked.
        let containers = appJSON.compactMap { key, value -> String? in
            guard !dataKeyedMaps.contains(key),
                  // Not mirrored at all (top-level allowlist), so there is
                  // no mirrored element type to compare against.
                  !StoredRecordingDriftTests.intentionallyUnmirrored.contains(key),
                  let elements = elements(of: value), !elements.isEmpty else { return nil }
            return key
        }.sorted()
        XCTAssertEqual(containers, ["actionItems", "retranscriptionPriorState", "segments",
                                    "untranscribedSpans"],
                       "Recording gained (or lost) a nested container. Populate it in "
                       + "fullyPopulatedRecording(), mirror its element type in "
                       + "StoredRecording, and pin its shape in "
                       + "test_nested_fixtures_populate_every_persisted_element_key — or, "
                       + "if its keys are data rather than schema, list it in dataKeyedMaps.")
        XCTAssertTrue(Set(intentionallyUnmirrored.keys).subtracting(containers).isEmpty,
                      "stale entries in the nested allowlist: "
                      + "\(Set(intentionallyUnmirrored.keys).subtracting(containers).sorted())")
        let staleMaps = dataKeyedMaps.filter { !(appJSON[$0] is [String: Any]) }
        XCTAssertTrue(staleMaps.isEmpty, "stale entries in dataKeyedMaps: \(staleMaps.sorted())")

        for container in containers {
            let allowlist = intentionallyUnmirrored[container] ?? []
            let appElements = try XCTUnwrap(elements(of: appJSON[container]))
            let mirrorElements = try XCTUnwrap(elements(of: mirrorJSON[container]),
                                               "\(container) is missing (or neither an object nor "
                                               + "an array of objects) in the mirror's JSON — the "
                                               + "whole container is unmirrored")
            XCTAssertFalse(mirrorElements.isEmpty,
                           "\(container) round-tripped as an EMPTY array — the mirror "
                           + "dropped every element")

            let missing = keyUnion(appElements)
                .subtracting(keyUnion(mirrorElements))
                .subtracting(allowlist)

            XCTAssertTrue(missing.isEmpty,
                          "Recording persists \(container)[].\(missing.sorted()) but MilaKit's "
                          + "StoredRecording.\(container) element does not mirror them, so "
                          + "mila-mcp will not see them. Add the field(s) to the mirror's "
                          + "element type, or add them to this test's allowlist with a reason.")
        }
    }

    /// The nested check above is only as good as the fixture feeding it:
    /// `encodeIfPresent` drops a nil optional, so a nested field left unset
    /// in `fullyPopulatedRecording()` never appears in the app's JSON and
    /// silently cannot be compared. Pin the element key sets literally, so
    /// a new nested field forces someone to look here.
    func test_nested_fixtures_populate_every_persisted_element_key() throws {
        let appJSON = try JSONSerialization.jsonObject(
            with: storeEncoder().encode(fullyPopulatedRecording())) as? [String: Any] ?? [:]

        let segment = try XCTUnwrap((appJSON["segments"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(segment.keys), ["id", "start", "end", "text", "speaker"],
                       "TranscriptSegment's persisted shape changed — update the fixture "
                       + "and decide whether the new key belongs in StoredRecording.Segment")

        let item = try XCTUnwrap((appJSON["actionItems"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(item.keys),
                       ["id", "text", "speaker", "timestampSeconds", "source", "addedAt"],
                       "ActionItem's persisted shape changed — update the fixture and decide "
                       + "whether the new key belongs in StoredRecording.ActionItem")

        let prior = try XCTUnwrap(appJSON["retranscriptionPriorState"] as? [String: Any])
        XCTAssertEqual(Set(prior.keys), ["status", "language", "modelName", "transcriptionDeferredAt"],
                       "RetranscriptionPriorState's persisted shape changed — update the fixture "
                       + "and decide whether the new key belongs in "
                       + "StoredRecording.RetranscriptionPriorState")

        let spans = try XCTUnwrap(appJSON["untranscribedSpans"] as? [[String: Any]])
        let spanKeys = spans.reduce(into: Set<String>()) { $0.formUnion($1.keys) }
        XCTAssertEqual(spanKeys, ["start", "end", "unreadable"],
                       "UntranscribedSpan's persisted shape changed — update the fixture and "
                       + "decide whether the new key belongs in StoredRecording.UntranscribedSpan")
    }

    /// The recovered fields must actually arrive, not merely have a key.
    func test_action_item_provenance_survives_the_round_trip() throws {
        let data = try storeEncoder().encode([fullyPopulatedRecording()])
        let s = try XCTUnwrap(storeDecoder().decode([StoredRecording].self, from: data).first)
        let item = try XCTUnwrap(s.actionItems?.first)
        XCTAssertEqual(item.id, "a1")
        XCTAssertEqual(item.source, ActionItem.Source.llmInferred.rawValue)
        XCTAssertEqual(item.addedAt, fixtureCreated)
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
        XCTAssertNil(s.summaryLanguage)
        XCTAssertNil(s.retranscriptionPriorState, "omitted when nil, so a never re-transcribed row has no key")
        XCTAssertNil(s.untranscribedSpans, "omitted when nil, so a complete transcript has no key")
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
