import Foundation
import TranscriptionCore
import Combine
import OSLog
import MilaKit

private let suggesterLog = Logger(subsystem: "io.island.whisper.IslandWhisper",
                                  category: "SpeakerNameSuggester")

/// Proposes names for a finished recording's still-unnamed speakers
/// (issue #348), from two sources:
///
/// 1. **"Me"** — `SpeakerIdentitySettings`' "Your name", for the single voice
///    in a recording captured from the user's own microphone
///    (`localUserSuggestion`). Local, no LLM.
/// 2. **The transcript** — one LLM call asking which unnamed speakers state
///    their own name ("Hi, I'm Dana") or are addressed by name right before
///    they answer. Every mapping must come with a quote, and the quote must
///    be about THAT speaker: in their own turn, or in the turn right before
///    they answer, stating the name as a whole word. Anything else — and any
///    ambiguous or already-taken name — is dropped (`parseSuggestions`).
///
/// **Everything it produces is a suggestion.** It writes only
/// `Recording.speakerNameSuggestions` (`RecordingStore.mergeSpeakerNameSuggestions`),
/// never `speakerNames`, so nothing reaches a voice profile until the user
/// clicks Accept — which goes through `RecordingStore.setSpeakerName`, the
/// normal rename path. A guessed name written straight in would be folded
/// into a voice profile and then spread to every future recording of that
/// voice; a wrong suggestion costs one click.
///
/// **When it runs.** Once per fresh completion, AFTER the recording's summary
/// attempt has settled: the completion paths (`TranscriptionService`'s
/// `onTranscriptionCompleted` hook, `QuickActionsController.finalizeTail`)
/// call `markPending`, and `RecordingSummarizer.onSummaryFinished` calls
/// `suggestIfPending`. Sequencing it behind the summary keeps one recording
/// to one provider call at a time, and by then the speaker labels are final
/// (the offline re-diarization finishes before the summary is kicked). The
/// launch-time summary backfill never marks anything, so it does not turn
/// into a name-inference sweep of the back catalogue.
///
/// **Why a separate call rather than a section of the summary prompt.** The
/// summary is built from `Recording.fullText`, which carries no speaker
/// labels, and this question cannot be answered without them. Folding it in
/// would mean feeding every summary a labelled transcript — changing what
/// every summary says, for every user, including those with this switch off
/// — and the summarizer's staleness machinery (#318) compares its input
/// against `fullText` to decide whether a result is still current. The call
/// is made only when there is an unnamed speaker to ask about and the user
/// has the switch on (`LLMSettings.isSpeakerNameSuggestionReady`).
@MainActor
final class SpeakerNameSuggester {

    /// Everything one LLM call is built from. Behind a seam (`RunLLM`) so
    /// tests return canned output without a subprocess, as
    /// `RecordingSummarizer.RunLLM` does.
    struct Call {
        let tool: LLMTool
        let prompt: String
        let transcript: String
        let executablePathOverride: String?
        let model: String?
        let extraArgs: [String]
        let timeout: TimeInterval
        let openAIBaseURL: String?
        let openAIAPIKey: String?
    }

    typealias RunLLM = @MainActor (Call) async throws -> String

    private let store: RecordingStore
    private let llmSettings: LLMSettings
    private let liveAISettings: LiveAISettings
    private let identity: SpeakerIdentitySettings
    private let runLLM: RunLLM

    /// Fresh completions waiting for their summary attempt to settle.
    private var pending: Set<UUID> = []
    /// Recordings waiting for an LLM slot.
    private var queue: [UUID] = []
    private var inFlight: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    /// Runs `cancel(recordingID:)` took out of `inFlight` whose tasks have
    /// not unwound yet; they still hold a slot (their child is still being
    /// killed), exactly as in `RecordingSummarizer.cancelledRuns`.
    private var cancelledRuns: [UUID: Task<Void, Never>] = [:]
    /// Recordings that asked again while their call was out — a
    /// re-transcription completing mid-call, say. That call's answer is
    /// about the OLD speakers and is discarded by the snapshot check, so the
    /// request must not be dropped either: it runs once the call in flight
    /// has finished (`runEnded`), like the summarizer's follow-up.
    private var rerunRequested: Set<UUID> = []

    /// One call at a time. This is a background nicety, not something the
    /// user is waiting on, and it already runs next to the summarizer's own
    /// `maxConcurrent` CLI processes.
    var maxConcurrent = 1

    private var cancellables: Set<AnyCancellable> = []

    init(store: RecordingStore,
         llmSettings: LLMSettings,
         liveAISettings: LiveAISettings,
         identity: SpeakerIdentitySettings,
         runLLM: @escaping RunLLM = { call in
             try await LLMRunner.run(
                 tool: call.tool,
                 prompt: call.prompt,
                 transcript: call.transcript,
                 executablePathOverride: call.executablePathOverride,
                 model: call.model,
                 extraArgs: call.extraArgs,
                 timeout: call.timeout,
                 openAIBaseURL: call.openAIBaseURL,
                 openAIAPIKey: call.openAIAPIKey,
                 jsonMode: false,
                 transport: nil,
                 feature: .speakerNames
             )
         }) {
        self.store = store
        self.llmSettings = llmSettings
        self.liveAISettings = liveAISettings
        self.identity = identity
        self.runLLM = runLLM
        // A permanently deleted recording gets no further LLM spend and
        // nothing written back (`bugbot-rules/deleted-data-stays-deleted.md`).
        store.permanentlyDeleted
            .sink { [weak self] ids in
                guard let self else { return }
                for id in ids { self.cancel(recordingID: id) }
            }
            .store(in: &cancellables)
        // A mark only means something until that recording's summary attempt
        // settles, and the summarizer does not signal for a row that was
        // trashed or deleted meanwhile. Drop such marks the moment the row
        // leaves the live list, so a later manual "Regenerate summary" (after
        // a restore, say) cannot consume a stale mark and trigger a call that
        // no fresh completion asked for.
        store.$recordings
            .sink { [weak self] recordings in
                guard let self, !self.pending.isEmpty else { return }
                let live = Set(recordings.lazy.filter { !$0.isTrashed }.map(\.id))
                self.pending.formIntersection(live)
            }
            .store(in: &cancellables)
    }

    // MARK: - Triggers

    /// A recording just completed a transcription pass (or the live path's
    /// finalization). Its suggestions run once its summary attempt settles —
    /// see `suggestIfPending`.
    func markPending(_ recordingID: UUID) {
        pending.insert(recordingID)
    }

    /// The summary attempt for `recording` has settled (generated, skipped or
    /// failed). Runs the suggester if, and only if, this recording was
    /// marked by a fresh completion.
    func suggestIfPending(_ recording: Recording) {
        guard pending.remove(recording.id) != nil else { return }
        suggest(recordingID: recording.id)
    }

    /// Produce suggestions for `recordingID` now: the local-user one
    /// synchronously, the transcript ones via a queued LLM call.
    func suggest(recordingID id: UUID) {
        guard let live = liveRecording(id), Self.isEligible(live) else {
            suggesterLog.log("skipped \(Self.shortID(id), privacy: .public): not a completed, diarized, live recording")
            return
        }
        if let me = Self.localUserSuggestion(for: live, myName: identity.resolvedName) {
            store.mergeSpeakerNameSuggestions([me], recordingID: id)
            suggesterLog.log("\(Self.shortID(id), privacy: .public): suggested the local user for the only voice")
        }
        guard llmSettings.isSpeakerNameSuggestionReady else {
            suggesterLog.log("\(Self.shortID(id), privacy: .public): transcript suggestions off or LLM not configured")
            return
        }
        guard !Self.unnamedSpeakers(in: live).isEmpty else { return }
        if inFlight[id] != nil {
            rerunRequested.insert(id)
            suggesterLog.log("\(Self.shortID(id), privacy: .public): already in flight — re-running after it")
            return
        }
        guard !queue.contains(id) else { return }
        queue.append(id)
        pump()
    }

    /// Drop all work for `recordingID`: pending mark, queue entry, and the
    /// in-flight call (task cancellation is what `LLMRunner` turns into
    /// SIGTERM/SIGKILL for a CLI child).
    func cancel(recordingID: UUID) {
        pending.remove(recordingID)
        rerunRequested.remove(recordingID)
        queue.removeAll { $0 == recordingID }
        if let run = inFlight.removeValue(forKey: recordingID) {
            run.task.cancel()
            cancelledRuns[run.token] = run.task
        }
    }

    /// Test seam: wait until no call is queued, running or unwinding.
    func awaitIdle() async {
        while let task = inFlight.values.first?.task ?? cancelledRuns.values.first {
            await task.value
        }
    }

    // MARK: - Running

    private func pump() {
        while inFlight.count + cancelledRuns.count < maxConcurrent, !queue.isEmpty {
            start(queue.removeFirst())
        }
    }

    private func start(_ id: UUID) {
        // Re-checked at start: the switch may have been turned off, or the
        // row trashed / renamed, while it waited.
        guard llmSettings.isSpeakerNameSuggestionReady,
              let live = liveRecording(id), Self.isEligible(live) else { return }
        let unnamed = Self.unnamedSpeakers(in: live)
        guard !unnamed.isEmpty else { return }

        let tool = llmSettings.tool
        let model = LLMSettings.backgroundModelName(tool: tool,
                                                    openAIModelName: llmSettings.openAIModelName,
                                                    liveAIModel: liveAISettings.model)
        let call = Call(
            tool: tool,
            prompt: Self.prompt(unnamedSpeakers: unnamed),
            transcript: Self.labeledTranscript(for: live),
            executablePathOverride: llmSettings.executablePath.isEmpty ? nil : llmSettings.executablePath,
            model: model.isEmpty ? nil : model,
            extraArgs: llmSettings.extraArgsTokens,
            timeout: llmSettings.cliTimeout,
            openAIBaseURL: llmSettings.openAIBaseURL,
            openAIAPIKey: llmSettings.openAIAPIKey
        )
        let snapshot = Snapshot(live)
        let token = UUID()
        let runLLM = self.runLLM
        suggesterLog.log("started \(Self.shortID(id), privacy: .public) unnamed=\(unnamed.count, privacy: .public)")

        let task = Task { @MainActor [weak self] in
            defer { self?.runEnded(id: id, token: token) }
            let raw: String
            do {
                raw = try await runLLM(call)
            } catch {
                // `logMessage(for:)`, never `localizedDescription`: a CLI's
                // stderr can echo the prompt, i.e. the transcript (#193).
                suggesterLog.error("failed \(SpeakerNameSuggester.shortID(id), privacy: .public): \(LLMRunnerError.logMessage(for: error), privacy: .public)")
                return
            }
            self?.runSucceeded(raw, id: id, token: token, snapshot: snapshot)
        }
        inFlight[id] = (token, task)
    }

    /// Every run's last step, whatever became of it: release this run's own
    /// slot (never a newer run's for the same id) and start the next one.
    private func runEnded(id: UUID, token: UUID) {
        let ownedSlot = inFlight[id]?.token == token
        if ownedSlot { inFlight[id] = nil }
        cancelledRuns[token] = nil
        // A request that arrived while this run was out gets its own run now,
        // built from the row as it is. Not for a cancelled run: `cancel`
        // already cleared the request with everything else.
        if ownedSlot, rerunRequested.remove(id) != nil {
            suggest(recordingID: id)
        }
        pump()
    }

    private func runSucceeded(_ raw: String, id: UUID, token: UUID, snapshot: Snapshot) {
        // Cancelled (permanent delete) while the call was out: nothing is
        // written back for a row the user threw away.
        guard inFlight[id]?.token == token else { return }
        apply(raw, to: id, snapshot: snapshot)
    }

    /// What the completion compares against to tell whether the output still
    /// describes the row: the same text, carried by the same speaker ids.
    /// Names are deliberately not part of it — a name landing meanwhile just
    /// removes that speaker from what is accepted.
    struct Snapshot: Equatable {
        let speakers: [String?]
        let fullText: String
        init(_ recording: Recording) {
            speakers = recording.segments.map(\.speaker)
            fullText = recording.fullText
        }
    }

    private func apply(_ raw: String, to id: UUID, snapshot: Snapshot) {
        guard let live = liveRecording(id), !live.isTrashed else {
            suggesterLog.log("discarded \(Self.shortID(id), privacy: .public): recording gone or trashed")
            return
        }
        // A re-transcription, merge, split or reassign while the call was
        // out means the labels the model answered about may now denote
        // different voices.
        guard Snapshot(live) == snapshot else {
            suggesterLog.log("discarded \(Self.shortID(id), privacy: .public): transcript or speakers changed mid-flight")
            return
        }
        let suggestions = Self.parseSuggestions(from: raw,
                                                unnamedSpeakers: Set(Self.unnamedSpeakers(in: live)),
                                                turns: Self.turns(for: live),
                                                takenNames: Array(live.speakerNames.values))
        let changed = store.mergeSpeakerNameSuggestions(suggestions, recordingID: id)
        // Counts only: names and quotes are user content.
        suggesterLog.log("succeeded \(Self.shortID(id), privacy: .public) output=\(raw.count, privacy: .public)c accepted=\(suggestions.count, privacy: .public) changed=\(changed, privacy: .public)")
    }

    private func liveRecording(_ id: UUID) -> Recording? {
        store.recordings.first(where: { $0.id == id })
    }

    private static func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    // MARK: - Pure helpers (tested directly)

    /// A recording worth asking about: finished, not in the bin, diarized.
    static func isEligible(_ recording: Recording) -> Bool {
        !recording.isTrashed
            && recording.status == .completed
            && recording.segments.contains(where: { ($0.speaker ?? "").isEmpty == false })
    }

    /// Distinct raw speaker ids, in first-appearance order.
    static func distinctSpeakers(in recording: Recording) -> [String] {
        var seen = Set<String>()
        return recording.segments.compactMap(\.speaker)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The speakers that have no name yet, in first-appearance order.
    static func unnamedSpeakers(in recording: Recording) -> [String] {
        distinctSpeakers(in: recording).filter {
            (recording.speakerNames[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        }
    }

    /// Captures that come from the user's own microphone and nothing else.
    /// `.meeting` is NOT here: it mixes the mic with the meeting app's audio
    /// into one mono track, so its diarized speakers carry no trace of which
    /// input they came in on. File imports are `.systemAudio`. (An orphan
    /// WAV recovered at launch is labelled `.microphone` as a best guess;
    /// that is the one imprecision, and it only ever yields a suggestion.)
    static let localUserSources: Set<RecordingSource> = [.microphone, .voiceMemo]

    /// "Your name" for the only voice in a recording from the user's own
    /// microphone, or nil. One voice is the condition because it is the only
    /// case the capture itself settles: with two voices on one mic, nothing
    /// says which is the user's.
    static func localUserSuggestion(for recording: Recording,
                                    myName: String?) -> SpeakerNameSuggestion? {
        guard let name = myName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty,
              localUserSources.contains(recording.source),
              isEligible(recording) else { return nil }
        let speakers = distinctSpeakers(in: recording)
        guard speakers.count == 1, let only = speakers.first,
              unnamedSpeakers(in: recording) == [only] else { return nil }
        return SpeakerNameSuggestion(speaker: only, name: name, evidence: "", origin: .localUser)
    }

    /// The transcript as the model sees it: one turn per line, prefixed with
    /// the speaker's name when the user gave one and with the RAW id
    /// (`SPEAKER_00`) otherwise. Raw ids rather than "Speaker A" because the
    /// answer must name them back unambiguously, in any transcript language.
    static func labeledTranscript(for recording: Recording) -> String {
        TranscriptFormatter.plainText(segments: recording.segments,
                                      fallback: recording.fullText,
                                      names: recording.speakerNames)
    }

    /// One speaker turn: consecutive segments of the same speaker joined, as
    /// `labeledTranscript` renders them. The unit a quote is checked against.
    struct Turn: Equatable {
        let speaker: String?
        let text: String
    }

    /// The recording's turns in order, blank segments skipped. Collapsing
    /// same-speaker segments means a quote that runs over a segment break
    /// inside one person's turn still matches, and that the turn after any
    /// turn is always a DIFFERENT speaker's.
    static func turns(for recording: Recording) -> [Turn] {
        var result: [Turn] = []
        for seg in recording.segments {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = result.last, last.speaker == seg.speaker {
                result[result.count - 1] = Turn(speaker: last.speaker, text: last.text + " " + text)
            } else {
                result.append(Turn(speaker: seg.speaker, text: text))
            }
        }
        return result
    }

    static func prompt(unnamedSpeakers: [String]) -> String {
        """
        You are helping label the speakers of the transcript below. Each line \
        starts with a speaker label and a colon. Speakers the user has already \
        named appear under their name. The still-unnamed speakers appear as: \
        \(unnamedSpeakers.joined(separator: ", ")).

        For each unnamed speaker, report a name ONLY when the transcript states \
        it explicitly:
        - the speaker says their own name ("Hi, my name is Dana", "This is Dana \
        speaking", "Dana here"), or
        - another participant addresses them by name and that speaker is the \
        one who answers immediately after ("Dana, what do you think?" followed \
        by that speaker's reply).

        Never infer a name from roles, topics, tone, who seems to lead, or a \
        name that is merely mentioned. If a speaker's name is not explicitly \
        stated, leave that speaker out — leaving a speaker out is always better \
        than guessing.

        Respond with ONLY this JSON object and nothing else:
        {"speakers": [{"speaker": "SPEAKER_00", "name": "Dana", "quote": "Hi, my name is Dana"}]}

        - "speaker" is one of the unnamed labels above, exactly as written.
        - "name" is the name exactly as it appears in the transcript — do not \
        translate or transliterate it.
        - "quote" is copied verbatim from the transcript, in its original \
        language, and contains the name.
        If no unnamed speaker's name is explicitly stated, respond with {"speakers": []}
        """
    }

    /// Longest name accepted. Real names fit; a sentence the model put in the
    /// name field does not.
    static let maxNameLength = 60
    /// Longest quote kept for display. Longer evidence is still accepted
    /// (it was verified against the transcript first) and stored truncated.
    static let maxStoredQuoteLength = 280

    /// Turn the model's output into suggestions, keeping only what is backed
    /// by explicit evidence. Never throws, never returns a partial entry:
    /// anything malformed is dropped on its own without costing the rest.
    ///
    /// An entry survives only if:
    ///  * `speaker` is one of `unnamedSpeakers` (a named speaker, an invented
    ///    label or a friendly "Speaker A" is dropped);
    ///  * `name` is a plausible name — non-empty, one line, at most
    ///    `maxNameLength`, not a placeholder ("Unknown", "Speaker B", …) —
    ///    and not already the name of another speaker here (`takenNames`);
    ///  * `quote` is at least two words, STATES the name as a whole word
    ///    (`quoteStatesName`), and is evidence about THIS speaker
    ///    (`quoteIsEvidence`): it occurs in one of the speaker's own turns
    ///    ("I'm Dana"), or in the turn immediately before one of theirs
    ///    ("Dana, what do you think?" — then they answer). A quote that is
    ///    merely somewhere in the transcript proves nothing about who it
    ///    names.
    /// Then ambiguity is resolved by dropping: a speaker given two different
    /// names, or one name given to two speakers, keeps neither.
    static func parseSuggestions(from raw: String,
                                 unnamedSpeakers: Set<String>,
                                 turns: [Turn],
                                 takenNames: [String] = []) -> [SpeakerNameSuggestion] {
        guard let entries = wireEntries(in: raw), !entries.isEmpty else { return [] }
        let normalizedTurns = turns.map { (speaker: $0.speaker, text: normalizedForMatching($0.text)) }
        guard normalizedTurns.contains(where: { !$0.text.isEmpty }) else { return [] }
        // Upper-cased lookup so "speaker_01" still resolves to the raw id.
        let byUpper = Dictionary(unnamedSpeakers.map { ($0.uppercased(), $0) },
                                 uniquingKeysWith: { first, _ in first })
        func key(_ name: String) -> String { normalizedForMatching(name) }
        let taken = Set(takenNames.map(key).filter { !$0.isEmpty })

        var candidates: [SpeakerNameSuggestion] = []
        for entry in entries {
            guard let rawSpeaker = entry.speaker?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let speaker = byUpper[rawSpeaker.uppercased()],
                  let name = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  isPlausibleName(name),
                  !taken.contains(key(name)),
                  let quote = entry.quote?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !quote.isEmpty
            else { continue }
            let normalizedQuote = normalizedForMatching(quote)
            // One word is at most the bare name — that names nobody.
            guard normalizedQuote.split(separator: " ").count >= 2,
                  quoteStatesName(normalizedQuote: normalizedQuote, name: name),
                  quoteIsEvidence(normalizedQuote: normalizedQuote, for: speaker,
                                  turns: normalizedTurns)
            else { continue }
            let stored = quote.count > maxStoredQuoteLength
                ? String(quote.prefix(maxStoredQuoteLength)) + "…"
                : quote
            candidates.append(SpeakerNameSuggestion(speaker: speaker, name: name,
                                                    evidence: stored, origin: .transcript))
        }

        // Ambiguity → drop. Compare names case-insensitively so "Dana" twice
        // for one speaker (two quotes) is one answer, not a conflict.
        var namesBySpeaker: [String: Set<String>] = [:]
        var speakersByName: [String: Set<String>] = [:]
        for c in candidates {
            namesBySpeaker[c.speaker, default: []].insert(key(c.name))
            speakersByName[key(c.name), default: []].insert(c.speaker)
        }
        var seenSpeakers = Set<String>()
        return candidates.filter { c in
            guard namesBySpeaker[c.speaker]?.count == 1,
                  speakersByName[key(c.name)]?.count == 1 else { return false }
            // First quote per speaker wins.
            return seenSpeakers.insert(c.speaker).inserted
        }
    }

    /// Whether `normalizedQuote` is evidence about `speaker`: it occurs, as
    /// whole words, in one of the speaker's own turns, or in the turn right
    /// before one of the speaker's turns (they were addressed, then answered).
    /// `turns` must already be collapsed, so the next turn is always another
    /// speaker's.
    static func quoteIsEvidence(normalizedQuote: String,
                                for speaker: String,
                                turns: [(speaker: String?, text: String)]) -> Bool {
        let needle = " \(normalizedQuote) "
        for (i, turn) in turns.enumerated() where " \(turn.text) ".contains(needle) {
            if turn.speaker == speaker { return true }
            if i + 1 < turns.count, turns[i + 1].speaker == speaker { return true }
        }
        return false
    }

    /// Placeholders a model writes when told not to guess, plus anything
    /// that is just a diarizer label again.
    private static let placeholderNames: Set<String> = [
        "unknown", "unnamed", "n a", "na", "none", "null", "nil", "anonymous",
        "speaker", "me", "you", "i", "host", "moderator", "interviewer",
        "interviewee", "participant", "user", "narrator",
    ]

    static func isPlausibleName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= maxNameLength,
              name.rangeOfCharacter(from: .newlines) == nil else { return false }
        let normalized = normalizedForMatching(name)
        guard !normalized.isEmpty, !placeholderNames.contains(normalized) else { return false }
        // "SPEAKER_01", "Speaker B", "דובר א׳" — a label, not a name.
        if normalized.hasPrefix("speaker ") || normalized.hasPrefix("speaker_")
            || normalized.hasPrefix("דובר") {
            return false
        }
        return true
    }

    /// Whether the (normalized) quote states the name: the whole name, or
    /// one of its words of two or more letters ("Dana" in "Dana Cohen"), as a
    /// WHOLE WORD — "Ed" must not match "edited". Word boundaries come from
    /// `normalizedForMatching`, which splits on every non-alphanumeric
    /// Unicode scalar, so this holds for Hebrew as for Latin script. (A
    /// Hebrew prefix letter glued to the name, "לדנה", therefore does not
    /// count; a quote that states the name plainly is required.)
    static func quoteStatesName(normalizedQuote: String, name: String) -> Bool {
        let normalizedName = normalizedForMatching(name)
        guard !normalizedName.isEmpty else { return false }
        let haystack = " \(normalizedQuote) "
        if haystack.contains(" \(normalizedName) ") { return true }
        return normalizedName.split(separator: " ")
            .contains { $0.count >= 2 && haystack.contains(" \($0) ") }
    }

    /// Lower-cased, diacritics folded, every run of non-alphanumerics
    /// collapsed to one space, trimmed. Used ONLY to compare a quote against
    /// the transcript — never stored or shown.
    nonisolated static func normalizedForMatching(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                  locale: nil)
        var out = ""
        out.reserveCapacity(folded.count)
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingSpace = true
            }
        }
        return out
    }

    /// One entry as the model wrote it. Every field optional and decoded
    /// leniently, so a wrong-typed field (a number, a null) drops that entry
    /// in `parseSuggestions` instead of failing the whole array.
    struct WireEntry: Decodable {
        let speaker: String?
        let name: String?
        let quote: String?

        private enum CodingKeys: String, CodingKey {
            case speaker, name, quote, evidence
        }

        init(from decoder: Decoder) throws {
            guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
                speaker = nil; name = nil; quote = nil
                return
            }
            speaker = try? c.decode(String.self, forKey: .speaker)
            name = try? c.decode(String.self, forKey: .name)
            quote = (try? c.decode(String.self, forKey: .quote))
                ?? (try? c.decode(String.self, forKey: .evidence))
        }
    }

    private struct Envelope: Decodable {
        let speakers: [WireEntry]?
    }

    /// The entries in the model's output: the `{"speakers": [...]}` object
    /// the prompt asks for, or — tolerated — a bare array, with or without
    /// ```json fences or a lead-in line (the balanced-block extractor skips
    /// both). Nil when there is no readable JSON at all.
    static func wireEntries(in raw: String) -> [WireEntry]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = LiveAISession.findFirstJSONStructure(in: trimmed, opening: "{", closing: "}"),
           let data = String(trimmed[range]).data(using: .utf8),
           let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
           let speakers = envelope.speakers {
            return speakers
        }
        if let range = LiveAISession.findFirstJSONArray(in: trimmed),
           let data = String(trimmed[range]).data(using: .utf8),
           let entries = try? JSONDecoder().decode([WireEntry].self, from: data) {
            return entries
        }
        return nil
    }
}
