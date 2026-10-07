import Foundation

/// What the receiver's import sheet shows for the voice profiles inside a
/// `.milashare`, and what the user decided for each — produced by
/// `SpeakerProfileImportResolver`, edited by `SharedSpeakersImportSection`,
/// consumed by `SpeakerProfileImportApplier`.
///
/// **Invariant: every row can be merged into ANY existing local profile or
/// added as a new one, whatever the resolver suggested.** The suggestion only
/// sets the initial `target`; `candidates` always lists every local profile
/// the vector could be folded into, so the menu is the manual pick for a
/// speaker that matched nothing, the override for one that did, and the way
/// back for one marked "already imported". Only a `blocker` removes the menu,
/// and only where a merge is physically impossible.
struct SpeakerProfileImportPlan: Equatable {

    enum Target: Equatable, Hashable {
        /// Fold the incoming vector into the local profile with this id —
        /// `SpeakerProfileStore.updateProfile`'s weighted mean.
        case merge(into: UUID)
        /// Create a new local profile under this name.
        case addAsNew(name: String)
        /// Write nothing; the transcript keeps the sender's label as text.
        case skip
    }

    /// A local profile the incoming vector could be merged into.
    struct Candidate: Identifiable, Equatable {
        let profile: VoiceProfile
        /// Cosine similarity between the incoming centroid and this one.
        let similarity: Double
        /// Case-insensitive name equality with the incoming profile.
        let nameMatches: Bool
        var id: UUID { profile.id }

        /// `similarity` as a whole-number percentage for display.
        var percent: Int { Int((similarity * 100).rounded()) }
    }

    /// Why a row cannot be imported at all. Each of these makes BOTH merge
    /// and add impossible — a row with a blocker has no menu.
    enum Blocker: Equatable {
        /// `VoiceRecognitionSettings.isEnabled == false`: the store refuses
        /// every write, so there is nothing a choice could do.
        case voiceRecognitionOff
        /// Enabled, but diarization isn't ready — `updateProfile`'s
        /// `isConfigured` gate is closed.
        case voiceRecognitionNotReady
        /// A model this build doesn't know; its vectors can't be compared
        /// with anything local.
        case unknownEmbeddingModel(String)
        /// Known model, wrong width — the file is inconsistent with itself.
        case dimensionMismatch(found: Int, expected: Int)
        /// Fails `VoiceProfile.unusableReason` (empty name, bad count, …).
        case invalidProfile(String)

        var message: String {
            switch self {
            case .voiceRecognitionOff:
                return "Turn on Voice recognition in Settings → Speakers to import voice profiles. The recording and its speaker names import either way."
            case .voiceRecognitionNotReady:
                return "Voice recognition is waiting on speaker diarization — set that up in Settings → Speakers to import voice profiles."
            case .unknownEmbeddingModel:
                return "Made with a voice model this version of Mila doesn't recognise."
            case .dimensionMismatch:
                return "This voice profile is malformed and can't be used."
            case .invalidProfile:
                return "This voice profile is malformed and can't be used."
            }
        }
    }

    struct Row: Identifiable, Equatable {
        /// Rows are unique by incoming name — the resolver dedupes.
        var id: String { incoming.name }
        let incoming: SharedSpeakerProfile
        /// Raw `SPEAKER_NN` ids on the shared recording carrying this name.
        let rawIDs: [String]
        /// Every local profile this could merge into, best match first.
        let candidates: [Candidate]
        /// What the resolver picked, and why, in the user's words.
        let suggested: Target
        let suggestionReason: String
        /// True when the suggestion deserves a second look — a merge
        /// suggested on name alone, with the voice below the threshold.
        let suggestionWarns: Bool
        /// A collision-free name for "add as new" — the sender's name when
        /// it is free locally, otherwise "Alex (from Daniel)".
        let suggestedNewName: String
        /// Non-nil ⇒ nothing can be imported for this row (menu hidden).
        let blocker: Blocker?
        /// This bundle's copy of this speaker was folded in before. Defaults
        /// the row to `.skip` but leaves the menu enabled.
        let alreadyImported: Bool
        /// What will happen on Import. Starts equal to `suggested`.
        var target: Target

        var isBlocked: Bool { blocker != nil }

        /// The candidate `target` currently points at, if it is a merge.
        var selectedCandidate: Candidate? {
            guard case .merge(let id) = target else { return nil }
            return candidates.first { $0.id == id }
        }
    }

    var rows: [Row]
    /// `ShareManifest.bundleID` as a string — the idempotency key.
    let bundleKey: String
    /// The threshold the suggestions were made with, so the sheet can flag
    /// a manually picked candidate that sits below it.
    let similarityThreshold: Double

    var isEmpty: Bool { rows.isEmpty }
    static let empty = SpeakerProfileImportPlan(rows: [], bundleKey: "", similarityThreshold: 0.55)
}

/// Pure: values in, plan out. Takes no live objects so it can be tested
/// without a store or a settings suite.
enum SpeakerProfileImportResolver {

    struct Context {
        var localProfiles: [VoiceProfile]
        var isEnabled: Bool
        var isConfigured: Bool
        /// The user's own slider (`LiveAISettings.speakerSimilarityThreshold`),
        /// not a constant — someone who tightened it after false matches
        /// should get the tighter threshold here too.
        var similarityThreshold: Double
        /// `ShareManifest.exportedBy.name`, for the "(from Daniel)" rename.
        var senderDisplayName: String?
        /// `SpeakerProfileStore.importedShareTokens`.
        var alreadyImported: Set<ImportedShareToken>
    }

    static func resolve(incoming: [SharedSpeakerProfile],
                        speakerNames: [String: String],
                        bundleKey: String,
                        context: Context) -> SpeakerProfileImportPlan {
        // One row per distinct incoming name, in a stable order. A bundle
        // with two entries for the same name is malformed; the first wins.
        var seen = Set<String>()
        let distinct: [SharedSpeakerProfile] = incoming.compactMap { profile in
            var trimmed = profile
            trimmed.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return seen.insert(trimmed.name).inserted ? trimmed : nil
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        var takenNewNames = Set<String>()
        let rows = distinct.map { profile -> SpeakerProfileImportPlan.Row in
            let blocker = blocker(for: profile, context: context)
            let token = ImportedShareToken(bundleKey: bundleKey, sharedName: profile.name)
            let alreadyImported = context.alreadyImported.contains(token)
            let candidates = candidates(for: profile, context: context)
            let newName = suggestedNewName(for: profile.name,
                                           sender: context.senderDisplayName,
                                           localNames: Set(context.localProfiles.map(\.name)),
                                           taken: takenNewNames)
            takenNewNames.insert(newName)
            let (suggested, reason, warns) = suggestion(for: profile,
                                                        candidates: candidates,
                                                        blocker: blocker,
                                                        alreadyImported: alreadyImported,
                                                        newName: newName,
                                                        threshold: context.similarityThreshold)
            let rawIDs = speakerNames
                .filter { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) == profile.name }
                .map(\.key)
                .sorted()
            return SpeakerProfileImportPlan.Row(
                incoming: profile,
                rawIDs: rawIDs,
                candidates: candidates,
                suggested: suggested,
                suggestionReason: reason,
                suggestionWarns: warns,
                suggestedNewName: newName,
                blocker: blocker,
                alreadyImported: alreadyImported,
                target: suggested)
        }
        return SpeakerProfileImportPlan(rows: rows, bundleKey: bundleKey,
                                        similarityThreshold: context.similarityThreshold)
    }

    // MARK: - Pieces

    private static func blocker(for profile: SharedSpeakerProfile,
                                context: Context) -> SpeakerProfileImportPlan.Blocker? {
        guard context.isEnabled else { return .voiceRecognitionOff }
        guard context.isConfigured else { return .voiceRecognitionNotReady }
        guard let model = SpeakerEmbeddingModel.known(id: profile.embeddingModel) else {
            return .unknownEmbeddingModel(profile.embeddingModel)
        }
        guard profile.embedding.count == model.dimension else {
            return .dimensionMismatch(found: profile.embedding.count, expected: model.dimension)
        }
        // The same invariants the store enforces on the way in — checked
        // here so the sheet can say "malformed" instead of the apply step
        // silently refusing.
        let probe = VoiceProfile(id: UUID(), name: profile.name, embedding: profile.embedding,
                                 sampleCount: profile.sampleCount, createdAt: Date(), lastSeenAt: Date())
        if let reason = probe.unusableReason { return .invalidProfile(reason) }
        return nil
    }

    /// Every local profile the vector could be folded into — same width and
    /// same model — scored and sorted best first.
    private static func candidates(for profile: SharedSpeakerProfile,
                                   context: Context) -> [SpeakerProfileImportPlan.Candidate] {
        context.localProfiles
            .filter {
                $0.embedding.count == profile.embedding.count
                    && $0.effectiveEmbeddingModel == profile.embeddingModel
            }
            .map {
                SpeakerProfileImportPlan.Candidate(
                    profile: $0,
                    similarity: cosineSimilarity(profile.embedding, $0.embedding),
                    nameMatches: $0.name.caseInsensitiveCompare(profile.name) == .orderedSame)
            }
            .sorted {
                if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
                return $0.profile.name.localizedCaseInsensitiveCompare($1.profile.name) == .orderedAscending
            }
    }

    /// Voice first: the best candidate above the user's threshold is the
    /// person, whatever either side calls them. A same-name profile whose
    /// voice scores low is still suggested — it is most likely the same
    /// person recorded differently — but flagged, so the user looks twice.
    private static func suggestion(for profile: SharedSpeakerProfile,
                                   candidates: [SpeakerProfileImportPlan.Candidate],
                                   blocker: SpeakerProfileImportPlan.Blocker?,
                                   alreadyImported: Bool,
                                   newName: String,
                                   threshold: Double) -> (SpeakerProfileImportPlan.Target, String, Bool) {
        if let blocker { return (.skip, blocker.message, false) }
        if alreadyImported { return (.skip, "Already imported from this file.", false) }
        if let best = candidates.first, best.similarity >= threshold {
            return (.merge(into: best.id),
                    "Sounds like your “\(best.profile.name)” (\(best.percent)% match).",
                    false)
        }
        if let named = candidates.first(where: \.nameMatches) {
            return (.merge(into: named.id),
                    "Same name as your “\(named.profile.name)”, but the voice only matches \(named.percent)%.",
                    true)
        }
        return (.addAsNew(name: newName), "No close match among your voice profiles.", false)
    }

    /// The sender's name if nobody local has it; otherwise
    /// "Alex (from Daniel)" / "Alex (shared)", de-collided with " 2", " 3"…
    /// against local names and the other rows' new names.
    static func suggestedNewName(for name: String,
                                 sender: String?,
                                 localNames: Set<String>,
                                 taken: Set<String>) -> String {
        let lowerLocal = Set(localNames.map { $0.lowercased() })
        let lowerTaken = Set(taken.map { $0.lowercased() })
        func isFree(_ candidate: String) -> Bool {
            let l = candidate.lowercased()
            return !lowerLocal.contains(l) && !lowerTaken.contains(l)
        }
        if isFree(name) { return name }

        let senderWord = sender?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init) ?? ""
        let base = senderWord.isEmpty ? "\(name) (shared)" : "\(name) (from \(senderWord))"
        if isFree(base) { return base }
        var n = 2
        while !isFree("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}
