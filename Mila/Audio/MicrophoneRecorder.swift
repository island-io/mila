import Foundation
import AVFoundation
import Combine
import os

private let micLog = Logger(subsystem: "io.island.whisper.IslandWhisper", category: "MicrophoneRecorder")

enum MicrophoneError: Error, Equatable {
    case noInputDevice
    case bringUpTimedOut
}

/// Per-session capture counters. The audio tap (a realtime thread) is the
/// only writer; the main actor reads a snapshot after `stop()`. Held behind
/// an `OSAllocatedUnfairLock` so the per-buffer update never hops actors.
/// Surfaced in the diagnostic log so a "0-second failed recording" can be
/// told apart from "device delivered no buffers" vs "every buffer failed
/// format conversion" — the three look identical on disk (an empty WAV) but
/// have completely different fixes.
struct MicFrameStats: Sendable {
    var buffers = 0
    var frames = 0
    var conversionFailures = 0
}

/// Pure, clock-injected detector for "the input tap has flatlined".
///
/// The audio tap is the only thing that grows `MicFrameStats.frames`, and a
/// live input device delivers buffers *continuously* — a silent room still
/// arrives as buffers of near-zero samples. So a frame count that stops
/// growing means capture is dead, not that nobody is talking. That's what
/// makes this a safe trigger for rebuilding the engine.
///
/// Kept as a value type with an injected `now` so the policy can be unit
/// tested exactly, without sleeping or touching CoreAudio.
struct CaptureStallDetector {
    /// How long the frame count may sit still before we call it a stall.
    let timeout: TimeInterval
    private var lastFrames: Int?
    private var armedAt: Date?

    init(timeout: TimeInterval) {
        self.timeout = timeout
    }

    /// Feed the current *cumulative* frame count. Returns `true` once the
    /// count has not moved for `timeout`.
    ///
    /// The first call arms the clock rather than reporting a stall, so a
    /// device that comes up but never delivers its first buffer also trips
    /// the detector once `timeout` has passed.
    mutating func observe(frames: Int, now: Date) -> Bool {
        defer { lastFrames = frames }
        guard let last = lastFrames, let armedAt else {
            self.armedAt = now
            return false
        }
        if frames > last {
            self.armedAt = now
            return false
        }
        return now.timeIntervalSince(armedAt) >= timeout
    }

    /// Re-arm after a recovery attempt so the next stall is timed from the
    /// rebuild, not from the last buffer the dead engine happened to deliver.
    mutating func reset() {
        lastFrames = nil
        armedAt = nil
    }
}

/// Pure, clock-injected minimum-interval + exponential-backoff gate for
/// *notification-driven* engine rebuilds.
///
/// `AVAudioEngineConfigurationChange` does not mean "something broke" — it
/// means "the I/O unit was reconfigured", and binding the input device during
/// our own bring-up is itself a reconfiguration. On at least one Mac that made
/// the recovery path self-sustaining: bind → notification → rebuild → bind →
/// notification, measured at ~150ms per cycle, which never let the tap live
/// long enough to deliver a single buffer (issue #147). The whole
/// `maxMidSessionRestarts` budget — documented as "60 attempts at ≥1s apart" —
/// was spent in about nine seconds, and the macOS microphone indicator
/// flickered for the entire recording.
///
/// The watchdog path is naturally spaced by `captureStallTimeout`; this gate
/// gives the notification path the same property, so the budget spans minutes
/// the way its comment always claimed. Throttled notifications are not lost
/// work: capture that is genuinely dead stops growing the frame count, so
/// `CaptureStallDetector` picks it up within `captureStallTimeout`.
///
/// A value type with an injected `now`, like `CaptureStallDetector`, so the
/// policy is unit-testable exactly and without sleeping.
struct RebuildThrottle {
    /// Floor between the first rebuild and the second one.
    let minimumInterval: TimeInterval
    /// Ceiling the doubling backoff saturates at.
    let maximumInterval: TimeInterval

    private var lastAllowedAt: Date?
    /// Rebuilds allowed in the current burst. Reset once things go quiet for
    /// `maximumInterval`, so an unrelated device change an hour into a meeting
    /// isn't punished for a storm at the start of it.
    private(set) var streak = 0

    init(minimumInterval: TimeInterval, maximumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
        self.maximumInterval = max(minimumInterval, maximumInterval)
    }

    /// How long after the last allowed rebuild the next one may happen.
    /// Zero before the first rebuild — the first configuration change of a
    /// session is always acted on immediately.
    var currentInterval: TimeInterval {
        guard streak > 0 else { return 0 }
        let scaled = minimumInterval * pow(2, Double(streak - 1))
        return min(scaled, maximumInterval)
    }

    /// Whether a rebuild may proceed at `now`. Mutating: an allowed rebuild
    /// starts the clock for the next one and lengthens the backoff.
    mutating func allow(now: Date) -> Bool {
        if let last = lastAllowedAt {
            let elapsed = now.timeIntervalSince(last)
            if elapsed < currentInterval { return false }
            // Quiet for a full backoff ceiling: the previous burst is over.
            if elapsed >= maximumInterval { streak = 0 }
        }
        lastAllowedAt = now
        streak += 1
        return true
    }
}

/// Pulls samples from the user's preferred input device using `AVAudioEngine`.
/// Emits whisper-format buffers (16kHz mono Float32) on `audioStream`.
///
/// **Important:** every `start()` call builds a brand-new `AVAudioEngine` and
/// a brand-new `AsyncStream`. Reusing a single engine across stop/start cycles
/// is a documented macOS quirk that makes the input node go silent after the
/// first session — the user-visible symptom was "first Voice Memo records
/// fine, every subsequent one captures ~60ms of noise and Whisper hallucinates
/// the same Hebrew test phrase for all of them".
///
/// **Threading:** the heavy CoreAudio bring-up (`inputFormat(forBus:)`,
/// `installTap`, `engine.prepare()`, `engine.start()`) runs OFF the main
/// actor inside a `Task.detached`, with a hard timeout. CoreAudio can stall
/// indefinitely when the input device is a wireless mic mid-profile-switch
/// (Bluetooth headset moving between A2DP and HFP, AirPods waking up, etc.);
/// before this fix, a stalled CoreAudio call froze the entire main thread
/// and made the app unresponsive — including the global hotkeys.
///
/// **Mid-session recovery:** bringing the engine up successfully is only half
/// the job — the input device can also be pulled out from under a *running*
/// engine. Per Apple's own docs, when the I/O unit sees the input or output
/// hardware change its sample rate or channel count, "the engine stops
/// itself" and posts `AVAudioEngineConfigurationChange`. The nodes stay
/// attached, so nothing looks broken: the tap simply never fires again.
/// Nobody was listening for that notification, which is how a user's
/// 26-minute Zoom meeting came back as 24 seconds of audio — their USB
/// EarPods died 25s in (`AUHAL: Device 860 died!`), CoreAudio re-pointed the
/// input at the 48kHz built-in mic, and the 44.1kHz tap went quiet for the
/// remaining 26 minutes while the UI happily showed a growing timer.
///
/// Two independent safety nets now cover that:
///   1. `AVAudioEngineConfigurationChange` → rebuild engine + tap immediately.
///   2. A `CaptureStallDetector` watchdog → rebuild when frames stop growing
///      for `captureStallTimeout`, catching stalls that post no notification.
/// Both keep the session's `AsyncStream`, gain controller and frame counters
/// intact, so recording continues into the same WAV instead of ending.
@MainActor
final class MicrophoneRecorder: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var level: Float = 0

    /// Current stream — replaced on every `start()` so leftover buffered
    /// samples from a previous recording can never leak into the next one.
    private(set) var audioStream: AsyncStream<AVAudioPCMBuffer>
    private var audioContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    private var engine: AVAudioEngine?

    /// Capture counters for the current/most-recent session, rebuilt on every
    /// `start()`. Left intact across `stop()` so the orchestrator can read
    /// `capturedFrameCount` after teardown.
    private var stats: OSAllocatedUnfairLock<MicFrameStats>?

    /// Whisper-format frames the tap has yielded to consumers this session.
    /// 0 after a recording means the mic produced nothing — a dead/muted
    /// device, the wrong input selected, or a failing format conversion.
    var capturedFrameCount: Int { stats?.withLock { $0.frames } ?? 0 }

    /// How long we'll wait for the AVAudioEngine bring-up before giving up
    /// and throwing `MicrophoneError.bringUpTimedOut`. CoreAudio can stall
    /// indefinitely on wireless mic profile switches; we'd rather throw
    /// (caller beeps, user retries) than freeze the app.
    var bringUpTimeout: TimeInterval = 5.0

    /// Test seam: when set, replaces the real `AVAudioEngine` bring-up so
    /// `MicrophoneRecorderTests` can simulate slow / stalled / failing
    /// CoreAudio without needing a real microphone or fragile timing in CI.
    /// Also used for mid-session rebuilds, so a test can count how many times
    /// the watchdog tried to repair capture.
    var bringUpOverride: (@Sendable () async throws -> Void)?

    /// How long the tap may deliver nothing before the watchdog rebuilds the
    /// engine. Generous next to a normal buffer interval (4096 frames at
    /// 44.1kHz ≈ 93ms) so ordinary scheduling jitter can't trip it, and short
    /// enough that a yanked device costs a few seconds of a meeting instead
    /// of the rest of it.
    var captureStallTimeout: TimeInterval = 4.0

    /// Watchdog poll cadence.
    var watchdogInterval: TimeInterval = 1.0

    /// Hard cap on rebuild attempts within one recording. A permanently dead
    /// input would otherwise have us rebuilding in a loop for the length of a
    /// meeting. Combined with the pacing below (the watchdog fires at most
    /// once per `captureStallTimeout`, the notification path is gated by
    /// `RebuildThrottle`), 60 attempts span minutes rather than seconds; past
    /// that we stop trying and say so in the log.
    var maxMidSessionRestarts = 60

    /// Configuration changes arriving this soon after a bring-up are treated
    /// as OUR OWN doing and ignored.
    ///
    /// `bringUp` binds the chosen input with
    /// `kAudioOutputUnitProperty_CurrentDevice`, and on some machines that
    /// bind is itself enough to make the engine post
    /// `AVAudioEngineConfigurationChange` — indistinguishable, at the
    /// notification, from a device being yanked. Reacting to it rebuilt the
    /// engine, which bound the device again, which posted again (issue #147).
    ///
    /// The cost of the window is that a device genuinely lost in the first
    /// fraction of a second of a recording is not repaired by the *fast*
    /// path — the stall watchdog still catches it `captureStallTimeout` later,
    /// so the failure mode is a few seconds of delay, not a lost recording.
    var configurationChangeGracePeriod: TimeInterval = 0.75

    /// Floor between two notification-driven rebuilds (doubling up to
    /// `maximumRebuildInterval`). See `RebuildThrottle`.
    var minimumRebuildInterval: TimeInterval = 1.0

    /// Ceiling for the notification-path backoff.
    var maximumRebuildInterval: TimeInterval = 30.0

    /// Rebuild attempts made during the current session — surfaced in the
    /// stop log so a diagnostic report shows "capture was repaired 3 times"
    /// rather than leaving an unexplained gap in the audio.
    private(set) var restartCount = 0

    private var watchdogTask: Task<Void, Never>?
    private var configChangeObserver: NSObjectProtocol?

    /// The object whose `AVAudioEngineConfigurationChange` notifications we're
    /// currently observing — the live `AVAudioEngine` in production.
    ///
    /// Held (rather than just registered for) for two reasons: `NotificationCenter`
    /// does not retain the object an observer is scoped to, and it gives the
    /// `bringUpOverride` test path — which has no real engine — a stand-in to
    /// post to. Tests exercise the REAL observer, the real notification name
    /// and the real handler policy; only the poster of the notification is
    /// simulated. Re-read it after every rebuild: production installs a fresh
    /// engine (and so a fresh source) each time, and a faithful test does the
    /// same.
    private(set) var configurationChangeSource: AnyObject?

    /// When the most recent successful bring-up finished — the start of the
    /// `configurationChangeGracePeriod` window.
    private var lastBringUpAt: Date?

    /// Paces notification-driven rebuilds. Rebuilt per session in `start()`.
    private var rebuildThrottle = RebuildThrottle(minimumInterval: 1.0, maximumInterval: 30.0)

    /// Guards against a configuration-change notification and a watchdog tick
    /// both deciding to rebuild at the same moment.
    private var isRebuilding = false

    /// Bumped by every `start()` and `stop()`. A rebuild captures the value it
    /// began with, because `isRunning` alone cannot tell "my session is still
    /// live" from "a *later* session is". A stop → start cycle inside a
    /// rebuild's bring-up (up to `bringUpTimeout`) would otherwise let the
    /// stale rebuild install its engine over the new session's — leaking a
    /// running engine, and with it a permanently hot microphone.
    private var captureEpoch = 0

    /// Smoothed digital gain applied to every captured float frame before
    /// it's yielded to consumers. Built fresh on each `start()` so a low-
    /// volume mic doesn't inherit a stale gain from a previous session.
    /// Held here (rather than rebuilt inside the tap closure) so tests and
    /// the level meter can observe `currentGain` while a recording is in
    /// flight.
    private(set) var gain: AdaptiveGainController?

    init() {
        var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation!
        self.audioStream = AsyncStream { continuation = $0 }
        self.audioContinuation = continuation
    }

    func requestAccess() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }

    func start() async throws {
        guard !isRunning else { return }

        // Tear down anything that may still be alive from a previous session
        // (defensive — `stop()` should have done this, but a partially-started
        // session that threw mid-way could leak engine/tap state). All cheap,
        // can stay on the main actor.
        watchdogTask?.cancel()
        watchdogTask = nil
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        configurationChangeSource = nil
        if let existing = engine {
            existing.inputNode.removeTap(onBus: 0)
            existing.stop()
            engine = nil
        }
        audioContinuation.finish()

        var newContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation!
        self.audioStream = AsyncStream { newContinuation = $0 }
        self.audioContinuation = newContinuation
        let continuationForTap = newContinuation!

        restartCount = 0
        isRebuilding = false
        captureEpoch += 1
        lastBringUpAt = nil
        rebuildThrottle = RebuildThrottle(minimumInterval: minimumRebuildInterval,
                                          maximumInterval: maximumRebuildInterval)

        if let override = bringUpOverride {
            try await Self.withTimeout(seconds: bringUpTimeout) {
                try await override()
            }
            isRunning = true
            lastBringUpAt = Date()
            // Observe on the test path too, against a stand-in source: the
            // configuration-change handling and its pacing are the part of
            // this class most in need of coverage, and the real path can't be
            // driven in CI (no microphone, no CoreAudio device to reconfigure).
            observeConfigurationChanges(on: ConfigurationChangeSource())
            // Start the watchdog on the test path too: with no real tap the
            // frame count never grows, so a test can drive the full
            // stall → rebuild loop by counting override invocations.
            startCaptureWatchdog()
            return
        }

        // Build a fresh AGC for this session. Pulls the persisted toggle
        // straight from UserDefaults so the recorder doesn't need to capture
        // a main-actor settings object onto the audio thread. Matches the
        // pattern already used here for `audio.input.preferredUID`.
        let agcEnabled: Bool = {
            if UserDefaults.standard.object(forKey: AudioInputSettings.adaptiveGainEnabledKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: AudioInputSettings.adaptiveGainEnabledKey)
        }()
        let agc = AdaptiveGainController(enabled: agcEnabled)
        self.gain = agc

        let sessionStats = OSAllocatedUnfairLock(initialState: MicFrameStats())
        self.stats = sessionStats

        let result = try await bringUpRealEngine(continuation: continuationForTap,
                                                 gain: agc,
                                                 stats: sessionStats)
        self.engine = result.engine
        isRunning = true
        lastBringUpAt = Date()
        micLog.log("mic started: \(result.format.sampleRate, privacy: .public)Hz \(result.format.channelCount, privacy: .public)ch agc=\(agcEnabled ? "on" : "off", privacy: .public)")
        // Registered only now, i.e. after the device bind inside the bring-up
        // has returned. That ordering alone is NOT enough (the notification is
        // posted asynchronously and can land after we register, which is why
        // `configurationChangeGracePeriod` exists), but it does drop the
        // changes that are already in flight by this point.
        observeConfigurationChanges(on: result.engine)
        startCaptureWatchdog()
    }

    /// Bring up a fresh engine + tap against the given session state. Shared
    /// by `start()` and by mid-session rebuilds, so a repaired engine gets the
    /// same timeout protection and abandoned-engine teardown as the first one.
    private func bringUpRealEngine(
        continuation: AsyncStream<AVAudioPCMBuffer>.Continuation,
        gain: AdaptiveGainController,
        stats: OSAllocatedUnfairLock<MicFrameStats>
    ) async throws -> EngineBox {
        // The level callback hops back to the main actor for the @Published
        // mutation. Captured weakly so a deinit'd recorder doesn't keep the
        // tap closure alive.
        let onLevel: @Sendable (Float) -> Void = { [weak self] lvl in
            Task { @MainActor in self?.level = lvl }
        }
        return try await Self.withTimeout(
            seconds: bringUpTimeout,
            onAbandoned: { box in
                // The bring-up finished after the timeout already threw.
                // Nobody owns this engine — tear it down (off-main, same as
                // stop()'s detached teardown) or the mic stays hot forever.
                micLog.error("mic bring-up completed after the timeout had thrown — tearing down the abandoned engine")
                box.engine.inputNode.removeTap(onBus: 0)
                box.engine.stop()
            }
        ) {
            try await Self.realBringUp(continuation: continuation,
                                       onLevel: onLevel,
                                       gain: gain,
                                       stats: stats)
        }
    }

    // MARK: - Mid-session recovery

    /// Stand-in notification source used on the `bringUpOverride` path, where
    /// there is no `AVAudioEngine` to scope the observer to. Its only job is to
    /// be an identity a test can post to.
    final class ConfigurationChangeSource: NSObject {}

    /// Watch one engine for the configuration change that silently kills the
    /// tap. Re-registered after every rebuild, since the notification is
    /// scoped to a specific engine instance.
    ///
    /// Takes `AnyObject` rather than `AVAudioEngine` so the override path can
    /// register the same observer against a `ConfigurationChangeSource` — see
    /// `configurationChangeSource`.
    private func observeConfigurationChanges(on source: AnyObject) {
        if let existing = configChangeObserver {
            NotificationCenter.default.removeObserver(existing)
        }
        configurationChangeSource = source
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVAudioEngineConfigurationChange,
            object: source,
            queue: nil
        ) { [weak self] _ in
            // The callback arrives on an AVFoundation-internal dispatch queue,
            // and its docs warn that tearing the engine down *inside* the
            // handler can deadlock. Hop to the main actor first; the actual
            // teardown then happens on a detached task from there.
            Task { @MainActor [weak self] in
                await self?.handleConfigurationChange()
            }
        }
    }

    private func handleConfigurationChange() async {
        guard isRunning else { return }
        let now = Date()

        // 1. Did we cause this ourselves? Our own bring-up binds the input
        //    device, and on some machines that bind posts a configuration
        //    change. Acting on it re-binds, which posts again — the ~150ms
        //    self-sustaining loop of issue #147, during which the tap never
        //    lives long enough to deliver one buffer.
        if let lastBringUpAt, now.timeIntervalSince(lastBringUpAt) < configurationChangeGracePeriod {
            micLog.log("ignoring AVAudioEngineConfigurationChange \(now.timeIntervalSince(lastBringUpAt), privacy: .public)s after bring-up — inside the \(self.configurationChangeGracePeriod, privacy: .public)s grace window, so this is our own device selection echoing back; the stall watchdog still covers a device that really did go away")
            return
        }

        // 2. Pace what's left. The watchdog is spaced by `captureStallTimeout`;
        //    without this the notification path had no spacing at all, so the
        //    rebuild budget could be spent in seconds.
        guard rebuildThrottle.allow(now: now) else {
            micLog.error("AVAudioEngine configuration changed again within \(self.rebuildThrottle.currentInterval, privacy: .public)s of the last rebuild — throttling this one (streak=\(self.rebuildThrottle.streak, privacy: .public)); if capture really is dead the stall watchdog will rebuild it")
            return
        }

        // No "is it really broken?" probe here on purpose: the documented
        // behaviour is that the engine has ALREADY stopped itself by the time
        // this notification is posted, so capture is dead either way and
        // there's nothing to preserve by waiting.
        micLog.error("AVAudioEngine configuration changed mid-session (input hardware format changed or the device died) — capture is dead until rebuilt")
        await rebuildEngine(reason: "configuration change")
    }

    /// Poll the session frame count and rebuild if capture flatlines.
    ///
    /// Backstop for the notification above: a device can also stop delivering
    /// without any format change to report (HAL wedge, a device that
    /// disappears and is replaced by an aggregate at the same rate), and those
    /// post nothing at all.
    private func startCaptureWatchdog() {
        watchdogTask?.cancel()
        let interval = max(0.01, watchdogInterval)
        let stallTimeout = captureStallTimeout
        watchdogTask = Task { @MainActor [weak self] in
            var detector = CaptureStallDetector(timeout: stallTimeout)
            var seenRebuilds = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                // Re-bind `self` weakly on EVERY iteration rather than once
                // before the loop. `watchdogTask` is stored on `self`, so a
                // strong binding held for the loop's lifetime would make the
                // recorder keep itself alive: the loop only ends on cancel or
                // `isRunning == false`, both of which come from `stop()`. An
                // owner that dropped a running recorder without calling
                // `stop()` would then never see `deinit`, and the engine (and
                // the hot microphone) would outlive it for the whole process.
                guard !Task.isCancelled, let self, self.isRunning else { return }
                // A rebuild is already in flight (or the notification handler
                // beat us to it) — don't stack a second one on top.
                if self.isRebuilding { continue }
                // ANY rebuild invalidates the stall clock, including one driven
                // by the configuration-change notification, which can't reach
                // this task-local detector. Frames can't grow while a rebuild
                // runs, so without this a slow rebuild could be followed
                // straight away by a second "stall" measured from an `armedAt`
                // that predates it — costing another audio gap and another
                // slot of the rebuild budget right after a successful repair.
                if self.restartCount != seenRebuilds {
                    seenRebuilds = self.restartCount
                    detector.reset()
                    continue
                }
                guard detector.observe(frames: self.capturedFrameCount, now: Date()) else { continue }
                // Budget spent: stop watching instead of re-logging the same
                // stall every `captureStallTimeout` for the rest of the
                // recording. A stall in a 40-minute meeting would otherwise
                // bury the diagnostic bundle in hundreds of identical lines —
                // the same trap `consumeSystem`'s overflow log had to throttle.
                if self.restartCount >= self.maxMidSessionRestarts {
                    micLog.error("mic capture is still stalled after \(self.restartCount, privacy: .public) rebuild attempts — giving up and stopping the watchdog; the rest of this recording has no microphone audio")
                    return
                }
                micLog.error("no mic buffers for \(self.captureStallTimeout, privacy: .public)s while recording — treating capture as stalled")
                await self.rebuildEngine(reason: "capture stalled")
                seenRebuilds = self.restartCount
                detector.reset()
            }
        }
    }

    /// Rebuild the engine + tap in place, keeping the session's `AsyncStream`,
    /// gain controller and frame counters.
    ///
    /// The stream MUST survive: `RecordingSession.micTask` is iterating it, so
    /// finishing the continuation would *end* the recording rather than repair
    /// it. A brand-new `AVAudioEngine` is equally mandatory — see the class
    /// note about reusing one leaving the input node permanently silent.
    private func rebuildEngine(reason: String) async {
        guard isRunning, !isRebuilding else { return }
        guard restartCount < maxMidSessionRestarts else {
            micLog.error("declining to rebuild capture (reason: \(reason, privacy: .public)): already used all \(self.maxMidSessionRestarts, privacy: .public) rebuild attempts this session")
            return
        }
        isRebuilding = true
        restartCount += 1
        let attempt = restartCount
        let epoch = captureEpoch
        // Only clear the flag if this rebuild still belongs to the live
        // session: a stale one finishing late must not clear a *new* session's
        // in-flight rebuild. `start()` resets the flag itself, so nothing is
        // left stuck.
        defer { if captureEpoch == epoch { isRebuilding = false } }

        let old = engine
        engine = nil
        if let old {
            // Off-main, and never from inside the notification handler: both
            // `removeTap` and `stop()` can block on the CoreAudio HAL queue.
            await Task.detached(priority: .userInitiated) {
                old.inputNode.removeTap(onBus: 0)
                old.stop()
            }.value
        }

        if let override = bringUpOverride {
            // Test path: no CoreAudio, but still exercise the full decision
            // and the timeout wrapper.
            try? await Self.withTimeout(seconds: bringUpTimeout) { try await override() }
            guard captureEpoch == epoch else { return }
            lastBringUpAt = Date()
            // Mirror the real path: a rebuild installs a new engine, so the
            // notification source is new too.
            observeConfigurationChanges(on: ConfigurationChangeSource())
            return
        }

        guard let sessionStats = stats, let agc = gain else {
            micLog.error("mic rebuild #\(attempt, privacy: .public) skipped: session state was already torn down")
            return
        }

        do {
            let result = try await bringUpRealEngine(continuation: audioContinuation,
                                                     gain: agc,
                                                     stats: sessionStats)
            // `bringUpRealEngine` suspends for up to `bringUpTimeout`, and
            // `stop()` is free to run on the main actor while it does — which
            // is exactly what happens when the user hits Stop because their
            // headphones just died. Adopting the engine now would hand it to a
            // session that no longer exists: nothing would ever tear it down,
            // and the microphone would stay hot for the rest of the process.
            // The epoch check covers the nastier variant — a whole stop/start
            // cycle during the bring-up, where `isRunning` is true again but
            // belongs to a different recording with its own live engine.
            guard isRunning, captureEpoch == epoch else {
                micLog.error("mic rebuild #\(attempt, privacy: .public) finished after its session ended — tearing down the orphaned engine")
                let orphan = result.engine
                await Task.detached(priority: .userInitiated) {
                    orphan.inputNode.removeTap(onBus: 0)
                    orphan.stop()
                }.value
                return
            }
            engine = result.engine
            lastBringUpAt = Date()
            observeConfigurationChanges(on: result.engine)
            micLog.log("mic capture rebuilt (attempt #\(attempt, privacy: .public), reason: \(reason, privacy: .public)) at \(result.format.sampleRate, privacy: .public)Hz \(result.format.channelCount, privacy: .public)ch — recording continues")
        } catch {
            // Leave `isRunning` true: the watchdog keeps ticking and will
            // retry, which is what rides out a device that's briefly absent
            // (unplug → replug) rather than mid-switch.
            micLog.error("mic rebuild #\(attempt, privacy: .public) (reason: \(reason, privacy: .public)) failed: \(error.localizedDescription, privacy: .public) — the watchdog will retry")
            if attempt == maxMidSessionRestarts {
                micLog.error("giving up on mic recovery after \(attempt, privacy: .public) attempts — the rest of this recording will have no microphone audio")
            }
        }
    }

    func stop() async {
        guard isRunning else { return }
        // Kill the watchdog and the notification hook FIRST: a rebuild racing
        // the teardown below would leave a hot engine nobody owns. Bump the
        // epoch too, so a rebuild already inside its bring-up abandons itself
        // even if a new recording starts before it returns.
        captureEpoch += 1
        watchdogTask?.cancel()
        watchdogTask = nil
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        configurationChangeSource = nil
        lastBringUpAt = nil
        if let s = stats?.withLock({ $0 }) {
            micLog.log("mic stopping: buffers=\(s.buffers, privacy: .public) frames=\(s.frames, privacy: .public) conversionFailures=\(s.conversionFailures, privacy: .public) rebuilds=\(self.restartCount, privacy: .public)")
            if s.frames == 0 {
                micLog.error("microphone delivered NO audio this session (buffers=\(s.buffers, privacy: .public), conversionFailures=\(s.conversionFailures, privacy: .public)) — the recording will be empty")
            }
            if self.restartCount > 0 {
                micLog.error("capture was rebuilt \(self.restartCount, privacy: .public)x mid-session (input device changed or stalled) — expect a short gap in the audio at each rebuild")
            }
        }
        let toTeardown = engine
        engine = nil
        gain = nil
        audioContinuation.finish()
        isRunning = false
        level = 0
        // Tear down off-main as well: `engine.stop()` can block on the same
        // CoreAudio HAL queue that `start()` blocks on, especially while a
        // Bluetooth mic is mid-profile-teardown.
        if let toTeardown {
            await Task.detached(priority: .userInitiated) {
                toTeardown.inputNode.removeTap(onBus: 0)
                toTeardown.stop()
            }.value
        }
    }

    deinit {
        // Block-based observers are not auto-removed when the observer object
        // dies, so a recorder torn down mid-session would leave a registration
        // behind for the lifetime of the process.
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
        audioContinuation.finish()
    }

    // MARK: - Off-main bring-up

    /// Box for handing the freshly-created `AVAudioEngine` + format back from
    /// the detached task to the main actor. `AVAudioEngine` and `AVAudioFormat`
    /// aren't formally `Sendable` but we're only crossing the boundary once,
    /// at construction time, before either side touches the references again.
    private struct EngineBox: @unchecked Sendable {
        let engine: AVAudioEngine
        let format: AVAudioFormat
    }

    private static func realBringUp(
        continuation: AsyncStream<AVAudioPCMBuffer>.Continuation,
        onLevel: @escaping @Sendable (Float) -> Void,
        gain: AdaptiveGainController,
        stats: OSAllocatedUnfairLock<MicFrameStats>
    ) async throws -> EngineBox {
        // Read the user's pinned input UID off the main actor — UserDefaults
        // is thread-safe and Settings writes via a @MainActor object, so the
        // value we see here is at worst one start() stale.
        let preferredUID = UserDefaults.standard.string(forKey: "audio.input.preferredUID")
        return try await Task.detached(priority: .userInitiated) { () -> EngineBox in
            let engine = AVAudioEngine()
            let input = engine.inputNode
            if let device = AudioDeviceManager.preferredInputDevice(preferredUID: preferredUID) {
                do {
                    try AudioDeviceManager.setInputDevice(device, on: engine)
                    micLog.log("input device: \(device.name, privacy: .public) [\(device.manufacturer, privacy: .public)] uid=\(device.uid, privacy: .public)")
                } catch {
                    micLog.error("could not switch to \(device.name, privacy: .public): \(error.localizedDescription, privacy: .public) — falling back to AVAudioEngine default input")
                }
            } else {
                micLog.log("input device: AVAudioEngine default (no connected device matched the preferred UID)")
            }
            let nativeFormat = input.inputFormat(forBus: 0)
            micLog.log("native input format: \(nativeFormat.sampleRate, privacy: .public)Hz \(nativeFormat.channelCount, privacy: .public)ch")
            // Both halves matter. A rebuild that lands on the wrong AUHAL —
            // issue #147 saw the *output* device selected, leaving an
            // "Input render format: 0 ch, 0 Hz" node — must be reported as a
            // failed bring-up rather than adopted as a working engine that
            // will never deliver a buffer. The caller logs the failure and the
            // watchdog retries, instead of the session silently going quiet.
            guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
                micLog.error("input format reports \(nativeFormat.sampleRate, privacy: .public)Hz \(nativeFormat.channelCount, privacy: .public)ch — no usable input device; throwing noInputDevice")
                throw MicrophoneError.noInputDevice
            }
            // One converter for the whole session: resampling is stateful,
            // and a fresh converter per tap buffer put a small discontinuity
            // at every ~85ms boundary (see StreamingWhisperConverter). Tap
            // callbacks for one engine are serial, so no locking needed.
            // Fallback to the per-buffer path only if the converter can't
            // be built for this format (effectively never).
            let sessionConverter = StreamingWhisperConverter(inputFormat: nativeFormat)
            input.installTap(onBus: 0,
                             bufferSize: 4096,
                             format: nativeFormat) { buffer, _ in
                onLevel(AudioMeter.level(from: buffer))
                do {
                    let converted = try sessionConverter?.convert(buffer)
                        ?? AudioConvert.toWhisperFormat(buffer)
                    // Apply adaptive digital gain in-place on the whisper-
                    // format buffer so the WAV writer AND the live VAD/
                    // whisper feed both see the same boosted signal —
                    // single source of truth. `toWhisperFormat` allocates
                    // a fresh buffer in every real-mic path (mics never
                    // come up at native 16kHz mono float), so writing into
                    // it doesn't touch the engine-owned source buffer.
                    // The defensive `aliasesInput` check covers the rare
                    // exotic-device case where the formats happen to match.
                    let toMutate: AVAudioPCMBuffer
                    if converted === buffer {
                        toMutate = Self.copyBuffer(buffer) ?? converted
                    } else {
                        toMutate = converted
                    }
                    if let channel = toMutate.floatChannelData?[0] {
                        gain.process(channel, count: Int(toMutate.frameLength))
                    }
                    let yielded = Int(toMutate.frameLength)
                    let isFirst = stats.withLock { s -> Bool in
                        s.buffers += 1
                        s.frames += yielded
                        return s.buffers == 1
                    }
                    if isFirst {
                        micLog.log("first mic buffer delivered (\(yielded, privacy: .public) frames) — capture is live")
                    }
                    continuation.yield(toMutate)
                } catch {
                    // Don't log every dropped buffer (could be thousands) —
                    // log the first, and `stop()` reports the running total.
                    let failures = stats.withLock { s -> Int in
                        s.conversionFailures += 1
                        return s.conversionFailures
                    }
                    if failures == 1 {
                        micLog.error("mic buffer conversion failed (dropping frames): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            engine.prepare()
            try engine.start()
            micLog.log("AVAudioEngine started; tap installed, awaiting buffers")
            return EngineBox(engine: engine, format: nativeFormat)
        }.value
    }

    /// Deep-copy a Float32 PCM buffer so we can apply in-place gain without
    /// mutating an engine-owned source buffer. Only used on the rare path
    /// where the input device already delivers whisper-format audio.
    private static func copyBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format,
                                          frameCapacity: source.frameCapacity) else {
            return nil
        }
        copy.frameLength = source.frameLength
        let channels = Int(source.format.channelCount)
        guard let src = source.floatChannelData, let dst = copy.floatChannelData else {
            return nil
        }
        let count = Int(source.frameLength)
        for ch in 0..<channels {
            dst[ch].update(from: src[ch], count: count)
        }
        return copy
    }

    /// Race `operation` against a sleep; whichever completes first wins.
    ///
    /// Implemented as a first-wins continuation race rather than a
    /// `withThrowingTaskGroup` race on purpose: a task group cannot return
    /// until ALL of its children finish, and the real bring-up child awaits
    /// a detached task's `.value` — an await that is NOT cancellation-
    /// responsive. With the group version, a wedged CoreAudio call kept
    /// `start()` suspended long past the deadline (the timeout error
    /// couldn't propagate out of the group), so the "throw after 5s, caller
    /// beeps, user retries" behavior never actually happened on the real
    /// path — or never happened at all if CoreAudio stayed stuck.
    ///
    /// On timeout the loser is *abandoned*, not cancelled: nothing can
    /// unblock a stalled CoreAudio `dispatch_sync`, so the detached worker
    /// keeps waiting. If it eventually succeeds after we already threw,
    /// `onAbandoned` is called with the result so the caller can tear down
    /// the now-ownerless resource (otherwise the engine would keep the mic
    /// hot forever). The main actor is never blocked either way.
    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        onAbandoned: @escaping @Sendable (T) -> Void = { _ in },
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let claimed = OSAllocatedUnfairLock(initialState: false)
        return try await withCheckedThrowingContinuation { cont in
            // Returns true when this call won the race and resumed `cont`.
            let finish: @Sendable (Result<T, Error>) -> Bool = { result in
                let isFirst = claimed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if isFirst { cont.resume(with: result) }
                return isFirst
            }
            Task.detached(priority: .userInitiated) {
                do {
                    let value = try await operation()
                    if !finish(.success(value)) { onAbandoned(value) }
                } catch {
                    _ = finish(.failure(error))
                }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                _ = finish(.failure(MicrophoneError.bringUpTimedOut))
            }
        }
    }
}
