import Foundation
import TranscriptionCore

/// A proposed name for one still-unnamed diarized speaker on a recording,
/// waiting for the user to accept or dismiss it (issue #348).
///
/// **A suggestion, never a name.** Nothing here is written into
/// `Recording.speakerNames` until the user clicks Accept, and accepting goes
/// through `RecordingStore.setSpeakerName` like any typed rename. That is the
/// whole design: naming a speaker folds its voice into a voice profile
/// (`RecordingStore.onSpeakerNamed`), and that profile then auto-names the
/// same voice in every future recording. A wrong guess written straight in
/// would be learned and spread; a wrong suggestion costs one click to dismiss.
///
/// Persisted on the row (`Recording.speakerNameSuggestions`) so a suggestion
/// produced after a recording survives a relaunch. Deliberately NOT mirrored
/// to MilaKit's `StoredRecording` and NOT carried in a `.milashare`: both
/// surfaces expose confirmed names, and an unconfirmed model guess presented
/// there would read as a fact.
struct SpeakerNameSuggestion: Codable, Hashable, Identifiable {

    /// Where the suggestion came from — decides how the UI explains it.
    enum Origin: String, Codable, Hashable {
        /// The LLM found the name stated in the transcript; `evidence` is
        /// the quote it pointed at, verified to occur in the transcript.
        case transcript
        /// "Your name" from Settings → Speakers, offered for the one voice
        /// in a recording captured from the user's own microphone. See
        /// `SpeakerNameSuggester.localUserSuggestion`.
        case localUser
    }

    /// Raw diarizer id (`SPEAKER_00`) the name is proposed for.
    var speaker: String
    /// The proposed display name.
    var name: String
    /// For `.transcript`: the transcript words that state the name. Empty
    /// for `.localUser`, whose reason the UI states itself.
    var evidence: String
    var origin: Origin

    /// One suggestion per speaker, so the raw id is a stable identity.
    var id: String { speaker }

    init(speaker: String, name: String, evidence: String, origin: Origin) {
        self.speaker = speaker
        self.name = name
        self.evidence = evidence
        self.origin = origin
    }

    private enum CodingKeys: String, CodingKey {
        case speaker, name, evidence, origin
    }

    /// Lenient on purpose: `recordings.json` loads all-or-nothing, and this
    /// type may be read by a build older or newer than the one that wrote
    /// it. An origin this build does not know reads as `.transcript` (the
    /// more cautious explanation — it shows its evidence) rather than
    /// failing the row. `Recording.init(from:)` additionally decodes the
    /// whole list with `try?`, so a malformed list costs only the
    /// suggestions, never the library.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.speaker = try c.decode(String.self, forKey: .speaker)
        self.name = try c.decode(String.self, forKey: .name)
        self.evidence = (try? c.decodeIfPresent(String.self, forKey: .evidence)) ?? ""
        let rawOrigin = (try? c.decodeIfPresent(String.self, forKey: .origin)) ?? nil
        self.origin = rawOrigin.flatMap(Origin.init(rawValue:)) ?? .transcript
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(speaker, forKey: .speaker)
        try c.encode(name, forKey: .name)
        try c.encode(evidence, forKey: .evidence)
        try c.encode(origin, forKey: .origin)
    }
}

extension Recording {
    /// Whether a name suggestion for `rawID` can still be acted on: the
    /// speaker still has lines in the transcript and has not been named since
    /// (by the user, by voice recognition, or by accepting). A merge, a split
    /// or a reassign can empty a speaker out, and a name can arrive from
    /// another path at any time. The one definition of the rule — both the UI
    /// filter below and `RecordingStore.mergeSpeakerNameSuggestions` use it.
    func acceptsSpeakerNameSuggestion(for rawID: String) -> Bool {
        let assigned = speakerNames[rawID]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return assigned.isEmpty && segments.contains { $0.speaker == rawID }
    }

    /// The stored suggestions that still hold after a transcript edit
    /// removed lines (`RecordingStore.applyTranscriptEdit`): the speaker has
    /// lines left, and a transcript suggestion's quote is still in the
    /// transcript. The quote is matched as plain text after normalizing (it
    /// may have been stored truncated), which can only keep too little, never
    /// a quote from a removed line that appears nowhere else.
    var speakerNameSuggestionsSurvivingEdit: [SpeakerNameSuggestion] {
        guard !speakerNameSuggestions.isEmpty else { return [] }
        let present = Set(segments.compactMap(\.speaker))
        let remaining = SpeakerNameSuggester.normalizedForMatching(
            segments.map(\.text).joined(separator: " "))
        return speakerNameSuggestions.filter { suggestion in
            guard present.contains(suggestion.speaker) else { return false }
            guard suggestion.origin == .transcript else { return true }
            let quote = SpeakerNameSuggester.normalizedForMatching(suggestion.evidence)
            return !quote.isEmpty && remaining.contains(quote)
        }
    }

    /// The suggestions that can still be acted on — re-derived on every read
    /// rather than trusted from the stored list.
    var actionableSpeakerNameSuggestions: [SpeakerNameSuggestion] {
        speakerNameSuggestions.filter { acceptsSpeakerNameSuggestion(for: $0.speaker) }
    }
}
