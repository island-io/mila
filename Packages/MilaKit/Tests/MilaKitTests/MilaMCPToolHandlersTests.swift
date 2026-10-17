import XCTest
@testable import MilaKit

final class MilaMCPToolHandlersTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPHandlerTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Recordings", isDirectory: true),
            withIntermediateDirectories: true)
        // Every test below exercises the granted path, so open the gate the
        // same way the app does — through the real file — rather than by
        // injecting a stub. File export is granted too, for the
        // save_transcript tests; MCPAccessGateTests covers both closed paths.
        try MCPAccessGate.set(true, fileExport: true, root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func handlers(now: Date = Date()) -> MilaMCPToolHandlers {
        MilaMCPToolHandlers(root: root, now: { now })
    }

    private func call(_ tool: String, _ args: [String: Any] = [:],
                      now: Date = Date()) throws -> [String: Any] {
        let raw = try handlers(now: now).handle(tool: tool, arguments: args)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    private func seedStore(_ recordings: [StoredRecording]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(recordings)
            .write(to: root.appendingPathComponent("recordings.json"))
    }

    private func meeting(_ title: String, daysAgo: Double,
                         speakerNames: [String: String] = [:],
                         summary: String? = nil) -> StoredRecording {
        StoredRecording(title: title,
                        createdAt: Date(timeIntervalSince1970: 1_700_000_000 - daysAgo * 86_400),
                        duration: 300, source: "meeting",
                        audioFileName: "\(title).wav", status: "completed",
                        segments: [
                            .init(start: 0, end: 3, text: "shalom everyone", speaker: "SPEAKER_00"),
                            .init(start: 3, end: 6, text: "let's begin", speaker: "SPEAKER_01"),
                        ],
                        summary: summary, speakerNames: speakerNames)
    }

    private func liveSnapshot(sessionID: UUID = UUID(), state: LiveTranscriptSnapshot.State = .recording,
                              revision: Int = 3, liveAvailable: Bool = true,
                              updatedAt: Date = Date(),
                              segments: [LiveTranscriptSnapshot.Segment]? = nil,
                              finalRecordingID: UUID? = nil,
                              segmentsRemovedAtRevision: Int? = nil) throws -> LiveTranscriptSnapshot {
        let snap = LiveTranscriptSnapshot(
            sessionID: sessionID, state: state, liveTranscriptAvailable: liveAvailable,
            recordingStartedAt: updatedAt.addingTimeInterval(-120), updatedAt: updatedAt,
            revision: revision,
            segments: segments ?? [
                .init(start: 0, end: 2, text: "first", speaker: "SPEAKER_00"),
                .init(start: 2, end: 4, text: "second", speaker: "SPEAKER_00"),
                .init(start: 4, end: 6, text: "third", speaker: "SPEAKER_01"),
            ],
            speakerNames: ["SPEAKER_00": "Dana"],
            finalRecordingID: finalRecordingID,
            segmentsRemovedAtRevision: segmentsRemovedAtRevision)
        try snap.write(root: root)
        return snap
    }

    // MARK: - Hostile cursor input

    /// `since_segment_index` is unvalidated client input. The cursor used to
    /// compute `index - 1` before clamping, which **traps on `Int.min`**
    /// (arithmetic overflow — the subscript itself was always fine, since
    /// `segments[endIndex...]` is a legal empty slice). A tool call must
    /// never be able to kill the server.
    func test_live_transcript_survives_extreme_segment_cursors() throws {
        let session = UUID()
        _ = try liveSnapshot(sessionID: session)
        for cursor in [Int.min, -1, 0, 1, 3, 4, 9_999, Int.max] {
            XCTAssertNoThrow(
                try call("get_live_transcript",
                         ["session_id": session.uuidString,
                          "since_segment_index": cursor]),
                "since_segment_index \(cursor) must be handled, not trapped")
        }
    }

    /// Clamping must not change what a legitimate cursor returns: the
    /// previously-seen segment is re-sent because live merges rewrite it.
    func test_segment_cursor_still_resends_the_last_seen_segment() throws {
        let snapshot = try liveSnapshot()
        XCTAssertEqual(snapshot.segments(sinceIndex: 0).count, 3)
        XCTAssertEqual(snapshot.segments(sinceIndex: 2).map(\.text), ["second", "third"],
                       "A client holding 2 segments re-reads the 2nd, which may have been rewritten.")
        XCTAssertEqual(snapshot.segments(sinceIndex: 3).map(\.text), ["third"])
        XCTAssertEqual(snapshot.segments(sinceIndex: 4), [],
                       "A cursor past the end means the client is up to date — send nothing, "
                       + "and do not re-send the tail.")
        XCTAssertEqual(snapshot.segments(sinceIndex: Int.max), [])
        XCTAssertEqual(snapshot.segments(sinceIndex: Int.min).count, 3,
                       "A nonsense cursor should read as \"from the start\", not crash.")
    }

    // MARK: - list / get / search via raw JSON args

    func test_list_recordings_speaker_filter_and_shape() throws {
        try seedStore([
            meeting("With John", daysAgo: 1, speakerNames: ["SPEAKER_01": "John Doe"]),
            meeting("Other", daysAgo: 0),
        ])
        let result = try call("list_recordings", ["speaker": "john", "limit": 5])
        XCTAssertEqual(result["count"] as? Int, 1)
        let first = try XCTUnwrap((result["recordings"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["title"] as? String, "With John")
        XCTAssertEqual(first["speakers"] as? [String], ["SPEAKER_00", "John Doe"])
        XCTAssertEqual(first["has_summary"] as? Bool, false)
    }

    /// `duration` arrives verbatim from recordings.json, and `Int(_:)`
    /// traps on anything that is not a finite, representable count — so a
    /// single `"duration": 1e300` row used to abort the whole `mila-mcp`
    /// process on every tool that lists or opens recordings (#322). That row
    /// must report 0, and the healthy row next to it must keep answering.
    func test_an_unrepresentable_duration_reports_zero_instead_of_trapping() throws {
        let huge = UUID(), healthy = UUID()
        let json = """
        [{"id":"\(huge.uuidString)","title":"Huge","createdAt":"2023-11-14T22:13:20Z",
        "duration":1e300,"source":"meeting","audioFileName":"Huge.wav","status":"completed",
        "segments":[{"start":0,"end":1,"text":"needle","speaker":"SPEAKER_00"}]},
        {"id":"\(healthy.uuidString)","title":"Healthy","createdAt":"2023-11-13T22:13:20Z",
        "duration":299.6,"source":"meeting","audioFileName":"Healthy.wav","status":"completed",
        "segments":[{"start":0,"end":1,"text":"needle","speaker":"SPEAKER_00"}]}]
        """
        try Data(json.utf8).write(to: root.appendingPathComponent("recordings.json"))

        let listed = try XCTUnwrap(try call("list_recordings")["recordings"] as? [[String: Any]])
        XCTAssertEqual(listed.map { $0["title"] as? String }, ["Huge", "Healthy"])
        XCTAssertEqual(listed.map { $0["duration_seconds"] as? Int }, [0, 300],
                       "a sane duration still rounds exactly as before")
        XCTAssertEqual(try call("get_transcript", ["id": huge.uuidString])["duration_seconds"] as? Int, 0)
        let hits = try XCTUnwrap(try call("search_transcripts", ["query": "needle"])["results"] as? [[String: Any]])
        XCTAssertEqual(hits.count, 2)
    }

    /// NaN and ±infinity cannot be spelled in JSON, but `StoredRecording`
    /// and the `MilaDataSource` seam carry them, and they trap `Int(_:)` the
    /// same way; a negative duration must not surface as a negative count.
    func test_non_finite_and_negative_durations_report_zero() throws {
        let values: [String: Double] = ["NaN": .nan, "Inf": .infinity, "NegInf": -.infinity,
                                        "Negative": -42, "Max": .greatestFiniteMagnitude]
        // Seeded sane (JSONEncoder refuses NaN/inf); the source substitutes them.
        try seedStore(values.keys.sorted().enumerated().map { index, title in
            meeting(title, daysAgo: Double(index))
        } + [meeting("Healthy", daysAgo: 10)])
        let handlers = MilaMCPToolHandlers(root: root, source: DurationOverridingSource(
            base: FileBackedDataSource(root: root), durations: values))

        let raw = try handlers.handle(tool: "list_recordings", arguments: ["limit": 50])
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let listed = try XCTUnwrap(result["recordings"] as? [[String: Any]])
        var reported: [String: Int] = [:]
        for row in listed { reported[row["title"] as! String] = row["duration_seconds"] as? Int }
        XCTAssertEqual(reported, ["NaN": 0, "Inf": 0, "NegInf": 0, "Negative": 0, "Max": 0, "Healthy": 300])
    }

    func test_whole_seconds_truncates_sane_values_and_zeroes_the_rest() {
        XCTAssertEqual(MilaMCPToolHandlers.wholeSeconds(0), 0)
        XCTAssertEqual(MilaMCPToolHandlers.wholeSeconds(59.9), 59, "truncates toward zero, as Int(_:) did")
        XCTAssertEqual(MilaMCPToolHandlers.wholeSeconds(3_600), 3_600)
        XCTAssertEqual(MilaMCPToolHandlers.wholeSeconds(-0.5), 0)
        for bad in [Double.nan, .infinity, -.infinity, 1e300, 9.3e18, -1] {
            XCTAssertEqual(MilaMCPToolHandlers.wholeSeconds(bad), 0, "\(bad)")
        }
    }

    /// `appBundleID` is mirrored and exposed alongside `app_name` — the stable
    /// key next to the localized display string. It was previously absent from
    /// the mirror entirely, which the drift guard couldn't see because its
    /// fixture never set the field (CodeRabbit on #183).
    func test_app_bundle_id_is_exposed_next_to_app_name() throws {
        var recording = meeting("Zoom call", daysAgo: 0)
        recording.appName = "zoom.us"
        recording.appBundleID = "us.zoom.xos"
        try seedStore([recording])

        let first = try XCTUnwrap((try call("list_recordings")["recordings"]
            as? [[String: Any]])?.first)
        XCTAssertEqual(first["app_name"] as? String, "zoom.us")
        XCTAssertEqual(first["app_bundle_id"] as? String, "us.zoom.xos")
    }

    /// Absent stays absent — the key must not appear as null for the mic
    /// recordings that have no app.
    func test_app_bundle_id_is_omitted_when_unknown() throws {
        try seedStore([meeting("Mic memo", daysAgo: 0)])
        let first = try XCTUnwrap((try call("list_recordings")["recordings"]
            as? [[String: Any]])?.first)
        XCTAssertNil(first["app_bundle_id"])
    }

    /// A recording that arrived as a `.milashare` bundle says who shared
    /// it; one this Mac captured itself carries no `shared_by` key at all.
    func test_shared_by_is_exposed_only_on_shared_recordings() throws {
        var shared = meeting("Their sync", daysAgo: 1)
        shared.sharedBy = "Ada Lovelace"
        shared.sharedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try seedStore([meeting("My memo", daysAgo: 0), shared])

        let rows = try XCTUnwrap(try call("list_recordings")["recordings"] as? [[String: Any]])
        let byTitle = Dictionary(uniqueKeysWithValues: rows.map { ($0["title"] as! String, $0) })
        XCTAssertEqual(byTitle["Their sync"]?["shared_by"] as? String, "Ada Lovelace")
        XCTAssertNil(byTitle["My memo"]?["shared_by"])
    }

    /// The tool-layer half of the trashed-recording leak: a client holding a
    /// retained UUID must get a not-found, not the transcript.
    /// (CodeRabbit on #183, CWE-200.)
    func test_get_transcript_refuses_a_trashed_recording_by_id() throws {
        var trashed = meeting("Deleted meeting", daysAgo: 0)
        trashed.deletedAt = Date(timeIntervalSince1970: 1_700_000_100)
        try seedStore([trashed])

        XCTAssertThrowsError(try call("get_transcript", ["id": trashed.id.uuidString])) { error in
            XCTAssertTrue(String(describing: error).contains("No recording with id"),
                          String(describing: error))
        }
        XCTAssertEqual(try call("list_recordings")["count"] as? Int, 0,
                       "and the listing agrees — one store, one answer")
    }

    func test_list_recordings_rejects_bad_sort_and_date() throws {
        try seedStore([meeting("A", daysAgo: 0)])
        XCTAssertThrowsError(try call("list_recordings", ["sort": "bogus"]))
        XCTAssertThrowsError(try call("list_recordings", ["after": "not-a-date"]))
    }

    func test_get_transcript_latest_with_names_and_summary() throws {
        try seedStore([
            meeting("Latest", daysAgo: 0,
                    speakerNames: ["SPEAKER_00": "Dana", "SPEAKER_01": "John Doe"],
                    summary: "Quick sync."),
            meeting("Older", daysAgo: 2),
        ])
        let result = try call("get_transcript")
        XCTAssertEqual(result["title"] as? String, "Latest")
        XCTAssertEqual(result["transcript"] as? String,
                       "Dana: shalom everyone\nJohn Doe: let's begin")
        XCTAssertEqual(result["summary"] as? String, "Quick sync.")
    }

    /// While a re-transcription in the other language is in flight the app
    /// has already switched `language` to the re-run's, but the text on disk
    /// is still the earlier transcript. `language` must describe the text
    /// returned (island-io/mila#330).
    func test_get_transcript_reports_the_earlier_language_while_a_rerun_is_in_flight() throws {
        var rerun = meeting("English meeting", daysAgo: 0)
        rerun.status = "running"
        rerun.language = "he"
        rerun.retranscriptionPriorState = .init(status: "completed", language: "en",
                                                modelName: "Earlier model")
        var settled = meeting("Settled", daysAgo: 1)
        settled.language = "he"
        // A stale prior state on a settled row (a crash between writes) must
        // not override the row's own language.
        settled.retranscriptionPriorState = .init(status: "completed", language: "en")
        // A re-run of a stopped partial draft: the kept text is not finished.
        var draftRerun = meeting("Draft", daysAgo: 2)
        draftRerun.status = "pending"
        draftRerun.retranscriptionPriorState = .init(status: "failed", language: "en")
        try seedStore([rerun, settled, draftRerun])

        let inFlight = try call("get_transcript", ["id": rerun.id.uuidString])
        XCTAssertEqual(inFlight["language"] as? String, "en")
        XCTAssertEqual(inFlight["transcript"] as? String,
                       "SPEAKER_00: shalom everyone\nSPEAKER_01: let's begin")
        let note = inFlight["note"] as? String ?? ""
        XCTAssertTrue(note.contains("re-transcription") && note.contains("finished"), note)

        let draftNote = try call("get_transcript", ["id": draftRerun.id.uuidString])["note"] as? String ?? ""
        XCTAssertTrue(draftNote.contains("may be partial") && !draftNote.contains("finished"), draftNote)

        XCTAssertEqual(try call("get_transcript", ["id": settled.id.uuidString])["language"] as? String,
                       "he")
    }

    func test_get_transcript_max_chars_truncates() throws {
        try seedStore([meeting("Long", daysAgo: 0)])
        let result = try call("get_transcript", ["max_chars": 10])
        XCTAssertEqual((result["transcript"] as? String)?.count, 10)
        XCTAssertEqual(result["transcript_truncated"] as? Bool, true)
    }

    // MARK: get_transcript format

    /// Omitting `format` is the pre-existing behaviour, now labelled.
    /// Every existing client reads this shape, so the only permitted
    /// difference is the added key.
    func test_get_transcript_default_format_is_text_and_reports_it() throws {
        try seedStore([meeting("Latest", daysAgo: 0,
                               speakerNames: ["SPEAKER_00": "Dana", "SPEAKER_01": "John Doe"])])
        let result = try call("get_transcript")
        XCTAssertEqual(result["format"] as? String, "text")
        XCTAssertEqual(result["transcript"] as? String,
                       "Dana: shalom everyone\nJohn Doe: let's begin")
        XCTAssertEqual(result["transcript_truncated"] as? Bool, false)
    }

    func test_get_transcript_format_srt_renders_named_cues() throws {
        try seedStore([meeting("Subtitled", daysAgo: 0,
                               speakerNames: ["SPEAKER_00": "Dana", "SPEAKER_01": "John Doe"],
                               summary: "Quick sync.")])
        let result = try call("get_transcript", ["format": "srt"])
        XCTAssertEqual(result["format"] as? String, "srt")
        XCTAssertEqual(result["transcript"] as? String,
                       "1\n00:00:00,000 --> 00:00:03,000\nDana: shalom everyone\n\n"
                       + "2\n00:00:03,000 --> 00:00:06,000\nJohn Doe: let's begin\n\n")
        XCTAssertEqual(result["transcript_truncated"] as? Bool, false)
        XCTAssertEqual(result["summary"] as? String, "Quick sync.",
                       "format changes the transcript rendering only")
    }

    /// A cue cut in the middle is not a subtitle file, so `max_chars`
    /// drops whole cues from the end instead — and when even the first
    /// does not fit, returns nothing rather than a fragment.
    func test_get_transcript_format_srt_max_chars_cuts_on_cue_boundary() throws {
        try seedStore([meeting("Subtitled", daysAgo: 0)])
        let full = try XCTUnwrap(try call("get_transcript", ["format": "srt"])["transcript"] as? String)
        let firstCue = try XCTUnwrap(full.components(separatedBy: "\n\n").first)

        let oneShort = try call("get_transcript", ["format": "srt", "max_chars": full.count - 1])
        XCTAssertEqual(oneShort["transcript"] as? String, firstCue + "\n\n")
        XCTAssertEqual(oneShort["transcript_truncated"] as? Bool, true)

        let exact = try call("get_transcript", ["format": "srt", "max_chars": full.count])
        XCTAssertEqual(exact["transcript"] as? String, full)
        XCTAssertEqual(exact["transcript_truncated"] as? Bool, false)

        let tiny = try call("get_transcript", ["format": "srt", "max_chars": 10])
        XCTAssertEqual(tiny["transcript"] as? String, "")
        XCTAssertEqual(tiny["transcript_truncated"] as? Bool, true)
    }

    /// For a recording with no speaker labels, text mode serves the `.txt`
    /// sidecar (that file IS the transcript). SRT must not: the sidecar has
    /// no timings, and the segments do.
    func test_get_transcript_format_srt_ignores_the_txt_sidecar() throws {
        let unlabelled = StoredRecording(
            title: "Plain", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 10, source: "mic", audioFileName: "Plain.wav", status: "completed",
            segments: [
                .init(start: 0, end: 2, text: "from the segments"),
                .init(start: 2, end: 4, text: "with timings"),
            ])
        try seedStore([unlabelled])
        try "SIDECAR TEXT".write(to: root.appendingPathComponent("Recordings/Plain.txt"),
                                atomically: true, encoding: .utf8)

        XCTAssertEqual(try call("get_transcript")["transcript"] as? String, "SIDECAR TEXT",
                       "precondition: text mode does read the sidecar for an unlabelled recording")
        let srt = try XCTUnwrap(try call("get_transcript", ["format": "srt"])["transcript"] as? String)
        XCTAssertEqual(srt,
                       "1\n00:00:00,000 --> 00:00:02,000\nfrom the segments\n\n"
                       + "2\n00:00:02,000 --> 00:00:04,000\nwith timings\n\n")
        XCTAssertFalse(srt.contains("SIDECAR"))
    }

    /// A legacy record whose transcript exists only as text has no SRT to
    /// give; the error says so and points back at `text`.
    func test_get_transcript_format_srt_without_segments_throws() throws {
        let id = UUID()
        let json = """
        [{"id":"\(id.uuidString)","title":"Legacy",
        "createdAt":"2023-11-14T22:13:20Z","duration":60,"source":"meeting",
        "audioFileName":"Legacy.wav","status":"completed",
        "fullText":"only ever stored as text"}]
        """
        try Data(json.utf8).write(to: root.appendingPathComponent("recordings.json"))

        XCTAssertEqual(try call("get_transcript")["transcript"] as? String, "only ever stored as text",
                       "precondition: text mode still answers")
        XCTAssertThrowsError(try call("get_transcript", ["format": "srt"])) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("srt") && message.contains(id.uuidString), message)
        }
    }

    func test_get_transcript_rejects_bad_format() throws {
        try seedStore([meeting("A", daysAgo: 0)])
        XCTAssertThrowsError(try call("get_transcript", ["format": "vtt"])) { error in
            XCTAssertTrue(String(describing: error).contains("Invalid arguments"),
                          String(describing: error))
        }
        // Arguments are validated before the store lookup, as in the other
        // tools, so a bad format is not hidden behind an unknown id.
        XCTAssertThrowsError(try call("get_transcript", ["id": UUID().uuidString, "format": "vtt"])) { error in
            XCTAssertTrue(String(describing: error).contains("Invalid arguments"),
                          String(describing: error))
        }
    }

    /// A `pending`/`running` recording has no segments stored yet either, and
    /// that is not a legacy text-only record: the refusal names the status so
    /// the client knows to wait rather than give up on subtitles.
    func test_get_transcript_format_srt_without_segments_names_the_status() throws {
        var pending = meeting("Fresh", daysAgo: 0)
        pending.status = "pending"
        pending.segments = []
        let legacy = StoredRecording(title: "Legacy", createdAt: Date(timeIntervalSince1970: 1_600_000_000),
                                     audioFileName: "Legacy.wav", status: "completed",
                                     legacyFullText: "only ever stored as text")
        try seedStore([pending, legacy])

        XCTAssertThrowsError(try call("get_transcript", ["id": pending.id.uuidString, "format": "srt"])) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("transcription status is \"pending\""), message)
            XCTAssertTrue(message.contains(pending.id.uuidString), message)
            XCTAssertFalse(message.contains("legacy"), message)
            XCTAssertFalse(message.contains("Invalid arguments"),
                           "a transcription still in progress is a precondition, not a caller mistake: \(message)")
        }
        XCTAssertThrowsError(try call("get_transcript", ["id": legacy.id.uuidString, "format": "srt"])) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.hasPrefix("Invalid arguments"), message)
            XCTAssertTrue(message.contains("legacy or text-only transcript"), message)
            XCTAssertFalse(message.contains("status is"), message)
        }
    }

    /// `transcript: ""` + `transcript_truncated: true` is the right answer
    /// when not even the first cue fits, but alone it reads like an empty
    /// recording. The `note` says what would have made it fit — and joins
    /// the status note rather than replacing it.
    func test_get_transcript_format_srt_explains_a_max_chars_too_small_for_one_cue() throws {
        try seedStore([meeting("Subtitled", daysAgo: 0)])
        let full = try XCTUnwrap(try call("get_transcript", ["format": "srt"])["transcript"] as? String)
        let firstCue = try XCTUnwrap(full.components(separatedBy: "\n\n").first)

        let tiny = try call("get_transcript", ["format": "srt", "max_chars": 10])
        XCTAssertEqual(tiny["transcript"] as? String, "")
        XCTAssertEqual(tiny["transcript_truncated"] as? Bool, true)
        let note = try XCTUnwrap(tiny["note"] as? String)
        XCTAssertTrue(note.contains("max_chars 10") && note.contains("\(firstCue.count + 2) characters"), note)

        let fits = try call("get_transcript", ["format": "srt", "max_chars": firstCue.count + 2])
        XCTAssertEqual(fits["transcript"] as? String, firstCue + "\n\n")
        XCTAssertNil(fits["note"], "the hint is only for an empty result")

        var running = meeting("Still going", daysAgo: 0)
        running.status = "running"
        try seedStore([running])
        let both = try XCTUnwrap(
            try call("get_transcript", ["id": running.id.uuidString, "format": "srt", "max_chars": 10])["note"] as? String)
        XCTAssertTrue(both.hasPrefix("Transcription status is \"running\""), both)
        XCTAssertTrue(both.contains("max_chars 10"), both)
    }

    /// A recording whose transcription the user stopped to run later is
    /// stored as `failed` — but nothing failed, and a client relaying "your
    /// transcription failed" would be wrong. Both surfaces have to say so,
    /// and a genuine failure must keep reading as one.
    func test_a_stopped_transcription_is_reported_as_stopped_not_failed() throws {
        var stopped = meeting("Stopped", daysAgo: 0)
        stopped.status = "failed"
        stopped.segments = []
        stopped.transcriptionDeferredAt = Date(timeIntervalSince1970: 1_700_000_050)
        var failed = meeting("Broken", daysAgo: 1)
        failed.status = "failed"
        failed.segments = []
        try seedStore([stopped, failed])

        let items = try XCTUnwrap(try call("list_recordings")["recordings"] as? [[String: Any]])
        let listedStopped = try XCTUnwrap(items.first { $0["title"] as? String == "Stopped" })
        let listedFailed = try XCTUnwrap(items.first { $0["title"] as? String == "Broken" })
        XCTAssertEqual(listedStopped["transcription_stopped"] as? Bool, true)
        XCTAssertNil(listedFailed["transcription_stopped"], "a real failure must not claim the user stopped it")

        let stoppedNote = try call("get_transcript", ["id": stopped.id.uuidString])["note"] as? String
        XCTAssertTrue(stoppedNote?.contains("stopped") == true, String(describing: stoppedNote))
        let failedNote = try call("get_transcript", ["id": failed.id.uuidString])["note"] as? String
        XCTAssertTrue(failedNote?.contains("\"failed\"") == true, String(describing: failedNote))
    }

    // MARK: save_transcript

    private func exportDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPExport-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func assertInvalid(_ args: [String: Any], mentions needle: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try call("save_transcript", args), file: file, line: line) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains(needle), message, file: file, line: line)
        }
    }

    /// The point of `save_transcript`: the file is written by the helper and
    /// the reply carries no transcript text for the client to re-emit.
    func test_save_transcript_writes_the_file_and_omits_the_transcript_from_the_reply() throws {
        try seedStore([meeting("Latest", daysAgo: 0,
                               speakerNames: ["SPEAKER_00": "דנה", "SPEAKER_01": "John Doe"],
                               summary: "Quick sync.")])
        let target = try exportDirectory().appendingPathComponent("out.txt")
        let result = try call("save_transcript", ["path": target.path])

        let written = try String(contentsOf: target, encoding: .utf8)
        XCTAssertEqual(written, "דנה: shalom everyone\nJohn Doe: let's begin")
        XCTAssertNil(result["transcript"])
        XCTAssertEqual(result["bytes"] as? Int, Data(written.utf8).count)
        XCTAssertEqual(result["characters"] as? Int, written.count)
        let savedTo = try XCTUnwrap(result["saved_to"] as? String)
        XCTAssertEqual(URL(fileURLWithPath: savedTo).resolvingSymlinksInPath(),
                       target.resolvingSymlinksInPath())
        XCTAssertNil(result["summary"], "the write reply stays small; get_transcript has the summary")
    }

    func test_save_transcript_srt_writes_the_same_bytes_the_reply_would_carry() throws {
        try seedStore([meeting("Subtitled", daysAgo: 0)])
        let inline = try XCTUnwrap(try call("get_transcript", ["format": "srt"])["transcript"] as? String)
        let target = try exportDirectory().appendingPathComponent("subs.srt")
        _ = try call("save_transcript", ["format": "srt", "path": target.path])
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), inline)
    }

    /// An existing folder gets a dated, title-derived name with the format's
    /// extension, with path separators in the title neutralised.
    func test_save_transcript_a_folder_names_the_file_from_date_and_title() throws {
        try seedStore([meeting("Q3 / planning: kickoff", daysAgo: 0)])
        let dir = try exportDirectory()
        let result = try call("save_transcript", ["format": "srt", "path": dir.path])
        let savedTo = URL(fileURLWithPath: try XCTUnwrap(result["saved_to"] as? String))
        XCTAssertEqual(savedTo.deletingLastPathComponent().resolvingSymlinksInPath(),
                       dir.resolvingSymlinksInPath())
        XCTAssertTrue(savedTo.lastPathComponent.hasSuffix(" Q3 - planning- kickoff.srt"),
                      savedTo.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedTo.path))
    }

    /// APFS caps a name at 255 UTF-8 bytes. A long Hebrew or emoji title
    /// must still produce a name that fits, cut between characters.
    func test_save_transcript_to_a_folder_keeps_long_titles_under_the_byte_limit() throws {
        let titles = [String(repeating: "פגישה ", count: 60), String(repeating: "🎙️", count: 100)]
        try seedStore(titles.enumerated().map { meeting($1, daysAgo: Double($0)) })
        let recordings = try MilaStoreReader(root: root).loadRecordings()
        let dir = try exportDirectory()
        for recording in recordings {
            let result = try call("save_transcript", ["id": recording.id.uuidString, "path": dir.path])
            let name = URL(fileURLWithPath: try XCTUnwrap(result["saved_to"] as? String)).lastPathComponent
            XCTAssertLessThanOrEqual(name.utf8.count, 255, name)
            XCTAssertTrue(name.hasSuffix(".txt"), name)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 2)
    }

    /// Writing is its own tool so a client asks permission for it
    /// separately — `get_transcript` must stay read-only.
    func test_get_transcript_has_no_write_arguments() throws {
        let specs = Dictionary(uniqueKeysWithValues: MilaMCPToolHandlers.toolSpecs.map { ($0.name, $0) })
        let getProps = try XCTUnwrap(specs["get_transcript"]?.inputSchema["properties"] as? [String: Any])
        XCTAssertNil(getProps["path"]); XCTAssertNil(getProps["save_to"]); XCTAssertNil(getProps["overwrite"])
        XCTAssertNotNil(specs["save_transcript"])
    }

    func test_save_transcript_refuses_an_existing_file_unless_overwrite() throws {
        try seedStore([meeting("Latest", daysAgo: 0)])
        let target = try exportDirectory().appendingPathComponent("out.txt")
        try "keep me".write(to: target, atomically: true, encoding: .utf8)

        assertInvalid(["path": target.path], mentions: "already exists")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep me")

        _ = try call("save_transcript", ["path": target.path, "overwrite": true])
        XCTAssertNotEqual(try String(contentsOf: target, encoding: .utf8), "keep me")
    }

    func test_save_transcript_rejects_relative_and_missing_paths() throws {
        try seedStore([meeting("Latest", daysAgo: 0)])
        let dir = try exportDirectory()
        assertInvalid(["path": "out.txt"], mentions: "absolute")
        assertInvalid(["path": dir.appendingPathComponent("nope/out.txt").path],
                      mentions: "does not exist")
        assertInvalid([:], mentions: "path is required")
        assertInvalid(["path": ""], mentions: "path is required")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [],
                       "a refused call leaves nothing behind")
    }

    /// Writing transcript text over recordings.json (or anything else in
    /// Mila's app-support root) would corrupt the library.
    func test_save_transcript_refuses_mila_own_data_directories() throws {
        try seedStore([meeting("Latest", daysAgo: 0)])
        let store = root.appendingPathComponent("recordings.json")
        let before = try Data(contentsOf: store)
        assertInvalid(["path": store.path, "overwrite": true], mentions: "Mila's own data")
        assertInvalid(["path": root.appendingPathComponent("Recordings").path],
                      mentions: "Mila's own data")
        assertInvalid(["path": root.appendingPathComponent("Recordings/new.txt").path],
                      mentions: "Mila's own data")
        XCTAssertEqual(try Data(contentsOf: store), before)
    }

    /// APFS is case-insensitive by default, so a differently-cased spelling
    /// of the root IS the root. A string-prefix check let this through and
    /// overwrote recordings.json; containment is now decided by filesystem
    /// identity.
    func test_save_transcript_refuses_a_differently_cased_spelling_of_the_root() throws {
        try seedStore([meeting("Latest", daysAgo: 0)])
        let store = root.appendingPathComponent("recordings.json")
        let before = try Data(contentsOf: store)
        let variant = root.deletingLastPathComponent()
            .appendingPathComponent(root.lastPathComponent.lowercased(), isDirectory: true)
        XCTAssertNotEqual(variant.path, root.path, "precondition: a different spelling")
        let target = variant.appendingPathComponent("RECORDINGS.JSON").path
        if FileManager.default.fileExists(atPath: variant.path) {
            // Case-insensitive volume (the macOS default): the same folder.
            assertInvalid(["path": target, "overwrite": true], mentions: "Mila's own data")
        } else {
            // Case-sensitive volume: a different, missing folder.
            assertInvalid(["path": target, "overwrite": true], mentions: "does not exist")
        }
        XCTAssertEqual(try Data(contentsOf: store), before)
    }

    /// A symlinked folder spells the root under another name entirely.
    func test_save_transcript_refuses_a_symlinked_folder_into_mila_data() throws {
        try seedStore([meeting("Latest", daysAgo: 0)])
        let store = root.appendingPathComponent("recordings.json")
        let before = try Data(contentsOf: store)
        let link = try exportDirectory().appendingPathComponent("mila-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)

        assertInvalid(["path": link.appendingPathComponent("recordings.json").path, "overwrite": true],
                      mentions: "Mila's own data")
        assertInvalid(["path": link.path], mentions: "Mila's own data")
        XCTAssertEqual(try Data(contentsOf: store), before)
    }

    /// `~/Desktop/notes.txt -> recordings.json` with overwrite used to write
    /// straight through the link. A destination that is a symlink is refused,
    /// with or without overwrite, and the link itself is left alone.
    func test_save_transcript_refuses_a_destination_that_is_a_symlink() throws {
        try seedStore([meeting("Latest", daysAgo: 0)])
        let store = root.appendingPathComponent("recordings.json")
        let before = try Data(contentsOf: store)
        let dir = try exportDirectory()
        let link = dir.appendingPathComponent("notes.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: store)
        let dangling = dir.appendingPathComponent("dangling.txt")
        try FileManager.default.createSymbolicLink(
            at: dangling, withDestinationURL: dir.appendingPathComponent("nowhere.txt"))

        assertInvalid(["path": link.path, "overwrite": true], mentions: "symbolic link")
        assertInvalid(["path": link.path], mentions: "symbolic link")
        assertInvalid(["path": dangling.path, "overwrite": true], mentions: "symbolic link")
        XCTAssertEqual(try Data(contentsOf: store), before)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), store.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("nowhere.txt").path),
                       "a dangling link must not be followed to create its target")
    }

    /// A relocated recordings folder can be somewhere ordinary, so it is not
    /// off limits as a whole: a new export may be created there. What is
    /// protected is Mila's own files in it.
    func test_save_transcript_into_a_relocated_recordings_folder_protects_only_milas_files() throws {
        let relocated = try exportDirectory()
        let store = relocated.appendingPathComponent("recordings.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([meeting("Latest", daysAgo: 0)]).write(to: store)
        try StoreLocationPointer(recordingsDirectory: relocated.path,
                                 storeFile: store.path, updatedAt: Date()).write(to: root)
        // A recording's audio, whose `.txt` sidecar is not written yet, and
        // an unrelated file the user keeps in the same folder.
        try Data("RIFF".utf8).write(to: relocated.appendingPathComponent("Latest.wav"))
        try "user's own notes".write(to: relocated.appendingPathComponent("notes.txt"),
                                     atomically: true, encoding: .utf8)
        let storeBefore = try Data(contentsOf: store)

        let result = try call("save_transcript",
                              ["path": relocated.appendingPathComponent("Export.txt").path])
        XCTAssertNotNil(result["saved_to"], "a new export in the relocated folder is allowed")
        let viaFolder = try call("save_transcript", ["path": relocated.path])
        XCTAssertNotNil(viaFolder["saved_to"], "so is the default name in it")

        // Nothing already there is replaced, overwrite or not.
        assertInvalid(["path": store.path, "overwrite": true], mentions: "recordings folder")
        assertInvalid(["path": relocated.appendingPathComponent("notes.txt").path, "overwrite": true],
                      mentions: "recordings folder")
        // Mila's names are reserved even before they exist, in any case.
        assertInvalid(["path": relocated.appendingPathComponent("Folders.JSON").path],
                      mentions: "Mila uses that name")
        // Audio would be imported as a recording by the orphan sweep.
        assertInvalid(["path": relocated.appendingPathComponent("export.wav").path],
                      mentions: "extension")
        // `Latest.txt` / `.srt` / `.summary.txt` are that recording's sidecars.
        for name in ["latest.txt", "Latest.srt", "Latest.summary.txt"] {
            assertInvalid(["path": relocated.appendingPathComponent(name).path],
                          mentions: "belongs to one of Mila's recordings")
        }
        XCTAssertEqual(try Data(contentsOf: store), storeBefore)
        XCTAssertEqual(try String(contentsOf: relocated.appendingPathComponent("notes.txt"), encoding: .utf8),
                       "user's own notes")
    }

    /// `~/Exports/` names a folder. When it does not exist that is an error —
    /// it used to become a FILE called `Exports` in the parent.
    func test_save_transcript_trailing_slash_means_a_folder() throws {
        try seedStore([meeting("Latest", daysAgo: 0)])
        let dir = try exportDirectory()
        assertInvalid(["path": dir.path + "/Exports/"], mentions: "does not exist")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [],
                       "no file named after the missing folder")

        let result = try call("save_transcript", ["path": dir.path + "/"])
        let savedTo = URL(fileURLWithPath: try XCTUnwrap(result["saved_to"] as? String))
        XCTAssertEqual(savedTo.deletingLastPathComponent().resolvingSymlinksInPath(),
                       dir.resolvingSymlinksInPath())
        XCTAssertTrue(savedTo.lastPathComponent.hasSuffix(" Latest.txt"), savedTo.lastPathComponent)
    }

    /// A file carries no "partial" note. Pending, failed and deferred rows are
    /// refused — and with overwrite, a good export must survive the attempt.
    func test_save_transcript_refuses_recordings_without_a_finished_transcript() throws {
        var pending = meeting("Fresh", daysAgo: 0)
        pending.status = "pending"
        pending.segments = []
        var failed = meeting("Broken", daysAgo: 1)
        failed.status = "failed"
        var deferred = meeting("Later", daysAgo: 2)
        deferred.status = "failed"
        deferred.transcriptionDeferredAt = Date(timeIntervalSince1970: 1_700_000_000)
        var rerun = meeting("Rerun", daysAgo: 3)
        rerun.status = "running"
        rerun.retranscriptionPriorState = .init(status: "completed", language: "en")
        try seedStore([pending, failed, deferred, rerun])

        let dir = try exportDirectory()
        let target = dir.appendingPathComponent("good.txt")
        try "a good export".write(to: target, atomically: true, encoding: .utf8)
        for recording in [pending, failed, deferred] {
            for format in ["text", "srt"] {
                assertInvalid(["id": recording.id.uuidString, "path": target.path,
                               "overwrite": true, "format": format],
                              mentions: "no finished transcript")
            }
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "a good export")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["good.txt"])

        // A re-run in flight still holds the earlier FINISHED transcript.
        let saved = try call("save_transcript", ["id": rerun.id.uuidString,
                                                 "path": dir.appendingPathComponent("rerun.txt").path])
        XCTAssertNotNil(saved["saved_to"])
        XCTAssertTrue((saved["note"] as? String ?? "").contains("re-transcription"))
    }

    /// A completed row whose transcript renders empty must not produce (or,
    /// with overwrite, leave behind) an empty file.
    func test_save_transcript_refuses_an_empty_transcript() throws {
        var empty = meeting("Silent", daysAgo: 0)
        empty.segments = []
        try seedStore([empty])
        let target = try exportDirectory().appendingPathComponent("good.txt")
        try "a good export".write(to: target, atomically: true, encoding: .utf8)
        assertInvalid(["id": empty.id.uuidString, "path": target.path, "overwrite": true],
                      mentions: "empty transcript")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "a good export")
    }

    /// The path is checked before the store is loaded: with no store at all,
    /// a bad path still reports the path, not "store could not be read".
    func test_save_transcript_validates_the_path_before_touching_the_store() throws {
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("recordings.json").path), "precondition: no store")
        let dir = try exportDirectory()
        assertInvalid(["path": "out.txt"], mentions: "absolute")
        assertInvalid(["path": dir.appendingPathComponent("missing/out.txt").path],
                      mentions: "does not exist")
        assertInvalid(["path": root.appendingPathComponent("out.txt").path],
                      mentions: "Mila's own data")
        // A good path does reach the store, and reports it.
        XCTAssertThrowsError(try call("save_transcript",
                                      ["path": dir.appendingPathComponent("out.txt").path])) { error in
            XCTAssertTrue(String(describing: error).contains("could not be read"),
                          String(describing: error))
        }
    }

    /// Format controls are not all hostile: ZWJ holds composed emoji
    /// together and RLM/LRM keep a mixed Hebrew/English title in order. Only
    /// the bidi override/isolate controls (which can make a name read as
    /// something else) and real control characters are replaced.
    func test_default_file_name_keeps_joiners_and_marks_but_not_overrides() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        func name(_ title: String) -> String {
            TranscriptFileWriter.defaultFileName(title: title, createdAt: date, fileExtension: "txt")
        }
        let family = "👨\u{200D}👩\u{200D}👧 sync"
        XCTAssertTrue(name(family).hasSuffix(" \(family).txt"), name(family))
        let mixed = "פגישה\u{200F} Q3\u{200E} review\u{200C}"
        XCTAssertTrue(name(mixed).hasSuffix(" \(mixed).txt"), name(mixed))
        for override in ["\u{202E}", "\u{202A}", "\u{2066}", "\u{2069}"] {
            XCTAssertFalse(name("a\(override)b").unicodeScalars.contains { $0 == override.unicodeScalars.first! },
                           "bidi control U+\(String(override.unicodeScalars.first!.value, radix: 16)) must be replaced")
        }
        XCTAssertTrue(name("a\u{0007}b\nc/d:e\\f").hasSuffix(" a-b-c-d-e-f.txt"),
                      name("a\u{0007}b\nc/d:e\\f"))
    }

    func test_get_transcript_unknown_id_throws_not_found() throws {
        try seedStore([meeting("A", daysAgo: 0)])
        XCTAssertThrowsError(try call("get_transcript", ["id": UUID().uuidString]))
        XCTAssertThrowsError(try call("get_transcript", ["id": "not-a-uuid"]))
    }

    func test_search_requires_query() throws {
        try seedStore([meeting("A", daysAgo: 0)])
        XCTAssertThrowsError(try call("search_transcripts"))
        let result = try call("search_transcripts", ["query": "begin"])
        XCTAssertEqual(result["count"] as? Int, 1)
    }

    func test_unknown_tool_throws() {
        XCTAssertThrowsError(try call("bogus_tool"))
    }

    // MARK: - get_live_transcript

    func test_live_no_snapshot_is_not_recording() throws {
        XCTAssertEqual(try call("get_live_transcript")["status"] as? String, "not_recording")
    }

    func test_live_first_poll_returns_full_transcript_and_cursor() throws {
        let snap = try liveSnapshot()
        let result = try call("get_live_transcript")
        XCTAssertEqual(result["status"] as? String, "recording")
        XCTAssertEqual(result["session_id"] as? String, snap.sessionID.uuidString)
        XCTAssertEqual(result["revision"] as? Int, 3)
        XCTAssertEqual(result["next_segment_index"] as? Int, 3)
        XCTAssertEqual((result["new_segments"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual(result["transcript"] as? String,
                       "Dana: first second\nSPEAKER_01: third")
    }

    func test_live_same_revision_short_circuits() throws {
        let snap = try liveSnapshot(revision: 3)
        let result = try call("get_live_transcript", [
            "session_id": snap.sessionID.uuidString,
            "since_revision": 3,
        ])
        XCTAssertEqual(result["changed"] as? Bool, false)
        XCTAssertNil(result["new_segments"])
    }

    func test_live_delta_resends_last_seen_segment() throws {
        let snap = try liveSnapshot(revision: 4)
        // Client saw 2 segments; snapshot now has 3 → resend segment 2 + new segment 3.
        let result = try call("get_live_transcript", [
            "session_id": snap.sessionID.uuidString,
            "since_revision": 2,
            "since_segment_index": 2,
        ])
        XCTAssertEqual(result["changed"] as? Bool, true)
        let texts = (result["new_segments"] as? [[String: Any]])?.compactMap { $0["text"] as? String }
        XCTAssertEqual(texts, ["second", "third"])
        XCTAssertEqual(result["next_segment_index"] as? Int, 3)
    }

    // MARK: - A deleted line must reach the poller

    /// The user deleted the middle line mid-meeting. A poller holding all
    /// three lines has a cursor the delta cannot honour: `segments(sinceIndex:
    /// 3)` over a two-entry list is `[]`, so the reply would be "nothing was
    /// removed, nothing is new" and the client would keep quoting the deleted
    /// text for the rest of the call. It must be handed the complete current
    /// set instead, flagged so it replaces rather than appends.
    func test_live_delta_resends_everything_after_a_line_is_removed() throws {
        let snap = try liveSnapshot(
            revision: 5,
            segments: [
                .init(start: 0, end: 2, text: "first", speaker: "SPEAKER_00"),
                .init(start: 4, end: 6, text: "third", speaker: "SPEAKER_01"),
            ],
            segmentsRemovedAtRevision: 5)
        let result = try call("get_live_transcript", [
            "session_id": snap.sessionID.uuidString,
            "since_revision": 4,
            "since_segment_index": 3,
        ])
        XCTAssertEqual(result["changed"] as? Bool, true)
        XCTAssertEqual(result["segments_removed"] as? Bool, true)
        let texts = (result["new_segments"] as? [[String: Any]])?.compactMap { $0["text"] as? String }
        XCTAssertEqual(texts, ["first", "third"],
                       "a cursor that predates the removal must get the whole set, not an empty delta")
        XCTAssertEqual(result["next_segment_index"] as? Int, 2,
                       "the client's cursor has to be corrected too, or every later line is mis-stitched")
        let transcript = try XCTUnwrap(result["transcript"] as? String)
        XCTAssertFalse(transcript.contains("second"),
                       "the deleted line must not come back in the rendered transcript")
        let note = try XCTUnwrap(result["note"] as? String)
        XCTAssertTrue(note.localizedCaseInsensitiveContains("removed"), note)
    }

    /// Once the client's cursor is at or past the removal it is back on the
    /// cheap path — a delete must not turn every remaining poll of the meeting
    /// into a full resend.
    func test_live_delta_stays_incremental_once_the_client_has_seen_the_removal() throws {
        let snap = try liveSnapshot(
            revision: 6,
            segments: [
                .init(start: 0, end: 2, text: "first", speaker: "SPEAKER_00"),
                .init(start: 4, end: 6, text: "third", speaker: "SPEAKER_01"),
                .init(start: 6, end: 8, text: "fourth", speaker: "SPEAKER_01"),
            ],
            segmentsRemovedAtRevision: 5)
        let result = try call("get_live_transcript", [
            "session_id": snap.sessionID.uuidString,
            "since_revision": 5,
            "since_segment_index": 2,
        ])
        XCTAssertNil(result["segments_removed"])
        XCTAssertNil(result["transcript"], "a delta carries segments, not the whole rendering")
        let texts = (result["new_segments"] as? [[String: Any]])?.compactMap { $0["text"] as? String }
        XCTAssertEqual(texts, ["third", "fourth"])
    }

    /// A client that sends a segment cursor but no `since_revision` cannot
    /// prove it has seen the removal, so it is served the full set. Failing
    /// closed here costs one large reply; failing open leaves deleted text in
    /// someone's context.
    func test_live_poll_without_a_revision_cursor_gets_the_full_set_after_a_removal() throws {
        let snap = try liveSnapshot(
            revision: 5,
            segments: [.init(start: 0, end: 2, text: "first", speaker: "SPEAKER_00")],
            segmentsRemovedAtRevision: 5)
        let result = try call("get_live_transcript", [
            "session_id": snap.sessionID.uuidString,
            "since_segment_index": 3,
        ])
        XCTAssertEqual(result["segments_removed"] as? Bool, true)
        XCTAssertEqual((result["new_segments"] as? [[String: Any]])?.count, 1)
    }

    /// Nothing has ever been removed → the delta path is untouched. This is
    /// the control for the three tests above.
    func test_live_delta_is_unaffected_when_nothing_was_removed() throws {
        let snap = try liveSnapshot(revision: 4)
        let result = try call("get_live_transcript", [
            "session_id": snap.sessionID.uuidString,
            "since_revision": 2,
            "since_segment_index": 3,
        ])
        XCTAssertNil(result["segments_removed"])
        XCTAssertEqual((result["new_segments"] as? [[String: Any]])?.count, 1,
                       "an ordinary cursor at the tail re-reads only the last segment")
    }

    func test_live_session_mismatch_returns_new_session_full_set() throws {
        _ = try liveSnapshot(revision: 3)
        let result = try call("get_live_transcript", [
            "session_id": UUID().uuidString,   // stale cursor from a previous meeting
            "since_revision": 3,
            "since_segment_index": 99,
        ])
        XCTAssertEqual(result["new_session"] as? Bool, true)
        XCTAssertEqual(result["changed"] as? Bool, true)
        XCTAssertEqual((result["new_segments"] as? [[String: Any]])?.count, 3)
        XCTAssertNotNil(result["transcript"])
    }

    func test_live_stale_heartbeat_reports_stale() throws {
        let now = Date()
        _ = try liveSnapshot(updatedAt: now.addingTimeInterval(-60))
        let result = try call("get_live_transcript", now: now)
        XCTAssertEqual(result["status"] as? String, "stale")
    }

    func test_live_gated_hardware_reports_unavailable() throws {
        _ = try liveSnapshot(liveAvailable: false)
        let result = try call("get_live_transcript")
        XCTAssertEqual(result["status"] as? String, "recording_live_unavailable")
    }

    func test_live_completed_hands_off_final_recording_id() throws {
        let finalID = UUID()
        _ = try liveSnapshot(state: .completed, finalRecordingID: finalID)
        let result = try call("get_live_transcript")
        XCTAssertEqual(result["status"] as? String, "completed")
        XCTAssertEqual(result["final_recording_id"] as? String, finalID.uuidString)
    }

    func test_live_interrupted_reports_not_recording_with_hint() throws {
        _ = try liveSnapshot(state: .interrupted)
        let result = try call("get_live_transcript")
        XCTAssertEqual(result["status"] as? String, "not_recording")
        XCTAssertEqual(result["last_session"] as? String, "interrupted")
    }

    // MARK: - The completed → get_transcript handoff

    /// The client-side half of the ordering fix in
    /// `QuickActionsController.stopRecording` (CodeRabbit on #183): the
    /// contract a poller relies on is that the *instant* it sees
    /// `completed`, following `final_recording_id` yields the FINAL
    /// transcript. This walks that handoff the way a client does — poll,
    /// read the id, fetch it — and asserts the fetched text is the final
    /// one, not the pre-drain snapshot the app wrote when it first added
    /// the row.
    ///
    /// The app-side ordering that makes this true (finish the sidecar only
    /// after `store.update`) is pinned separately by
    /// `QuickActionsControllerTests`, which needs the app target.
    func test_completed_handoff_id_resolves_to_the_final_transcript() throws {
        let finalID = UUID()
        var saved = meeting("Handoff", daysAgo: 0)
        saved.id = finalID
        // What the drain wrote LAST: the final segments, not the initial
        // ones the row was created with.
        saved.segments = [
            .init(start: 0, end: 3, text: "shalom everyone", speaker: "SPEAKER_00"),
            .init(start: 3, end: 6, text: "let's begin", speaker: "SPEAKER_01"),
            .init(start: 6, end: 9, text: "and the tail of the meeting", speaker: "SPEAKER_00"),
        ]
        try seedStore([saved])
        _ = try liveSnapshot(state: .completed, finalRecordingID: finalID)

        let poll = try call("get_live_transcript")
        XCTAssertEqual(poll["status"] as? String, "completed")
        let handoff = try XCTUnwrap(poll["final_recording_id"] as? String)

        let fetched = try call("get_transcript", ["id": handoff])
        let transcript = try XCTUnwrap(fetched["transcript"] as? String)
        XCTAssertTrue(transcript.contains("and the tail of the meeting"),
                      "the handoff id must resolve to the FINAL transcript: \(transcript)")
    }

    /// A recording removed during finalization (the user cancels the rename
    /// sheet) closes the sidecar with `completed` and NO id. The refusal
    /// must be the documented "check list_recordings" hint, never an id that
    /// `get_transcript` can only 404 on.
    func test_completed_without_handoff_id_points_at_list_recordings() throws {
        _ = try liveSnapshot(state: .completed, finalRecordingID: nil)
        let result = try call("get_live_transcript")
        XCTAssertEqual(result["status"] as? String, "completed")
        XCTAssertNil(result["final_recording_id"])
        let note = try XCTUnwrap(result["note"] as? String)
        XCTAssertTrue(note.contains("list_recordings"), note)
    }

    // MARK: - Action items

    /// `ActionItem.source` distinguishes an item the speaker DICTATED
    /// (`voice_command`) from one the model INFERRED. The app has always
    /// persisted it; the mirror did not carry it and the handler did not
    /// emit it, so over MCP the two were indistinguishable and a client
    /// answering "what did I commit to?" had to treat a guess as a
    /// commitment. Mirrored + exposed after `StoredRecordingDriftTests`
    /// grew a nested key-set check that finally saw the gap.
    func test_action_items_expose_source_and_timestamp() throws {
        try seedStore([
            StoredRecording(
                title: "Planning", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                duration: 60, source: "meeting", audioFileName: "Planning.wav",
                status: "completed",
                segments: [.init(start: 0, end: 2, text: "hello", speaker: "SPEAKER_00")],
                summary: "A summary.",
                actionItems: [
                    .init(id: "a1", text: "Ship it", speaker: "SPEAKER_00",
                          timestampSeconds: 12.5, source: "voice_command",
                          addedAt: Date(timeIntervalSince1970: 1_700_000_100)),
                    .init(id: "a2", text: "Maybe refactor", timestampSeconds: 30,
                          source: "inferred"),
                ],
                speakerNames: ["SPEAKER_00": "Dana"]),
        ])

        let result = try call("get_transcript")
        let items = try XCTUnwrap(result["action_items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)

        XCTAssertEqual(items[0]["text"] as? String, "Ship it")
        // Raw diarizer IDs never leave the handler — resolved to the display name.
        XCTAssertEqual(items[0]["speaker"] as? String, "Dana")
        XCTAssertEqual(items[0]["source"] as? String, "voice_command")
        XCTAssertEqual(items[0]["timestamp_seconds"] as? Double, 12.5)

        XCTAssertEqual(items[1]["source"] as? String, "inferred")
        XCTAssertNil(items[1]["speaker"], "an unattributed item must not invent a speaker")

        // The LLM-chosen id is mirrored but deliberately not published: it is
        // unique only within one recording's list, so exposing it would
        // suggest a handle no tool accepts.
        XCTAssertNil(items[0]["id"])
    }

    /// An older store — written before the app persisted `source` — must
    /// still decode, and must not emit an empty `source` that a client
    /// would have to special-case. Absent beats blank.
    func test_action_items_from_a_legacy_store_omit_source() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","title":"Legacy",
        "createdAt":"2023-11-14T22:13:20Z","duration":60,"source":"meeting",
        "audioFileName":"Legacy.wav","status":"completed","segments":[],
        "actionItems":[{"text":"Old item"}]}]
        """
        try Data(json.utf8).write(to: root.appendingPathComponent("recordings.json"))

        let items = try XCTUnwrap(try call("get_transcript")["action_items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["text"] as? String, "Old item")
        XCTAssertNil(items[0]["source"])
        XCTAssertNil(items[0]["timestamp_seconds"])
    }

    // MARK: - ISO 8601 dates

    /// `iso(_:)` moved off `ISO8601DateFormatter` (a non-thread-safe class
    /// that cannot be shared, and cannot be a stored property of a
    /// `Sendable` struct) onto `Date.ISO8601FormatStyle`. The output format
    /// is part of every tool response, so pin that it did not drift.
    func test_created_at_is_rendered_as_internet_date_time_in_utc() throws {
        try seedStore([meeting("Stamped", daysAgo: 0)])
        let result = try call("list_recordings")
        let first = try XCTUnwrap((result["recordings"] as? [[String: Any]])?.first)
        // 1_700_000_000 == 2023-11-14T22:13:20Z
        XCTAssertEqual(first["created_at"] as? String, "2023-11-14T22:13:20Z")
    }

    /// Both input shapes the old formatter accepted still parse: a full
    /// internet date-time, and a bare `yyyy-MM-dd`.
    func test_date_filters_accept_full_timestamps_and_bare_dates() throws {
        try seedStore([meeting("Older", daysAgo: 10), meeting("Newer", daysAgo: 0)])

        let byTimestamp = try call("list_recordings", ["after": "2023-11-10T00:00:00Z"])
        XCTAssertEqual((byTimestamp["recordings"] as? [[String: Any]])?
            .compactMap { $0["title"] as? String }, ["Newer"])

        let byBareDate = try call("list_recordings", ["after": "2023-11-10"])
        XCTAssertEqual((byBareDate["recordings"] as? [[String: Any]])?
            .compactMap { $0["title"] as? String }, ["Newer"])
    }

    /// A fractional-seconds timestamp must not fall through to the date-only
    /// attempt and parse as MIDNIGHT — that quietly widens the caller's
    /// window by up to a day. It is the shape any client built on JS gets
    /// for free: `Date.toISOString()` always emits `.mmm`.
    ///
    /// The failure is silent rather than loud because `fullDate.parse`
    /// matches a PREFIX — handed the whole timestamp it succeeds at
    /// midnight instead of throwing — so nothing but an assertion catches
    /// it. Both directions are pinned: `2023-11-14T22:13:20.500Z` is half a
    /// second AFTER the `daysAgo: 0` fixture (22:13:20Z), so as an `after`
    /// bound it must exclude the fixture (midnight would include it) and as
    /// a `before` bound it must include it (midnight would exclude it).
    /// One assertion alone is satisfiable by a broken parse.
    func test_fractional_seconds_do_not_parse_as_midnight() throws {
        try seedStore([meeting("Exactly", daysAgo: 0)])

        let after = try call("list_recordings", ["after": "2023-11-14T22:13:20.500Z"])
        XCTAssertEqual(after["count"] as? Int, 0,
                       "a sub-second-later `after` cursor must exclude the fixture, "
                       + "not fall back to midnight")

        let before = try call("list_recordings", ["before": "2023-11-14T22:13:20.500Z"])
        XCTAssertEqual(before["count"] as? Int, 1,
                       "a sub-second-later `before` cursor must include the fixture; "
                       + "a midnight fallback would have excluded it")
    }

    /// Fractional seconds combined with a numeric UTC offset — the other
    /// half of the shape a non-Z client sends. `2023-11-15T00:13:20.500+02:00`
    /// is the same instant as `2023-11-14T22:13:20.500Z`, so it must behave
    /// identically to the test above. A date-only fallback would read the
    /// *local* calendar date (the 15th) and be a day out on top of being
    /// midnight.
    func test_fractional_seconds_with_utc_offset_parse_as_the_same_instant() throws {
        try seedStore([meeting("Exactly", daysAgo: 0)])
        let result = try call("list_recordings", ["after": "2023-11-15T00:13:20.500+02:00"])
        XCTAssertEqual(result["count"] as? Int, 0)
    }

    /// A whole-second timestamp must keep working after the fractional
    /// attempt was inserted — the new style is field-exact in the other
    /// direction, so it must not be the only one tried.
    func test_whole_second_timestamps_still_parse_after_the_fractional_attempt() throws {
        try seedStore([meeting("Exactly", daysAgo: 0)])
        XCTAssertEqual(try call("list_recordings",
                                ["after": "2023-11-14T22:13:20Z"])["count"] as? Int, 1)
        XCTAssertEqual(try call("list_recordings",
                                ["after": "2023-11-14T22:13:21Z"])["count"] as? Int, 0)
    }

    func test_unparseable_date_is_rejected_with_the_offending_value() throws {
        try seedStore([meeting("Any", daysAgo: 0)])
        XCTAssertThrowsError(try call("list_recordings", ["after": "last tuesday"])) { error in
            XCTAssertTrue(String(describing: error).contains("last tuesday"),
                          String(describing: error))
        }
    }
}

/// Wraps the real file-backed source and substitutes `duration` by title —
/// the only way to put NaN / ±infinity in front of the handlers, since JSON
/// cannot spell them.
private struct DurationOverridingSource: MilaDataSource {
    let base: FileBackedDataSource
    let durations: [String: Double]

    private func patch(_ recording: StoredRecording) -> StoredRecording {
        var copy = recording
        if let value = durations[recording.title] { copy.duration = value }
        return copy
    }

    func listRecordings(filter: MilaStoreReader.Filter, sort: MilaStoreReader.SortKey,
                        order: MilaStoreReader.SortOrder, limit: Int) throws -> [StoredRecording] {
        try base.listRecordings(filter: filter, sort: sort, order: order, limit: limit).map(patch)
    }
    func recording(id: UUID) throws -> StoredRecording? { try base.recording(id: id).map(patch) }
    func latestCompletedRecording() throws -> StoredRecording? { try base.latestCompletedRecording().map(patch) }
    func namedTranscript(for recording: StoredRecording) -> String { base.namedTranscript(for: recording) }
    func searchTranscripts(query: String, speaker: String?, sort: MilaStoreReader.SearchSortKey,
                           order: MilaStoreReader.SortOrder, limit: Int) throws -> [MilaStoreReader.SearchHit] {
        try base.searchTranscripts(query: query, speaker: speaker, sort: sort, order: order, limit: limit)
            .map { .init(recording: patch($0.recording), matchCount: $0.matchCount, snippets: $0.snippets) }
    }
    func liveSnapshot() -> LiveTranscriptSnapshot? { base.liveSnapshot() }
}
