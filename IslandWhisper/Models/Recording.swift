import Foundation

enum RecordingSource: String, Codable, CaseIterable, Identifiable {
    case microphone
    case systemAudio
    case meeting

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .systemAudio: return "System audio"
        case .meeting: return "Meeting (mic + system)"
        }
    }

    var sfSymbol: String {
        switch self {
        case .microphone: return "mic.fill"
        case .systemAudio: return "speaker.wave.3.fill"
        case .meeting: return "person.2.wave.2.fill"
        }
    }
}

enum TranscriptionStatus: String, Codable {
    case pending
    case running
    case completed
    case failed
}

struct TranscriptSegment: Codable, Identifiable, Hashable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
}

struct Recording: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var createdAt: Date
    var duration: Double
    var source: RecordingSource
    /// File name (relative to recordings directory) of the .wav file.
    var audioFileName: String
    var status: TranscriptionStatus
    var language: String
    var modelName: String?
    var segments: [TranscriptSegment]
    var fullText: String
    /// When non-nil the recording is in the "Recently Deleted" trash.
    var deletedAt: Date?

    init(id: UUID = UUID(),
         title: String,
         createdAt: Date = Date(),
         duration: Double = 0,
         source: RecordingSource,
         audioFileName: String,
         status: TranscriptionStatus = .pending,
         language: String = "he",
         modelName: String? = nil,
         segments: [TranscriptSegment] = [],
         fullText: String = "",
         deletedAt: Date? = nil) {
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
        self.fullText = fullText
        self.deletedAt = deletedAt
    }

    var isTrashed: Bool { deletedAt != nil }
}

/// Categories used by the sidebar. Matches the History grouping.
enum HistoryCategory: String, CaseIterable, Identifiable, Hashable {
    case transcriptions   // any non-deleted recording with a transcript
    case meetings         // source == .meeting
    case dictations       // source == .microphone, marked as dictation
    case recentlyDeleted

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .transcriptions:   return "Transcriptions"
        case .meetings:         return "Meetings"
        case .dictations:       return "Dictations"
        case .recentlyDeleted:  return "Recently Deleted"
        }
    }
    var sfSymbol: String {
        switch self {
        case .transcriptions:   return "text.alignleft"
        case .meetings:         return "person.2.wave.2"
        case .dictations:       return "mic"
        case .recentlyDeleted:  return "trash"
        }
    }
}
