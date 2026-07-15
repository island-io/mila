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
public struct LiveTranscriptSnapshot: Codable {

    public enum State: String, Codable {
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
                finalRecordingID: UUID? = nil) {
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
    public func segments(sinceIndex index: Int) -> [Segment] {
        let start = max(0, min(index - 1, segments.count))
        return Array(segments[start...])
    }
}
