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
            // been written — so the observer (SpeakerProfileStore) sees the
            // new value. This is the repo's existing callback idiom
            // (`RecordingStore.onSpeakerNamed`, `svc.onTranscriptionCompleted`)
            // rather than a Combine sink, because `@Published` delivers on
            // *willSet*: a sink would fire while `isEnabled` still read the
            // old value, and the store's own guards read it.
            onEnabledChange?(isEnabled)
        }
    }

    /// Called on every actual change to `isEnabled`, with the new value.
    /// `SpeakerProfileStore` installs this to load stored profiles on
    /// opt-in and to drop them out of memory again on opt-out.
    var onEnabledChange: ((Bool) -> Void)?

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
