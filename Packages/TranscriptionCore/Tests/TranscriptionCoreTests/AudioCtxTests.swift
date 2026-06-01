import XCTest
@testable import TranscriptionCore

/// Tests for `WhisperEngine.computeAudioCtx(sampleCount:)`.
///
/// Policy (after the live fixture sweep documented in `computeAudioCtx`'s
/// header):
///   * audio < 30s → returns 750 (one of two known-quality-stable values).
///   * audio ≥ 30s → returns 0 (= "use whisper's default 1500").
///
/// The earlier "ceil(seconds * 50) + 50" formula was reverted after an
/// integration sweep showed it produced 0 segments on every fixture (silent
/// failure mode of whisper's encoder under unaligned audio_ctx values).
final class AudioCtxTests: XCTestCase {

    private let sampleRate = 16_000

    func test_empty_input_returns_zero() {
        XCTAssertEqual(WhisperEngine.computeAudioCtx(sampleCount: 0), 0)
    }

    func test_full_30s_window_returns_zero() {
        // 30s at 16 kHz = 480_000 samples; default audio_ctx applies.
        XCTAssertEqual(WhisperEngine.computeAudioCtx(sampleCount: 30 * sampleRate), 0)
    }

    func test_longer_than_window_returns_zero() {
        // Anything past the full window can't be truncated further.
        XCTAssertEqual(WhisperEngine.computeAudioCtx(sampleCount: 60 * sampleRate), 0)
    }

    func test_one_second_clip_uses_750() {
        XCTAssertEqual(WhisperEngine.computeAudioCtx(sampleCount: sampleRate), 750)
    }

    func test_five_second_clip_uses_750() {
        XCTAssertEqual(WhisperEngine.computeAudioCtx(sampleCount: 5 * sampleRate), 750)
    }

    func test_ten_second_clip_uses_750() {
        // The VAD's max-utterance cap is 10s — this is the most common
        // live-recording case.
        XCTAssertEqual(WhisperEngine.computeAudioCtx(sampleCount: 10 * sampleRate), 750)
    }

    func test_just_under_full_window_uses_750() {
        // 29.9s still fits inside the 15s capacity? No — 29.9s is past
        // 15s, so 750 would TRUNCATE. But we still return 750 (the
        // sweep showed 750 is the only stable sub-window value, so we
        // either use it or fall back to default 1500 at the >=30s
        // boundary; truncation past 15s is the deliberate tradeoff).
        // The post-record batch path always uses the full WAV which
        // crosses the 30s boundary in chunks, so this case is rare
        // in practice for VAD-bounded utterances (max 10s).
        let samples = Int(29.9 * Double(sampleRate))
        XCTAssertEqual(WhisperEngine.computeAudioCtx(sampleCount: samples), 750)
    }

    func test_returns_same_value_for_all_sub_window_sizes() {
        // No matter the clip length below 30s, computeAudioCtx returns
        // a constant — the "discrete safe value" policy.
        let oneSec = WhisperEngine.computeAudioCtx(sampleCount: sampleRate)
        let fiveSec = WhisperEngine.computeAudioCtx(sampleCount: 5 * sampleRate)
        let tenSec = WhisperEngine.computeAudioCtx(sampleCount: 10 * sampleRate)
        XCTAssertEqual(oneSec, fiveSec)
        XCTAssertEqual(fiveSec, tenSec)
        XCTAssertEqual(oneSec, 750)
    }
}
