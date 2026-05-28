import XCTest
@testable import Mila

final class AdaptiveGainControllerTests: XCTestCase {

    // MARK: - Helpers

    /// Generate a sine wave at the given peak amplitude. The RMS of a sine
    /// is `amplitude / sqrt(2)`, so a -40 dBFS RMS target corresponds to
    /// peak ≈ 0.01414.
    private func sine(amplitude: Float,
                      durationSeconds: Double = 0.5,
                      frequencyHz: Double = 440,
                      sampleRate: Double = 16_000) -> [Float] {
        let count = Int(durationSeconds * sampleRate)
        var out = [Float](repeating: 0, count: count)
        let twoPi = 2.0 * Double.pi
        for i in 0..<count {
            let phase = twoPi * frequencyHz * Double(i) / sampleRate
            out[i] = Float(sin(phase)) * amplitude
        }
        return out
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Drive `controller` with `chunk` repeatedly for `seconds` of audio.
    /// Returns the gained samples from the *final* chunk so callers can
    /// measure the steady-state RMS after attack/release has settled.
    private func drive(_ controller: AdaptiveGainController,
                       chunk: [Float],
                       seconds: Double,
                       sampleRate: Double = 16_000) -> [Float] {
        let chunkDuration = Double(chunk.count) / sampleRate
        let chunkCount = max(1, Int((seconds / chunkDuration).rounded(.up)))
        var last: [Float] = []
        for _ in 0..<chunkCount {
            last = controller.process(chunk)
        }
        return last
    }

    /// Convert a linear RMS to dBFS. Returns `-inf` for zero input.
    private func dBFS(_ rmsValue: Float) -> Float {
        guard rmsValue > 0 else { return -.infinity }
        return 20 * log10(rmsValue)
    }

    // MARK: - Tests

    /// Constant low-level input (~-34 dBFS RMS, just above the silence
    /// floor at 0.012) should be raised toward the -26 dBFS target.
    /// Allow ±2 dB tolerance and ~4 release time-constants to settle.
    func test_lowLevelSine_settlesNearTarget() {
        let controller = AdaptiveGainController()
        // RMS ≈ 0.02 (well above the 0.012 silence floor so adaptation
        // engages). amplitude = 0.02 * sqrt(2) for a sine of that RMS.
        let amplitude: Float = 0.02 * sqrt(2)
        // Use 30 ms chunks (matches the live VAD frame size) so the
        // attack/release dt mapping in `process` is realistic.
        let chunk = sine(amplitude: amplitude, durationSeconds: 0.030)
        // Drive for 8 seconds (4× the release time-constant) so the
        // smoother is well within ε of steady state.
        let final = drive(controller, chunk: chunk, seconds: 8.0)

        let outRMS = rms(final)
        let outDb = dBFS(outRMS)
        let targetDb = dBFS(AdaptiveGainController.defaultTargetRMS)
        XCTAssertEqual(outDb, targetDb, accuracy: 2.0,
                       "settled RMS \(outDb) dBFS should be within ±2 dB of target \(targetDb) dBFS (gain=\(controller.currentGain))")
    }

    /// A full-scale signal should be passed through at gain == 1 —
    /// never attenuate, and never soft-clip a signal that's already at or
    /// below the soft-clip threshold.
    func test_fullScaleSine_holdsGainAtOne_noClipping() {
        let controller = AdaptiveGainController()
        // 0 dBFS sine has peak amplitude 1.0 and RMS 1/sqrt(2) ≈ 0.707.
        // Use 0.95 to stay just under the 0.98 soft-clip threshold so we
        // can assert the output equals the input bit-for-bit.
        let chunk = sine(amplitude: 0.95, durationSeconds: 0.030)
        let final = drive(controller, chunk: chunk, seconds: 2.0)

        XCTAssertEqual(controller.currentGain, 1.0, accuracy: 1e-6,
                       "gain must be clamped to 1.0 on loud input (minGain == 1)")
        // Output samples should equal input (no clipping, no scaling).
        for (a, b) in zip(chunk, final) {
            XCTAssertEqual(a, b, accuracy: 1e-6)
        }
    }

    /// Pure silence should HOLD the last-known gain rather than ramp the
    /// noise floor up. We pre-condition the controller with a loud signal
    /// (gain → 1) and then a stretch of silence; gain must stay at 1.
    func test_silence_holdsLastGain() {
        let controller = AdaptiveGainController()
        // Drive a loud signal first so the gain converges to 1 (loud
        // signal -> desired gain pinned to minGain).
        let loud = sine(amplitude: 0.5, durationSeconds: 0.030)
        _ = drive(controller, chunk: loud, seconds: 1.0)
        XCTAssertEqual(controller.currentGain, 1.0, accuracy: 1e-3)

        // Now feed 5 s of pure silence (well below the silence floor).
        // The gain MUST NOT ramp toward maxGain — that would amplify
        // room hum into audible noise on the live feed.
        let silence = [Float](repeating: 0, count: 480)  // 30 ms @ 16 kHz
        let final = drive(controller, chunk: silence, seconds: 5.0)

        XCTAssertEqual(controller.currentGain, 1.0, accuracy: 1e-3,
                       "silence must NOT raise gain — held last value should still be 1.0")
        // Output is gain × silence == silence. No NaN, no infinities.
        for s in final {
            XCTAssertEqual(s, 0, accuracy: 1e-9)
        }
    }

    /// Silence after a quiet signal should also hold (not continue ramping).
    /// Pre-condition with a low-level signal (gain converges high), then
    /// silence — gain must stay at the high value, NOT keep rising.
    func test_silence_doesNotKeepRising() {
        let controller = AdaptiveGainController()
        // RMS ≈ 0.02 — above the silence floor (0.012) so adaptation
        // engages and pushes the gain up toward target / RMS = 2.5×.
        let lowSignal = sine(amplitude: 0.02 * sqrt(2),
                              durationSeconds: 0.030)
        _ = drive(controller, chunk: lowSignal, seconds: 8.0)
        let gainAfterSpeech = controller.currentGain
        // Sanity: gain should be elevated (we were boosting low signal).
        XCTAssertGreaterThan(gainAfterSpeech, 2.0)

        let silence = [Float](repeating: 0, count: 480)
        _ = drive(controller, chunk: silence, seconds: 5.0)

        XCTAssertEqual(controller.currentGain, gainAfterSpeech, accuracy: 1e-4,
                       "gain must hold during silence — observed drift")
    }

    /// A sudden loud transient must not produce out-of-range output.
    /// Pre-condition gain toward its max by driving a signal just above
    /// the silence floor, then slam in a near-full-scale buffer; output
    /// must stay inside [-1, +1] thanks to the soft-clipper.
    func test_softClipper_keepsOutputInRange() {
        // Use a custom controller with a very low silence floor so we can
        // push the gain near the max with a small-amplitude signal. The
        // production controller's silence floor (0.012) prevents
        // amplifying ambient noise — that gate is verified by the
        // silence tests; here we only care that the soft-clipper handles
        // large-magnitude post-gain samples correctly.
        let controller = AdaptiveGainController(silenceFloor: 0.0001)
        let tinyChunk = sine(amplitude: 0.001, durationSeconds: 0.030)
        // Drive for ~10× the release time-constant (2.0s) so the smoother
        // gets to within 0.005% of the max gain. 10s only gets ~99.3% of
        // the way (gain ≈ 7.953), which fails a ±0.01 tolerance check.
        _ = drive(controller, chunk: tinyChunk, seconds: 20.0)
        // Gain should be pinned at the max (target/RMS would be ~70).
        XCTAssertEqual(controller.currentGain,
                       AdaptiveGainController.defaultMaxGain,
                       accuracy: 0.01)

        // Now slam a near-FS impulse. With gain == 8, samples become
        // 8 × 0.99 ≈ 7.9 — far above the soft-clip threshold (0.98).
        var loud = [Float](repeating: 0.5, count: 480)
        loud[100] = 0.99
        loud[200] = -0.99
        let out = controller.process(loud)

        for s in out {
            XCTAssertTrue(s.isFinite, "soft-clip produced non-finite sample")
            XCTAssertLessThanOrEqual(s, 1.0, "output exceeded +1.0 (saw \(s))")
            XCTAssertGreaterThanOrEqual(s, -1.0, "output below -1.0 (saw \(s))")
        }
    }

    /// When the toggle is off, the controller is a pure pass-through.
    /// Output equals input bit-for-bit and `currentGain` stays at 1.
    func test_bypass_whenDisabled_outputEqualsInput() {
        let controller = AdaptiveGainController(enabled: false)
        // Low-level signal that would otherwise be amplified ~5x.
        let chunk = sine(amplitude: 0.01, durationSeconds: 0.030)
        let out = controller.process(chunk)

        XCTAssertEqual(controller.currentGain, 1.0)
        XCTAssertEqual(out.count, chunk.count)
        for (a, b) in zip(chunk, out) {
            XCTAssertEqual(a, b)
        }

        // Also after several iterations.
        let final = drive(controller, chunk: chunk, seconds: 2.0)
        for (a, b) in zip(chunk, final) {
            XCTAssertEqual(a, b)
        }
    }

    /// Sanity: gain only adapts upward — never below 1.0 — even on a very
    /// loud sustained input. Protects against a future tweak that would
    /// silently attenuate a loud speaker.
    func test_neverAttenuates() {
        let controller = AdaptiveGainController()
        // 0.9 amplitude sine has RMS ≈ 0.636 — way above any reasonable
        // target. If we allowed attenuation, gain would drop to ~0.08.
        let loud = sine(amplitude: 0.9, durationSeconds: 0.030)
        _ = drive(controller, chunk: loud, seconds: 4.0)
        XCTAssertGreaterThanOrEqual(controller.currentGain, 1.0)
    }

    /// Reset wipes the gain back to 1 (fresh recording starts).
    func test_reset_clearsGain() {
        let controller = AdaptiveGainController()
        // RMS ≈ 0.02, just above the silence floor so adaptation engages.
        let lowSignal = sine(amplitude: 0.02 * sqrt(2),
                              durationSeconds: 0.030)
        _ = drive(controller, chunk: lowSignal, seconds: 8.0)
        XCTAssertGreaterThan(controller.currentGain, 1.5)
        controller.reset()
        XCTAssertEqual(controller.currentGain, 1.0)
    }
}
