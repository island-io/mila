import XCTest
import AVFoundation
import os
import TranscriptionCore
@testable import Mila

/// Only the FIRST app-audio or meeting recording after launch used to capture
/// app audio. `SystemAudioRecorder.audioStream` was one `AsyncStream` for the
/// life of the process; `RecordingSession.stop()` cancels the task iterating
/// it, and cancelling an `AsyncStream`'s consumer terminates the stream for
/// good. Every later session then ran a healthy SCStream whose buffers went
/// nowhere — an app-audio recording of a whole Zoom call saved 0 samples, and
/// meetings silently lost the other side (the mic clock kept `writes` looking
/// normal).
///
/// These drive two back-to-back sessions through the `bringUpOverride` seam,
/// since ScreenCaptureKit can't run on CI.
@MainActor
final class SystemAudioSessionStreamTests: XCTestCase {

    /// The recorder-level contract, consumed exactly the way `RecordingSession`
    /// consumes it: iterate after `start()`, cancel the iterating task after
    /// `stop()`.
    func test_a_second_session_still_receives_buffers_after_the_first_consumer_is_cancelled() async throws {
        let recorder = SystemAudioRecorder()
        recorder.bringUpOverride = {}

        for session in 1...2 {
            try await recorder.start()
            let stream = recorder.audioStream
            let received = OSAllocatedUnfairLock(initialState: 0)
            let consumer = Task {
                for await _ in stream { received.withLock { $0 += 1 } }
            }
            recorder.deliverForTesting(Self.tone())
            await waitUntil { received.withLock { $0 } > 0 }
            XCTAssertGreaterThan(received.withLock { $0 }, 0,
                                 "session \(session) received no system-audio buffers")

            await recorder.stop()
            consumer.cancel()
            _ = await consumer.value
        }
    }

    /// `stop()` finishes the session's stream, so a consumer ends on its own
    /// rather than depending on being cancelled.
    func test_stop_finishes_the_session_stream() async throws {
        let recorder = SystemAudioRecorder()
        recorder.bringUpOverride = {}
        try await recorder.start()
        let stream = recorder.audioStream
        let consumer = Task { for await _ in stream {} }
        await recorder.stop()
        _ = await consumer.value   // hangs (test timeout) if the stream was left open
    }

    /// The end-to-end symptom: the second app-audio recording's WAV has audio.
    func test_back_to_back_app_audio_recordings_both_capture_audio() async throws {
        let session = RecordingSession()
        session.system.bringUpOverride = {}

        for take in 1...2 {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("system-audio-take\(take)-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: url) }

            try await session.start(source: .systemAudio, outputURL: url)
            session.system.deliverForTesting(Self.tone())
            await waitUntil { session.writesSinceStart > 0 }
            XCTAssertEqual(session.systemBuffersSinceStart, 1, "take \(take)")
            _ = await session.stop()

            let file = try AVAudioFile(forReading: url)
            XCTAssertGreaterThan(file.length, 0,
                                 "take \(take) saved an empty WAV — the app-audio stream was dead")
        }
    }

    // MARK: - Helpers

    /// 0.1 s of a 440 Hz tone, already in whisper format (pass-through converter).
    private static func tone() -> AVAudioPCMBuffer {
        let format = WhisperAudioFormat.pcmFloat32
        let frames = AVAudioFrameCount(format.sampleRate / 10)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            channel[i] = 0.3 * sinf(2 * .pi * 440 * Float(i) / Float(format.sampleRate))
        }
        return buffer
    }

    /// Poll until `condition` holds or `timeout` elapses; the assertion that
    /// follows decides the verdict.
    private func waitUntil(_ timeout: TimeInterval = 3.0, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !condition() {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
