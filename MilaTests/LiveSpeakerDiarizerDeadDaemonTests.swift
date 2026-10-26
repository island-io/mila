import XCTest
@testable import Mila

/// Stopping a recording whose live-diarization daemon had already exited
/// killed Mila with SIGPIPE: in 1.9.7 the daemon's Python imports failed at
/// startup, `start()` kept its stdin pipe, and `stop()` wrote `shutdown` into
/// a pipe nobody was reading. See `LiveSpeakerDiarizer.makeDaemonStdinPipe`.
@MainActor
final class LiveSpeakerDiarizerDeadDaemonTests: XCTestCase {

    func test_daemon_stdin_reports_a_missing_reader_instead_of_raising_SIGPIPE() {
        let pipe = LiveSpeakerDiarizer.makeDaemonStdinPipe()
        XCTAssertEqual(fcntl(pipe.fileHandleForWriting.fileDescriptor, F_GETNOSIGPIPE), 1)
    }

    func test_stop_after_the_daemon_exited_returns_instead_of_killing_the_app() async throws {
        let stdin = LiveSpeakerDiarizer.makeDaemonStdinPipe()
        // Without the flag the writes below kill the whole test host. Fail
        // here instead, so a regression reports as one failed test.
        guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_GETNOSIGPIPE) == 1 else {
            return XCTFail("the daemon's stdin would raise SIGPIPE")
        }

        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        daemon.standardInput = stdin
        let exited = expectation(description: "daemon exited")
        daemon.terminationHandler = { _ in exited.fulfill() }
        try daemon.run()
        await fulfillment(of: [exited], timeout: 10)

        // The pipe really has no reader left — Process closed the parent's
        // copy of the read end at launch, and the child is gone — so this is
        // the write that used to raise SIGPIPE.
        XCTAssertThrowsError(try stdin.fileHandleForWriting.write(contentsOf: Data("probe\n".utf8)))

        let diarizer = LiveSpeakerDiarizer()
        diarizer.adoptDaemonForTesting(daemon, stdin: stdin)
        diarizer.stop()
        XCTAssertFalse(diarizer.isReady)
    }
}
