import Foundation

/// Read-only mirror of one entry in the app's `recordings.json`.
///
/// The app's `Recording` type stays in the app target (its init is
/// referenced across dozens of files); this mirror exists so the external
/// mila-mcp helper can decode the store without linking app code. Every
/// field the app encodes must decode here — guarded by
/// `StoredRecordingDriftTests` in MilaTests, which encodes a fully
/// populated app `Recording` and asserts this type round-trips it.
/// Decoding is deliberately lenient (`decodeIfPresent` + defaults) so an
/// older helper never chokes on a newer app's additions.
public struct StoredRecording: Codable, Identifiable {
    public struct Segment: Codable, SpeakerTextSegment {
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

    public struct ActionItem: Codable {
        public var text: String
        public var speaker: String?
        public var timestampSeconds: Double?

        public init(text: String, speaker: String? = nil, timestampSeconds: Double? = nil) {
            self.text = text
            self.speaker = speaker
            self.timestampSeconds = timestampSeconds
        }

        private enum CodingKeys: String, CodingKey { case text, speaker, timestampSeconds }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            speaker = try c.decodeIfPresent(String.self, forKey: .speaker)
            timestampSeconds = try c.decodeIfPresent(Double.self, forKey: .timestampSeconds)
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
             summary, actionItems, speakerNames
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
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        actionItems = try c.decodeIfPresent([ActionItem].self, forKey: .actionItems)
        speakerNames = try c.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
        legacyFullText = try c.decodeIfPresent(String.self, forKey: .legacyFullText)
    }

    public init(id: UUID = UUID(), title: String, createdAt: Date, duration: Double = 0,
                source: String = "microphone", audioFileName: String, status: String = "completed",
                language: String = "en", modelName: String? = nil, segments: [Segment] = [],
                deletedAt: Date? = nil, folder: String? = nil, appName: String? = nil,
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
        self.summary = summary
        self.actionItems = actionItems
        self.speakerNames = speakerNames
        self.legacyFullText = legacyFullText
    }
}
