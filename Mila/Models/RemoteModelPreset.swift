import Foundation

/// One entry in the remote-transcription model picker: a model id Mila is
/// known to be able to *talk to*, together with the endpoint it belongs to.
///
/// The picker exists because the Model field used to be plain free text whose
/// only guidance was a placeholder, and most of OpenAI's transcription models
/// answer a request Mila can't form with an opaque HTTP 400. Naming the ones
/// that work turns "type a model id and find out" into a choice (issue #178).
///
/// **Every preset must be reachable by `RemoteWhisperEngine`.** That is not a
/// convention to remember: `timestamps` is read off
/// `RemoteWhisperEngine.ResponseFormat.forModel(id)`, so a preset is described
/// by the same code that decides what to send for it. There is no second
/// model→format table to drift out of step with the first.
struct RemoteModelPreset: Identifiable, Hashable, Sendable {

    /// Where the model runs — the picker's section headers.
    enum Group: String, CaseIterable, Sendable {
        /// OpenAI's hosted API. Fixed endpoint, key required.
        case openAI
        /// A server the user runs (`speaches`, faster-whisper, vLLM, …).
        case selfHosted

        var displayName: String {
            switch self {
            case .openAI:     return "OpenAI hosted"
            case .selfHosted: return "Self-hosted (speaches / faster-whisper)"
            }
        }
    }

    /// The model id sent as the multipart `model` field. Doubles as the
    /// identity, since a picker never needs two rows for one id.
    let id: String
    /// Short label for the picker row.
    let displayName: String
    let group: Group
    /// The endpoint this model lives behind, when there is a canonical one.
    ///
    /// Applied by `RemoteTranscriptionSettings.apply(_:)` only when the
    /// endpoint currently configured is another preset's canonical endpoint (or
    /// unusable) — a URL the user typed themselves is never overwritten, since
    /// a private gateway can proxy any of these models.
    let endpoint: String
    /// One line under the picker explaining what this choice is for.
    let detail: String

    /// What timings a transcript from this model will carry. Derived, never
    /// declared: see the type's note.
    var timestamps: RemoteWhisperEngine.ResponseFormat.TimestampSupport {
        RemoteWhisperEngine.ResponseFormat.forModel(id).timestamps
    }

    /// The endpoints presets own, and may therefore replace when the user
    /// switches groups. Anything else is the user's and is left alone.
    static var canonicalEndpoints: Set<String> {
        Set(all.map { Self.normalizeEndpoint($0.endpoint) })
    }

    /// Compare endpoints ignoring case and a trailing slash, so
    /// `https://API.openai.com/v1/` counts as the OpenAI endpoint.
    static func normalizeEndpoint(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// The endpoint the docs' self-hosted quickstart uses
    /// (`docs/REMOTE_TRANSCRIPTION_SERVER.md`, Option A).
    static let selfHostedEndpoint = "http://localhost:8000/v1"

    /// Every configuration Mila is known to work with.
    ///
    /// The OpenAI half is the full transcription line-up as of 2026-08, all of
    /// which `RemoteWhisperEngine` can now reach — `whisper-1` via
    /// `verbose_json`, the `gpt-*` family via `json`, and the diarizing variant
    /// via `diarized_json` (issue #180 / PR #189). Before that the engine
    /// hardcoded `verbose_json` and only `whisper-1` worked, which is why this
    /// list could not have been offered earlier.
    static let all: [RemoteModelPreset] = [
        RemoteModelPreset(
            id: RemoteTranscriptionSettings.defaultModel, // "whisper-1"
            displayName: "whisper-1",
            group: .openAI,
            endpoint: RemoteTranscriptionSettings.defaultEndpoint,
            detail: "Multilingual, with per-segment timings. The safe default — SRT export and local speaker labels both work."),
        RemoteModelPreset(
            id: "gpt-transcribe",
            displayName: "gpt-transcribe",
            group: .openAI,
            endpoint: RemoteTranscriptionSettings.defaultEndpoint,
            detail: "OpenAI's current general-purpose transcriber. Usually more accurate text than whisper-1."),
        RemoteModelPreset(
            id: "gpt-4o-transcribe",
            displayName: "gpt-4o-transcribe",
            group: .openAI,
            endpoint: RemoteTranscriptionSettings.defaultEndpoint,
            detail: "GPT-4o audio transcription."),
        RemoteModelPreset(
            id: "gpt-4o-mini-transcribe",
            displayName: "gpt-4o-mini-transcribe",
            group: .openAI,
            endpoint: RemoteTranscriptionSettings.defaultEndpoint,
            detail: "Cheaper and faster than gpt-4o-transcribe, slightly less accurate."),
        RemoteModelPreset(
            id: "gpt-4o-transcribe-diarize",
            displayName: "gpt-4o-transcribe-diarize",
            group: .openAI,
            endpoint: RemoteTranscriptionSettings.defaultEndpoint,
            detail: "Labels speakers itself, per turn. Mila keeps its labels and skips the local diarization pass."),
        RemoteModelPreset(
            id: "ivrit-ai/whisper-large-v3-turbo-ct2",
            displayName: "ivrit.ai large-v3-turbo (Hebrew)",
            group: .selfHosted,
            endpoint: RemoteModelPreset.selfHostedEndpoint,
            detail: "Hebrew-only finetune. Mila fills in a multilingual English model below, because this one renders English speech with Hebrew words."),
        RemoteModelPreset(
            id: RemoteTranscriptionSettings.defaultEnglishModel, // deepdml/…-turbo-ct2
            displayName: "faster-whisper large-v3-turbo (multilingual)",
            group: .selfHosted,
            endpoint: RemoteModelPreset.selfHostedEndpoint,
            detail: "Multilingual CTranslate2 build of Whisper large-v3-turbo, with per-segment timings."),
    ]

    /// The preset naming `modelID`, or `nil` for a model id Mila has no entry
    /// for — which the picker renders as *Custom…* rather than silently
    /// snapping the user's value to something nearby.
    ///
    /// Exact match on the trimmed, lowercased id. Deliberately not the tolerant
    /// substring style of `isHebrewOnlyModel(_:)`: this decides whether to
    /// *describe* a model to the user, and describing a near-miss id with a
    /// preset's guarantees would be a lie. `ResponseFormat.forModel(_:)`
    /// remains tolerant, so a near-miss still gets the right wire format.
    static func matching(_ modelID: String) -> RemoteModelPreset? {
        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty else { return nil }
        return all.first { $0.id.lowercased() == id }
    }

    static func presets(in group: Group) -> [RemoteModelPreset] {
        all.filter { $0.group == group }
    }
}

extension RemoteWhisperEngine.ResponseFormat.TimestampSupport {
    /// Whether a recording transcribed this way arrives as one untimed blob —
    /// the tradeoff the picker has to surface, because losing per-segment
    /// timings silently costs SRT timings *and* speaker assignment.
    var isUntimed: Bool { self == .none }
}
