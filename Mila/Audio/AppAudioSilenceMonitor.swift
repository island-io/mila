import Foundation
import AVFoundation
import Accelerate
import OSLog

private let silenceLog = Logger(subsystem: "io.island.whisper.IslandWhisper",
                                category: "AppAudioSilenceMonitor")

/// Tracks RMS levels of the system-audio capture during the opening window
/// of a meeting recording. If no buffer exceeds the silence threshold for
/// the entire window, the recording is considered "system audio was never
/// real" (e.g. user pressed Record before the Zoom call started, or picked
/// the wrong app). The owner of this monitor — `RecordingSession` — then
/// tears down the system-audio leg while keeping the microphone leg alive,
/// silently. No UI notification: the requirement is "seamless" and the
/// user keeps their mic recording either way.
///
/// Design notes:
///   * The window length is configurable so UI tests can compress
///     5 minutes → 10 seconds without rebuilding the app.
///   * The decision is a single boolean ("did any buffer exceed the
///     threshold?") rather than e.g. an EMA — we want to catch even
///     short bursts so a Zoom join chime or quiet hold music counts as
///     "audio is happening, keep the capture".
///   * The threshold is on raw RMS (linear amplitude), not the normalized
///     0..1 meter level. `AudioMeter.level` rounds anything below ~0.001
///     RMS to exactly 0 already (via the -60 dB floor); using raw RMS
///     keeps the threshold meaningful and tunable.
@MainActor
final class AppAudioSilenceMonitor {
    /// Default window: 5 minutes. The class is `final` rather than a
    /// struct with a mutable `windowSeconds` so callers configure once
    /// (at recording start) and never have to worry about a mid-window
    /// timer reset.
    ///
    /// `nonisolated` so this constant can be used as a default argument
    /// to `init` (default-argument expressions are evaluated at the
    /// call site, which may not be on the main actor) and so it can be
    /// referenced from `RecordingSession.installSilenceMonitor` without
    /// the call site needing main-actor isolation for a literal lookup.
    /// The value is a compile-time constant — no isolation needed.
    nonisolated static let defaultWindowSeconds: TimeInterval = 5 * 60

    /// Raw RMS threshold below which a buffer counts as "silent".
    /// 0.001 (~ -60 dBFS) matches the meter floor used elsewhere in the
    /// app, so this stays consistent with what the user sees in the UI
    /// when system audio "looks silent" — we drop in cases where the
    /// meter never lit up.
    ///
    /// `nonisolated` for the same reason as `defaultWindowSeconds`:
    /// compile-time constant, no actor crossing needed.
    nonisolated static let rmsThreshold: Float = 0.001

    let windowSeconds: TimeInterval
    private let onDrop: () -> Void

    private var armed = false
    private var startedAt: Date?
    private var sawAudio = false
    private var deadlineTask: Task<Void, Never>?

    init(windowSeconds: TimeInterval = AppAudioSilenceMonitor.defaultWindowSeconds,
         onDrop: @escaping () -> Void) {
        self.windowSeconds = windowSeconds
        self.onDrop = onDrop
    }

    /// Begin tracking. Idempotent — safe to call repeatedly; only the
    /// first call arms the window. Spawns a `Task.sleep` that fires the
    /// "drop?" decision exactly once after `windowSeconds`.
    func start() {
        guard !armed else { return }
        armed = true
        startedAt = Date()
        sawAudio = false
        silenceLog.log("armed window=\(self.windowSeconds, privacy: .public)s threshold=\(AppAudioSilenceMonitor.rmsThreshold, privacy: .public)")
        deadlineTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let ns = UInt64(self.windowSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            if Task.isCancelled { return }
            self.evaluate()
        }
    }

    /// Disarm the monitor — used when the recording ends naturally or
    /// the system-audio leg has already been torn down.
    func cancel() {
        guard armed else { return }
        armed = false
        deadlineTask?.cancel()
        deadlineTask = nil
        startedAt = nil
        silenceLog.log("cancelled")
    }

    /// Feed a buffer's worth of samples. Called for every system-audio
    /// chunk while the window is open. We compute raw RMS and short-
    /// circuit once any buffer crosses the threshold — there's no value
    /// in evaluating later samples once we've decided "audio is real".
    func ingest(buffer: AVAudioPCMBuffer) {
        guard armed, !sawAudio,
              let data = buffer.floatChannelData else { return }
        let count = vDSP_Length(buffer.frameLength)
        guard count > 0 else { return }
        var rms: Float = 0
        vDSP_rmsqv(data[0], 1, &rms, count)
        if rms >= Self.rmsThreshold {
            sawAudio = true
            silenceLog.log("audio detected rms=\(rms, privacy: .public) — window will keep system capture")
        }
    }

    /// Decide at the end of the window. Public so tests can force
    /// evaluation without waiting on real time.
    func evaluate() {
        guard armed else { return }
        armed = false
        deadlineTask?.cancel()
        deadlineTask = nil
        if sawAudio {
            silenceLog.log("window elapsed — audio was present, keeping system capture")
            return
        }
        silenceLog.log("window elapsed — no audio observed, dropping system capture")
        onDrop()
    }
}
