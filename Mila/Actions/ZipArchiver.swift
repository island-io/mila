import Foundation
import os

private let zipLog = Logger(subsystem: "io.island.whisper.IslandWhisper", category: "ZipArchiver")

/// Zip and unzip through the system `ditto`, the way `DiagnosticReporter`
/// already does — Foundation has no zip *container* API (`Compression` is a
/// stream codec, `AppleArchive` writes `.aar`), and `ditto` is on every Mac.
///
/// The subprocess wait follows `.claude/rules/python-subprocess.md`:
/// `terminationHandler` + semaphore installed before `run()`, stderr drained
/// on a dedicated thread, a `waitUntilExit()` backstop on another, every wait
/// bounded, SIGTERM then SIGKILL on timeout. Nothing here touches
/// `DispatchQueue.global()`.
enum ZipArchiver {

    struct Failure: LocalizedError, Equatable {
        enum Kind: Equatable {
            case launchFailed
            case nonZeroExit(Int32)
            case timedOut
        }

        let kind: Kind
        /// `ditto`'s stderr. Shown to the user (it is the diagnostic), never
        /// logged (it quotes the paths it was given).
        let stderr: String

        var errorDescription: String? {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            switch kind {
            case .launchFailed:
                return "Couldn't start the archive tool."
            case .nonZeroExit(let code):
                return detail.isEmpty
                    ? "The archive tool failed (exit \(code))."
                    : "The archive tool failed (exit \(code)): \(detail)"
            case .timedOut:
                return "The archive tool did not finish in time."
            }
        }

        /// Exit code and a byte count, nothing `ditto` said — its messages
        /// embed the source and destination paths, i.e. the user's folder
        /// names and the recording title.
        var logDescription: String {
            switch kind {
            case .launchFailed: return "ditto failed to launch"
            case .nonZeroExit(let code): return "ditto exit \(code), \(stderr.utf8.count) bytes of stderr"
            case .timedOut: return "ditto timed out, \(stderr.utf8.count) bytes of stderr"
            }
        }
    }

    /// Zip the **contents** of `directory` (not the directory itself) into
    /// `archive`, with no resource forks and therefore no `__MACOSX/` entry.
    static func zipContents(of directory: URL, to archive: URL,
                            timeout: TimeInterval = 300) async throws {
        try await run(arguments: ["-c", "-k", "--norsrc", directory.path, archive.path],
                      timeout: timeout)
    }

    /// Extract `archive` into `directory` (created if needed).
    static func unzip(_ archive: URL, into directory: URL,
                      timeout: TimeInterval = 300) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await run(arguments: ["-x", "-k", archive.path, directory.path], timeout: timeout)
    }

    // MARK: - Subprocess

    private static func run(arguments: [String], timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // The body blocks on semaphores, so it must not run on a
            // cooperative-pool thread or a global queue (see BlockingWork).
            BlockingWork.onDedicatedThread(named: "ZipArchiver.ditto") {
                do {
                    try runBlocking(arguments: arguments, timeout: timeout)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Thread-safe holder for the stderr bytes the reader thread collects.
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    private static func runBlocking(arguments: [String], timeout: TimeInterval) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe

        // Exit observation that costs no thread of ours. Installed BEFORE
        // run(), so a child that exits instantly cannot slip past it.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        // Drain stderr on its own thread so a chatty child can never fill
        // the 64 KB pipe buffer and block on write() while we wait on exit.
        let stderrBox = DataBox()
        let stderrDone = DispatchSemaphore(value: 0)
        let errHandle = errPipe.fileHandleForReading
        BlockingWork.onDedicatedThread(named: "ZipArchiver.stderr") {
            stderrBox.set(errHandle.readDataToEndOfFile())
            stderrDone.signal()
        }

        do {
            try process.run()
        } catch {
            // Nothing was written to the pipe; let the reader see EOF.
            try? errPipe.fileHandleForWriting.close()
            _ = stderrDone.wait(timeout: .now() + 2)
            zipLog.error("ditto failed to launch: \(error.localizedDescription, privacy: .public)")
            throw Failure(kind: .launchFailed, stderr: "")
        }

        // Backstop for the macOS 26 reaping race where `terminationHandler`
        // and `waitUntilExit` can fail independently; whichever notices
        // first signals, and a second signal is harmless because every wait
        // on this semaphore is bounded.
        BlockingWork.onDedicatedThread(named: "ZipArchiver.waitUntilExit") {
            process.waitUntilExit()
            exited.signal()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 3)
            }
        }
        // The reader ends at EOF, which arrives when the child (and any
        // grandchild holding the pipe) is gone. Bounded, like everything else.
        _ = stderrDone.wait(timeout: .now() + 5)
        let stderr = String(decoding: stderrBox.get(), as: UTF8.self)

        if timedOut {
            let failure = Failure(kind: .timedOut, stderr: stderr)
            zipLog.error("\(failure.logDescription, privacy: .public)")
            throw failure
        }
        guard process.terminationStatus == 0 else {
            let failure = Failure(kind: .nonZeroExit(process.terminationStatus), stderr: stderr)
            zipLog.error("\(failure.logDescription, privacy: .public)")
            throw failure
        }
    }
}
