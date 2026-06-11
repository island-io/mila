import Foundation
import Accelerate

/// Smoothly-tracked digital gain that boosts low-volume microphone capture
/// toward a target RMS so the live VAD (cutoff ~0.012) actually triggers and
/// whisper has enough signal to transcribe accurately.
///
/// ## Motivation
/// On laptops where the system input-volume slider has been turned down
/// (a common Zoom / Krisp side-effect) the built-in MacBook Pro mic captures
/// speech at peak ~-29 dBFS / RMS ~-58 dBFS — well below the live VAD's RMS
/// cutoff of 0.012. The live transcript stays empty even though the on-disk
/// WAV is salvageable by post-record whisper (which normalises internally).
/// This controller closes the gap by raising every outbound sample to a
/// target observed RMS of ~0.05 (-26 dBFS), uniformly across the live VAD
/// feed and the saved WAV (single source of truth).
///
/// ## Behaviour
/// - **Update gate**: gain only adapts on frames whose RMS exceeds the VAD
///   noise floor. Pure silence is passed through at the last-known gain so
///   the noise floor never gets amplified into garbage.
/// - **Attack** (signal louder than target, gain too high): ~200 ms time
///   constant — fast enough to prevent clipping on sudden voice onsets.
/// - **Release** (signal quieter than target, gain too low): ~2 s time
///   constant — slow enough to avoid pumping during natural speech pauses.
/// - **Soft clipper**: if `sample * gain` would exceed ±0.98, a `tanh`
///   soft-clip is applied instead of hard-clipping — preserves transients
///   without buzzing.
/// - **Gain bounds**: 1.0 ≤ gain ≤ 8.0. We never *attenuate* (that would
///   silently make a loud speaker quieter), and we cap at 8× so a muted
///   mic doesn't get artificially boosted into a roaring noise floor.
///
/// ## Threading
/// The controller is touched from the CoreAudio render thread inside the
/// `AVAudioEngine` input tap. There is exactly one writer; we mark the type
/// `@unchecked Sendable` so it can be captured into the tap closure without
/// fighting the Swift-6 isolation checker. Callers must not share a single
/// instance across two concurrent recorders.
final class AdaptiveGainController: @unchecked Sendable {
    /// Target observed RMS, ~-26 dBFS. Speech captured at this level
    /// comfortably clears the live VAD cutoff (0.012) and gives whisper
    /// enough dynamic range without risking clipping on transients.
    static let defaultTargetRMS: Float = 0.05
    /// Maximum gain. Caps amplification so a muted / disconnected mic
    /// doesn't get boosted into a roar.
    static let defaultMaxGain: Float = 8.0
    /// Minimum gain. 1.0 means "never attenuate" — a loud speaker passes
    /// through unchanged.
    static let defaultMinGain: Float = 1.0
    /// Threshold below which we treat the frame as silence and *hold* the
    /// last gain instead of adapting. Matches the live VAD's static cutoff
    /// (`UtteranceDetector.rmsThreshold`) so we adapt on the same frames
    /// the VAD treats as speech.
    static let defaultSilenceFloor: Float = 0.012
    /// Attack time-constant in seconds. ~200 ms — fast enough to bring the
    /// gain back down when speech turns out louder than expected.
    static let defaultAttackSeconds: Double = 0.2
    /// Release time-constant in seconds. ~2 s — slow enough that brief
    /// quiet patches inside speech don't make the gain pump up and down
    /// audibly.
    static let defaultReleaseSeconds: Double = 2.0
    /// Soft-clip threshold. Sample magnitudes above this get tanh-shaped
    /// back into [-1, 1) rather than being hard-limited.
    static let defaultSoftClipThreshold: Float = 0.98

    let targetRMS: Float
    let maxGain: Float
    let minGain: Float
    let silenceFloor: Float
    let attackSeconds: Double
    let releaseSeconds: Double
    let softClipThreshold: Float
    let sampleRate: Double

    /// Live readout for level meters and tests. Updated on each frame —
    /// safe to read from another thread for display because Swift `Float`
    /// loads/stores are atomic and we tolerate one-frame staleness.
    private(set) var currentGain: Float = 1.0
    /// `false` disables all adaptation and bypasses the soft clipper —
    /// output equals input bit-for-bit. Settings toggle.
    var enabled: Bool

    init(
        sampleRate: Double = 16_000,
        targetRMS: Float = defaultTargetRMS,
        maxGain: Float = defaultMaxGain,
        minGain: Float = defaultMinGain,
        silenceFloor: Float = defaultSilenceFloor,
        attackSeconds: Double = defaultAttackSeconds,
        releaseSeconds: Double = defaultReleaseSeconds,
        softClipThreshold: Float = defaultSoftClipThreshold,
        enabled: Bool = true
    ) {
        self.sampleRate = sampleRate
        self.targetRMS = targetRMS
        self.maxGain = maxGain
        self.minGain = minGain
        self.silenceFloor = silenceFloor
        self.attackSeconds = attackSeconds
        self.releaseSeconds = releaseSeconds
        self.softClipThreshold = softClipThreshold
        self.enabled = enabled
    }

    /// Reset internal state. Call when starting a fresh recording so the
    /// gain doesn't begin where the previous session left off.
    func reset() {
        currentGain = 1.0
    }

    /// Apply gain in-place to a mono Float32 channel buffer. Computes the
    /// frame's RMS, updates the smoothed gain (if signal is above the
    /// silence floor), and writes the gained + soft-clipped samples back
    /// into `samples`.
    ///
    /// `frameDurationSeconds` is the elapsed wall-clock time the frame
    /// represents; used to convert the attack/release time-constants into
    /// per-frame smoothing coefficients. For a 30 ms frame this is `0.030`.
    func process(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        guard count > 0 else { return }
        if !enabled {
            // Bypass: output equals input. Do NOT touch `currentGain` — the
            // soft-clipper / level meter shouldn't claim to be doing
            // anything.
            currentGain = 1.0
            return
        }

        // 1) Compute the frame's RMS via vDSP (faster than a Swift loop and
        //    keeps this safe to call on the audio render thread).
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))

        // 2) Adapt the gain only when there's signal — never amplify pure
        //    room hum. If the frame is below the silence floor, hold the
        //    last gain and skip straight to applying it.
        if rms >= silenceFloor {
            let desired = clamp(targetRMS / max(rms, 1e-6),
                                lower: minGain,
                                upper: maxGain)
            // Attack (desired < currentGain, signal too loud) vs release
            // (desired > currentGain, signal too quiet). Convert the
            // time-constant into a 0…1 blend factor using the frame's
            // wall-clock duration: alpha = 1 - exp(-dt / tau).
            let frameDuration = Double(count) / sampleRate
            let tau = (desired < currentGain) ? attackSeconds : releaseSeconds
            let alpha = Float(1.0 - exp(-frameDuration / max(tau, 1e-6)))
            currentGain += (desired - currentGain) * alpha
            // Defensive clamp — shouldn't be needed but keeps rounding
            // errors from drifting outside [minGain, maxGain] over a long
            // recording.
            currentGain = clamp(currentGain, lower: minGain, upper: maxGain)
        }

        // 3) Apply the gain. With min=1, gain==1 is a no-op so skip the
        //    multiply (most loud-speaker frames hit this path).
        let g = currentGain
        if g != 1.0 {
            vDSP_vsmul(samples, 1, [g], samples, 1, vDSP_Length(count))
        }

        // 4) Soft-clip any sample whose magnitude exceeds the threshold.
        //    The bulk of speech frames won't trigger this; we pay the loop
        //    only on the few transients that need protection.
        let threshold = softClipThreshold
        for i in 0..<count {
            let s = samples[i]
            if s > threshold {
                samples[i] = softClip(s, threshold: threshold)
            } else if s < -threshold {
                samples[i] = -softClip(-s, threshold: threshold)
            }
        }
    }

    /// Convenience wrapper for an `[Float]` array. Returns the gained
    /// samples (out-of-place). Used by the unit tests and any caller that
    /// would rather not deal with raw pointers.
    func process(_ samples: [Float]) -> [Float] {
        var out = samples
        out.withUnsafeMutableBufferPointer { buf in
            if let base = buf.baseAddress {
                process(base, count: buf.count)
            }
        }
        return out
    }

    // MARK: - Helpers

    @inline(__always)
    private func clamp(_ x: Float, lower: Float, upper: Float) -> Float {
        min(max(x, lower), upper)
    }

    /// Smooth saturator: keeps `output` strictly inside ±1 even for very
    /// large inputs, with a continuous derivative across the threshold so
    /// there's no audible kink. We blend in a `tanh` shape above the
    /// threshold (and reflect symmetrically below). The headroom term
    /// `(1 - threshold)` ensures the output asymptote stays just below
    /// ±1 instead of saturating to exactly ±1.
    @inline(__always)
    private func softClip(_ x: Float, threshold: Float) -> Float {
        // `excess` ≥ 0; tanh(excess / headroom) is in [0, 1).
        let headroom = max(1.0 - threshold, 1e-6)
        let excess = x - threshold
        return threshold + headroom * tanh(excess / headroom)
    }
}
