import Foundation
import os

private let subprocessLog = os.Logger(subsystem: "io.island.whisper.IslandWhisper",
                                      category: "SubprocessRunner")

/// One place that runs a child process and waits for it without parking
/// threads of the Swift cooperative pool (#399).
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
/// Signals go to the child's whole process group when it leads one
/// (`LLMRunner.processGroup(ledBy:)`), so a timeout or cancel also reaches the
/// processes it started: `sh -c "find | xargs codesign"` otherwise leaves
/// `xargs` re-signing dylibs after `sh` is gone.
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

    /// `LocalizedError` so a caller that only reads `localizedDescription`
    /// (bootstrap stages, diagnostics) shows the underlying Cocoa reason —
    /// "The file “python3” doesn't exist." — not "SubprocessRunner.Failure error 0".
    enum Failure: LocalizedError {
        case launchFailed(Swift.Error)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let underlying): return underlying.localizedDescription
            }
        }
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
            /// The process group the child leads, or nil when it does not
            /// lead one (then only the child itself is signalled).
            var group: pid_t?
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
            let (process, group) = state.withLock { s -> (Process?, pid_t?) in
                s.cancelled = true
                return (s.process, s.group)
            }
            // Only while the child is running (checked inside): once it is
            // reaped its pid, and so its group id, can be reused.
            if let process { LLMRunner.sendSignal(SIGTERM, to: process, group: group) }
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
            // Read now: the child cannot have been reaped before `run()`
            // returns unless it already exited, and then there is nothing to
            // signal.
            let group = LLMRunner.processGroup(ledBy: process.processIdentifier)
            // Close the narrow window where a cancel ran before `run()`: it
            // had no process to signal.
            let cancelledBeforeLaunch = state.withLock { s -> Bool in
                s.process = process
                s.group = group
                return s.cancelled
            }
            if cancelledBeforeLaunch { LLMRunner.sendSignal(SIGTERM, to: process, group: group) }
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
            if killed { terminate(process, group: group) }

            if killed {
                // The output is discarded (timed out or cancelled), so a short
                // bound; a straggler holding the pipes was swept above.
                _ = drained.wait(timeout: .now() + SubprocessRunner.drainGraceAfterKill)
            } else if !drainAfterExit(drained) {
                // The child exited but something still holds its stdout or
                // stderr open (a process it started), and either the grace ran
                // out or the task was cancelled. Its own output arrived before
                // it exited, so what was read is complete unless a reader was
                // starved for the whole grace; say so unless it is a cancel.
                if !isCancelled {
                    subprocessLog.error("\(self.executable.lastPathComponent, privacy: .public): pipe drain timed out after exit; returning the output read so far")
                }
                // Every caller runs a one-shot tool, so a process still in its
                // group at this point is a stray: stop it rather than leave it,
                // and the two readers blocked on it, for the life of the app.
                // Then give the readers the kill path's short bound.
                if let group { LLMRunner.terminateHelpers(of: group) }
                _ = drained.wait(timeout: .now() + SubprocessRunner.drainGraceAfterKill)
            }

            // A SIGTERM'd run surfaces as cancellation, not as a failure
            // banner. Checked before the output is used.
            if isCancelled { throw CancellationError() }

            return Result(
                stdout: outBox.withLock { $0 },
                stderr: errBox.withLock { $0 },
                exitCode: process.isRunning ? -1 : process.terminationStatus,
                timedOut: timedOut)
        }

        /// Waits for the pipe readers after a normal exit: up to
        /// `drainGraceAfterExit`, in short slices so a cancel arriving NOW is
        /// seen. The child is already gone, so the cancel's own SIGTERM did
        /// nothing; whatever still holds the pipes is a process it started,
        /// and returning early lets the caller sweep that group, instead of a
        /// cancelled diarization holding the serial transcription queue for
        /// the whole grace. Returns whether the readers finished; on `false`
        /// (grace over, or cancelled) the caller sweeps, so the two cases
        /// cannot take different branches.
        private func drainAfterExit(_ drained: DispatchGroup) -> Bool {
            let deadline = DispatchTime.now() + SubprocessRunner.drainGraceAfterExit
            while DispatchTime.now() < deadline {
                if drained.wait(timeout: min(.now() + .milliseconds(250), deadline)) == .success {
                    return true
                }
                if isCancelled { return false }
            }
            return false
        }

        /// Waits until the child exits, the task is cancelled or `timeout`
        /// passes. Returns whether the timeout fired. Each semaphore wait is
        /// bounded (one-second slices, so a missed signal costs a second). With
        /// `timeout: nil` the loop itself is not: it ends only on the exit or a
        /// cancel, so a nil-timeout caller must be cancellable (diarization is,
        /// through Stop). The macOS 26 reaping race has been seen after a
        /// SIGKILL, and that path (`terminate`) is bounded.
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

        /// SIGTERM the child (and its group), give it `terminationGrace`, then
        /// SIGKILL; finally sweep whatever it started that is still in the
        /// group. A cancel may already have sent the first SIGTERM; a second
        /// one is harmless.
        private func terminate(_ process: Process, group: pid_t?) {
            LLMRunner.sendSignal(SIGTERM, to: process, group: group)
            let graceEnd = DispatchTime.now() + SubprocessRunner.terminationGrace
            while process.isRunning && DispatchTime.now() < graceEnd {
                _ = exited.wait(timeout: .now() + 0.05)
            }
            if process.isRunning { LLMRunner.sendSignal(SIGKILL, to: process, group: group) }
            // BOUNDED: `waitUntilExit` has been seen never returning after a
            // SIGKILL on macOS 26, so poll `isRunning` instead of waiting on it.
            let reapEnd = DispatchTime.now() + 5
            while process.isRunning && DispatchTime.now() < reapEnd {
                _ = exited.wait(timeout: .now() + 0.05)
            }
            if process.isRunning {
                subprocessLog.error("\(self.executable.lastPathComponent, privacy: .public): pid \(process.processIdentifier, privacy: .public) still not reaped 5 s after SIGKILL; abandoning the wait")
            }
            // The child exiting inside the grace does nothing to a process it
            // started that ignores SIGTERM; sweep the group once it is gone.
            if let group { LLMRunner.terminateHelpers(of: group) }
        }
    }
}
