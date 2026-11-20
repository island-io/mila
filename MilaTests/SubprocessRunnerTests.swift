import XCTest
@testable import Mila

/// `SubprocessRunner` replaces five hand-rolled `waitUntilExit()` sites that
/// parked cooperative-pool threads (improvement plan item 7).
final class SubprocessRunnerTests: XCTestCase {

    private let sh = URL(fileURLWithPath: "/bin/sh")

    func test_captures_large_stdout_and_stderr_without_deadlock() async throws {
        let r = try await SubprocessRunner.run(
            executable: sh,
            arguments: ["-c", "head -c 300000 /dev/zero | tr '\\0' a; head -c 300000 /dev/zero | tr '\\0' b 1>&2; exit 3"])
        XCTAssertEqual(r.stdout.count, 300_000)
        XCTAssertEqual(r.stderr.count, 300_000)
        XCTAssertEqual(r.exitCode, 3)
        XCTAssertFalse(r.timedOut)
    }

    func test_discarded_streams_do_not_block_a_chatty_child() async throws {
        let r = try await SubprocessRunner.run(
            executable: sh,
            arguments: ["-c", "head -c 500000 /dev/zero; head -c 500000 /dev/zero 1>&2"],
            stdout: .discard, stderr: .discard)
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertTrue(r.stdout.isEmpty)
    }

    func test_timeout_terminates_the_child() async throws {
        let started = Date()
        let r = try await SubprocessRunner.run(executable: sh, arguments: ["-c", "sleep 30"], timeout: 1)
        XCTAssertTrue(r.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func test_a_child_that_ignores_sigterm_is_killed() async throws {
        let started = Date()
        let r = try await SubprocessRunner.run(
            executable: sh,
            arguments: ["-c", "trap '' TERM; while :; do sleep 1; done"],
            timeout: 1)
        XCTAssertTrue(r.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 12)
    }

    func test_cancelling_the_task_throws_cancellation_promptly() async throws {
        let task = Task { try await SubprocessRunner.run(executable: sh, arguments: ["-c", "sleep 30"]) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let cancelledAt = Date()
        task.cancel()
        let result = await task.result
        guard case .failure(let error) = result else { return XCTFail("expected cancellation") }
        XCTAssertTrue(error is CancellationError, "\(error)")
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 10)
    }

    func test_launch_failure_is_reported() async {
        do {
            _ = try await SubprocessRunner.run(executable: URL(fileURLWithPath: "/nonexistent/tool"), arguments: [])
            XCTFail("expected a launch failure")
        } catch let failure as SubprocessRunner.Failure {
            guard case .launchFailed(let underlying) = failure else { return XCTFail("unexpected \(failure)") }
            // Callers that only read `localizedDescription` must get the
            // Cocoa reason, not "SubprocessRunner.Failure error 0".
            XCTAssertEqual(failure.localizedDescription, underlying.localizedDescription)
            XCTAssertFalse(failure.localizedDescription.contains("SubprocessRunner"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    /// The reason the helper exists: 16 long-running children must not use
    /// up the cooperative pool, so an unrelated task still runs at once.
    func test_many_children_do_not_starve_the_cooperative_pool() async throws {
        let children = Task {
            try await withThrowingTaskGroup(of: SubprocessRunner.Result.self) { group in
                for _ in 0..<16 {
                    group.addTask { try await SubprocessRunner.run(executable: self.sh, arguments: ["-c", "sleep 2"]) }
                }
                var all: [SubprocessRunner.Result] = []
                for try await r in group { all.append(r) }
                return all
            }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let probeStart = Date()
        let value = await Task.detached { 1 + 1 }.value
        XCTAssertEqual(value, 2)
        XCTAssertLessThan(Date().timeIntervalSince(probeStart), 1.0)
        let all = try await children.value
        XCTAssertEqual(all.count, 16)
    }
}
