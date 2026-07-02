import XCTest
@testable import Mila

/// Regression coverage for `SpeakerDiarizer.runPython` honoring Swift task
/// cancellation.
///
/// Before the fix, `runPython` had no cancellation path at all: cancelling
/// the transcription task (user hits Cancel in the rename sheet, app
/// shutdown) left the pyannote subprocess running to completion —
/// `waitUntilExit()` blocked for the full diarization pass (minutes on a
/// long recording that may already be deleted), and the serial transcription
/// queue stalled behind it the whole time.
final class SpeakerDiarizerCancelTests: XCTestCase {

    /// Cancelling the awaiting task must SIGTERM the subprocess and unwind
    /// with `CancellationError` promptly — not after the subprocess decides
    /// to finish on its own (30s here, "whole pyannote pass" in production).
    func test_cancelling_runPython_terminates_the_subprocess_promptly() async throws {
        let task = Task {
            try await SpeakerDiarizer.runPython(
                path: "/bin/sh",
                arguments: ["-c", "sleep 30"]
            )
        }
        // Let the subprocess actually start.
        try await Task.sleep(nanoseconds: 300_000_000)

        let cancelledAt = Date()
        task.cancel()
        let result = await task.result
        let elapsed = Date().timeIntervalSince(cancelledAt)

        switch result {
        case .success(let r):
            XCTFail("Expected CancellationError, got success (exit \(r.exitCode))")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError,
                          "A SIGTERM'd run must surface as CancellationError, not \(error)")
        }
        // Generous bound for CI VM jitter; the point is "returns in seconds,
        // not when the 30s subprocess finishes".
        XCTAssertLessThan(elapsed, 10.0,
                          "Cancellation must terminate the subprocess promptly; took \(elapsed)s")
    }

    /// Sanity: an uncancelled run still completes and returns stdout/stderr
    /// and the exit code (the drain-then-wait plumbing survived the
    /// cancellation refactor).
    func test_uncancelled_runPython_still_returns_output_and_exit_code() async throws {
        let result = try await SpeakerDiarizer.runPython(
            path: "/bin/sh",
            arguments: ["-c", "printf OUT; printf ERR >&2; exit 3"]
        )
        XCTAssertEqual(String(data: result.stdout, encoding: .utf8), "OUT")
        XCTAssertEqual(String(data: result.stderr, encoding: .utf8), "ERR")
        XCTAssertEqual(result.exitCode, 3)
    }
}
