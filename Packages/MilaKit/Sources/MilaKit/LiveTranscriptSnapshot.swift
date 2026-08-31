import Foundation

/// On-disk snapshot of the in-progress recording's live transcript —
/// `<app-support>/Mila/live/current.json`. Written by the app
/// (`LiveTranscriptSidecarWriter`) on every live-transcript tick and read
/// by mila-mcp's `get_live_transcript` tool, so an external Claude session
/// can follow a meeting while it happens.
///
/// Freshness contract: `revision` bumps on every CONTENT change (segments
/// or speaker names) and is the poller's cheap "anything new?" cursor.
/// `updatedAt` is a liveness heartbeat, refreshed every few seconds even
/// when nothing was said — a `recording` snapshot whose heartbeat is stale
/// means the app crashed or hung mid-meeting. `sessionID` is minted fresh
/// per recording so a poller can tell "same meeting, nothing new" apart
/// from "a different meeting whose counters happen to line up".
public struct LiveTranscriptSnapshot: Codable, Sendable {

    public enum State: String, Codable, Sendable {
        /// A recording is in progress; segments may still grow.
        case recording
        /// The recording ended normally; `finalRecordingID` points at the
        /// saved recording. Kept on disk until the next recording begins
        /// so a poller can't miss the handoff.
        case completed
        /// A leftover `recording` snapshot found at app launch — the app
        /// died mid-recording. Crash recovery re-transcribes the audio
        /// separately; the live feed is over.
        case interrupted
    }

    public typealias Segment = StoredRecording.Segment

    public var version: Int
    public var sessionID: UUID
    public var state: State
    /// False when the recording runs on hardware below the live-AI bar:
    /// the meeting is being captured, but no live transcript will appear
    /// until it completes.
    public var liveTranscriptAvailable: Bool
    public var recordingStartedAt: Date
    public var updatedAt: Date
    /// Monotonic within a session; bumps only on content changes.
    public var revision: Int
    public var title: String?
    /// Raw `RecordingSource` value, when known.
    public var source: String?
    public var segments: [Segment]
    public var speakerNames: [String: String]
    /// Set when `state == .completed` — the saved recording's UUID, for
    /// handoff to `get_transcript`.
    public var finalRecordingID: UUID?
    /// The `revision` at which segments were last REMOVED rather than
    /// appended-to or trailing-rewritten — i.e. the user deleted a line from
    /// the live pane.
    ///
    /// The incremental poll contract (`since_segment_index`) is append-only by
    /// construction: `next_segment_index` is a count, and a delta re-sends
    /// only from one before that index. Nothing in it can say "the line you
    /// already hold is gone", so without this marker a poller that had
    /// already fetched a deleted line would keep it in its own context for
    /// the rest of the meeting — and its cursor would be off by one, so
    /// subsequent lines would be mis-stitched too.
    ///
    /// A poller whose `since_revision` predates this value is served the FULL
    /// segment set instead of a delta. `nil` (the common case, and what an
    /// older app's file decodes to) means nothing has ever been removed, so
    /// deltas behave exactly as before.
    ///
    /// Optional deliberately: the mila-mcp helper and the app ship in the
    /// same bundle but need not be the same build — a non-optional `Int`
    /// would make a newer helper fail to decode an older app's snapshot
    /// entirely and report "not recording" mid-meeting.
    public var segmentsRemovedAtRevision: Int?

    public init(version: Int = 1,
                sessionID: UUID = UUID(),
                state: State = .recording,
                liveTranscriptAvailable: Bool = true,
                recordingStartedAt: Date,
                updatedAt: Date,
                revision: Int = 1,
                title: String? = nil,
                source: String? = nil,
                segments: [Segment] = [],
                speakerNames: [String: String] = [:],
                finalRecordingID: UUID? = nil,
                segmentsRemovedAtRevision: Int? = nil) {
        self.version = version
        self.sessionID = sessionID
        self.state = state
        self.liveTranscriptAvailable = liveTranscriptAvailable
        self.recordingStartedAt = recordingStartedAt
        self.updatedAt = updatedAt
        self.revision = revision
        self.title = title
        self.source = source
        self.segments = segments
        self.speakerNames = speakerNames
        self.finalRecordingID = finalRecordingID
        self.segmentsRemovedAtRevision = segmentsRemovedAtRevision
    }

    /// Heartbeat age beyond which a `recording` snapshot is reported stale.
    public static let staleAfter: TimeInterval = 20

    public static let directoryName = "live"
    public static let fileName = "current.json"

    public static func fileURL(root: URL = StoreLocationPointer.defaultRoot()) -> URL {
        root.appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    public static func read(root: URL = StoreLocationPointer.defaultRoot()) -> LiveTranscriptSnapshot? {
        guard let data = try? Data(contentsOf: fileURL(root: root)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LiveTranscriptSnapshot.self, from: data)
    }

    public func write(root: URL = StoreLocationPointer.defaultRoot()) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        let url = Self.fileURL(root: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // .atomic = write-to-temp + rename, so a concurrent reader always
        // sees a complete JSON document.
        try data.write(to: url, options: .atomic)
    }

    /// Segments a poller hasn't fully seen. Returns from ONE BEFORE
    /// `index` — the last segment the client already has is re-sent
    /// because the live merge can rewrite the trailing segment's text as
    /// more audio context arrives; the client replaces its copy.
    ///
    /// `index` is unvalidated client input — it arrives as
    /// `since_segment_index` in a tool call — and `index - 1` traps on
    /// `Int.min` (arithmetic overflow; the subscript was never the
    /// problem, since `segments[endIndex...]` is a legal empty slice).
    ///
    /// Non-positive cursors are answered before any subtraction happens,
    /// which removes the only overflow and leaves every other cursor
    /// computing exactly what it did before — including a cursor past the
    /// end, which still yields `[]` rather than re-sending the tail.
    public func segments(sinceIndex index: Int) -> [Segment] {
        guard index > 0 else { return segments }
        let start = min(index - 1, segments.count)
        return Array(segments[start...])
    }

    /// Whether going from `old` to `new` REMOVED a line a poller may already
    /// hold, as opposed to the two changes the incremental cursor already
    /// describes correctly:
    ///
    ///   * **Appending** — new entries past the old count.
    ///   * **Rewriting the trailing entry** — the live merge extends the last
    ///     utterance as whisper gets more audio, which is exactly why
    ///     `segments(sinceIndex:)` re-sends one before the cursor. Deleting
    ///     the LAST line therefore needs no marker either: the client is told
    ///     to replace that entry with whatever now occupies it (or, when
    ///     nothing does, `next_segment_index` shrinks past it).
    ///
    /// `speaker` is deliberately NOT compared. Live diarization labels land
    /// on already-published lines several seconds late; treating that as a
    /// removal would force a full resend on most ticks of a multi-speaker
    /// meeting. (An in-place speaker label is not delivered incrementally
    /// today either — a separate, pre-existing gap.)
    public static func segmentsWereRemoved(from old: [Segment], to new: [Segment]) -> Bool {
        // Anything shorter lost a line outright. (Also the `old.count == 1`
        // case: its only entry is the trailing one, so a shrink to 0 is the
        // sole way it can go.)
        if new.count < old.count { return true }
        guard old.count > 1 else { return false }
        // Compare the protected prefix — everything except the trailing
        // entry the protocol already re-sends.
        for i in 0..<(old.count - 1) {
            if new[i].start != old[i].start
                || new[i].end != old[i].end
                || new[i].text != old[i].text {
                return true
            }
        }
        return false
    }
}
