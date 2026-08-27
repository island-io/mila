import Foundation

/// Everything the MCP tool layer needs from Mila, as one protocol.
///
/// There is exactly one implementation today — `FileBackedDataSource`, which
/// reads the app's files directly — and this abstraction is not needed to
/// support it. It exists to keep a decision reversible.
///
/// The alternative architecture considered for this feature was for Mila to
/// serve a local API (a unix-domain socket) with `mila-mcp` as a thin client,
/// which would decouple the helper from the store's on-disk format. That was
/// declined for now because it would stop transcripts being readable while
/// Mila isn't running — Mila is an ordinary dock app (`LSUIElement: false`,
/// no login item), and the common request ("what did we decide on Tuesday?")
/// arrives days later with the app closed. Reading files works either way.
///
/// If that trade ever changes — a third-party consumer appears, or the store
/// format starts churning — a socket-backed implementation of this protocol
/// is the whole change on this side. The handler bodies don't move.
public protocol MilaDataSource: Sendable {
    func listRecordings(filter: MilaStoreReader.Filter,
                        sort: MilaStoreReader.SortKey,
                        order: MilaStoreReader.SortOrder,
                        limit: Int) throws -> [StoredRecording]
    func recording(id: UUID) throws -> StoredRecording?
    func latestCompletedRecording() throws -> StoredRecording?
    func namedTranscript(for recording: StoredRecording) -> String
    func searchTranscripts(query: String,
                           speaker: String?,
                           sort: MilaStoreReader.SearchSortKey,
                           order: MilaStoreReader.SortOrder,
                           limit: Int) throws -> [MilaStoreReader.SearchHit]
    func liveSnapshot() -> LiveTranscriptSnapshot?
}

/// Reads the app's store and live sidecar off disk.
public struct FileBackedDataSource: MilaDataSource {

    private let root: URL

    public init(root: URL = StoreLocationPointer.defaultRoot()) {
        self.root = root
    }

    /// Rebuilt per call on purpose: the reader resolves `store-location.json`
    /// in its initialiser, so a long-lived server picks up a mid-session
    /// relocation instead of holding a stale path.
    private var reader: MilaStoreReader { MilaStoreReader(root: root) }

    public func listRecordings(filter: MilaStoreReader.Filter,
                               sort: MilaStoreReader.SortKey,
                               order: MilaStoreReader.SortOrder,
                               limit: Int) throws -> [StoredRecording] {
        try reader.listRecordings(filter: filter, sort: sort, order: order, limit: limit)
    }

    public func recording(id: UUID) throws -> StoredRecording? {
        try reader.recording(id: id)
    }

    public func latestCompletedRecording() throws -> StoredRecording? {
        try reader.latestCompletedRecording()
    }

    public func namedTranscript(for recording: StoredRecording) -> String {
        reader.namedTranscript(for: recording)
    }

    public func searchTranscripts(query: String,
                                  speaker: String?,
                                  sort: MilaStoreReader.SearchSortKey,
                                  order: MilaStoreReader.SortOrder,
                                  limit: Int) throws -> [MilaStoreReader.SearchHit] {
        try reader.searchTranscripts(query: query, speaker: speaker,
                                     sort: sort, order: order, limit: limit)
    }

    public func liveSnapshot() -> LiveTranscriptSnapshot? {
        LiveTranscriptSnapshot.read(root: root)
    }
}
