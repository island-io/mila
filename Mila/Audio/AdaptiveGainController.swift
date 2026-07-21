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
/// - **Update gate**: gain only adapts on frames whose RMS clearly exceeds
///   the *observed* room noise floor — the MINIMUM frame RMS over the
///   last `noiseFloorWindowSeconds` (two half-window buckets, classic
///   minimum statistics). The minimum is the right statistic: speech
///   pauses within any window pin the floor at true room tone no matter
///   how loud or continuous the talking is, so quiet speech keeps
///   clearing the gate — while sustained hum, which never pauses, becomes
///   the window minimum within one window and gates itself off. (An
///   earlier EMA-toward-signal variant regressed the quiet-mic fix: in a
///   room with elevated tone it settled at the AVERAGE level and parked
///   the gate on top of quiet speech.) Pure silence is passed through at
///   the last-known gain so the noise floor never gets amplified into
///   garbage.
///
///   The gate was previously a static 0.012 — the same value as the live
///   VAD's speech cutoff — which made the controller useless in exactly
///   the scenario it was built for: speech quieter than 0.012 never
///   adapted the gain, so it stayed below the VAD cutoff forever and the
///   live transcript sat empty for the whole recording (observed on a
///   MacBook Pro built-in mic at ~0.004-0.010 RMS speech).
///
/// - **Sustained-noise relaxation**: hum that starts mid-recording (AC
///   kicking in after a quiet stretch) briefly clears the gate while the
///   floor catches up, picking up some gain. Any gain acquired that way
///   must not stick: after `noiseRelaxAfterSeconds` of *continuous*
///   below-gate (but non-silent) signal, the gain decays back toward 1
///   with a `noiseRelaxSeconds` time constant. Ordinary speech pauses are
///   far shorter than the trigger, so hold semantics are preserved for
///   conversation; only genuinely sustained noise unwinds the gain.
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
    /// Absolute minimum RMS below which a frame can never adapt the gain,
    /// regardless of how quiet the observed noise floor is. Keeps a dead-
    /// silent room (floor ≈ 0) from letting sub-audible rumble adapt.
    /// Deliberately far below the VAD cutoff (0.012): frames between the
    /// two are exactly the quiet speech this controller exists to boost.
    static let defaultSilenceFloor: Float = 0.002
    /// The adaptation gate is `max(silenceFloor, noiseFloor × this)`. 4×
    /// sits between room tone (the floor itself, fluctuating up to ~2-3×
    /// its own minimum) and quiet speech (≥ 5-10× the floor) — hum near
    /// the floor holds the gain, speech adapts it. Observed field values
    /// that must stay separated: room-tone minimum ~0.0005-0.0015 on a
    /// MacBook Pro built-in mic vs quiet-speech frames ~0.004-0.010.
    static let defaultNoiseFloorMultiplier: Float = 4.0
    /// Length of the minimum-statistics window. Hum that starts after a
    /// silent stretch owns the floor once the window has fully rotated
    /// past the silence — ≤ 12 s — bounding how long its onset can keep
    /// adapting the gain. Conversation always pauses within any 12 s
    /// span, so speech never becomes its own floor.
    static let defaultNoiseFloorWindowSeconds: Double = 12.0
    /// How long the signal must sit continuously below the adaptation
    /// gate (but above dead silence) before the gain starts relaxing
    /// back toward 1. Longer than any conversational pause or single
    /// utterance, shorter than "the AC has clearly been on for a while".
    static let defaultNoiseRelaxAfterSeconds: Double = 15.0
    /// Time constant of that relaxation once it engages. ~20 s unwinds
    /// a hum-acquired gain within half a minute without audible pumping.
    static let defaultNoiseRelaxSeconds: Double = 20.0
    /// RMS below which a frame counts as dead silence: the gain holds
    /// and the sustained-noise run is reset (silence is not noise). Well
    /// below any real room tone; digital zero-fill and muted inputs land
    /// here.
    static let defaultDeadSilenceFloor: Float = 1e-4
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
    let noiseFloorMultiplier: Float
    let noiseFloorWindowSeconds: Double
    let noiseRelaxAfterSeconds: Double
    let noiseRelaxSeconds: Double
    let deadSilenceFloor: Float
    let attackSeconds: Double
    let releaseSeconds: Double
    let softClipThreshold: Float
    let sampleRate: Double

    /// Live readout for level meters and tests. Updated on each frame —
    /// safe to read from another thread for display because Swift `Float`
    /// loads/stores are atomic and we tolerate one-frame staleness.
    private(set) var currentGain: Float = 1.0
    /// Minimum-statistics estimate of the room's background RMS: the
    /// minimum frame RMS over the last `noiseFloorWindowSeconds`, via two
    /// half-window buckets. Negative sentinel = "no frame seen yet";
    /// seeded from the first frame so a recording that starts inside
    /// steady hum treats that hum as floor from sample one. Read-only
    /// outside for tests/diagnostics.
    private(set) var observedNoiseFloor: Float = -1
    /// Current and previous half-window minimum buckets backing
    /// `observedNoiseFloor`, plus how much of the current half-window
    /// has elapsed. `.infinity` = bucket empty.
    private var windowMin: Float = .infinity
    private var prevWindowMin: Float = .infinity
    private var windowElapsed: Double = 0
    /// Seconds of *continuous* below-gate, above-dead-silence signal seen
    /// so far. Crossing `noiseRelaxAfterSeconds` engages the gain
    /// relaxation; any speech frame or dead-silence frame resets it.
    private var sustainedNoiseSeconds: Double = 0
    /// `false` disables all adaptation and bypasses the soft clipper —
    /// output equals input bit-for-bit. Settings toggle.
    var enabled: Bool

    init(
        sampleRate: Double = 16_000,
        targetRMS: Float = defaultTargetRMS,
        maxGain: Float = defaultMaxGain,
        minGain: Float = defaultMinGain,
        silenceFloor: Float = defaultSilenceFloor,
        noiseFloorMultiplier: Float = defaultNoiseFloorMultiplier,
        noiseFloorWindowSeconds: Double = defaultNoiseFloorWindowSeconds,
        noiseRelaxAfterSeconds: Double = defaultNoiseRelaxAfterSeconds,
        noiseRelaxSeconds: Double = defaultNoiseRelaxSeconds,
        deadSilenceFloor: Float = defaultDeadSilenceFloor,
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
        self.noiseFloorMultiplier = noiseFloorMultiplier
        self.noiseFloorWindowSeconds = noiseFloorWindowSeconds
        self.noiseRelaxAfterSeconds = noiseRelaxAfterSeconds
        self.noiseRelaxSeconds = noiseRelaxSeconds
        self.deadSilenceFloor = deadSilenceFloor
        self.attackSeconds = attackSeconds
        self.releaseSeconds = releaseSeconds
        self.softClipThreshold = softClipThreshold
        self.enabled = enabled
    }

    /// Reset internal state. Call when starting a fresh recording so the
    /// gain doesn't begin where the previous session left off.
    func reset() {
        currentGain = 1.0
        observedNoiseFloor = -1
        windowMin = .infinity
        prevWindowMin = .infinity
        windowElapsed = 0
        sustainedNoiseSeconds = 0
    }

    /// Apply gain in-place to a mono Float32 channel buffer. Computes the
    /// frame's RMS, updates the windowed-minimum noise floor and the
    /// adaptation gate derived from it, updates the smoothed gain (adapting
    /// toward target when the gate is cleared, relaxing back toward 1
    /// after sustained below-gate noise, holding through everything else),
    /// and writes the gained + soft-clipped samples back into `samples`.
    ///
    /// The frame's wall-clock duration — `count / sampleRate` — converts
    /// the floor-window/attack/release/relax time-constants into per-frame
    /// smoothing coefficients. For a 30 ms frame this is `0.030`.
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
        let frameDuration = Double(count) / sampleRate

        // 2) Track the room's noise floor as the MINIMUM frame RMS over
        //    the last window (two half-window buckets). Speech pauses
        //    within any window pin the floor at true room tone — the
        //    floor must NOT follow the average signal (an earlier EMA
        //    variant did, and in a room with elevated tone it parked
        //    the gate on top of quiet speech). A signal that never
        //    pauses — hum, fan, AC — owns the window minimum once the
        //    window rotates past whatever preceded it, so a
        //    mid-recording hum onset gates itself off within
        //    `noiseFloorWindowSeconds`.
        let clampedRMS = max(rms, 1e-6)
        windowMin = min(windowMin, clampedRMS)
        windowElapsed += frameDuration
        if windowElapsed >= noiseFloorWindowSeconds / 2 {
            prevWindowMin = windowMin
            windowMin = clampedRMS
            windowElapsed = 0
        }
        observedNoiseFloor = min(windowMin, prevWindowMin)

        // 3) Adapt the gain only when the frame is clearly above the
        //    observed floor — never amplify room hum toward the VAD's
        //    trigger range. Below the gate: hold the last gain through
        //    ordinary speech pauses, but if the signal sits below the
        //    gate CONTINUOUSLY for noiseRelaxAfterSeconds while staying
        //    above dead silence (i.e. it's sustained noise, not a
        //    pause), relax the gain back toward 1 — this unwinds any
        //    gain picked up in the brief window where a mid-recording
        //    hum onset cleared the gate before the floor caught up.
        let adaptGate = max(silenceFloor, observedNoiseFloor * noiseFloorMultiplier)
        if rms >= adaptGate {
            sustainedNoiseSeconds = 0
            let desired = clamp(targetRMS / max(rms, 1e-6),
                                lower: minGain,
                                upper: maxGain)
            // Attack (desired < currentGain, signal too loud) vs release
            // (desired > currentGain, signal too quiet). Convert the
            // time-constant into a 0…1 blend factor using the frame's
            // wall-clock duration: alpha = 1 - exp(-dt / tau).
            let tau = (desired < currentGain) ? attackSeconds : releaseSeconds
            let alpha = Float(1.0 - exp(-frameDuration / max(tau, 1e-6)))
            currentGain += (desired - currentGain) * alpha
            // Defensive clamp — shouldn't be needed but keeps rounding
            // errors from drifting outside [minGain, maxGain] over a long
            // recording.
            currentGain = clamp(currentGain, lower: minGain, upper: maxGain)
        } else if rms >= deadSilenceFloor {
            sustainedNoiseSeconds += frameDuration
            if sustainedNoiseSeconds >= noiseRelaxAfterSeconds, currentGain > minGain {
                let alpha = Float(1.0 - exp(-frameDuration / max(noiseRelaxSeconds, 1e-6)))
                currentGain += (minGain - currentGain) * alpha
            }
        } else {
            // Dead silence: hold the gain and reset the noise run —
            // silence is not sustained noise.
            sustainedNoiseSeconds = 0
        }

        // 4) Apply the gain. With min=1, gain==1 is a no-op so skip the
        //    multiply (most loud-speaker frames hit this path).
        let g = currentGain
        if g != 1.0 {
            vDSP_vsmul(samples, 1, [g], samples, 1, vDSP_Length(count))
        }

        // 5) Soft-clip any sample whose magnitude exceeds the threshold.
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
