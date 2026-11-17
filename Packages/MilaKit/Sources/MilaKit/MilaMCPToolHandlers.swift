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

    /// `get_transcript`'s `format` argument. `text` is the default and the
    /// pre-existing behaviour; `srt` renders `TranscriptFormatter.srt` from
    /// the recording's timed segments.
    enum TranscriptFormat: String, Sendable {
        case text, srt
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
    /// The separate consent `save_transcript` needs on top of read access.
    /// Same contract as `isAccessEnabled`: consulted on every call.
    private let isFileExportEnabled: @Sendable (URL) -> Bool

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
                },
                isFileExportEnabled: @escaping @Sendable (URL) -> Bool = {
                    MCPAccessGate.isFileExportEnabled(root: $0)
                }) {
        self.root = root
        self.now = now
        self.source = source ?? FileBackedDataSource(root: root)
        self.isAccessEnabled = isAccessEnabled
        self.isFileExportEnabled = isFileExportEnabled
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
            Pass format "srt" for SubRip subtitles (one timed cue per segment, speaker \
            names as cue prefixes) — the same bytes Mila's own Export Subtitles writes; \
            save them to a .srt file rather than quoting them. With "srt", max_chars \
            drops whole cues from the end so the result stays a valid file — omit it \
            for the complete file, and check transcript_truncated before saving one.
            To put a transcript in a file, use save_transcript instead of writing this \
            tool's text out yourself.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": ["type": "string",
                           "description": "Recording UUID. Omit for the latest completed recording."],
                    "format": ["type": "string", "enum": ["text", "srt"],
                               "description": "text (default): speaker-named transcript. srt: SubRip subtitles with one cue per segment, timestamps relative to the recording start, speaker names as cue prefixes. Unavailable for recordings without timed segments."],
                    "include_summary": ["type": "boolean",
                                        "description": "Include summary + action items (default true)."],
                    "max_chars": ["type": "integer",
                                  "description": "Truncate the transcript to this many characters (whole cues only for srt)."],
                ],
            ]
        ),
        ToolSpec(
            name: "save_transcript",
            description: """
            Write one recording's complete transcript to a file on this Mac — Mila writes \
            it directly, and the reply carries saved_to and bytes, NOT the text. Use this \
            whenever the transcript should end up in a file (export, upload, attach, \
            subtitles next to a video) instead of fetching it with get_transcript and \
            writing it out yourself: re-emitting a long transcript costs minutes of \
            generation, this costs milliseconds. format "text" (default) is the \
            speaker-named transcript; "srt" is SubRip subtitles, the same bytes as \
            get_transcript's srt and Mila's Export Subtitles. path may name a file or an \
            existing folder (the file is then named "<date> <title>.txt" or ".srt"). An \
            existing file is refused unless overwrite is true — ask the user first. Only \
            finished transcripts are saved. Writing files is a separate opt-in in Mila's \
            settings; if it is off this tool says so, and get_transcript still works.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string",
                             "description": "Absolute path (~ allowed) of the file to write, or of an existing folder to write into (a path ending in / always means a folder). The folder must exist. Paths inside Mila's own data, and symbolic links, are refused."],
                    "id": ["type": "string",
                           "description": "Recording UUID. Omit for the latest completed recording."],
                    "format": ["type": "string", "enum": ["text", "srt"],
                               "description": "text (default) or srt. srt is unavailable for recordings without timed segments."],
                    "overwrite": ["type": "boolean",
                                  "description": "Replace an existing file (default false: an existing file is an error)."],
                ],
                "required": ["path"],
            ]
        ),
        ToolSpec(
            name: "search_transcripts",
            description: """
            Full-text search over recording titles and transcript text (case- and \
            diacritic-insensitive). Returns matching recordings with short context snippets; \
            follow up with get_transcript for the full text. Relevance ranking has to score \
            every recording, so when you just want the latest mentions prefer \
            sort "created_at", which stops at `limit` matches.
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
            may rewrite it — replace your copy). If a reply carries segments_removed:true the \
            user deleted lines from the transcript: new_segments is then the COMPLETE current \
            set, so discard your previous copy of this session's segments instead of appending, \
            and do not quote the removed text. When status becomes "completed", stop \
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
    ///
    /// `save_transcript` needs a second consent on top: the user's grant of
    /// read access predates file writes and did not agree to them, so
    /// writing is its own opt-in (`MCPAccessGate.isFileExportEnabled`),
    /// re-read per call for the same reason.
    public func handle(tool: String, arguments: [String: Any]) throws -> String {
        guard isAccessEnabled(root) else { throw MCPAccessDisabledError() }
        switch tool {
        case "list_recordings": return try listRecordings(arguments)
        case "get_transcript": return try getTranscript(arguments)
        case "save_transcript":
            guard isFileExportEnabled(root) else { throw MCPFileExportDisabledError() }
            return try saveTranscript(arguments)
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
        // Validate the arguments before touching the store, as the other
        // tools do: a bad `format` should surface on its own rather than
        // hide behind an unknown `id` or cost a recordings.json load first.
        let format = try enumArg(args, "format", TranscriptFormat.self) ?? .text
        let maxChars = args["max_chars"] as? Int
        let recording = try resolveRecording(args)
        let rendered = try renderTranscript(recording, format: format, maxChars: maxChars)

        var result = summaryObject(for: recording)
        // The language of the text returned, not of a re-run still in flight.
        result["language"] = recording.transcriptLanguage
        result["format"] = format.rawValue
        result["transcript"] = rendered.text
        result["transcript_truncated"] = rendered.truncated
        var notes = statusNotes(for: recording)
        if let sizeHint = rendered.sizeHint { notes.append(sizeHint) }
        if !notes.isEmpty { result["note"] = notes.joined(separator: " ") }
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

    /// Writes the transcript to disk from the helper and replies with where
    /// it went, never with the text — see `TranscriptFileWriter` for why.
    ///
    /// A separate tool from `get_transcript` on purpose. MCP clients ask
    /// permission per tool NAME, and a user who has "always allowed" a
    /// read-only `get_transcript` has not agreed to let a client create or
    /// replace files on their Mac. Folding writes into that tool would have
    /// extended the standing approval silently; as its own tool, the first
    /// write prompts on its own.
    ///
    /// Reached only through `handle(tool:)`, after BOTH gates: read access,
    /// and the separate file-export consent.
    private func saveTranscript(_ args: [String: Any]) throws -> String {
        // Everything that depends only on the arguments is checked before
        // the store is touched, as in `getTranscript`: a relative path or a
        // missing folder should surface on its own, not behind an unknown
        // `id` or the cost of a recordings.json load.
        let format = try enumArg(args, "format", TranscriptFormat.self) ?? .text
        guard let path = args["path"] as? String, !path.isEmpty else {
            throw ToolError.invalidArguments("path is required")
        }
        let overwrite = (args["overwrite"] as? Bool) ?? false
        let writer = TranscriptFileWriter(protected: protectedLocations())
        let plan = try writeStep { try writer.plan(for: path) }

        let recording = try resolveRecording(args)
        // A file is a finished artifact: it gets attached, uploaded, handed
        // on, and nothing about it says "partial". `get_transcript` can
        // carry a note beside a draft; a file cannot — and with `overwrite`
        // a pending row would replace a good export with an empty one. So
        // only a finished transcript is written: a completed row, or the
        // earlier finished transcript a re-run in flight still holds.
        let hasFinishedTranscript = recording.status == "completed"
            || (recording.isRetranscriptionInFlight
                && recording.retranscriptionPriorState?.status == "completed")
        guard hasFinishedTranscript, !recording.isTranscriptionDeferred else {
            let state = recording.isTranscriptionDeferred
                ? "the user stopped its transcription to run it later"
                : "transcription status is \"\(recording.status)\""
            throw ToolError.notFound(
                "Recording \(recording.id.uuidString) has no finished transcript to save (\(state)). "
                + "Nothing was written. get_transcript shows whatever text exists so far.")
        }
        // No `max_chars`: a file is only useful complete, and a truncated
        // `.srt` is a subtitle track that silently stops early.
        let rendered = try renderTranscript(recording, format: format, maxChars: nil)
        guard !rendered.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.notFound(
                "Recording \(recording.id.uuidString) has an empty transcript; nothing was written.")
        }

        let defaultName = TranscriptFileWriter.defaultFileName(
            title: recording.title, createdAt: recording.createdAt,
            fileExtension: format == .srt ? "srt" : "txt")
        var result = summaryObject(for: recording)
        result["format"] = format.rawValue
        let destination = try writeStep {
            try writer.destination(for: plan, defaultFileName: defaultName)
        }
        let bytes: Int = try writeStep {
            try writer.write(rendered.text, to: destination, overwrite: overwrite)
        }
        result["bytes"] = bytes
        result["saved_to"] = destination.path
        result["characters"] = rendered.text.count
        let notes = statusNotes(for: recording)
        if !notes.isEmpty { result["note"] = notes.joined(separator: " ") }
        return try json(result)
    }

    /// `TranscriptFileWriter`'s refusals are the caller's to fix (another
    /// path, another name, `overwrite`), so they surface as invalid arguments.
    private func writeStep<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as TranscriptFileWriter.WriteError {
            throw ToolError.invalidArguments(error.description)
        }
    }

    /// `id` → that recording (trashed ones are unreachable, via the reader);
    /// no `id` → the latest completed one.
    private func resolveRecording(_ args: [String: Any]) throws -> StoredRecording {
        do {
            if let idString = args["id"] as? String {
                guard let id = UUID(uuidString: idString) else {
                    throw ToolError.invalidArguments("id must be a UUID, got \"\(idString)\"")
                }
                guard let found = try source.recording(id: id) else {
                    throw ToolError.notFound("No recording with id \(id.uuidString)")
                }
                return found
            }
            guard let latest = try source.latestCompletedRecording() else {
                throw ToolError.notFound("No completed recordings exist yet")
            }
            return latest
        } catch let error as ToolError {
            throw error
        } catch {
            throw ToolError.storeUnavailable(String(describing: error))
        }
    }

    private struct RenderedTranscript {
        var text: String
        var truncated: Bool
        /// Set only when `max_chars` is too small for even the first SRT cue:
        /// `transcript: ""` + `transcript_truncated: true` is the right answer
        /// there, but on its own it gives the client nothing to act on.
        var sizeHint: String?
    }

    private func renderTranscript(_ recording: StoredRecording, format: TranscriptFormat,
                                  maxChars: Int?) throws -> RenderedTranscript {
        var transcript: String
        var truncated = false
        var sizeHint: String?
        switch format {
        case .text:
            transcript = source.namedTranscript(for: recording)
            if let maxChars, maxChars > 0, transcript.count > maxChars {
                transcript = String(transcript.prefix(maxChars))
                truncated = true
            }
        case .srt:
            // Rendered straight from the segments, NOT via `namedTranscript`:
            // SRT needs timings, which only the segments carry, and the
            // `.txt` sidecar `namedTranscript` falls back to for unlabelled
            // recordings has none. So a recording whose transcript exists
            // only as text (legacy `fullText`, sidecar-only) has no SRT to
            // give, and saying so beats returning an empty file.
            let cues = TranscriptFormatter.srtCues(segments: recording.segments,
                                                   names: recording.speakerNames)
            guard !cues.isEmpty else {
                // A `pending`/`running` (or `failed`) recording reaches this
                // branch too — its segments simply are not stored yet — and
                // that is a different situation from a legacy text-only
                // record. The first is a precondition that resolves on its
                // own, reported the way "No completed recordings exist yet"
                // is rather than as a caller mistake; the second can never
                // succeed for this recording, so the argument is what is
                // wrong.
                guard recording.status == "completed" else {
                    throw ToolError.notFound(
                        "Recording \(recording.id.uuidString) has no timed segments "
                        + "(transcription status is \"\(recording.status)\"); format \"srt\" needs "
                        + "a completed transcription. Use format \"text\" for what exists so far.")
                }
                throw ToolError.invalidArguments(
                    "format \"srt\" is unavailable for recording \(recording.id.uuidString): "
                    + "it has no timed segments (legacy or text-only transcript). Use format \"text\".")
            }
            // `max_chars` keeps whole cues: a cue cut mid-timestamp is not
            // a subtitle file any player will load. Fewer characters than
            // asked for is the right answer; an invalid file is not.
            var kept: [String] = []
            if let maxChars, maxChars > 0 {
                // Each kept cue costs its own text plus the terminator
                // `srt(cues:)` appends to every cue.
                let costs = cues.map { $0.count + TranscriptFormatter.srtCueTerminator.count }
                var length = 0
                for (cue, cost) in zip(cues, costs) {
                    guard length + cost <= maxChars else { break }
                    kept.append(cue)
                    length += cost
                }
                truncated = kept.count < cues.count
                if kept.isEmpty {
                    sizeHint = "max_chars \(maxChars) is smaller than the first cue, which needs "
                        + "\(costs[0]) characters (including its trailing blank line); "
                        + "raise it to receive any cues."
                }
            } else {
                kept = cues
            }
            transcript = TranscriptFormatter.srt(cues: kept)
        }
        return RenderedTranscript(text: transcript, truncated: truncated, sizeHint: sizeHint)
    }

    private func statusNotes(for recording: StoredRecording) -> [String] {
        if recording.isTranscriptionDeferred {
            // Stored as `failed` (see `StoredRecording.transcriptionDeferredAt`),
            // but nothing failed: the user chose to transcribe it later.
            return ["The user stopped this recording's transcription in Mila to run it later, so it hasn't been fully transcribed — any text here is only a partial live draft."]
        }
        if recording.isRetranscriptionInFlight {
            // The earlier transcript is finished only if it was `completed`:
            // it can also be a stopped or failed partial draft.
            let earlier = recording.retranscriptionPriorState?.status == "completed"
                ? "the earlier, finished transcript"
                : "the earlier transcript, which may be partial"
            return ["A re-transcription of this recording is in progress; this is \(earlier), which it will replace when it completes."]
        }
        if recording.status != "completed" {
            return ["Transcription status is \"\(recording.status)\" — the transcript may be partial."]
        }
        return []
    }

    /// Where `save_transcript` may not write.
    ///
    /// The app-support root is off limits as a whole: consent and pointer
    /// files, the live sidecar, and the default store all live there, and no
    /// export belongs in it.
    ///
    /// A relocated store is different: the user picked that folder, and it
    /// can be somewhere ordinary like `~/Documents`, where refusing every
    /// export would be absurd. So it is a MANAGED folder — new files may be
    /// created in it, but nothing already there may be replaced and Mila's
    /// own names are reserved (see `TranscriptFileWriter`). The recordings
    /// folder and the folder holding `recordings.json` are the same folder in
    /// every layout the app writes; listed once either way.
    private func protectedLocations() -> TranscriptFileWriter.ProtectedLocations {
        let location = MilaStoreReader.resolvedLocation(root: root)
        var managed: [URL] = []
        for folder in [location.recordingsDirectory,
                       location.storeFileURL.deletingLastPathComponent()] {
            let key = folder.standardizedFileURL.path
            if !managed.contains(where: { $0.standardizedFileURL.path == key }) {
                managed.append(folder)
            }
        }
        return .init(roots: [root], managedFolders: managed)
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
                // live-off and empty-live recordings — not a failure. The
                // wording has to be accurate for all of them, so it names the
                // action and warns the row may still be transcribing rather
                // than implying something went wrong.
                result["note"] = "The recording ended without a transcript handoff; check list_recordings for the newest entry. Its transcript may still be processing — get_transcript reports status \"pending\" until it is done, or says so if the user stopped the transcription to run it later."
            }
            return try json(result)
        }

        // state == .recording
        guard snapshot.liveTranscriptAvailable else {
            result["status"] = "recording_live_unavailable"
            result["elapsed_seconds"] = Self.wholeSeconds(now().timeIntervalSince(snapshot.recordingStartedAt))
            result["note"] = "A recording is in progress, but live transcription is off for it (turned off in Mila's settings, or not available on this Mac) — no text will appear until it completes. Poll occasionally for status \"completed\" instead of expecting segments."
            return try json(result)
        }
        let heartbeatAge = now().timeIntervalSince(snapshot.updatedAt)
        let status = heartbeatAge > LiveTranscriptSnapshot.staleAfter ? "stale" : "recording"
        result["status"] = status
        result["elapsed_seconds"] = Self.wholeSeconds(now().timeIntervalSince(snapshot.recordingStartedAt))
        if status == "stale" {
            result["note"] = "The live snapshot hasn't been refreshed in \(Self.wholeSeconds(heartbeatAge))s — the Mila app may have crashed or hung; this transcript may be incomplete and won't grow."
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

        // A delta is only honest while the client's prefix is still valid. The
        // user can DELETE a line from the live pane, and the cursor has no way
        // to say so: it is a count plus "re-read the entry before it", so a
        // client that already fetched the deleted line would keep it for the
        // rest of the meeting and mis-stitch every line after it. When the
        // removal happened at a revision the client hasn't seen, resend
        // everything and say why. A client that sent no `since_revision` at
        // all can't prove it saw the removal, so it gets the same treatment.
        let clientRevision = args["since_revision"] as? Int
        let prefixInvalidated: Bool = {
            guard let removedAt = snapshot.segmentsRemovedAtRevision else { return false }
            guard let clientRevision else { return true }
            return clientRevision < removedAt
        }()

        if sameSession, !prefixInvalidated, let sinceIndex = args["since_segment_index"] as? Int {
            result["new_segments"] = snapshot.segments(sinceIndex: sinceIndex)
                .map(segmentObject(for:))
        } else {
            // First poll, a new session, or a removal the client hasn't seen:
            // full transcript + all segments.
            result["new_segments"] = snapshot.segments.map(segmentObject(for:))
            result["transcript"] = TranscriptFormatter.plainText(
                segments: snapshot.segments,
                fallback: TranscriptFormatter.joinedFullText(segments: snapshot.segments),
                names: snapshot.speakerNames
            )
            if sameSession, prefixInvalidated {
                result["segments_removed"] = true
                // Don't clobber the stale-heartbeat note, which is the more
                // urgent thing to tell the client.
                if !result.keys.contains("note") {
                    result["note"] = "Lines were removed from this transcript, so new_segments is the COMPLETE current set — discard your previous copy of this session's segments rather than appending."
                }
            }
        }
        return try json(result)
    }

    // MARK: - Helpers

    /// Every integer-seconds field the tools report (`duration_seconds`,
    /// `elapsed_seconds`, the stale-heartbeat note) goes through here.
    /// `Int(_:)` traps on NaN, ±infinity and anything at or beyond 2^63,
    /// and `duration` arrives verbatim from recordings.json — user-editable,
    /// written by every past app version — so a single row with
    /// `"duration": 1e300` (valid JSON, a valid Double) used to abort this
    /// long-lived process on EVERY list_recordings / get_transcript /
    /// search_transcripts call, not just the one that touched the row, and
    /// again after each restart. Same family as the `srtTimestamp` trap
    /// (#311). The `Date` differences in get_live_transcript are bounded by
    /// the ISO8601 decoder in practice but have the same shape, so they take
    /// the same path rather than staying the odd ones out.
    ///
    /// Truncates toward zero exactly as `Int(_:)` did, so every sane value
    /// is reported unchanged. Anything that is not a finite, non-negative,
    /// representable count reports 0 — the value a row with no `duration`
    /// at all already reports (`StoredRecording` defaults the field), so
    /// "unknown" has one spelling on the surface instead of a trap, a
    /// negative, or a sentinel a client would have to know about. No cap
    /// below representability: there is no principled line between a
    /// 1e15-second recording and a 9e18-second one, and neither traps.
    static func wholeSeconds(_ seconds: Double) -> Int {
        // `Int(exactly:)` answers nil for NaN, ±inf and out-of-range values
        // where `Int(_:)` would trap; truncating first makes it accept every
        // in-range value, integral or not.
        guard let whole = Int(exactly: seconds.rounded(.towardZero)), whole >= 0 else { return 0 }
        return whole
    }

    private func summaryObject(for recording: StoredRecording) -> [String: Any] {
        var obj: [String: Any] = [
            "id": recording.id.uuidString,
            "title": recording.title,
            "created_at": iso(recording.createdAt),
            "duration_seconds": Self.wholeSeconds(recording.duration.rounded()),
            "source": recording.source,
            "status": recording.status,
            "speakers": recording.speakerDisplayNames,
            "has_summary": !(recording.summary ?? "").isEmpty,
        ]
        if let folder = recording.folder { obj["folder"] = folder }
        if let appName = recording.appName { obj["app_name"] = appName }
        // The stable companion to the localized `app_name`.
        if let bundleID = recording.appBundleID { obj["app_bundle_id"] = bundleID }
        // Present only on recordings another Mila user shared as a
        // `.milashare` bundle — a client answering "whose meeting was this?"
        // should not have to guess from the title.
        if let sharedBy = recording.sharedBy { obj["shared_by"] = sharedBy }
        // Lets a client tell "the user chose to transcribe this later" from a
        // genuine `failed` without fetching the transcript.
        if recording.isTranscriptionDeferred { obj["transcription_stopped"] = true }
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
