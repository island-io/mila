import Foundation

/// The mila-mcp tool surface, implemented as a pure JSON-in / JSON-out
/// layer with no MCP-SDK types — the executable's transport wiring stays
/// a thin shell (and swappable for a hand-rolled JSON-RPC loop if the SDK
/// ever misbehaves), and everything here is unit-testable in-process.
public struct MilaMCPToolHandlers: Sendable {

    public enum ToolError: Error, CustomStringConvertible {
        case unknownTool(String)
        case invalidArguments(String)
        case notFound(String)
        case storeUnavailable(String)

        public var description: String {
            switch self {
            case .unknownTool(let name): return "Unknown tool: \(name)"
            case .invalidArguments(let msg): return "Invalid arguments: \(msg)"
            case .notFound(let msg): return msg
            case .storeUnavailable(let msg):
                return "Mila's recording store could not be read (\(msg)). "
                    + "Has the Mila app run at least once on this Mac?"
            }
        }
    }

    /// One tool's transport-agnostic declaration. Deliberately NOT
    /// `Sendable`: `inputSchema` is a `[String: Any]` JSON tree, which
    /// cannot be. Specs are built on demand by `toolSpecs` and consumed
    /// synchronously by the caller that asked for them, so no value of
    /// this type ever crosses an isolation boundary.
    public struct ToolSpec {
        public let name: String
        public let description: String
        /// JSON Schema for the tool's arguments, as a JSON object tree
        /// ([String: Any]), ready to re-encode into any transport's type.
        public let inputSchema: [String: Any]
    }

    /// Root under which `store-location.json` and `live/current.json`
    /// live — the default Mila app-support directory in production, a
    /// temp fixture in tests.
    private let root: URL
    private let now: @Sendable () -> Date
    private let source: any MilaDataSource
    /// Injectable so tests can drive both sides of the gate without writing
    /// to the real app-support directory.
    private let isAccessEnabled: @Sendable (URL) -> Bool

    /// The two defaults are written as closure literals rather than the
    /// tidier unapplied references (`Date.init`,
    /// `MCPAccessGate.isEnabled(root:)`): an unapplied function reference is
    /// not inferred `@Sendable`, so those forms warn under strict
    /// concurrency even though both targets are trivially concurrency-safe.
    public init(root: URL = StoreLocationPointer.defaultRoot(),
                now: @escaping @Sendable () -> Date = { Date() },
                source: (any MilaDataSource)? = nil,
                isAccessEnabled: @escaping @Sendable (URL) -> Bool = {
                    MCPAccessGate.isEnabled(root: $0)
                }) {
        self.root = root
        self.now = now
        self.source = source ?? FileBackedDataSource(root: root)
        self.isAccessEnabled = isAccessEnabled
    }

    // MARK: - Tool definitions

    /// Computed, not a `static let`: a stored global would have to be
    /// `Sendable`, and `ToolSpec.inputSchema` is a `[String: Any]` JSON
    /// tree that never can be. Built once per read, and the only reader is
    /// the transport shell's `tools/list` wiring at startup.
    public static var toolSpecs: [ToolSpec] { [
        ToolSpec(
            name: "list_recordings",
            description: """
            List Mila recordings (meetings, voice memos, app-audio captures), newest first by \
            default. Filter by speaker display name to find conversations with a specific \
            person — e.g. the last meeting with John Doe is list_recordings(speaker: "john \
            doe", limit: 1). Trashed recordings are excluded.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": ["type": "string",
                              "description": "Substring match over title, app name, and folder."],
                    "speaker": ["type": "string",
                                "description": "Case-insensitive substring over the recording's speaker display names (as renamed by the user)."],
                    "folder": ["type": "string", "description": "Filter to a folder by name."],
                    "source": ["type": "string",
                               "enum": ["microphone", "systemAudio", "meeting", "voiceMemo"],
                               "description": "Filter by capture source."],
                    "after": ["type": "string",
                              "description": "ISO 8601 date; only recordings created at/after this instant."],
                    "before": ["type": "string",
                               "description": "ISO 8601 date; only recordings created at/before this instant."],
                    "sort": ["type": "string", "enum": ["created_at", "duration", "title"],
                             "description": "Sort key (default created_at)."],
                    "order": ["type": "string", "enum": ["asc", "desc"],
                              "description": "Sort order (default desc)."],
                    "limit": ["type": "integer", "description": "Max results (default 20, max 100)."],
                ],
            ]
        ),
        ToolSpec(
            name: "get_transcript",
            description: """
            Fetch one recording's full transcript with speaker names resolved (e.g. "John \
            Doe: …"), plus its summary and action items when available. Pass the id from \
            list_recordings/search_transcripts; omit it for the latest completed recording.
            Each action item carries "source": "voice_command" when the speaker dictated it \
            out loud, "inferred" when the model derived it from the conversation — do not \
            present an inferred item as something the speaker said.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": ["type": "string",
                           "description": "Recording UUID. Omit for the latest completed recording."],
                    "include_summary": ["type": "boolean",
                                        "description": "Include summary + action items (default true)."],
                    "max_chars": ["type": "integer",
                                  "description": "Truncate the transcript to this many characters."],
                ],
            ]
        ),
        ToolSpec(
            name: "search_transcripts",
            description: """
            Full-text search over recording titles and transcript text (case- and \
            diacritic-insensitive). Returns matching recordings with short context snippets; \
            follow up with get_transcript for the full text.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Text to search for."],
                    "speaker": ["type": "string",
                                "description": "Only search recordings featuring this speaker display name."],
                    "sort": ["type": "string", "enum": ["relevance", "created_at"],
                             "description": "relevance = match count, ties newest-first (default)."],
                    "order": ["type": "string", "enum": ["asc", "desc"],
                              "description": "Sort order (default desc)."],
                    "limit": ["type": "integer", "description": "Max results (default 10, max 100)."],
                ],
                "required": ["query"],
            ]
        ),
        ToolSpec(
            name: "get_live_transcript",
            description: """
            Read the in-progress Mila recording's live transcript. To follow a meeting, poll \
            this every 15-20 seconds passing back the returned session_id, revision (as \
            since_revision) and next_segment_index (as since_segment_index): unchanged \
            meetings answer with a tiny {changed:false}, and changed ones return only the new \
            segments (the last previously-seen segment is re-sent because live transcription \
            may rewrite it — replace your copy). When status becomes "completed", stop \
            polling: call get_transcript with the returned final_recording_id when there is \
            one, and otherwise take the newest entry from list_recordings (a completed \
            recording can finish without a handoff id).
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "session_id": ["type": "string",
                                   "description": "The session_id from the previous poll. A mismatch means a new recording started; the full new transcript is returned."],
                    "since_revision": ["type": "integer",
                                       "description": "The revision from the previous poll; equal revision short-circuits to {changed:false}."],
                    "since_segment_index": ["type": "integer",
                                            "description": "The next_segment_index from the previous poll; only segments from one before this index are returned."],
                ],
            ]
        ),
    ] }

    // MARK: - Dispatch

    /// Execute a tool call. Returns the result as a JSON string.
    ///
    /// The gate is re-read on **every** call rather than cached at startup:
    /// an MCP server started by an editor can outlive many Mila sessions, and
    /// revoking access should take effect immediately, not at the client's
    /// next restart. It costs one small file read per tool call, and tool
    /// calls are rare.
    public func handle(tool: String, arguments: [String: Any]) throws -> String {
        guard isAccessEnabled(root) else { throw MCPAccessDisabledError() }
        switch tool {
        case "list_recordings": return try listRecordings(arguments)
        case "get_transcript": return try getTranscript(arguments)
        case "search_transcripts": return try searchTranscripts(arguments)
        case "get_live_transcript": return try getLiveTranscript(arguments)
        default: throw ToolError.unknownTool(tool)
        }
    }

    // MARK: - Tools

    private func listRecordings(_ args: [String: Any]) throws -> String {
        let filter = MilaStoreReader.Filter(
            query: args["query"] as? String,
            speaker: args["speaker"] as? String,
            folder: args["folder"] as? String,
            source: args["source"] as? String,
            after: try date(args, "after"),
            before: try date(args, "before")
        )
        let sort = try enumArg(args, "sort", MilaStoreReader.SortKey.self) ?? .createdAt
        let order = try enumArg(args, "order", MilaStoreReader.SortOrder.self) ?? .desc
        let limit = min(args["limit"] as? Int ?? 20, 100)
        let recordings: [StoredRecording]
        do {
            recordings = try source.listRecordings(filter: filter, sort: sort,
                                                   order: order, limit: limit)
        } catch {
            throw ToolError.storeUnavailable(String(describing: error))
        }
        return try json([
            "count": recordings.count,
            "recordings": recordings.map { summaryObject(for: $0) },
        ])
    }

    private func getTranscript(_ args: [String: Any]) throws -> String {
        let recording: StoredRecording
        do {
            if let idString = args["id"] as? String {
                guard let id = UUID(uuidString: idString) else {
                    throw ToolError.invalidArguments("id must be a UUID, got \"\(idString)\"")
                }
                guard let found = try source.recording(id: id) else {
                    throw ToolError.notFound("No recording with id \(id.uuidString)")
                }
                recording = found
            } else {
                guard let latest = try source.latestCompletedRecording() else {
                    throw ToolError.notFound("No completed recordings exist yet")
                }
                recording = latest
            }
        } catch let error as ToolError {
            throw error
        } catch {
            throw ToolError.storeUnavailable(String(describing: error))
        }

        var transcript = source.namedTranscript(for: recording)
        var truncated = false
        if let maxChars = args["max_chars"] as? Int, maxChars > 0, transcript.count > maxChars {
            transcript = String(transcript.prefix(maxChars))
            truncated = true
        }
        var result = summaryObject(for: recording)
        result["language"] = recording.language
        result["transcript"] = transcript
        result["transcript_truncated"] = truncated
        if recording.status != "completed" {
            result["note"] = "Transcription status is \"\(recording.status)\" — the transcript may be partial."
        }
        if (args["include_summary"] as? Bool) ?? true {
            if let summary = recording.summary, !summary.isEmpty {
                result["summary"] = summary
            }
            if let items = recording.actionItems, !items.isEmpty {
                result["action_items"] = items.map { item in
                    var obj: [String: Any] = ["text": item.text]
                    if let speaker = item.speaker {
                        obj["speaker"] = recording.speakerNames[speaker] ?? speaker
                    }
                    // `voice_command` (the speaker dictated the item) vs
                    // `inferred` (the model derived it). Without this the
                    // two are indistinguishable and every item reads as
                    // equally authoritative — see StoredRecording.ActionItem.
                    if !item.source.isEmpty { obj["source"] = item.source }
                    if let seconds = item.timestampSeconds {
                        obj["timestamp_seconds"] = seconds
                    }
                    return obj
                }
            }
        }
        return try json(result)
    }

    private func searchTranscripts(_ args: [String: Any]) throws -> String {
        guard let query = args["query"] as? String, !query.isEmpty else {
            throw ToolError.invalidArguments("query is required")
        }
        let sort = try enumArg(args, "sort", MilaStoreReader.SearchSortKey.self) ?? .relevance
        let order = try enumArg(args, "order", MilaStoreReader.SortOrder.self) ?? .desc
        let limit = min(args["limit"] as? Int ?? 10, 100)
        let hits: [MilaStoreReader.SearchHit]
        do {
            hits = try source.searchTranscripts(query: query,
                                                speaker: args["speaker"] as? String,
                                                sort: sort, order: order, limit: limit)
        } catch {
            throw ToolError.storeUnavailable(String(describing: error))
        }
        return try json([
            "count": hits.count,
            "results": hits.map { hit -> [String: Any] in
                var obj = summaryObject(for: hit.recording)
                obj["match_count"] = hit.matchCount
                obj["snippets"] = hit.snippets
                return obj
            },
        ])
    }

    private func getLiveTranscript(_ args: [String: Any]) throws -> String {
        guard let snapshot = source.liveSnapshot() else {
            return try json(["status": "not_recording"])
        }

        switch snapshot.state {
        case .interrupted:
            return try json([
                "status": "not_recording",
                "last_session": "interrupted",
                "note": "The app stopped unexpectedly during the last recording; its audio is re-transcribed in the background — check list_recordings.",
            ])
        case .completed, .recording:
            break
        }

        var result: [String: Any] = [
            "session_id": snapshot.sessionID.uuidString,
            "revision": snapshot.revision,
            "recording_started_at": iso(snapshot.recordingStartedAt),
            "updated_at": iso(snapshot.updatedAt),
        ]
        if let title = snapshot.title { result["title"] = title }
        if let source = snapshot.source { result["source"] = source }

        if snapshot.state == .completed {
            result["status"] = "completed"
            if let finalID = snapshot.finalRecordingID {
                result["final_recording_id"] = finalID.uuidString
                result["note"] = "The recording ended. Call get_transcript with final_recording_id for the authoritative transcript (speaker labels may improve after the post-stop pass)."
            } else {
                // No id covers several cases the snapshot can't tell apart, and
                // since the app stopped publishing an id for a not-yet-final
                // transcript this is the ORDINARY outcome for chunk-mode,
                // hardware-gated and empty-live recordings — not a failure. The
                // wording has to be accurate for all of them, so it names the
                // action and warns the row may still be transcribing rather
                // than implying something went wrong.
                result["note"] = "The recording ended without a transcript handoff; check list_recordings for the newest entry. Its transcript may still be processing — get_transcript reports status \"pending\" until it is done."
            }
            return try json(result)
        }

        // state == .recording
        guard snapshot.liveTranscriptAvailable else {
            result["status"] = "recording_live_unavailable"
            result["elapsed_seconds"] = Int(now().timeIntervalSince(snapshot.recordingStartedAt))
            result["note"] = "A recording is in progress, but live transcription is disabled on this hardware — no text will appear until it completes. Poll occasionally for status \"completed\" instead of expecting segments."
            return try json(result)
        }
        let heartbeatAge = now().timeIntervalSince(snapshot.updatedAt)
        let status = heartbeatAge > LiveTranscriptSnapshot.staleAfter ? "stale" : "recording"
        result["status"] = status
        result["elapsed_seconds"] = Int(now().timeIntervalSince(snapshot.recordingStartedAt))
        if status == "stale" {
            result["note"] = "The live snapshot hasn't been refreshed in \(Int(heartbeatAge))s — the Mila app may have crashed or hung; this transcript may be incomplete and won't grow."
        }

        let clientSession = (args["session_id"] as? String).flatMap(UUID.init(uuidString:))
        let sameSession = clientSession == snapshot.sessionID
        if let clientSession, clientSession != snapshot.sessionID {
            result["new_session"] = true
        }

        // Cheap no-change short-circuit — only valid within the same session.
        if sameSession, let sinceRevision = args["since_revision"] as? Int,
           sinceRevision == snapshot.revision {
            return try json([
                "status": status,
                "session_id": snapshot.sessionID.uuidString,
                "revision": snapshot.revision,
                "changed": false,
            ])
        }
        result["changed"] = true
        result["speaker_names"] = snapshot.speakerNames
        result["next_segment_index"] = snapshot.segments.count

        if sameSession, let sinceIndex = args["since_segment_index"] as? Int {
            result["new_segments"] = snapshot.segments(sinceIndex: sinceIndex)
                .map(segmentObject(for:))
        } else {
            // First poll (or a new session): full transcript + all segments.
            result["new_segments"] = snapshot.segments.map(segmentObject(for:))
            result["transcript"] = TranscriptFormatter.plainText(
                segments: snapshot.segments,
                fallback: TranscriptFormatter.joinedFullText(segments: snapshot.segments),
                names: snapshot.speakerNames
            )
        }
        return try json(result)
    }

    // MARK: - Helpers

    private func summaryObject(for recording: StoredRecording) -> [String: Any] {
        var obj: [String: Any] = [
            "id": recording.id.uuidString,
            "title": recording.title,
            "created_at": iso(recording.createdAt),
            "duration_seconds": Int(recording.duration.rounded()),
            "source": recording.source,
            "status": recording.status,
            "speakers": recording.speakerDisplayNames,
            "has_summary": !(recording.summary ?? "").isEmpty,
        ]
        if let folder = recording.folder { obj["folder"] = folder }
        if let appName = recording.appName { obj["app_name"] = appName }
        // The stable companion to the localized `app_name`.
        if let bundleID = recording.appBundleID { obj["app_bundle_id"] = bundleID }
        return obj
    }

    private func segmentObject(for segment: LiveTranscriptSnapshot.Segment) -> [String: Any] {
        var obj: [String: Any] = [
            "start": segment.start,
            "end": segment.end,
            "text": segment.text,
        ]
        if let speaker = segment.speaker { obj["speaker"] = speaker }
        return obj
    }

    private func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// `Date.ISO8601FormatStyle`, not `ISO8601DateFormatter`.
    ///
    /// The formatter is a class and is NOT thread-safe (unlike
    /// `DateFormatter`, it never got internal locking, and it is not
    /// `Sendable`), so it can be neither hoisted into a shared `static let`
    /// nor held as a stored property of this `Sendable` struct. Allocating
    /// one per call is safe but wasteful — `iso(_:)` runs once per
    /// recording in every `list_recordings` / `search_transcripts`
    /// response, up to 100 per call.
    ///
    /// The format style is a value type and `Sendable`, so one shared
    /// instance is both correct and allocation-free. Output is byte-identical
    /// to the old formatter's default (`.withInternetDateTime` in GMT →
    /// `2026-07-15T12:34:56Z`).
    private static let internetDateTime = Date.ISO8601FormatStyle()
    /// The same style with `includingFractionalSeconds`, tried second.
    ///
    /// Whether `internetDateTime` tolerates a fractional-seconds input is
    /// **runtime-dependent**: current Foundation parses `…T22:13:20.500Z`
    /// with the plain style, but the styles are field-exact on the older
    /// Foundation shipped with this package's deployment floor (macOS 14),
    /// where the plain style rejects it. Relying on the newer behaviour
    /// would make `after` / `before` correct on the dev machine and wrong
    /// on a supported OS — the worst shape of bug. (CodeRabbit on #183.)
    private static let fractionalDateTime =
        Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let fullDate = Date.ISO8601FormatStyle(dateSeparator: .dash,
                                                          timeZone: .gmt)
        .year().month().day()

    private func iso(_ date: Date) -> String {
        date.formatted(Self.internetDateTime)
    }

    private func date(_ args: [String: Any], _ key: String) throws -> Date? {
        guard let raw = args[key] as? String else { return nil }
        if let parsed = try? Self.internetDateTime.parse(raw) { return parsed }
        // Fractional seconds — a real shape for an MCP client that built the
        // string from a JS `Date.toISOString()` (which always emits `.mmm`).
        //
        // Ordering is load-bearing, not cosmetic. `fullDate.parse` matches a
        // PREFIX: handed the whole `2023-11-14T22:13:20.500Z` it succeeds and
        // returns MIDNIGHT rather than throwing. So on a runtime where the
        // plain style rejects fractional seconds, putting this attempt after
        // the date-only fallback would not surface an error — it would
        // silently widen the caller's window by up to 24 hours.
        if let parsed = try? Self.fractionalDateTime.parse(raw) { return parsed }
        // Accept plain dates too ("2026-07-15").
        if let parsed = try? Self.fullDate.parse(raw) { return parsed }
        throw ToolError.invalidArguments("\(key) must be an ISO 8601 date, got \"\(raw)\"")
    }

    private func enumArg<E: RawRepresentable>(_ args: [String: Any], _ key: String,
                                              _ type: E.Type) throws -> E?
        where E.RawValue == String {
        guard let raw = args[key] as? String else { return nil }
        guard let value = E(rawValue: raw) else {
            throw ToolError.invalidArguments("\(key) has unsupported value \"\(raw)\"")
        }
        return value
    }
}
