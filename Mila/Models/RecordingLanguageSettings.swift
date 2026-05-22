import Foundation
import Combine

/// The language a freshly-started voice memo / app-audio recording will be
/// transcribed in. Surfaced in the toolbar as a flag dropdown so users can
/// flip between Hebrew (ivrit.ai model) and English (OpenAI model) without
/// digging into Settings.
///
/// Persisted to `UserDefaults` so the choice sticks across launches.
enum RecordingLanguage: String, CaseIterable, Identifiable, Codable {
    case hebrew = "he"
    case english = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hebrew:  return "Hebrew"
        case .english: return "English"
        }
    }

    /// Regional flag emoji used in the toolbar picker. Hebrew shows the
    /// Israeli flag; English shows the British flag (matches the user's
    /// "Israel and UK" mental model).
    var flagEmoji: String {
        switch self {
        case .hebrew:  return "🇮🇱"
        case .english: return "🇬🇧"
        }
    }

    /// The opposite-language pair, used by the right-click "Re-transcribe in
    /// the other language" menu item on a recording.
    var other: RecordingLanguage {
        switch self {
        case .hebrew:  return .english
        case .english: return .hebrew
        }
    }

    /// Best-effort decode of an ISO-style language string (`"he"`, `"he-IL"`,
    /// `"iw"`, `"en"`, `"en-US"`, …). Falls back to Hebrew for legacy
    /// recordings that pre-date the per-language UX (those were always
    /// Hebrew before the rename).
    static func fromCode(_ code: String) -> RecordingLanguage {
        let normalized = code.lowercased()
        if normalized == "iw" || normalized.hasPrefix("he") { return .hebrew }
        if normalized.hasPrefix("en") { return .english }
        return .hebrew
    }
}

@MainActor
final class RecordingLanguageSettings: ObservableObject {
    /// Language to use for the next voice memo / app-audio recording.
    @Published var current: RecordingLanguage {
        didSet {
            guard current != oldValue else { return }
            defaults.set(current.rawValue, forKey: Self.key)
        }
    }

    private let defaults: UserDefaults
    private static let key = "recording.language"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Self.key),
           let stored = RecordingLanguage(rawValue: raw) {
            self.current = stored
        } else {
            self.current = .hebrew
        }
    }
}
