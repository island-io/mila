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
            // …and then the gate, which the toggle is only *half* of. Kept
            // after the loop above so the two channels fire in a fixed
            // order; they are independent removals from different holders,
            // so the order is arbitrary but should not be accidental.
            refreshConfiguredState()
        }
    }

    private var enabledObservers: [(Bool) -> Void] = []

    /// Register a handler for actual changes to `isEnabled`, called
    /// synchronously with the new value.
    ///
    /// Two registrants, one per place a copied embedding sits that belongs
    /// to the *toggle* rather than to the gate: `SpeakerProfileStore` loads
    /// stored profiles on opt-in and drops them from memory on opt-out, and
    /// `ObservedVoiceSnapshots` discards the observations it is holding.
    ///
    /// Both are deliberately keyed on `isEnabled` and not on `isConfigured`.
    /// Diarization becoming unready is not the user withdrawing consent: the
    /// Settings pane still has to list the stored profiles so they can be
    /// renamed or deleted, and a name applied to a just-finished recording
    /// still has to resolve through its snapshot. Only the *live pool* is
    /// the gate's business — see `addConfiguredObserver`.
    ///
    /// A list rather than one assignable slot on purpose: with a single slot
    /// the second registrant silently unhooked the first, so whichever
    /// object was constructed last would have been the only one to ever hear
    /// about an opt-out.
    func addEnabledObserver(_ observer: @escaping (Bool) -> Void) {
        enabledObservers.append(observer)
    }

    private var configuredObservers: [(Bool) -> Void] = []

    /// The last value `configuredObservers` were told about, so a refresh
    /// only fires on an actual transition. Starts at `isConfigured`'s value
    /// for a freshly-built object — `false`, since `diarizationReady` is
    /// still unwired at that point.
    private var lastConfigured = false

    /// Register a handler for changes to **`isConfigured`** — the gate —
    /// called synchronously with its new value.
    ///
    /// This is the channel for anything that must stop the moment the
    /// feature stops being usable, whichever half of the gate closed.
    /// `MilaApp` registers exactly one handler: `LiveSpeakerDiarizer`'s
    /// `forgetSeededProfiles()`, so a recording that is *already running*
    /// stops matching against the centroids `seedPool` copied out of the
    /// store at record-start.
    ///
    /// **Why the gate and not the toggle.** `isConfigured` is `isEnabled &&
    /// diarizationReady`, so there are two ways for it to close, and #204
    /// wired only the first. Turning *diarization* off mid-recording (or its
    /// Python pipeline becoming unavailable) left the pool holding the
    /// seeded centroids and `assign` matching against them for the rest of
    /// the recording: the write gates held, so nothing was persisted, but
    /// the transcript went on auto-filling with names from stored voices
    /// after the feature had stopped being configured. Deleting a profile,
    /// opting out, and diarization going away are the same revocation and
    /// now take the same effect (#215).
    func addConfiguredObserver(_ observer: @escaping (Bool) -> Void) {
        configuredObservers.append(observer)
    }

    /// Re-evaluate `isConfigured` and notify `configuredObservers` if it
    /// changed. Idempotent and cheap (one closure call and a comparison), so
    /// callers may fire it as often as they like.
    ///
    /// Called internally whenever this object owns the change — `isEnabled`
    /// and `diarizationReady` — and externally by `trackDiarizationReadiness`
    /// for the half this object does not own.
    func refreshConfiguredState() {
        let nowConfigured = isConfigured
        guard nowConfigured != lastConfigured else { return }
        lastConfigured = nowConfigured
        for observer in configuredObservers { observer(nowConfigured) }
    }

    private var readinessCancellables: Set<AnyCancellable> = []

    /// Watch the objects behind `diarizationReady` so a change *there*
    /// reaches `configuredObservers` too. `MilaApp` passes
    /// `DiarizationSettings.objectWillChange` and its bootstrap's, which
    /// between them cover every input to `DiarizationSettings.isConfigured`:
    /// the toggle, the verification state, the Python path, and the
    /// runtime-torch bootstrap.
    ///
    /// Subscribing to `objectWillChange` rather than to named properties is
    /// deliberate — `isConfigured` is derived from four of them across two
    /// objects, and a list of individual sinks would silently stop covering
    /// the gate the next time someone adds a fifth. The recompute is a
    /// closure call, so over-firing costs nothing.
    ///
    /// **The hop is required, not incidental.** `objectWillChange` fires on
    /// *willSet*, so reading `isConfigured` inside the sink would see the
    /// pre-change value — the same trap documented on `isEnabled` above,
    /// which is why that side uses a synchronous callback instead. Deferring
    /// to the next main-actor turn reads the settled value. It also lands in
    /// time: the pool is only ever read from `LiveSpeakerDiarizer.process`,
    /// which `submit` likewise enqueues as a main-actor task, so an
    /// utterance captured *after* the change queues behind this refresh.
    /// One captured before it may still be labelled, which is correct — the
    /// feature was configured when that audio was spoken.
    ///
    /// Re-tracking replaces any previous subscriptions rather than adding
    /// to them.
    func trackDiarizationReadiness(_ publishers: ObservableObjectPublisher...) {
        readinessCancellables.removeAll()
        for publisher in publishers {
            publisher
                .sink { [weak self] in
                    Task { @MainActor in self?.refreshConfiguredState() }
                }
                .store(in: &readinessCancellables)
        }
    }

    /// Answers "can the embedding pipeline this feature rides on actually
    /// produce embeddings right now?". Injected by `MilaApp` as a read of
    /// `DiarizationSettings.isConfigured`; a closure rather than a stored
    /// reference so this object can never mutate diarization settings, and
    /// so the gate is trivially testable.
    ///
    /// Defaults to `false` — an unwired instance is never "ready", so a
    /// forgotten injection fails closed (nothing stored) rather than open.
    ///
    /// Assigning it re-evaluates the gate, so wiring readiness up (or a test
    /// swapping the closure) cannot leave `configuredObservers` believing a
    /// stale answer.
    var diarizationReady: (() -> Bool)? {
        didSet { refreshConfiguredState() }
    }

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
