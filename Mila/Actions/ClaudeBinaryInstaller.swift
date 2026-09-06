import Foundation
import os

private let installLog = os.Logger(subsystem: "io.island.whisper.IslandWhisper",
                                   category: "ClaudeInstall")

/// The network half of the managed install, behind a protocol so the installer
/// can be driven end-to-end in a unit test without touching the network.
///
/// Two methods rather than one because the two kinds of fetch have genuinely
/// different shapes: the version string and the manifest are a few hundred
/// bytes and want to be `Data`, while the binary is ~200 MB, needs a progress
/// bar, and must never be held in memory.
protocol ClaudeBinaryDownloading {
    /// Small `GET`, whole body in memory.
    func data(from url: URL) async throws -> Data
    /// Large `GET` streamed to `destination`. `progress` receives 0…1, or a
    /// negative value while the total size is unknown.
    func downloadFile(from url: URL,
                      to destination: URL,
                      progress: @escaping (Double) -> Void) async throws
}

/// What a completed install knows about itself. Persisted by
/// `ClaudeSetupSettings` so the Settings row can say *which* version is
/// installed, and so a "Reinstall" can report that it changed something.
struct ClaudeInstallResult: Equatable {
    let version: String
    let platform: String
    let binary: URL
}

/// Downloads, verifies and installs Anthropic's native `claude` binary.
///
/// The ordering here is the whole point, and it is: **download → size →
/// checksum → signature → make executable → install**. Nothing is moved to the
/// path `LLMRunner` resolves until every check has passed, and the staging
/// directory is deliberately not on that resolution path (see
/// `ClaudeManagedInstall.stagingDirectory`), so there is no window in which a
/// half-verified file is reachable by something that would run it.
///
/// The two verification steps are not redundant. The checksum proves the bytes
/// are the ones the release manifest describes — it catches a truncated or
/// corrupted transfer, and it is the check `install.sh` performs. The signature
/// proves Anthropic produced them, and keeps proving it if the manifest and the
/// binary are served by the same compromised host. A CDN that can substitute
/// the binary can substitute its checksum with it; it cannot forge a Developer
/// ID signature.
struct ClaudeBinaryInstaller {

    let downloader: ClaudeBinaryDownloading
    let verifier: ClaudeSignatureVerifying
    let fileManager: FileManager
    let appSupportRoot: URL

    init(downloader: ClaudeBinaryDownloading = URLSessionClaudeDownloader(),
         verifier: ClaudeSignatureVerifying = SecurityFrameworkSignatureVerifier(),
         fileManager: FileManager = .default,
         appSupportRoot: URL = ClaudeManagedInstall.applicationSupportRoot()) {
        self.downloader = downloader
        self.verifier = verifier
        self.fileManager = fileManager
        self.appSupportRoot = appSupportRoot
    }

    /// Resolve the current release, fetch it, verify it, and put it at
    /// `ClaudeManagedInstall.binaryURL`. Existing installs are replaced.
    ///
    /// `progress` is called on an arbitrary executor with 0…1 for the download
    /// phase; callers that drive UI must hop to the main actor themselves.
    func install(progress: @escaping (Double) -> Void = { _ in }) async throws -> ClaudeInstallResult {
        let machine = ClaudeManagedInstall.currentMachine()
        guard let platform = ClaudeManagedInstall.platformKey() else {
            throw ClaudeInstallError.unsupportedPlatform(machine)
        }

        let version = try await resolveLatestVersion()
        let manifest = try await fetchManifest(version: version)
        guard let expectedChecksum = manifest.checksum(for: platform) else {
            throw ClaudeInstallError.manifestMissingPlatform(platform)
        }
        let expectedSize = manifest.expectedSize(for: platform)

        guard let binaryURL = ClaudeManagedInstall.binaryDownloadURL(version: version,
                                                                    platform: platform),
              ClaudeManagedInstall.isTrusted(binaryURL) else {
            throw ClaudeInstallError.untrustedURL("\(ClaudeManagedInstall.downloadBase)/\(version)")
        }

        installLog.notice("""
            claude install start version=\(version, privacy: .public) \
            platform=\(platform, privacy: .public) \
            size=\(expectedSize ?? -1, privacy: .public)B
            """)

        let staging = ClaudeManagedInstall.stagingDirectory(appSupportRoot: appSupportRoot)
        try createDirectory(staging)
        let staged = staging.appendingPathComponent("claude-\(version)-\(platform)")
        // A leftover from an interrupted run must not be mistaken for this
        // one's download — and `downloadFile` refuses to overwrite.
        try? fileManager.removeItem(at: staged)

        // Everything from here on either finishes the install or removes the
        // staged file: an unverified binary is never left on disk, not even
        // outside the resolution path.
        do {
            try await downloader.downloadFile(from: binaryURL, to: staged, progress: progress)
            // A cancel that arrives during (or right after) the download must
            // not proceed to change what is on disk: past `moveIntoPlace`
            // there is no undo, and the caller that cancelled has already
            // stopped listening. Checked twice — once before the (slow) hash
            // and signature work, once right before the irreversible move.
            try Task.checkCancellation()
            try verifyDownload(at: staged,
                               expectedChecksum: expectedChecksum,
                               expectedSize: expectedSize)
            try makeExecutable(staged)
            try verifySignature(at: staged)
            try Task.checkCancellation()
            let installed = try moveIntoPlace(staged)
            installLog.notice("""
                claude install ok version=\(version, privacy: .public) \
                platform=\(platform, privacy: .public)
                """)
            return ClaudeInstallResult(version: version, platform: platform, binary: installed)
        } catch {
            try? fileManager.removeItem(at: staged)
            let described = (error as? ClaudeInstallError)?.logDescription
                ?? ((error is CancellationError) ? "cancelled" : "transport-failure")
            installLog.error("""
                claude install failed version=\(version, privacy: .public) \
                reason=\(described, privacy: .public)
                """)
            throw error
        }
    }

    // MARK: - Steps

    /// `GET /latest`, which returns a bare version string.
    ///
    /// The response is validated before it is ever interpolated into another
    /// URL. `install.sh` does the same thing, and says why: an HTML error page
    /// (a captive portal, an unsupported region) otherwise becomes a manifest
    /// path, and the resulting failure names the wrong problem.
    private func resolveLatestVersion() async throws -> String {
        let data = try await downloader.data(from: ClaudeManagedInstall.latestVersionURL)
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard ClaudeManagedInstall.isPlausibleVersion(text) else {
            throw ClaudeInstallError.versionLookupFailed(
                "The server didn't return a version number. This can happen if downloads.claude.ai is unreachable or unavailable in your region.")
        }
        return text
    }

    private func fetchManifest(version: String) async throws -> ClaudeManagedInstall.ReleaseManifest {
        guard let url = ClaudeManagedInstall.manifestURL(version: version) else {
            throw ClaudeInstallError.versionLookupFailed("Version \(version) isn't a shape Mila recognises.")
        }
        let data = try await downloader.data(from: url)
        do {
            return try JSONDecoder().decode(ClaudeManagedInstall.ReleaseManifest.self, from: data)
        } catch {
            throw ClaudeInstallError.versionLookupFailed("Anthropic's release manifest couldn't be read.")
        }
    }

    /// Size first, then checksum. The order is for the error message, not for
    /// correctness: a truncated download fails both checks, and "the download
    /// stopped early" tells the user to retry while "checksum mismatch" reads
    /// like tampering.
    func verifyDownload(at url: URL,
                        expectedChecksum: String,
                        expectedSize: Int64?) throws {
        if let expectedSize {
            let actual = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.int64Value ?? 0
            guard actual == expectedSize else {
                throw ClaudeInstallError.sizeMismatch(expected: expectedSize, actual: actual)
            }
        }
        let actualChecksum: String
        do {
            actualChecksum = try ClaudeBinaryVerification.sha256Hex(ofFileAt: url)
        } catch {
            throw ClaudeInstallError.installFailed("Couldn't read the downloaded file back to check it.")
        }
        guard ClaudeBinaryVerification.digestsMatch(actualChecksum, expectedChecksum) else {
            throw ClaudeInstallError.checksumMismatch(expected: expectedChecksum,
                                                      actual: actualChecksum)
        }
    }

    /// Ask the verifier who signed this, and refuse anything that isn't
    /// Anthropic's CLI. The decision itself lives in
    /// `ClaudeBinaryVerification.accept` so it is testable without a real
    /// signed binary.
    func verifySignature(at url: URL) throws {
        let identity = try verifier.identity(ofBinaryAt: url)
        if let refusal = ClaudeBinaryVerification.accept(identity) {
            throw refusal
        }
    }

    private func makeExecutable(_ url: URL) throws {
        do {
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            throw ClaudeInstallError.installFailed("Couldn't mark the download as executable.")
        }
    }

    /// Move the verified binary to its final path, replacing any previous
    /// install, and drop the quarantine flag.
    ///
    /// Quarantine is removed **only here** — after the signature check, never
    /// before. Mila has by this point verified the Developer ID signature
    /// against a pinned requirement, which is a stricter statement than the
    /// first-run Gatekeeper prompt makes; and that prompt is not available to
    /// us anyway, because the binary is launched as a subprocess of a GUI app
    /// where a refusal surfaces as an unexplained non-zero exit.
    private func moveIntoPlace(_ staged: URL) throws -> URL {
        let destination = ClaudeManagedInstall.binaryURL(appSupportRoot: appSupportRoot)
        try createDirectory(destination.deletingLastPathComponent())
        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
            } else {
                try fileManager.moveItem(at: staged, to: destination)
            }
        } catch {
            throw ClaudeInstallError.installFailed(error.localizedDescription)
        }
        // Re-assert 0o755 on the FINAL path: `replaceItemAt` preserves the
        // *destination's* metadata by default, so a reinstall over a
        // non-executable leftover would inherit its permissions — and a
        // non-executable managed binary reads as "not installed" everywhere.
        try makeExecutable(destination)
        // Best effort: the attribute is usually absent (URLSession does not
        // quarantine on behalf of a non-sandboxed app), and its absence is
        // reported as an error we deliberately ignore.
        destination.path.withCString { path in
            _ = removexattr(path, "com.apple.quarantine", 0)
        }
        return destination
    }

    private func createDirectory(_ url: URL) throws {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw ClaudeInstallError.installFailed(
                "Couldn't create \(url.path): \(error.localizedDescription)")
        }
    }

    /// Remove the managed binary (and any staging leftovers). Used by "Remove"
    /// in Settings. Returns false when something is still there afterwards, so
    /// the caller never reports a removal that didn't happen.
    @discardableResult
    func removeManagedBinary() -> Bool {
        let binary = ClaudeManagedInstall.binaryURL(appSupportRoot: appSupportRoot)
        try? fileManager.removeItem(at: binary)
        try? fileManager.removeItem(at: ClaudeManagedInstall.stagingDirectory(appSupportRoot: appSupportRoot))
        return !fileManager.fileExists(atPath: binary.path)
    }
}

// MARK: - URLSession transport

/// The production `ClaudeBinaryDownloading`.
///
/// Two properties are worth stating because they are easy to lose in a
/// refactor:
///
///  * **Redirects off the release host are refused, not followed.** The host
///    check is not just applied to the URL we compose — a 302 is a perfectly
///    ordinary way to be handed a different binary, and following one would
///    make the allowlist decorative.
///  * **The download is streamed to a file.** `URLSessionDownloadTask` writes
///    straight to disk, so a ~200 MB binary never sits in memory.
final class URLSessionClaudeDownloader: NSObject, ClaudeBinaryDownloading {

    /// Bounds the whole transfer. Generous — a 200 MB download on a slow
    /// connection is legitimately slow — but present, because a stalled
    /// download with no bound leaves the Settings UI in `installing` forever.
    private let resourceTimeout: TimeInterval = 900
    private let requestTimeout: TimeInterval = 60

    func data(from url: URL) async throws -> Data {
        guard ClaudeManagedInstall.isTrusted(url) else {
            throw ClaudeInstallError.untrustedURL(url.absoluteString)
        }
        let delegate = RedirectGuard()
        let session = URLSession(configuration: configuration(),
                                 delegate: delegate,
                                 delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: url)
        try check(response)
        return data
    }

    func downloadFile(from url: URL,
                      to destination: URL,
                      progress: @escaping (Double) -> Void) async throws {
        guard ClaudeManagedInstall.isTrusted(url) else {
            throw ClaudeInstallError.untrustedURL(url.absoluteString)
        }
        let delegate = RedirectGuard(onProgress: progress)
        let session = URLSession(configuration: configuration(),
                                 delegate: delegate,
                                 delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        // The completion-handler form, not the async one: with a completion
        // handler Foundation does NOT call `didFinishDownloadingTo` on the
        // delegate, so the temporary file is ours to move for the duration of
        // this closure and there is no race with an internal delegate proxy.
        let box = TaskBox()
        let temporary: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: url) { location, response, error in
                    if let error {
                        continuation.resume(throwing: Self.mapped(error))
                        return
                    }
                    guard let location else {
                        continuation.resume(throwing: ClaudeInstallError.installFailed(
                            "The download finished with no file."))
                        return
                    }
                    if let http = response as? HTTPURLResponse,
                       !(200...299).contains(http.statusCode) {
                        continuation.resume(throwing: ClaudeInstallError.httpError(status: http.statusCode))
                        return
                    }
                    // Move it out of the system temp directory NOW: Foundation
                    // deletes this file as soon as the handler returns.
                    let holding = location.deletingLastPathComponent()
                        .appendingPathComponent("mila-claude-\(UUID().uuidString)")
                    do {
                        try FileManager.default.moveItem(at: location, to: holding)
                        continuation.resume(returning: holding)
                    } catch {
                        continuation.resume(throwing: ClaudeInstallError.installFailed(
                            error.localizedDescription))
                    }
                }
                box.adopt(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }

        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw ClaudeInstallError.installFailed(error.localizedDescription)
        }
    }

    private func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        // No credential is ever needed for a public release artifact, and not
        // asking for one means a proxy that demands auth fails loudly.
        config.httpAdditionalHeaders = ["Accept": "*/*"]
        return config
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            throw ClaudeInstallError.httpError(status: http.statusCode)
        }
    }

    private static func mapped(_ error: Error) -> Error {
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return CancellationError()
        }
        return error
    }

    /// Holds the in-flight task so `onCancel` can reach it. A class because the
    /// cancellation handler runs outside the continuation's closure.
    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var isCancelled = false

        /// Adopt the task, cancelling it immediately if cancellation already
        /// won the race. The unsynchronized version dropped exactly that
        /// cancel: `onCancel` could read `task` as nil an instant before the
        /// assignment, leaving the download running with nobody awaiting it.
        func adopt(_ task: URLSessionTask) {
            lock.lock()
            let cancelNow = isCancelled
            self.task = task
            lock.unlock()
            if cancelNow { task.cancel() }
        }

        func cancel() {
            lock.lock()
            isCancelled = true
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }

    /// Session delegate: refuses off-host redirects and reports progress.
    private final class RedirectGuard: NSObject, URLSessionDownloadDelegate {
        private let onProgress: ((Double) -> Void)?

        init(onProgress: ((Double) -> Void)? = nil) {
            self.onProgress = onProgress
        }

        func urlSession(_ session: URLSession,
                        task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            guard let url = request.url, ClaudeManagedInstall.isTrusted(url) else {
                // nil = don't follow. The task completes with whatever the
                // redirect response itself was, which surfaces as a non-2xx.
                installLog.error("claude install refused an off-host redirect")
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }

        func urlSession(_ session: URLSession,
                        downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            guard let onProgress else { return }
            guard totalBytesExpectedToWrite > 0 else {
                onProgress(-1)   // indeterminate
                return
            }
            onProgress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        }

        /// Required by the protocol. Never called for a task created with a
        /// completion handler — see the call site.
        func urlSession(_ session: URLSession,
                        downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {}
    }
}
