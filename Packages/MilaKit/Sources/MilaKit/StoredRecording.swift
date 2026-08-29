import Foundation

/// Read-only mirror of one entry in the app's `recordings.json`.
///
/// The app's `Recording` type stays in the app target (its init is
/// referenced across dozens of files); this mirror exists so the external
/// mila-mcp helper can decode the store without linking app code. Every
/// field the app encodes must decode here — guarded by
/// `StoredRecordingDriftTests` in MilaTests, which encodes a fully
/// populated app `Recording` and asserts this type round-trips it —
/// **including the nested `segments` and `actionItems` element types**,
/// which encode as objects and so are invisible to a top-level key-set
/// comparison. Decoding is deliberately lenient (`decodeIfPresent` +
/// defaults) so an older helper never chokes on a newer app's additions.
public struct StoredRecording: Codable, Identifiable, Sendable {
    /// The app's `TranscriptSegment` also persists an `id` UUID. It is
    /// deliberately NOT mirrored: it is minted by `TranscriptSegment`'s
    /// default initializer purely to give SwiftUI lists a stable identity,
    /// it is regenerated wholesale by a re-transcription, and no MCP tool
    /// accepts a segment id. Mirroring it would advertise an addressability
    /// the app does not offer. Recorded in `StoredRecordingDriftTests`'
    /// nested allowlist so the tripwire stays armed for every OTHER field.
    public struct Segment: Codable, Equatable, Sendable, SpeakerTextSegment {
        public var start: Double
        public var end: Double
        public var text: String
        public var speaker: String?

        public init(start: Double, end: Double, text: String, speaker: String? = nil) {
            self.start = start
            self.end = end
            self.text = text
            self.speaker = speaker
        }

        private enum CodingKeys: String, CodingKey { case start, end, text, speaker }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
            end = try c.decodeIfPresent(Double.self, forKey: .end) ?? 0
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            speaker = try c.decodeIfPresent(String.self, forKey: .speaker)
        }
    }

    public struct ActionItem: Codable, Sendable {
        /// The app's `ActionItem.id` — chosen by the LLM and stable across
        /// Live-AI ticks so the app can dedupe. Mirrored because the app
        /// persists it, **not** as a client-facing handle: it is unique
        /// only within one recording's list (the model happily emits "1",
        /// "2"), so no tool takes it as an argument.
        public var id: String
        public var text: String
        public var speaker: String?
        public var timestampSeconds: Double?
        /// Raw value of the app's `ActionItem.Source`: `voice_command` when
        /// the speaker dictated the item out loud, `inferred` when the model
        /// derived it from the conversation. Kept as a string so a future
        /// case added by the app doesn't fail the decode.
        ///
        /// This is the field whose absence actually cost something: without
        /// it every item read over MCP looked equally authoritative, and a
        /// client answering "what did I commit to?" could not tell a
        /// spoken commitment from a model's guess.
        public var source: String
        /// When the item first appeared in the app's Live-AI list. Wall
        /// clock, not an offset into the recording — `timestampSeconds` is
        /// the in-recording position. Mirrored for completeness; the tool
        /// surface exposes the offset, which is what a client can act on.
        public var addedAt: Date?

        public init(id: String = "", text: String, speaker: String? = nil,
                    timestampSeconds: Double? = nil, source: String = "",
                    addedAt: Date? = nil) {
            self.id = id
            self.text = text
            self.speaker = speaker
            self.timestampSeconds = timestampSeconds
            self.source = source
            self.addedAt = addedAt
        }

        private enum CodingKeys: String, CodingKey {
            case id, text, speaker, timestampSeconds, source, addedAt
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            speaker = try c.decodeIfPresent(String.self, forKey: .speaker)
            timestampSeconds = try c.decodeIfPresent(Double.self, forKey: .timestampSeconds)
            source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
            addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt)
        }
    }

    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var duration: Double
    /// Raw value of the app's `RecordingSource` (`microphone` /
    /// `systemAudio` / `meeting` / `voiceMemo`). Kept as a string so a
    /// future source added by the app doesn't fail the decode.
    public var source: String
    public var audioFileName: String
    /// Raw value of the app's `TranscriptionStatus` (`pending` / `running`
    /// / `completed` / `failed`).
    public var status: String
    public var language: String
    public var modelName: String?
    public var segments: [Segment]
    public var deletedAt: Date?
    public var folder: String?
    public var appName: String?
    /// The captured app's bundle identifier (`us.zoom.xxx`), recorded
    /// alongside `appName`. Mirrored because it is the AUTHORITATIVE app
    /// signal: `appName` is a localized display string, this one is stable
    /// and machine-matchable. Exposing only the display name would give an
    /// MCP client the fuzzy half and withhold the exact half.
    public var appBundleID: String?
    public var summary: String?
    public var actionItems: [ActionItem]?
    /// Raw diarizer ID (`SPEAKER_00`) → user-assigned display name.
    public var speakerNames: [String: String]
    /// Inline transcript on legacy records only; current records keep the
    /// text in the `.txt` sidecar and omit this key.
    public var legacyFullText: String?

    public var isTrashed: Bool { deletedAt != nil }

    /// Sidecar names, derived from `audioFileName` the same way the app does.
    public var transcriptFileName: String {
        (audioFileName as NSString).deletingPathExtension + ".txt"
    }
    public var summaryFileName: String {
        (audioFileName as NSString).deletingPathExtension + ".summary.txt"
    }

    /// Display names of this recording's diarized speakers (raw IDs
    /// resolved through `speakerNames`; unnamed IDs stay raw), in
    /// first-spoken order.
    public var speakerDisplayNames: [String] {
        var seen = Set<String>()
        var names: [String] = []
        for seg in segments {
            guard let raw = seg.speaker else { continue }
            let resolved = speakerNames[raw] ?? raw
            if seen.insert(resolved).inserted { names.append(resolved) }
        }
        return names
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, duration, source, audioFileName,
             status, language, modelName, segments, deletedAt, folder, appName,
             summary, actionItems, speakerNames, appBundleID
        case legacyFullText = "fullText"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        audioFileName = try c.decodeIfPresent(String.self, forKey: .audioFileName) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? ""
        modelName = try c.decodeIfPresent(String.self, forKey: .modelName)
        segments = try c.decodeIfPresent([Segment].self, forKey: .segments) ?? []
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
        appName = try c.decodeIfPresent(String.self, forKey: .appName)
        appBundleID = try c.decodeIfPresent(String.self, forKey: .appBundleID)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        actionItems = try c.decodeIfPresent([ActionItem].self, forKey: .actionItems)
        speakerNames = try c.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
        legacyFullText = try c.decodeIfPresent(String.self, forKey: .legacyFullText)
    }

    public init(id: UUID = UUID(), title: String, createdAt: Date, duration: Double = 0,
                source: String = "microphone", audioFileName: String, status: String = "completed",
                language: String = "en", modelName: String? = nil, segments: [Segment] = [],
                deletedAt: Date? = nil, folder: String? = nil, appName: String? = nil,
                appBundleID: String? = nil,
                summary: String? = nil, actionItems: [ActionItem]? = nil,
                speakerNames: [String: String] = [:], legacyFullText: String? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.source = source
        self.audioFileName = audioFileName
        self.status = status
        self.language = language
        self.modelName = modelName
        self.segments = segments
        self.deletedAt = deletedAt
        self.folder = folder
        self.appName = appName
        self.appBundleID = appBundleID
        self.summary = summary
        self.actionItems = actionItems
        self.speakerNames = speakerNames
        self.legacyFullText = legacyFullText
    }
}
