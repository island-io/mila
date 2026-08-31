import Foundation

/// Read-only access to Mila's recording store for external processes
/// (mila-mcp). Resolves the store location via `StoreLocationPointer`,
/// falling back to the default app-support layout when no pointer exists
/// (the app hasn't run since the pointer feature shipped). Every call
/// re-reads from disk — the store is small, the app's writes are atomic,
/// and freshness beats caching for a live assistant.
///
/// That statelessness is deliberate and stays: nothing here remembers
/// anything between calls, so the only way to make a call cheaper is to make
/// it do less work, not to reuse work from an earlier one. `searchTranscripts`
/// is where that matters — see its own note for what one call costs, what
/// `limit` bounds, and what it deliberately does not (#201).
public struct MilaStoreReader: Sendable {

    public let recordingsDirectory: URL
    public let storeFileURL: URL

    /// How a recording's `.txt` sidecar is read.
    ///
    /// Internal and injectable for exactly one reason: tests need to COUNT
    /// the sidecar reads a single call performs. A read whose result is
    /// discarded leaves no trace in the output — which is precisely the waste
    /// #201 was about — so no assertion over results can see it, and the
    /// bound `searchTranscripts` promises would be unpinnable. Production
    /// always gets `readSidecarFromDisk`. (`MilaMCPToolHandlers` takes an
    /// injectable `isAccessEnabled` for the same kind of reason.)
    typealias SidecarReader = @Sendable (URL) -> String?

    /// Written as a closure literal rather than the tidier unapplied
    /// `String.init(contentsOf:encoding:)`: an unapplied function reference
    /// is not inferred `@Sendable`, which this package's strict-concurrency
    /// checking rejects.
    static let readSidecarFromDisk: SidecarReader = {
        try? String(contentsOf: $0, encoding: .utf8)
    }

    private let readSidecar: SidecarReader

    public init(recordingsDirectory: URL, storeFileURL: URL) {
        self.init(recordingsDirectory: recordingsDirectory,
                  storeFileURL: storeFileURL,
                  readSidecar: Self.readSidecarFromDisk)
    }

    /// Test seam — see `SidecarReader`.
    init(recordingsDirectory: URL, storeFileURL: URL,
         readSidecar: @escaping SidecarReader) {
        self.recordingsDirectory = recordingsDirectory
        self.storeFileURL = storeFileURL
        self.readSidecar = readSidecar
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
        if let text = readSidecar(url), !text.isEmpty {
            return text
        }
        if let legacy = recording.legacyFullText, !legacy.isEmpty { return legacy }
        return TranscriptFormatter.joinedFullText(segments: recording.segments)
    }

    /// Speaker-named transcript — the app's canonical rendering
    /// (`SPEAKER_00:` prefixes resolved through `speakerNames`, same-speaker
    /// turns collapsed).
    ///
    /// The `fallback:` argument is an `@autoclosure`, so `transcriptText`
    /// (a file read) runs only for a recording whose segments carry no
    /// speaker labels — the one case where the sidecar is what the rendering
    /// is made of. A diarized recording renders from segments that are
    /// already decoded, and reading its sidecar to throw the text away was
    /// one wasted file read per recording per search (#201). Keep the read
    /// inside the argument; hoisting it into a `let` puts them all back.
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
    ///
    /// **What one call costs.** There is no cache (see the type's own note),
    /// so the cost is whatever this call does:
    ///
    ///   * one `recordings.json` decode, which is also where the trashed
    ///     filter is applied — candidates come from `listRecordings`, so
    ///     nothing below can reach a row the listing hides;
    ///   * per candidate, the rendered transcript: free for a diarized
    ///     recording (its segments are already decoded and its sidecar is
    ///     never part of the rendering), one file read for a recording with
    ///     no speaker labels, whose sidecar IS its transcript;
    ///   * per candidate whose transcript contains the query at all, a
    ///     second per-line pass to count matches and build snippets. A
    ///     non-matching recording — the common case for a specific query —
    ///     never pays for the line split or the per-line scans.
    ///
    /// **What `limit` bounds.** `sort: .createdAt` is bounded by it: date
    /// order is the traversal order, so the scan stops at the `limit`-th hit
    /// and never opens the rest of the store.
    ///
    /// `sort: .relevance` (the default) is NOT, and cannot be: ranking by
    /// match count has to score every candidate before it knows which few
    /// are the top ones. Capping the candidate set instead — title matches
    /// first, then a few transcripts — would drop the best hit in a large
    /// store silently, which is a worse answer rather than a cheaper one.
    /// So the ceiling on the default path stays linear in the store: one
    /// transcript render per non-trashed recording, plus one sidecar read
    /// per undiarized one. #201 reduced the constant (it used to be one read
    /// per recording unconditionally, diarized or not); it did not remove
    /// the linear term, and a store in the tens of thousands would want the
    /// on-disk index that issue also weighs.
    public func searchTranscripts(query: String,
                                  speaker: String? = nil,
                                  sort: SearchSortKey = .relevance,
                                  order: SortOrder = .desc,
                                  limit: Int = 10) throws -> [SearchHit] {
        // Date order is the one ranking whose output order is knowable
        // before the whole store has been scored, so it is the one that can
        // stop early. Relevance re-sorts by match count afterwards, so the
        // order candidates arrive in is only its tie-break input — kept at
        // `.desc` (newest first), which is what it was when the hits were
        // always collected in that order.
        let sortedByRecency: Bool
        switch sort {
        case .createdAt: sortedByRecency = true
        case .relevance: sortedByRecency = false
        }
        let cap = max(0, limit)
        let candidates = try listRecordings(filter: Filter(speaker: speaker),
                                            sort: .createdAt,
                                            order: sortedByRecency ? order : .desc,
                                            limit: Int.max)
        var hits: [SearchHit] = []
        for rec in candidates {
            guard let hit = searchHit(for: rec, query: query) else { continue }
            hits.append(hit)
            // Already in output order, so the first `cap` hits ARE the
            // answer: everything after this point in the store can only be
            // older (or newer, ascending) than results that are already in.
            if sortedByRecency, hits.count >= cap { break }
        }
        if !sortedByRecency {
            hits.sort { a, b in
                let comparison: ComparisonResult
                if a.matchCount != b.matchCount {
                    comparison = compare(a.matchCount, b.matchCount)
                } else {
                    comparison = compare(a.recording.createdAt, b.recording.createdAt)
                }
                return isOrdered(comparison, order)
            }
        }
        return Array(hits.prefix(cap))
    }

    /// One recording's hit, or nil when it does not match.
    ///
    /// Ordered cheapest-first: the title is already in memory, the
    /// transcript may cost a file read, and the per-line pass allocates a
    /// string per line and re-scans each one.
    private func searchHit(for recording: StoredRecording, query: String) -> SearchHit? {
        let titleMatches = matchCount(of: query, in: recording.title)
        let transcript = namedTranscript(for: recording)
        var textMatches = 0
        var snippets: [String] = []
        // Every line is a contiguous substring of the transcript, so if the
        // whole transcript does not contain the query, no line can either —
        // one scan rules out the per-line pass for a non-matching recording.
        //
        // This is a gate, not a replacement: counting over the whole string
        // would NOT be equivalent, because a query containing a newline
        // matches the joined transcript while matching no single line. The
        // counts a caller sees stay per-line; only the work is skipped.
        if contains(query, in: transcript) {
            let lines = transcript.components(separatedBy: .newlines)
            for (i, line) in lines.enumerated() {
                let n = matchCount(of: query, in: line)
                guard n > 0 else { continue }
                textMatches += n
                if snippets.count < 3 {
                    let context = lines[max(0, i - 1)...min(lines.count - 1, i + 1)]
                    snippets.append(context.joined(separator: "\n"))
                }
            }
        }
        let total = titleMatches + textMatches
        guard total > 0 else { return nil }
        return SearchHit(recording: recording, matchCount: total, snippets: snippets)
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

    /// Whether `haystack` contains `needle` at all, under the same matching
    /// options `matchCount` uses — one scan that stops at the first hit.
    private func contains(_ needle: String, in haystack: String) -> Bool {
        guard !needle.isEmpty else { return false }
        return haystack.range(of: needle,
                              options: [.caseInsensitive, .diacriticInsensitive]) != nil
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
