import Foundation
import os

/// One place that runs a child process and waits for it without parking
/// threads of the Swift cooperative pool (improvement plan item 7).
///
/// The cooperative pool has one thread per core. A `Task.detached` that calls
/// `Process.waitUntilExit()`, plus two more that sit in `readDataToEndOfFile`,
/// takes three of them for the whole life of the child — a diarization pass or a
/// pip install runs for minutes. Every other `async` task in the app queues
/// behind what remains. This is the starvation pattern from #246 (see
/// `BlockingWork`), reached through Swift concurrency instead of GCD.
///
/// The wait here follows the rules in `.claude/rules/python-subprocess.md`:
///
/// 1. The exit is observed with `terminationHandler` plus a `DispatchSemaphore`,
///    installed **before** `run()`. That costs no thread of ours.
/// 2. Everything that must genuinely block — each pipe reader, the
///    `waitUntilExit()` backstop and the coordinating wait — runs on a thread of
///    its own (`BlockingWork.onDedicatedThread`).
/// 3. The `waitUntilExit()` backstop stays: macOS 26 has a reaping race where it
///    never returns even after SIGKILL, so the two paths fail independently and
///    whichever notices first signals. Every semaphore wait is bounded.
///
/// Callers that can spawn children in a batch need their own concurrency limit;
/// the thread count follows the number of concurrent child processes.
enum SubprocessRunner {

    /// What to do with a child's stdout or stderr.
    enum Stream {
        /// Read it all and return it in the result.
        case capture
        /// Send it to the null device. Never an unread `Pipe()`: that is a
        /// ~64 KB buffer, and a chatty child blocks on `write()` once it fills.
        case discard
    }

    struct Result: Sendable {
        let stdout: Data
        let stderr: Data
        let exitCode: Int32
        /// The child outlived `timeout` and was terminated. `exitCode` is then
        /// the signal-driven status and the output is whatever arrived.
        let timedOut: Bool
    }

    enum Failure: Swift.Error {
        case launchFailed(Swift.Error)
    }

    /// How long to wait for a child to die after SIGTERM before SIGKILL.
    static let terminationGrace: TimeInterval = 1
    /// How long to wait for the pipe readers after the child is gone.
    /// Bounded because a grandchild can inherit the pipes and hold them open
    /// forever; the output of a killed child is discarded anyway.
    static let drainGraceAfterKill: TimeInterval = 3
    static let drainGraceAfterExit: TimeInterval = 30

    /// Runs `executable` and returns when it exits, times out or the calling
    /// task is cancelled (which throws `CancellationError`).
    ///
    /// - Parameter timeout: seconds before the child is terminated, or `nil` for
    ///   none. `nil` is for work whose length is legitimately unbounded (a
    ///   diarization pass over a long recording); the wait is still performed in
    ///   short bounded slices.
    /// - Parameter onLaunch: called on the coordinating thread right after the
    ///   child started, e.g. to record its pid.
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        stdout stdoutMode: Stream = .capture,
        stderr stderrMode: Stream = .capture,
        timeout: TimeInterval? = nil,
        onLaunch: (@Sendable (Process) -> Void)? = nil
    ) async throws -> Result {
        let job = Job(
            executable: executable, arguments: arguments, environment: environment,
            stdoutMode: stdoutMode, stderrMode: stderrMode, timeout: timeout, onLaunch: onLaunch)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Swift.Error>) in
                BlockingWork.onDedicatedThread(named: "io.island.mila.subprocess.\(executable.lastPathComponent)") {
                    do {
                        continuation.resume(returning: try job.execute())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            job.cancel()
        }
    }

    // MARK: - Job

    /// The state shared between the coordinating thread and a cancel.
    private final class Job: @unchecked Sendable {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]?
        let stdoutMode: Stream
        let stderrMode: Stream
        let timeout: TimeInterval?
        let onLaunch: (@Sendable (Process) -> Void)?

        private struct State {
            var cancelled = false
            var process: Process?
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        /// Signalled by the exit observers and by a cancel. A semaphore is only
        /// unsafe to destroy while its value is below where it started; every
        /// wait on it is bounded and extra signals are harmless.
        private let exited = DispatchSemaphore(value: 0)

        init(executable: URL, arguments: [String], environment: [String: String]?,
             stdoutMode: Stream, stderrMode: Stream, timeout: TimeInterval?,
             onLaunch: (@Sendable (Process) -> Void)?) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.stdoutMode = stdoutMode
            self.stderrMode = stderrMode
            self.timeout = timeout
            self.onLaunch = onLaunch
        }

        var isCancelled: Bool { state.withLock { $0.cancelled } }

        func cancel() {
            let process = state.withLock { s -> Process? in
                s.cancelled = true
                return s.process
            }
            if let process, process.isRunning { process.terminate() }
            exited.signal()   // wake the coordinating wait now, not at the deadline
        }

        func execute() throws -> Result {
            if isCancelled { throw CancellationError() }

            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            if let environment {
                var env = ProcessInfo.processInfo.environment
                env.merge(environment) { _, new in new }
                process.environment = env
            }

            let stdoutPipe: Pipe? = stdoutMode == .capture ? Pipe() : nil
            let stderrPipe: Pipe? = stderrMode == .capture ? Pipe() : nil
            process.standardOutput = stdoutPipe ?? FileHandle.nullDevice
            process.standardError = stderrPipe ?? FileHandle.nullDevice

            process.terminationHandler = { [exited] _ in exited.signal() }
            do {
                try process.run()
            } catch {
                throw Failure.launchFailed(error)
            }
            // Close the narrow window where a cancel ran before `run()`: its
            // terminate() hit a not-yet-launched process and did nothing.
            let cancelledBeforeLaunch = state.withLock { s -> Bool in
                s.process = process
                return s.cancelled
            }
            if cancelledBeforeLaunch { process.terminate() }
            onLaunch?(process)

            // Chunked reads into lock-guarded boxes, so a bounded drain can
            // snapshot what arrived without racing a still-blocked reader.
            let outBox = OSAllocatedUnfairLock(initialState: Data())
            let errBox = OSAllocatedUnfairLock(initialState: Data())
            let drained = DispatchGroup()
            for (pipe, box, name) in [(stdoutPipe, outBox, "stdout"), (stderrPipe, errBox, "stderr")] {
                guard let pipe else { continue }
                drained.enter()
                BlockingWork.onDedicatedThread(named: "io.island.mila.subprocess.drain.\(name)") {
                    let handle = pipe.fileHandleForReading
                    while true {
                        let chunk = handle.availableData   // blocks until data or EOF
                        if chunk.isEmpty { break }
                        box.withLock { $0.append(chunk) }
                    }
                    drained.leave()
                }
            }

            // Backstop for `terminationHandler` (macOS 26 reaping race).
            BlockingWork.onDedicatedThread(named: "io.island.mila.subprocess.reap") { [exited] in
                process.waitUntilExit()
                exited.signal()
            }

            let timedOut = waitForExit(of: process)
            let killed = timedOut || isCancelled
            if killed { terminate(process) }

            let grace = killed ? SubprocessRunner.drainGraceAfterKill : SubprocessRunner.drainGraceAfterExit
            _ = drained.wait(timeout: .now() + grace)

            // A SIGTERM'd run surfaces as cancellation, not as a failure
            // banner. Checked before the output is used.
            if isCancelled { throw CancellationError() }

            return Result(
                stdout: outBox.withLock { $0 },
                stderr: errBox.withLock { $0 },
                exitCode: process.isRunning ? -1 : process.terminationStatus,
                timedOut: timedOut)
        }

        /// Waits until the child exits, the task is cancelled or `timeout`
        /// passes. Returns whether the timeout fired. Always bounded: the wait is
        /// taken in one-second slices so a missed signal costs a second.
        private func waitForExit(of process: Process) -> Bool {
            let deadline = timeout.map { DispatchTime.now() + $0 }
            while true {
                if isCancelled || !process.isRunning { return false }
                if let deadline, DispatchTime.now() >= deadline { return true }
                var slice = DispatchTime.now() + 1
                if let deadline, deadline < slice { slice = deadline }
                if exited.wait(timeout: slice) == .success {
                    // Either the exit or a cancel; the loop head tells which.
                    if isCancelled || !process.isRunning { return false }
                }
            }
        }

        /// SIGTERM was sent by the caller of this (or by `cancel()`); make sure
        /// the child is really gone, escalating to SIGKILL.
        private func terminate(_ process: Process) {
            if process.isRunning { process.terminate() }
            let graceEnd = DispatchTime.now() + SubprocessRunner.terminationGrace
            while process.isRunning && DispatchTime.now() < graceEnd {
                _ = exited.wait(timeout: .now() + 0.05)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            // BOUNDED: `waitUntilExit` has been seen never returning after a
            // SIGKILL on macOS 26, so poll `isRunning` instead of waiting on it.
            let reapEnd = DispatchTime.now() + 5
            while process.isRunning && DispatchTime.now() < reapEnd {
                _ = exited.wait(timeout: .now() + 0.05)
            }
        }
    }
}
