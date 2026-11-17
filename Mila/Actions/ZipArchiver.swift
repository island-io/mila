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
    ///
    /// `ditto -x` inflates every entry it finds, with no way to say which or
    /// how much. Callers that extract something they did not make should
    /// `listEntries(of:)` first and refuse an archive whose declared contents
    /// are not what they expect — that is the only point at which a
    /// hostile archive can still be stopped for free.
    static func unzip(_ archive: URL, into directory: URL,
                      timeout: TimeInterval = 300) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await run(arguments: ["-x", "-k", archive.path, directory.path], timeout: timeout)
    }

    // MARK: - Listing

    /// One central-directory record: what the archive *declares* about an
    /// entry, read without inflating anything.
    struct Entry: Equatable {
        let name: String
        /// The size the entry claims it inflates to. A lie here is caught
        /// only after extraction, by comparing the real file — so this bounds
        /// honest archives and naive bombs, not a forged header.
        let uncompressedSize: UInt64
        let isDirectory: Bool
        let isSymlink: Bool
    }

    /// The archive's central directory could not be read as a zip.
    struct MalformedArchive: LocalizedError, Equatable {
        /// Structural, never a quote of the archive's contents.
        let reason: String
        var errorDescription: String? { "The archive isn't a zip file Mila can read (\(reason))." }
    }

    /// A central directory larger than this is refused unread. A bundle has
    /// three entries and a directory of a few hundred bytes; the cap keeps
    /// a forged size field from making us allocate gigabytes to find out.
    static let maxCentralDirectoryBytes: UInt64 = 1 << 20

    /// Read `archive`'s central directory — entry names, declared
    /// uncompressed sizes and file types — without extracting anything.
    ///
    /// Parsed here rather than through `unzip -l` / `zipinfo` because the
    /// zip container is a fixed binary layout and those tools' text output
    /// is not: a name with a newline in it would split a line, and the type
    /// bits (symlink / directory) that the importer wants are only in
    /// `zipinfo`'s long format. Handles ZIP64 (`ditto` switches to it past
    /// 4 GB). Every offset and length read from the file is checked against
    /// the file before it is used; anything inconsistent throws
    /// `MalformedArchive` rather than trapping on an index.
    static func listEntries(of archive: URL) throws -> [Entry] {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()

        // 1. End-of-central-directory record: 22 fixed bytes plus a comment
        //    of at most 65535, so it begins within the last 65557 bytes. Scan
        //    back for a signature whose comment length ends exactly at EOF —
        //    a bare signature match could be bytes inside the comment.
        let tailLength = min(fileSize, 22 + 65_535)
        guard tailLength >= 22 else { throw MalformedArchive(reason: "too short") }
        try handle.seek(toOffset: fileSize - tailLength)
        let tail = try readExactly(handle, count: Int(tailLength), what: "end of central directory")
        var eocd = tail.count - 22
        while eocd >= 0 {
            if tail.le32(eocd) == 0x0605_4b50, Int(tail.le16(eocd + 20)) == tail.count - eocd - 22 { break }
            eocd -= 1
        }
        guard eocd >= 0 else { throw MalformedArchive(reason: "no end-of-central-directory record") }

        var entryCount = UInt64(tail.le16(eocd + 10))
        var directorySize = UInt64(tail.le32(eocd + 12))
        var directoryOffset = UInt64(tail.le32(eocd + 16))

        // 2. ZIP64: a saturated field means the real values are in the ZIP64
        //    record, reached through the locator that sits just before the
        //    EOCD.
        if entryCount == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            guard eocd >= 20, tail.le32(eocd - 20) == 0x0706_4b50 else {
                throw MalformedArchive(reason: "ZIP64 sizes without a ZIP64 locator")
            }
            let recordOffset = tail.le64(eocd - 20 + 8)
            guard recordOffset <= fileSize, fileSize - recordOffset >= 56 else {
                throw MalformedArchive(reason: "ZIP64 record outside the file")
            }
            try handle.seek(toOffset: recordOffset)
            let record = try readExactly(handle, count: 56, what: "ZIP64 end of central directory")
            guard record.le32(0) == 0x0606_4b50 else { throw MalformedArchive(reason: "bad ZIP64 record") }
            entryCount = record.le64(32)
            directorySize = record.le64(40)
            directoryOffset = record.le64(48)
        }

        // 3. The directory itself.
        guard directorySize <= maxCentralDirectoryBytes else {
            throw MalformedArchive(reason: "central directory too large")
        }
        guard directoryOffset <= fileSize, directorySize <= fileSize - directoryOffset else {
            throw MalformedArchive(reason: "central directory outside the file")
        }
        // Each header is at least 46 bytes, so this also bounds the loop.
        guard entryCount <= directorySize / 46 else {
            throw MalformedArchive(reason: "entry count exceeds the directory")
        }
        try handle.seek(toOffset: directoryOffset)
        let directory = try readExactly(handle, count: Int(directorySize), what: "central directory")

        var entries: [Entry] = []
        var position = 0
        while position < directory.count {
            guard directory.count - position >= 46, directory.le32(position) == 0x0201_4b50 else {
                throw MalformedArchive(reason: "bad central directory header")
            }
            let madeBy = directory.le16(position + 4)
            let compressedSize = UInt64(directory.le32(position + 20))
            var uncompressedSize = UInt64(directory.le32(position + 24))
            let nameLength = Int(directory.le16(position + 28))
            let extraLength = Int(directory.le16(position + 30))
            let commentLength = Int(directory.le16(position + 32))
            let externalAttributes = directory.le32(position + 38)
            let localHeaderOffset = UInt64(directory.le32(position + 42))
            let nameStart = position + 46
            let extraStart = nameStart + nameLength
            let extraEnd = extraStart + extraLength
            let next = extraEnd + commentLength
            guard next <= directory.count else {
                throw MalformedArchive(reason: "truncated central directory header")
            }

            if uncompressedSize == 0xFFFF_FFFF || compressedSize == 0xFFFF_FFFF
                || localHeaderOffset == 0xFFFF_FFFF {
                // ZIP64 extended information (id 0x0001): only the saturated
                // fields are present, in this fixed order.
                var cursor = extraStart
                var resolved = false
                while extraEnd - cursor >= 4 {
                    let id = directory.le16(cursor)
                    let length = Int(directory.le16(cursor + 2))
                    let dataStart = cursor + 4
                    guard length <= extraEnd - dataStart else {
                        throw MalformedArchive(reason: "truncated extra field")
                    }
                    if id == 0x0001 {
                        var field = dataStart
                        let fieldEnd = dataStart + length
                        func take() throws -> UInt64 {
                            guard fieldEnd - field >= 8 else {
                                throw MalformedArchive(reason: "truncated ZIP64 extra field")
                            }
                            defer { field += 8 }
                            return directory.le64(field)
                        }
                        if uncompressedSize == 0xFFFF_FFFF { uncompressedSize = try take() }
                        // The other two are only consumed to keep the
                        // field order; nothing here extracts, so the
                        // compressed size and local offset are not needed.
                        if compressedSize == 0xFFFF_FFFF { _ = try take() }
                        if localHeaderOffset == 0xFFFF_FFFF { _ = try take() }
                        resolved = true
                        break
                    }
                    cursor = dataStart + length
                }
                guard resolved else { throw MalformedArchive(reason: "ZIP64 sizes without a ZIP64 extra field") }
            }

            // Callers compare names against fixed ASCII, so a lossy UTF-8
            // decode is enough: a name that isn't valid UTF-8 cannot match.
            let name = String(decoding: directory[directory.startIndex + nameStart
                                                  ..< directory.startIndex + extraStart], as: UTF8.self)
            // Unix hosts (3 = Unix, 19 = macOS — both `ditto` and `zip`
            // write 3) keep `st_mode` in the high half of the external
            // attributes; every other host has only the MS-DOS directory bit.
            let hostOS = madeBy >> 8
            let isUnix = hostOS == 3 || hostOS == 19
            let unixType = (externalAttributes >> 16) & 0o170000
            let isDirectory = name.hasSuffix("/")
                || (isUnix && unixType == 0o040000)
                || (!isUnix && externalAttributes & 0x10 != 0)
            let isSymlink = isUnix && unixType == 0o120000
            entries.append(Entry(name: name, uncompressedSize: uncompressedSize,
                                 isDirectory: isDirectory, isSymlink: isSymlink))
            position = next
        }
        guard UInt64(entries.count) == entryCount else {
            throw MalformedArchive(reason: "entry count disagrees with the directory")
        }
        return entries
    }

    private static func readExactly(_ handle: FileHandle, count: Int, what: String) throws -> Data {
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw MalformedArchive(reason: "truncated \(what)")
        }
        return data
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

private extension Data {
    /// Little-endian reads at an offset relative to `startIndex` (a slice
    /// does not start at 0). Callers bounds-check before reading.
    func le16(_ offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }
    func le32(_ offset: Int) -> UInt32 {
        UInt32(le16(offset)) | UInt32(le16(offset + 2)) << 16
    }
    func le64(_ offset: Int) -> UInt64 {
        UInt64(le32(offset)) | UInt64(le32(offset + 4)) << 32
    }
}
