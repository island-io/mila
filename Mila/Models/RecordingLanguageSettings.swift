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
    /// Let whisper detect the language of each utterance instead of forcing
    /// one. Whisper's `detect_language` runs per `whisper_full` call, and the
    /// live path transcribes one VAD-bounded utterance per call — so this
    /// handles code-switching (a Hebrew meeting with the odd English
    /// sentence) without rendering the English *as Hebrew*, which is what
    /// forcing `he` on a Hebrew-specialised model does. Keeps the user's
    /// selected model (see `ModelManager.model(for:)`), so a Hebrew user's
    /// Hebrew accuracy isn't traded away for the multilingual generalist.
    case auto = "auto"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hebrew:  return "Hebrew"
        case .english: return "English"
        case .auto:    return "Auto-detect"
        }
    }

    /// Regional flag emoji used in the toolbar picker. Hebrew shows the
    /// Israeli flag; English shows the British flag (matches the user's
    /// "Israel and UK" mental model); Auto shows a globe.
    var flagEmoji: String {
        switch self {
        case .hebrew:  return "🇮🇱"
        case .english: return "🇬🇧"
        case .auto:    return "🌐"
        }
    }

    /// The opposite-language pair, used by the right-click "Re-transcribe in
    /// the other language" menu item on a recording. Auto-detected
    /// recordings offer a re-transcribe forced to Hebrew (the dominant
    /// language for our users) as the manual override.
    var other: RecordingLanguage {
        switch self {
        case .hebrew:  return .english
        case .english: return .hebrew
        case .auto:    return .hebrew
        }
    }

    /// Best-effort decode of an ISO-style language string (`"he"`, `"he-IL"`,
    /// `"iw"`, `"en"`, `"en-US"`, `"auto"`, …). Falls back to Hebrew for
    /// legacy recordings that pre-date the per-language UX (those were always
    /// Hebrew before the rename).
    static func fromCode(_ code: String) -> RecordingLanguage {
        let normalized = code.lowercased()
        if normalized == "auto" { return .auto }
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
