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
/// `limit` bounds, and what it deliberately does not (#201, #241).
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

    /// How a recording's transcript is rendered during a search.
    ///
    /// Injectable for exactly the same reason as `SidecarReader`, and to pin
    /// the same kind of invisible work: a transcript that is rendered,
    /// scanned for a query and thrown away changes nothing an assertion over
    /// the RESULTS can see. Rendering one for every candidate on the
    /// relevance path was #241, so the tests count renders the way they
    /// count sidecar reads. Production always gets `renderNamedTranscript`.
    ///
    /// The reader arrives as a parameter rather than a captured `self`
    /// because the default is a `static let`, evaluated before any instance
    /// exists.
    typealias TranscriptRenderer = @Sendable (StoredRecording, MilaStoreReader) -> String

    static let renderNamedTranscript: TranscriptRenderer = { recording, reader in
        reader.namedTranscript(for: recording)
    }

    private let readSidecar: SidecarReader
    private let renderTranscript: TranscriptRenderer

    public init(recordingsDirectory: URL, storeFileURL: URL) {
        self.init(recordingsDirectory: recordingsDirectory,
                  storeFileURL: storeFileURL,
                  readSidecar: Self.readSidecarFromDisk,
                  renderTranscript: Self.renderNamedTranscript)
    }

    /// Test seams — see `SidecarReader` and `TranscriptRenderer`. Both are
    /// required rather than defaulted, so this initialiser can never be
    /// confused with the public two-argument one above.
    init(recordingsDirectory: URL, storeFileURL: URL,
         readSidecar: @escaping SidecarReader,
         renderTranscript: @escaping TranscriptRenderer) {
        self.recordingsDirectory = recordingsDirectory
        self.storeFileURL = storeFileURL
        self.readSidecar = readSidecar
        self.renderTranscript = renderTranscript
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
    ///   * per candidate, one scan for the query. A diarized recording is
    ///     scanned where it already sits — the raw segment strings the
    ///     decode produced — and nothing is built, copied or opened for it
    ///     (`rawScore`). A recording with no speaker labels costs one file
    ///     read, because its `.txt` sidecar IS its transcript;
    ///   * per candidate whose text contains the query at all, a per-line
    ///     pass to count matches. A non-matching recording — the common
    ///     case for a specific query — never pays for the line split or the
    ///     per-line scans;
    ///   * per RETURNED hit that carries a snippet, one rendered transcript.
    ///     At most `limit` of them, whichever way the results are sorted.
    ///
    /// **What `limit` bounds.** `sort: .createdAt` is bounded by it: date
    /// order is the traversal order, so the scan stops at the `limit`-th hit
    /// and opens no transcript past it. What it bounds is that per-recording
    /// transcript work; `recordings.json` is still decoded, filtered and
    /// sorted whole by `listRecordings`, because that metadata is where the
    /// traversal order the early stop depends on comes from.
    ///
    /// `sort: .relevance` (the default) is NOT bounded by it, and cannot be:
    /// ranking by match count has to score every candidate before it knows
    /// which few are the top ones, and it still does. Capping the candidate
    /// set instead — title matches first, then a few transcripts — would
    /// drop the best hit in a large store silently, which is a worse answer
    /// rather than a cheaper one. Every non-trashed recording is scored.
    ///
    /// What `limit` DOES bound on the relevance path is the rendering
    /// (#241). Scoring a diarized recording never needed the rendered
    /// transcript: see `rawScore`, which counts the query against the raw
    /// segment text `recordings.json` already decoded and gets the identical
    /// number. So the transcript is rendered only for the hits that come
    /// back — at most `limit` of them, and only those that carry a snippet —
    /// where before it was rendered once per candidate and thrown away.
    ///
    /// What stays linear is the scan itself, and the sidecar read for a
    /// recording with no speaker labels, whose transcript exists nowhere
    /// else: those ARE the text, so no rearrangement avoids them. A store in
    /// the tens of thousands still wants the on-disk index #201 weighs.
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
        // A caller asking for nothing gets nothing without the store being
        // touched. The trailing `prefix(cap)` already returned empty, but only
        // after paying for it: the relevance path scores every candidate, and
        // even the date path renders transcripts until the *first* hit, because
        // the early stop below is checked after a hit is appended. Same answer,
        // zero reads. `limit` is `min`-clamped upstream in the handler but has
        // no lower bound there, so `limit: 0` is reachable from a client.
        guard cap > 0 else { return [] }
        let candidates = try listRecordings(filter: Filter(speaker: speaker),
                                            sort: .createdAt,
                                            order: sortedByRecency ? order : .desc,
                                            limit: Int.max)
        var scored: [ScoredCandidate] = []
        for rec in candidates {
            guard let candidate = score(rec, for: query) else { continue }
            scored.append(candidate)
            // Already in output order, so the first `cap` hits ARE the
            // answer: everything after this point in the store can only be
            // older (or newer, ascending) than results that are already in.
            if sortedByRecency, scored.count >= cap { break }
        }
        if !sortedByRecency {
            scored.sort { a, b in
                let comparison: ComparisonResult
                if a.matchCount != b.matchCount {
                    comparison = compare(a.matchCount, b.matchCount)
                } else {
                    comparison = compare(a.recording.createdAt, b.recording.createdAt)
                }
                return isOrdered(comparison, order)
            }
        }
        // Only now — with the answer known — does anything get rendered.
        return scored.prefix(cap).map { hit(for: $0, query: query) }
    }

    /// A candidate that matched, before it is known to be in the answer.
    ///
    /// `snippets` is `nil` when the count came from `rawScore` and no
    /// transcript was rendered: snippets are the one part of a hit that
    /// needs the rendering, so they wait until the candidate has survived
    /// the ranking. Candidates that do not survive are never rendered at
    /// all, which is the whole of #241.
    private struct ScoredCandidate {
        let recording: StoredRecording
        let matchCount: Int
        let snippets: [String]?
    }

    /// One recording's score, or nil when it does not match.
    ///
    /// Ordered cheapest-first: the title is already in memory, the raw
    /// segments are already decoded, and only failing both of those costs a
    /// rendered transcript — which for a recording with no speaker labels
    /// costs a file read.
    private func score(_ recording: StoredRecording, for query: String) -> ScoredCandidate? {
        let titleMatches = matchCount(of: query, in: recording.title)
        switch rawScore(of: query, for: recording) {
        case .exact(let textMatches):
            let total = titleMatches + textMatches
            guard total > 0 else { return nil }
            // Nothing in the transcript matched, so there is nothing to
            // snip: the rendering has no answer to contribute even if this
            // candidate is returned.
            return ScoredCandidate(recording: recording, matchCount: total,
                                   snippets: textMatches == 0 ? [] : nil)
        case .noMatch:
            guard titleMatches > 0 else { return nil }
            return ScoredCandidate(recording: recording, matchCount: titleMatches, snippets: [])
        case .unknown:
            let transcript = renderTranscript(recording, self)
            let (textMatches, snippets) = countAndSnippets(of: query, in: transcript)
            let total = titleMatches + textMatches
            guard total > 0 else { return nil }
            return ScoredCandidate(recording: recording, matchCount: total, snippets: snippets)
        }
    }

    /// Fills in the snippets a returned hit needs, rendering the transcript
    /// if that was deferred. The match count is the one the ranking used —
    /// `rawScore`'s count and the rendered count are the same number (see
    /// its note), and reporting the other one would let a payload disagree
    /// with the order it arrived in.
    private func hit(for candidate: ScoredCandidate, query: String) -> SearchHit {
        if let snippets = candidate.snippets {
            return SearchHit(recording: candidate.recording,
                             matchCount: candidate.matchCount, snippets: snippets)
        }
        let transcript = renderTranscript(candidate.recording, self)
        return SearchHit(recording: candidate.recording,
                         matchCount: candidate.matchCount,
                         snippets: countAndSnippets(of: query, in: transcript).snippets)
    }

    /// Per-line match count and up to three context snippets over a rendered
    /// transcript.
    private func countAndSnippets(of query: String,
                                  in transcript: String) -> (count: Int, snippets: [String]) {
        // Every line is a contiguous substring of the transcript, so if the
        // whole transcript does not contain the query, no line can either —
        // one scan rules out the per-line pass.
        //
        // This is a gate, not a replacement: counting over the whole string
        // would NOT be equivalent, because a query containing a newline
        // matches the joined transcript while matching no single line. The
        // counts a caller sees stay per-line; only the work is skipped.
        guard contains(query, in: transcript) else { return (0, []) }
        var textMatches = 0
        var snippets: [String] = []
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
        return (textMatches, snippets)
    }

    /// What the raw material of a recording says about `query`, without
    /// rendering its transcript.
    private enum RawScore {
        /// Exactly the count `countAndSnippets` would report — not an
        /// estimate, not a lower bound.
        case exact(Int)
        /// Proof that no line of the rendered transcript matches.
        case noMatch
        /// Nothing proved; the transcript has to be rendered.
        case unknown
    }

    /// Score `query` against the pieces `TranscriptFormatter.plainText`
    /// builds a transcript OUT of, instead of against the transcript.
    ///
    /// The rendering inserts exactly three separators: `": "` after a
    /// speaker label, `" "` between segments of one turn, and `"\n"`
    /// between turns. **Every one of them contains whitespace**, and
    /// case/diacritic folding neither deletes a character nor turns a
    /// non-whitespace one into whitespace. So a run of the query with no
    /// whitespace in it cannot span two pieces: wherever it occurs in the
    /// rendered text it occurs inside a single `"<label>:"` or inside a
    /// single segment's text. And a segment's text is trimmed of whitespace
    /// before it goes in, so an occurrence in the trimmed text is an
    /// occurrence in the raw text and vice versa — the raw string
    /// `recordings.json` already handed over can be scanned instead, with
    /// nothing built and nothing copied.
    ///
    /// That gives two answers for the price of a scan:
    ///
    ///   * when the whole query is whitespace-free, its occurrences are
    ///     partitioned across the segments, so summing the per-segment
    ///     counts IS the per-line count — `.exact`;
    ///   * otherwise the longest whitespace-free run of the query is a
    ///     substring of it, so every occurrence of the query contains one of
    ///     that run. No run anywhere means no match anywhere — `.noMatch` —
    ///     which is what rules out the overwhelming majority of a store for
    ///     a phrase query.
    ///
    /// Two cases hand back `.unknown` rather than guess. A recording with no
    /// speaker labels renders to its `.txt` sidecar, and reading that file
    /// is precisely the work this would have to do to answer — so it is left
    /// to the rendering path, which reads it once. And a query that occurs
    /// in a speaker label is counted once per TURN, which the flat segment
    /// list does not describe; that is rare enough to pay for a rendering.
    private func rawScore(of query: String, for recording: StoredRecording) -> RawScore {
        // `matchCount` and `contains` both report nothing for an empty
        // needle, so an empty query matches nothing, anywhere, for free.
        guard !query.isEmpty else { return .noMatch }
        guard recording.segments.contains(where: { $0.speaker != nil }) else { return .unknown }
        guard let probe = longestWhitespaceFreeRun(in: query) else { return .unknown }

        var seenSpeakers = Set<String>()
        for segment in recording.segments {
            guard let raw = segment.speaker, seenSpeakers.insert(raw).inserted else { continue }
            // The colon belongs to the piece: `"Daniel:"` is a
            // whitespace-free query that matches the rendered line while
            // matching neither the label nor any segment on its own.
            if contains(probe, in: (recording.speakerNames[raw] ?? raw) + ":") {
                return .unknown
            }
        }

        // No label carries the probe, so every occurrence is inside one
        // segment — countable when the probe is the whole query, and merely
        // rulable-out when it is one word of a phrase.
        let exact = probe.count == query.count
        var total = 0
        for segment in recording.segments {
            if exact {
                total += matchCount(of: query, in: segment.text)
            } else if contains(probe, in: segment.text) {
                return .unknown
            }
        }
        return exact ? .exact(total) : .noMatch
    }

    /// The longest stretch of `query` with no whitespace in it, or nil when
    /// the query is nothing but whitespace (which no piece of the rendering
    /// can be scanned for — the separators are made of it).
    private func longestWhitespaceFreeRun(in query: String) -> String? {
        query.split(whereSeparator: { $0.isWhitespace })
            .max(by: { $0.count < $1.count })
            .map { String($0) }
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
