import Foundation
import Combine

/// User settings for cross-recording voice recognition — the feature that
/// remembers a named speaker's voice so the same person is labelled
/// automatically in later recordings.
///
/// Follows the same shape as `DiarizationSettings` / `VoiceMemosSettings`:
/// `@Published` properties writing through to namespaced `UserDefaults`
/// keys, with an injectable `defaults` suite so tests never touch the
/// user's real preferences.
///
/// **Why this is its own opt-in rather than part of diarization.** A voice
/// fingerprint is a 256-dimensional embedding of somebody's voice — one of
/// the few things Mila could store that identifies a *person* rather than a
/// recording, and it is captured for everyone in the room, not just the
/// person driving the app. Diarization only separates voices within a
/// single recording and keeps nothing afterwards; this feature keeps a
/// durable, matchable record. That difference in kind is why it gets its
/// own switch, defaults off, and does nothing whatsoever until the user
/// turns it on.
@MainActor
final class VoiceRecognitionSettings: ObservableObject {

    enum Keys {
        static let enabled = "speakers.voiceRecognition.enabled"
    }

    /// Master switch. **Off by default** and deliberately not inferred from
    /// anything else: with this off Mila writes no voice fingerprint to
    /// disk, reads none back, and seeds no recognition — a user who never
    /// opts in has no voice data stored at all.
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Keys.enabled)
            // Synchronous, on the main actor, and after the property has
            // been written — so observers see the new value. This is the
            // repo's existing callback idiom (`RecordingStore.onSpeakerNamed`,
            // `svc.onTranscriptionCompleted`) rather than a Combine sink,
            // because `@Published` delivers on *willSet*: a sink would fire
            // while `isEnabled` still read the old value, and the observers'
            // own guards read it.
            for observer in enabledObservers { observer(isEnabled) }
        }
    }

    private var enabledObservers: [(Bool) -> Void] = []

    /// Register a handler for actual changes to `isEnabled`, called
    /// synchronously with the new value.
    ///
    /// Three registrants, one per place a copied embedding can be sitting
    /// when the user flips the switch: `SpeakerProfileStore` loads stored
    /// profiles on opt-in and drops them from memory on opt-out;
    /// `ObservedVoiceSnapshots` discards the observations it is holding; and
    /// `MilaApp` calls `LiveSpeakerDiarizer.forgetSeededProfiles()` so the
    /// pool of a recording that is *already running* stops matching against
    /// centroids `seedPool` copied out of the store at record-start. Miss
    /// that last one and opting out stops the writes but not the reads —
    /// the transcript goes on being auto-labelled from stored voices until
    /// the recording ends.
    ///
    /// A list rather than one assignable slot on purpose: with a single slot
    /// the second registrant silently unhooked the first, so whichever
    /// object was constructed last would have been the only one to ever hear
    /// about an opt-out.
    func addEnabledObserver(_ observer: @escaping (Bool) -> Void) {
        enabledObservers.append(observer)
    }

    /// Answers "can the embedding pipeline this feature rides on actually
    /// produce embeddings right now?". Injected by `MilaApp` as a read of
    /// `DiarizationSettings.isConfigured`; a closure rather than a stored
    /// reference so this object can never mutate diarization settings, and
    /// so the gate is trivially testable.
    ///
    /// Defaults to `false` — an unwired instance is never "ready", so a
    /// forgotten injection fails closed (nothing stored) rather than open.
    var diarizationReady: (() -> Bool)?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Keys.enabled)
    }

    /// **The gate.** True iff voice recognition is switched on *and* able to
    /// work — per `.claude/rules/feature-gates.md`, "enabled" alone is not
    /// enough.
    ///
    /// The readiness half is `diarizationReady`. Voice recognition owns no
    /// embedding pipeline of its own: every centroid it stores or matches
    /// comes out of `LiveSpeakerDiarizer`'s pool, which is only populated
    /// while diarization is enabled *and* its local Python pipeline is
    /// verified (`DiarizationSettings.isConfigured`). With diarization off
    /// there is nothing to persist and nothing to match against, so acting
    /// on the toggle alone would mean seeding an empty pool and writing
    /// profiles that can never be recognised.
    ///
    /// Every persist, seed and match path is guarded on this — not on
    /// `isEnabled`.
    var isConfigured: Bool {
        guard isEnabled else { return false }
        return diarizationReady?() ?? false
    }
}
