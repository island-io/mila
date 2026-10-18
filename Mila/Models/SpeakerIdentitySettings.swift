import Foundation
import Combine

/// Who "me" is: the name of the person running Mila, set once in
/// Settings → Speakers → "Your name" (issue #348).
///
/// **Where it is used, and where it deliberately is not.** A meeting capture
/// mixes the microphone and the app's audio into ONE mono track before
/// anything is transcribed or diarized (`RecordingSession`), so nothing
/// downstream can tell which diarized speaker came in through the local mic.
/// Guessing there — "the speaker who talks most", "the first speaker" — would
/// be wrong often enough to matter, and a wrong name that the user accepts is
/// folded into a voice profile. So this name is offered only where the
/// capture itself identifies the local user: a recording made from the
/// user's own microphone in which the diarizer heard exactly one voice
/// (`SpeakerNameSuggester.localUserSuggestion`). Even there it is a
/// one-click SUGGESTION, not an automatic rename, for the same
/// voice-profile reason.
///
/// Accepting it once is what makes "me" stick everywhere else: with voice
/// recognition on, naming that speaker creates the user's voice profile, and
/// from then on recognition names them automatically — in meetings too.
///
/// Local only: the name is never sent to the LLM.
@MainActor
final class SpeakerIdentitySettings: ObservableObject {

    /// The user's own display name. Settings writes it once per committed
    /// edit (Return / focus loss), never per keystroke: this is an App-level
    /// `@StateObject`, so every publish re-diffs every scene. Readers use
    /// `resolvedName`, which also covers a hand-edited untrimmed value.
    @Published var myName: String {
        didSet {
            guard myName != oldValue else { return }
            defaults.set(myName, forKey: Keys.myName)
        }
    }

    /// `myName` trimmed, or nil when it is blank — "not set", which turns the
    /// local-user suggestion off.
    var resolvedName: String? {
        let trimmed = myName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.myName = defaults.string(forKey: Keys.myName) ?? ""
    }

    enum Keys {
        static let myName = "speakers.myName"
    }
}
