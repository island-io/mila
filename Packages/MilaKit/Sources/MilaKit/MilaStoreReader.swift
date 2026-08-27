import Foundation

/// Read-only access to Mila's recording store for external processes
/// (mila-mcp). Resolves the store location via `StoreLocationPointer`,
/// falling back to the default app-support layout when no pointer exists
/// (the app hasn't run since the pointer feature shipped). Every call
/// re-reads from disk — the store is small, the app's writes are atomic,
/// and freshness beats caching for a live assistant.
public struct MilaStoreReader: Sendable {

    public let recordingsDirectory: URL
    public let storeFileURL: URL

    public init(recordingsDirectory: URL, storeFileURL: URL) {
        self.recordingsDirectory = recordingsDirectory
        self.storeFileURL = storeFileURL
    }

    /// The store paths an external reader ends up on.
    public struct ResolvedLocation: Equatable, Sendable {
        public let recordingsDirectory: URL
        public let storeFileURL: URL
        /// True when no pointer existed and the default layout was assumed.
        public let usedFallback: Bool
    }

    /// Where an external reader lands, given what is on disk at `root`
    /// right now: the pointer file if there is one, otherwise the
    /// historical default layout (`<root>/recordings.json` +
    /// `<root>/Recordings/`).
    ///
    /// Factored out of `init(root:)` so the APP can ask the same question
    /// the helper answers — "what store would mila-mcp read?" — and compare
    /// it against the store it is actually writing to. Two copies of this
    /// rule would be free to drift, and a drift here is silent: the helper
    /// would serve a different store than the app without either side
    /// noticing. See `resolvesActiveStore(root:recordingsDirectory:storeFile:)`.
    public static func resolvedLocation(root: URL = StoreLocationPointer.defaultRoot())
        -> ResolvedLocation {
        if let pointer = StoreLocationPointer.read(from: root) {
            return ResolvedLocation(
                recordingsDirectory: URL(fileURLWithPath: pointer.recordingsDirectory,
                                         isDirectory: true),
                storeFileURL: URL(fileURLWithPath: pointer.storeFile),
                usedFallback: false)
        }
        return ResolvedLocation(
            recordingsDirectory: root.appendingPathComponent("Recordings", isDirectory: true),
            storeFileURL: root.appendingPathComponent("recordings.json"),
            usedFallback: true)
    }

    /// Whether what an external reader resolves from `root` is the store the
    /// app is actually using.
    ///
    /// The app calls this straight after writing `store-location.json`, and
    /// treats `false` as "mila-mcp must not answer". The check is a read-back
    /// rather than a "did `write()` throw?", because the failure that matters
    /// is not the throw — it is the END STATE. `relocateRecordings` switches
    /// the live store paths BEFORE the pointer is written and deliberately
    /// leaves the old store on disk, so a pointer write that fails (or half
    /// succeeds, or is clobbered) leaves a perfectly readable pointer naming
    /// a store the app has stopped writing to. The helper would then answer
    /// questions from stale recordings — confidently wrong, with nothing to
    /// tell the user it happened. Comparing the resolved end state catches
    /// every route into that shape, including a `write()` that returned
    /// without error.
    ///
    /// Paths are compared with symlinks resolved and standardized on both
    /// sides: the pointer stores strings, the app holds `URL`s, and macOS
    /// temp roots live behind the `/var` → `/private/var` symlink.
    public static func resolvesActiveStore(root: URL,
                                           recordingsDirectory: URL,
                                           storeFile: URL) -> Bool {
        func key(_ url: URL) -> String {
            url.resolvingSymlinksInPath().standardizedFileURL.path
        }
        let resolved = resolvedLocation(root: root)
        return key(resolved.recordingsDirectory) == key(recordingsDirectory)
            && key(resolved.storeFileURL) == key(storeFile)
    }

    /// Resolve from the pointer file at `root`, or fall back to the
    /// historical default layout (`<root>/recordings.json` +
    /// `<root>/Recordings/`).
    public init(root: URL = StoreLocationPointer.defaultRoot()) {
        let resolved = Self.resolvedLocation(root: root)
        self.init(recordingsDirectory: resolved.recordingsDirectory,
                  storeFileURL: resolved.storeFileURL)
    }

    // MARK: - Loading

    public func loadRecordings() throws -> [StoredRecording] {
        let data = try Data(contentsOf: storeFileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([StoredRecording].self, from: data)
    }

    /// Plain transcript text: sidecar `.txt` → legacy inline text →
    /// joined segments (same fallback chain, and now the same join, as the
    /// app's load path — see `TranscriptFormatter.joinedFullText`).
    public func transcriptText(for recording: StoredRecording) -> String {
        let url = recordingsDirectory.appendingPathComponent(recording.transcriptFileName)
        if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
            return text
        }
        if let legacy = recording.legacyFullText, !legacy.isEmpty { return legacy }
        return TranscriptFormatter.joinedFullText(segments: recording.segments)
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

    public struct Filter: Sendable {
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

    public enum SortKey: String, Sendable {
        case createdAt = "created_at"
        case duration
        case title
    }

    public enum SortOrder: String, Sendable {
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
            let comparison: ComparisonResult
            switch sort {
            case .createdAt: comparison = compare(a.createdAt, b.createdAt)
            case .duration: comparison = compare(a.duration, b.duration)
            case .title: comparison = a.title.localizedCaseInsensitiveCompare(b.title)
            }
            return isOrdered(comparison, order)
        }
        return Array(results.prefix(max(0, limit)))
    }

    /// Latest non-trashed completed recording, if any.
    public func latestCompletedRecording() throws -> StoredRecording? {
        try listRecordings(limit: Int.max).first { $0.status == "completed" }
    }

    /// One non-trashed recording by id.
    ///
    /// Trashed rows are excluded HERE rather than in the tool handler so the
    /// invariant — "this reader never surfaces a recording the user moved to
    /// the trash" — lives in exactly one place, alongside the identical
    /// filter in `listRecordings`. Enforcing it in the handler instead would
    /// leave the reader's own API a trap: `recording(id:)` looked like a
    /// safe lookup and quietly wasn't.
    ///
    /// It used to have no filter at all, so a client that had cached a UUID
    /// from an earlier `list_recordings` could still fetch the transcript of
    /// a recording the user had since deleted — a store that answers "no" to
    /// a listing and "yes" to a direct lookup for the same row.
    /// (CodeRabbit on #183, CWE-200.)
    ///
    /// A trashed id is reported as simply not found. Distinguishing "trashed"
    /// from "never existed" would confirm the recording exists, which is the
    /// same disclosure in a smaller package.
    public func recording(id: UUID) throws -> StoredRecording? {
        try loadRecordings().first { $0.id == id && !$0.isTrashed }
    }

    // MARK: - Search

    public struct SearchHit: Sendable {
        public let recording: StoredRecording
        /// Total case-insensitive matches across title + transcript.
        public let matchCount: Int
        /// Up to a few matching lines with one line of context each side.
        public let snippets: [String]
    }

    public enum SearchSortKey: String, Sendable {
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
            let comparison: ComparisonResult
            switch sort {
            case .relevance:
                if a.matchCount != b.matchCount {
                    comparison = compare(a.matchCount, b.matchCount)
                } else {
                    comparison = compare(a.recording.createdAt, b.recording.createdAt)
                }
            case .createdAt:
                comparison = compare(a.recording.createdAt, b.recording.createdAt)
            }
            return isOrdered(comparison, order)
        }
        return Array(hits.prefix(max(0, limit)))
    }

    /// Three-way comparison for any `Comparable`.
    private func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        if a < b { return .orderedAscending }
        if b < a { return .orderedDescending }
        return .orderedSame
    }

    /// Turns a three-way comparison into the strict-weak-ordering predicate
    /// `sort(by:)` requires.
    ///
    /// The obvious `order == .asc ? ascending : !ascending` is **not** a valid
    /// ordering: for equal elements `ascending` is `false`, so its negation
    /// claims `a < b` *and* `b < a` are both true. Swift's sort is documented
    /// as requiring a strict weak ordering and gives unspecified results
    /// otherwise — in practice equal elements came back silently reversed.
    /// `.orderedSame` must map to `false` in both directions.
    private func isOrdered(_ comparison: ComparisonResult, _ order: SortOrder) -> Bool {
        switch comparison {
        case .orderedSame: return false
        case .orderedAscending: return order == .asc
        case .orderedDescending: return order == .desc
        }
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
