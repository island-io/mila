import XCTest
@testable import TranscriptionCore

final class NormalizeTests: XCTestCase {

    /// `normalize` works in place; these tests read its result as a value.
    private func normalized(_ input: [Float]) -> [Float] {
        var samples = input
        WhisperEngine.normalize(&samples)
        return samples
    }

    func test_empty_input_returns_empty() {
        let result = normalized([])
        XCTAssertTrue(result.isEmpty)
    }

    func test_silence_returns_silence() {
        let result = normalized([0, 0, 0])
        XCTAssertEqual(result, [0, 0, 0])
    }

    func test_loud_signal_is_not_boosted() {
        let input: [Float] = [0.5, -0.5, 0.3]
        let result = normalized(input)
        XCTAssertEqual(result, input)
    }

    func test_quiet_signal_is_boosted_toward_target() {
        let input: [Float] = [0.01, -0.01]
        let result = normalized(input)
        let peak = result.map { abs($0) }.max()!
        XCTAssertGreaterThan(peak, 0.1)
    }

    func test_gain_is_capped_at_20x() {
        let input: [Float] = [0.001]
        let result = normalized(input)
        XCTAssertEqual(result[0], 0.02, accuracy: 0.001)
    }

    func test_output_is_clamped_to_minus_one_one() {
        let input: [Float] = [0.1, -0.08]
        let result = normalized(input)
        for s in result {
            XCTAssertGreaterThanOrEqual(s, -1.0)
            XCTAssertLessThanOrEqual(s, 1.0)
        }
    }

    // MARK: - In place (#403)

    /// The copying `normalize` this replaced, with its `peakMagnitude` call
    /// written out so the reference shares no code with what it checks. The
    /// in-place version must produce the same bits for every input.
    private static func referenceNormalize(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }
        var peak: Float = 0
        for s in samples { let a = abs(s); if a > peak { peak = a } }
        guard peak > 0 else { return samples }
        let target: Float = 0.5
        let gain = min(target / peak, 20.0)
        if gain <= 1.05 { return samples }
        var out = samples
        for i in 0..<out.count { out[i] = max(-1, min(1, out[i] * gain)) }
        return out
    }

    private func assertMatchesReference(_ input: [Float], file: StaticString = #filePath, line: UInt = #line) {
        // Bit patterns, so NaN compares equal to NaN and -0 differs from +0.
        XCTAssertEqual(normalized(input).map(\.bitPattern),
                       Self.referenceNormalize(input).map(\.bitPattern),
                       file: file, line: line)
    }

    func test_inPlace_matches_the_copying_normalize() {
        assertMatchesReference([])
        assertMatchesReference([0, 0, 0])
        assertMatchesReference([0.5, -0.5, 0.3])          // gain ≤ 1.05: untouched
        assertMatchesReference([0.48, -0.2])              // just under the 1.05 threshold
        assertMatchesReference([0.01, -0.01, 0.004])      // gain 50 → capped at 20
        assertMatchesReference([0.1, -0.08, 0.05])        // gain 5
        assertMatchesReference([-0.25, 0.125, -0.0])      // negative peak, signed zero
        let subnormal = Float.leastNormalMagnitude / 8
        assertMatchesReference([subnormal, -3 * subnormal, 0.002])  // subnormals
        assertMatchesReference([.infinity, 0.1])          // infinite peak → gain 0 → untouched
        assertMatchesReference([.nan, 0.1, -0.05])        // NaN skipped by the peak, mapped like before
        assertMatchesReference([.nan, .nan])
    }

    func test_inPlace_matches_the_copying_normalize_on_random_audio() {
        // Deterministic so a failure reproduces.
        var rng = SplitMix64(seed: 0x1D4_0403)
        for _ in 0..<50 {
            let count = Int(rng.next() % 4_000) + 1
            let scale = Float(rng.next() % 1_000 + 1) / 2_000   // peak 0.0005…0.5
            let input = (0..<count).map { _ in
                (Float(rng.next() % 2_000_001) / 1_000_000 - 1) * scale
            }
            assertMatchesReference(input)
        }
    }

    func test_normalize_writes_into_the_callers_buffer() {
        // The point of #403: a uniquely owned buffer is scaled where it is,
        // not copied into a second full-size array.
        var samples = [Float](repeating: 0.01, count: 16_000)
        let before = samples.withUnsafeBufferPointer { $0.baseAddress }
        WhisperEngine.normalize(&samples)
        let after = samples.withUnsafeBufferPointer { $0.baseAddress }
        XCTAssertEqual(before, after)
        XCTAssertEqual(samples[0], 0.2, accuracy: 1e-6)   // gain 20 was applied
    }

    func test_transcribe_requirement_takes_ownership_across_the_actor_hop() async throws {
        // The same call shape `TranscriptionService` uses for the batch pass:
        // `transcribe(samples: consume samples)` through `any
        // TranscribingEngine`, across an actor hop, here into a probe engine.
        // It does not run `TranscriptionService` itself, so it cannot catch
        // that call site gaining a second holder of `samples`; it pins the
        // protocol half. With the requirement declared `consuming`, the
        // engine receives the caller's buffer itself, so its in-place gain
        // does not copy. A borrowed parameter would leave the caller holding
        // a second reference and the first write would copy the whole
        // recording.
        //
        // Toolchain canary: this checks what the compiler builds, which the
        // language does not promise. If it fails with no Mila change, the
        // compiler now copies while forwarding the argument. Swift 6.2
        // (Xcode 26) and 6.4 (Xcode 27) pass it in debug and release. Swift
        // 5.10, which only the Linux package-test job uses, does not: there
        // the argument still arrives with a second reference, so the gain
        // copies, which is the cost from before #403 and nothing worse. The
        // app is built only with Xcode, so 5.x skips the address check.
        let engine: any TranscribingEngine = OwnershipProbeEngine()
        let samples = [Float](repeating: 0.01, count: 16_000)
        let callerAddress = samples.withUnsafeBufferPointer { Int(bitPattern: $0.baseAddress) }
        let probe = try await engine.transcribe(samples: consume samples, language: "en",
                                                audioCtx: 0, progress: nil, isCancelled: nil)
        // Copy-on-write keeps a shared buffer's address until something
        // writes to it, so the addresses only prove anything if the gain
        // was actually applied.
        XCTAssertEqual(probe.first?.start ?? 0, 0.2, accuracy: 1e-6,
                       "the probe must write to the buffer (gain 20 on a 0.01 signal)")
        #if compiler(<6.0)
        _ = callerAddress
        throw XCTSkip("""
            Swift 5.x keeps a second reference to a consumed argument across \
            this call, so the in-place gain copies; the app is built with Swift 6.
            """)
        #else
        let addresses = probe.first?.text.split(separator: " ").compactMap { Int($0) } ?? []
        XCTAssertEqual(addresses, [callerAddress, callerAddress], """
            The engine did not receive the caller's buffer. If no Mila code \
            changed, this toolchain copies a consumed argument across the \
            existential/actor boundary, and #403's saving is gone on it.
            """)
        #endif
    }

    // MARK: - peakMagnitude

    func test_peakMagnitude_matches_the_allocating_formulation() {
        let input: [Float] = [0.1, -0.7, 0.3, 0.69]
        XCTAssertEqual(WhisperEngine.peakMagnitude(input), input.map { abs($0) }.max()!)
        XCTAssertEqual(WhisperEngine.peakMagnitude([]), 0)
        XCTAssertEqual(WhisperEngine.peakMagnitude([0, 0]), 0)
        // A NaN after the first element never won `max()` either.
        let midNaN: [Float] = [-0.4, .nan, 0.2]
        XCTAssertEqual(WhisperEngine.peakMagnitude(midNaN), midNaN.map { abs($0) }.max()!)
    }

    /// Deliberate change for a LEADING NaN: `max()` seeded with it and
    /// returned NaN; the helper skips it like `normalize`'s loop always did.
    func test_peakMagnitude_ignores_nan() {
        XCTAssertEqual(WhisperEngine.peakMagnitude([.nan, -0.4, 0.2]), 0.4)
        XCTAssertEqual(WhisperEngine.peakMagnitude([.nan, .nan]), 0)
    }
}

/// Reports where its `samples` buffer lived on arrival and after the same
/// in-place gain `WhisperEngine.transcribe` applies, and (as `start`) the
/// first sample after that gain, which shows a write happened.
private actor OwnershipProbeEngine: TranscribingEngine {
    func loadIfNeeded(modelURL: URL, displayName: String) async throws {}

    func transcribe(samples: consuming [Float],
                    language: String,
                    audioCtx: Int32?,
                    progress: (@Sendable (Float) -> Void)?,
                    isCancelled: (@Sendable () -> Bool)?) throws -> [TranscriptSegment] {
        let arrived = samples.withUnsafeBufferPointer { Int(bitPattern: $0.baseAddress) }
        WhisperEngine.normalize(&samples)
        let scaled = samples.withUnsafeBufferPointer { Int(bitPattern: $0.baseAddress) }
        return [TranscriptSegment(start: Double(samples.first ?? 0), end: 0,
                                  text: "\(arrived) \(scaled)")]
    }

    func shutdown() async {}
}

/// Small deterministic generator for the randomized parity test.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
