import AppKit
import Foundation
import OSLog

private let writerLog = Logger(subsystem: "io.island.whisper.IslandWhisper", category: "RecordingStore")
private let writerSignposter = OSSignposter(logger: writerLog)

/// Writes `recordings.json` off the main actor (#406).
///
/// Every store mutation used to encode the whole library on the main actor
/// and write it before returning: about 0.9 s at 500 recordings and 4 s at
/// 2,000 (600 segments each), for a rename, a folder move or a speaker name.
/// `RecordingStore.persist()` now hands this writer a value snapshot of the
/// library and returns; the encode and the atomic write run on a serial
/// background queue.
///
/// **Coalescing.** One queued job per file. A snapshot handed in while an
/// earlier one for the same file is still waiting replaces it, so a burst
/// of mutations costs one encode of the newest state, plus at most the one
/// already running.
///
/// **Ordering.** Every snapshot takes a generation from one counter, and a
/// file is only ever written by a generation newer than the last one
/// written to it. So a background encode that finishes after a newer
/// synchronous `writeNow` does not put older contents back — a row the
/// user just deleted, say. `enqueue` and `writeNow` are main-actor only,
/// which is what makes "newer generation" mean "newer state".
///
/// **Synchronous path.** `writeNow` encodes on the calling thread and
/// reports whether the file now holds that state. `RecordingStore` uses it
/// through `persistNow()`, whose doc lists the callers: ones that act on
/// the answer, deletions that must reach mila-mcp before the call returns,
/// and changes a crash must not undo (an add, a folder rename or delete,
/// an audio trim).
///
/// **Quit.** On `NSApplication.willTerminateNotification` the writer waits
/// for queued writes to finish, so a change made just before quitting is
/// not lost. A crash or a kill is not covered: a change handed off less
/// than one encode before it is lost.
final class RecordingLibraryWriter: @unchecked Sendable {
    /// The one the app uses. The ordering above holds only between stores
    /// that share a writer, and `BundleRelocator` drains this one before
    /// its hard exit, so every app store must use it. Only tests pass
    /// another (`RecordingStore.init(rootDirectory:writer:)`).
    static let shared = RecordingLibraryWriter()

    typealias Encode = @Sendable ([Recording]) throws -> Data

    private struct Job {
        let generation: UInt64
        let recordings: [Recording]
    }

    private let encode: Encode
    private let queue = DispatchQueue(label: "io.island.mila.recordings-writer", qos: .userInitiated)
    /// Guards `nextGeneration`, `queued` and `keys`. Held only for that
    /// bookkeeping, so `enqueue` (on the main actor) never waits for a file
    /// write.
    private let stateLock = NSLock()
    private var nextGeneration: UInt64 = 0
    private var queued: [String: Job] = [:]
    /// `key(for:)` per URL as first seen: resolving touches the file system,
    /// which on a slow or unresponsive volume would stall the main actor on
    /// every mutation, and a cached key stays the same for the session.
    private var keys: [URL: String] = [:]
    /// Guards `lastWritten`, and is held across each file write so a
    /// generation check and its write are one step. Never held across an
    /// encode.
    private let writeLock = NSLock()
    private var lastWritten: [String: UInt64] = [:]
    private var terminationObserver: NSObjectProtocol?

    /// `encode` is a seam for tests, which hold or fail an encode to see
    /// what happens to the writes around it. The app uses the default.
    init(encode: @escaping Encode = { try RecordingStore.encodeLibrary($0) }) {
        self.encode = encode
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.drain()
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    /// Queue `recordings` to be written to `url` and return at once.
    @MainActor
    func enqueue(_ recordings: [Recording], to url: URL) {
        let key = key(for: url)
        stateLock.lock()
        defer { stateLock.unlock() }
        nextGeneration += 1
        let alreadyScheduled = queued[key] != nil
        queued[key] = Job(generation: nextGeneration, recordings: recordings)
        if !alreadyScheduled {
            queue.async { [self] in runQueuedJob(key: key, url: url) }
        }
    }

    private func runQueuedJob(key: String, url: URL) {
        stateLock.lock()
        let job = queued.removeValue(forKey: key)
        stateLock.unlock()
        // `nil`: a `writeNow` wrote something newer after this was scheduled.
        guard let job else { return }
        _ = encodeAndWrite(job, key: key, to: url, synchronous: false)
    }

    /// Encode `recordings` and write them to `url` on the calling thread.
    /// Returns whether the file now holds them.
    @MainActor
    func writeNow(_ recordings: [Recording], to url: URL) -> Bool {
        let key = key(for: url)
        stateLock.lock()
        nextGeneration += 1
        let job = Job(generation: nextGeneration, recordings: recordings)
        stateLock.unlock()
        // On failure a snapshot still queued stays queued: it holds changes
        // handed off before this one that are not on disk either.
        guard encodeAndWrite(job, key: key, to: url, synchronous: true) else { return false }
        // Anything still queued is older than what was just written.
        stateLock.lock()
        if let pending = queued[key], pending.generation < job.generation {
            queued[key] = nil
        }
        stateLock.unlock()
        return true
    }

    /// Blocks until every write handed off before the call has finished.
    ///
    /// For `RecordingStore.load()`, so a store reading the file sees what
    /// another store in this process handed in (a relocate back to a folder,
    /// or a relaunch in tests), for the quit path, and for tests that read
    /// the file directly. Never call it from the writer's own queue.
    func drain() {
        queue.sync {}
    }

    /// One key per file however its URL is spelled (`/var` and
    /// `/private/var` are the same folder), so the ordering holds across
    /// stores. The folder is resolved rather than the file, because the
    /// file does not exist before its first write, and how a missing path
    /// resolves differs from how an existing one does.
    private func key(for url: URL) -> String {
        stateLock.lock()
        let cached = keys[url]
        stateLock.unlock()
        if let cached { return cached }
        let resolved = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).path
        stateLock.lock()
        keys[url] = resolved
        stateLock.unlock()
        return resolved
    }

    private func encodeAndWrite(_ job: Job, key: String, to url: URL, synchronous: Bool) -> Bool {
        let interval = writerSignposter.beginInterval("persist", id: writerSignposter.makeSignpostID())
        defer { writerSignposter.endInterval("persist", interval) }
        let data: Data
        do {
            data = try encode(job.recordings)
        } catch {
            let ns = error as NSError
            writerLog.error("""
                encoding recordings.json failed \
                (\(ns.domain, privacy: .public) \(ns.code, privacy: .public))
                """)
            return false
        }
        writeLock.lock()
        defer { writeLock.unlock() }
        // A newer generation already reached this file: these contents are
        // older than what is on disk, and writing them would undo a change.
        // Only a background job ends up here while every caller is on the
        // main actor; a synchronous one that ever did would not have its
        // contents on disk, so it says so.
        guard job.generation > lastWritten[key, default: 0] else { return !synchronous }
        do {
            try data.write(to: url, options: .atomic)
            lastWritten[key] = job.generation
            return true
        } catch {
            // `.private` on the description: `url` follows the user's chosen
            // storage folder, and Cocoa quotes the containing folder in the
            // message (CodeRabbit on #183, CWE-532). Domain + code stay
            // public so "no permission" (513) is still distinguishable from
            // a full disk or a missing directory.
            let ns = error as NSError
            writerLog.error("""
                persist failed for recordings.json \
                (\(ns.domain, privacy: .public) \(ns.code, privacy: .public)): \
                \(error.localizedDescription, privacy: .private)
                """)
            return false
        }
    }
}
