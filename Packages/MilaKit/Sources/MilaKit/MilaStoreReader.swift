import Foundation

/// Read-only access to Mila's recording store for external processes
/// (mila-mcp). Resolves the store location via `StoreLocationPointer`,
/// falling back to the default app-support layout when no pointer exists
/// (the app hasn't run since the pointer feature shipped). Every call
/// re-reads from disk — the store is small, the app's writes are atomic,
/// and freshness beats caching for a live assistant.
public struct MilaStoreReader {

    public let recordingsDirectory: URL
    public let storeFileURL: URL

    public init(recordingsDirectory: URL, storeFileURL: URL) {
        self.recordingsDirectory = recordingsDirectory
        self.storeFileURL = storeFileURL
    }

    /// Resolve from the pointer file at `root`, or fall back to the
    /// historical default layout (`<root>/recordings.json` +
    /// `<root>/Recordings/`).
    public init(root: URL = StoreLocationPointer.defaultRoot()) {
        if let pointer = StoreLocationPointer.read(from: root) {
            self.init(recordingsDirectory: URL(fileURLWithPath: pointer.recordingsDirectory,
                                               isDirectory: true),
                      storeFileURL: URL(fileURLWithPath: pointer.storeFile))
        } else {
            self.init(recordingsDirectory: root.appendingPathComponent("Recordings",
                                                                       isDirectory: true),
                      storeFileURL: root.appendingPathComponent("recordings.json"))
        }
    }

    // MARK: - Loading

    public func loadRecordings() throws -> [StoredRecording] {
        let data = try Data(contentsOf: storeFileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([StoredRecording].self, from: data)
    }

    /// Plain transcript text: sidecar `.txt` → legacy inline text →
    /// joined segments (same fallback chain as the app's load path).
    public func transcriptText(for recording: StoredRecording) -> String {
        let url = recordingsDirectory.appendingPathComponent(recording.transcriptFileName)
        if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
            return text
        }
        if let legacy = recording.legacyFullText, !legacy.isEmpty { return legacy }
        return recording.segments.map(\.text).joined()
    }

    /// Speaker-named transcript — the app's canonical rendering
    /// (`SPEAKER_00:` prefixes resolved through `speakerNames`, same-speaker
    /// turns collapsed).
    public func namedTranscript(for recording: StoredRecording) -> String {
        TranscriptFormatter.plainText(
            segments: recording.segments,
            fallback: transcriptText(for: recording)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            names: recording.speakerNames
        )
    }

    // MARK: - Listing

    public struct Filter {
        /// Substring over title, appName, and folder.
        public var query: String?
        /// Substring over resolved speaker display names.
        public var speaker: String?
        public var folder: String?
        /// Raw `RecordingSource` value (`microphone` / `systemAudio` / …).
        public var source: String?
        public var after: Date?
        public var before: Date?

        public init(query: String? = nil, speaker: String? = nil, folder: String? = nil,
                    source: String? = nil, after: Date? = nil, before: Date? = nil) {
            self.query = query
            self.speaker = speaker
            self.folder = folder
            self.source = source
            self.after = after
            self.before = before
        }
    }

    public enum SortKey: String {
        case createdAt = "created_at"
        case duration
        case title
    }

    public enum SortOrder: String {
        case asc, desc
    }

    /// Non-trashed recordings matching `filter`, sorted and capped.
    public func listRecordings(filter: Filter = Filter(),
                               sort: SortKey = .createdAt,
                               order: SortOrder = .desc,
                               limit: Int = 20) throws -> [StoredRecording] {
        var results = try loadRecordings().filter { rec in
            guard !rec.isTrashed else { return false }
            if let q = filter.query, !q.isEmpty {
                let haystacks = [rec.title, rec.appName ?? "", rec.folder ?? ""]
                guard haystacks.contains(where: { $0.localizedStandardContains(q) }) else {
                    return false
                }
            }
            if let speaker = filter.speaker, !speaker.isEmpty {
                guard rec.speakerDisplayNames.contains(where: {
                    $0.localizedStandardContains(speaker)
                }) else { return false }
            }
            if let folder = filter.folder, !folder.isEmpty {
                guard rec.folder?.localizedStandardContains(folder) == true else { return false }
            }
            if let source = filter.source, !source.isEmpty {
                guard rec.source == source else { return false }
            }
            if let after = filter.after, rec.createdAt < after { return false }
            if let before = filter.before, rec.createdAt > before { return false }
            return true
        }
        results.sort { a, b in
            let ascending: Bool
            switch sort {
            case .createdAt: ascending = a.createdAt < b.createdAt
            case .duration: ascending = a.duration < b.duration
            case .title:
                ascending = a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
            return order == .asc ? ascending : !ascending
        }
        return Array(results.prefix(max(0, limit)))
    }

    /// Latest non-trashed completed recording, if any.
    public func latestCompletedRecording() throws -> StoredRecording? {
        try listRecordings(limit: Int.max).first { $0.status == "completed" }
    }

    public func recording(id: UUID) throws -> StoredRecording? {
        try loadRecordings().first { $0.id == id }
    }

    // MARK: - Search

    public struct SearchHit {
        public let recording: StoredRecording
        /// Total case-insensitive matches across title + transcript.
        public let matchCount: Int
        /// Up to a few matching lines with one line of context each side.
        public let snippets: [String]
    }

    public enum SearchSortKey: String {
        case relevance
        case createdAt = "created_at"
    }

    /// Case/diacritic-insensitive full-text search over titles and
    /// transcript text of non-trashed recordings.
    public func searchTranscripts(query: String,
                                  speaker: String? = nil,
                                  sort: SearchSortKey = .relevance,
                                  order: SortOrder = .desc,
                                  limit: Int = 10) throws -> [SearchHit] {
        let recordings = try listRecordings(filter: Filter(speaker: speaker), limit: Int.max)
        var hits: [SearchHit] = []
        for rec in recordings {
            let transcript = namedTranscript(for: rec)
            let titleMatches = matchCount(of: query, in: rec.title)
            let lines = transcript.components(separatedBy: .newlines)
            var textMatches = 0
            var snippets: [String] = []
            for (i, line) in lines.enumerated() {
                let n = matchCount(of: query, in: line)
                guard n > 0 else { continue }
                textMatches += n
                if snippets.count < 3 {
                    let context = lines[max(0, i - 1)...min(lines.count - 1, i + 1)]
                    snippets.append(context.joined(separator: "\n"))
                }
            }
            let total = titleMatches + textMatches
            guard total > 0 else { continue }
            hits.append(SearchHit(recording: rec, matchCount: total, snippets: snippets))
        }
        hits.sort { a, b in
            let ascending: Bool
            switch sort {
            case .relevance:
                if a.matchCount != b.matchCount {
                    ascending = a.matchCount < b.matchCount
                } else {
                    ascending = a.recording.createdAt < b.recording.createdAt
                }
            case .createdAt:
                ascending = a.recording.createdAt < b.recording.createdAt
            }
            return order == .asc ? ascending : !ascending
        }
        return Array(hits.prefix(max(0, limit)))
    }

    private func matchCount(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle,
                                         options: [.caseInsensitive, .diacriticInsensitive],
                                         range: searchRange) {
            count += 1
            searchRange = found.upperBound..<haystack.endIndex
        }
        return count
    }
}
