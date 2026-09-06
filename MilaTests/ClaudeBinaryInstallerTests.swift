import XCTest
@testable import Mila

/// Serves a scripted release feed. No network: the installer's transport is a
/// protocol precisely so the download/verify/install ordering can be driven
/// over fixtures.
private final class FakeDownloader: ClaudeBinaryDownloading {
    var version = "2.1.263"
    var manifestJSON: String?
    var payload = Data("#!/bin/sh\necho claude\n".utf8)
    /// Bytes actually written, which may differ from `payload` to simulate a
    /// truncated transfer.
    var truncateTo: Int?
    var dataError: Error?
    var downloadError: Error?
    private(set) var requestedURLs: [URL] = []
    private(set) var progressReports: [Double] = []

    func data(from url: URL) async throws -> Data {
        requestedURLs.append(url)
        if let dataError { throw dataError }
        if url.lastPathComponent == "latest" { return Data(version.utf8) }
        if let manifestJSON { return Data(manifestJSON.utf8) }
        throw ClaudeInstallError.versionLookupFailed("no manifest scripted")
    }

    func downloadFile(from url: URL,
                      to destination: URL,
                      progress: @escaping (Double) -> Void) async throws {
        requestedURLs.append(url)
        if let downloadError { throw downloadError }
        progress(0.5)
        progress(1.0)
        progressReports = [0.5, 1.0]
        let bytes = truncateTo.map { Data(payload.prefix($0)) } ?? payload
        try bytes.write(to: destination)
    }
}

/// Reports whatever identity the test wants, so the REFUSAL paths can be
/// exercised — a unit test cannot produce a genuinely Anthropic-signed Mach-O,
/// and a check only ever run on the happy path is a check nobody has seen fail.
private final class FakeVerifier: ClaudeSignatureVerifying {
    var identity: ClaudeSignatureIdentity
    var error: Error?
    private(set) var examined: [URL] = []

    init(identity: ClaudeSignatureIdentity) { self.identity = identity }

    static var anthropic: ClaudeSignatureIdentity {
        ClaudeSignatureIdentity(teamIdentifier: ClaudeManagedInstall.anthropicTeamIdentifier,
                                signingIdentifier: ClaudeManagedInstall.claudeSigningIdentifier,
                                isValid: true)
    }

    func identity(ofBinaryAt url: URL) throws -> ClaudeSignatureIdentity {
        examined.append(url)
        if let error { throw error }
        return identity
    }
}

/// Download → size → checksum → signature → install (issue #271).
///
/// The ordering is the point: nothing reaches the path `LLMRunner` resolves
/// until every check has passed, and a refused download leaves nothing on disk.
final class ClaudeBinaryInstallerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeBinaryInstallerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var installedBinary: URL { ClaudeManagedInstall.binaryURL(appSupportRoot: root) }
    private var staging: URL { ClaudeManagedInstall.stagingDirectory(appSupportRoot: root) }

    /// A manifest listing BOTH macOS builds, so the suite passes on an Apple
    /// Silicon and an Intel test host alike.
    private func manifest(checksum: String, size: Int64?) -> String {
        let sizeField = size.map { "\"size\": \($0)," } ?? ""
        return """
        {"version": "2.1.263",
         "platforms": {
           "darwin-arm64": {\(sizeField) "checksum": "\(checksum)"},
           "darwin-x64":   {\(sizeField) "checksum": "\(checksum)"}}}
        """
    }

    private func makeInstaller(downloader: FakeDownloader,
                               verifier: FakeVerifier) -> ClaudeBinaryInstaller {
        ClaudeBinaryInstaller(downloader: downloader,
                              verifier: verifier,
                              fileManager: .default,
                              appSupportRoot: root)
    }

    // MARK: - Happy path

    func test_a_verified_download_is_installed_and_executable() async throws {
        let downloader = FakeDownloader()
        let digest = ClaudeBinaryVerification.sha256Hex(of: downloader.payload)
        downloader.manifestJSON = manifest(checksum: digest,
                                           size: Int64(downloader.payload.count))
        let verifier = FakeVerifier(identity: FakeVerifier.anthropic)

        var seen: [Double] = []
        let result = try await makeInstaller(downloader: downloader, verifier: verifier)
            .install { seen.append($0) }

        XCTAssertEqual(result.version, "2.1.263")
        XCTAssertEqual(result.binary.path, installedBinary.path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installedBinary.path))
        XCTAssertEqual(seen, [0.5, 1.0], "progress is reported while downloading")
        XCTAssertEqual(verifier.examined.count, 1, "the signature was actually checked")

        // The staged copy is gone: the only survivor is the installed binary.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "staging is empty after a successful install, got \(leftovers)")
    }

    func test_the_signature_is_checked_before_anything_is_installed() async throws {
        let downloader = FakeDownloader()
        let digest = ClaudeBinaryVerification.sha256Hex(of: downloader.payload)
        downloader.manifestJSON = manifest(checksum: digest, size: nil)
        let verifier = FakeVerifier(identity: FakeVerifier.anthropic)

        _ = try await makeInstaller(downloader: downloader, verifier: verifier).install()

        // The file the verifier looked at was the STAGED one, not the installed
        // path — i.e. verification happened before the move.
        let examined = try XCTUnwrap(verifier.examined.first)
        XCTAssertNotEqual(examined.path, installedBinary.path)
        XCTAssertTrue(examined.path.hasPrefix(staging.path))
    }

    // MARK: - Refusals

    func test_a_checksum_mismatch_refuses_and_leaves_nothing_behind() async throws {
        let downloader = FakeDownloader()
        downloader.manifestJSON = manifest(checksum: String(repeating: "a", count: 64), size: nil)
        let verifier = FakeVerifier(identity: FakeVerifier.anthropic)

        do {
            _ = try await makeInstaller(downloader: downloader, verifier: verifier).install()
            XCTFail("expected a checksum refusal")
        } catch let error as ClaudeInstallError {
            guard case .checksumMismatch = error else {
                return XCTFail("expected checksumMismatch, got \(error)")
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: installedBinary.path),
                       "an unverified binary must never reach the resolution path")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "the staged file is deleted too, got \(leftovers)")
        XCTAssertTrue(verifier.examined.isEmpty, "a bad checksum short-circuits before signing")
    }

    func test_a_truncated_download_is_reported_as_a_short_transfer() async throws {
        let downloader = FakeDownloader()
        let digest = ClaudeBinaryVerification.sha256Hex(of: downloader.payload)
        downloader.manifestJSON = manifest(checksum: digest,
                                           size: Int64(downloader.payload.count))
        downloader.truncateTo = 4
        let verifier = FakeVerifier(identity: FakeVerifier.anthropic)

        do {
            _ = try await makeInstaller(downloader: downloader, verifier: verifier).install()
            XCTFail("expected a size refusal")
        } catch let error as ClaudeInstallError {
            guard case .sizeMismatch(let expected, let actual) = error else {
                return XCTFail("expected sizeMismatch, got \(error)")
            }
            XCTAssertEqual(actual, 4)
            XCTAssertEqual(expected, Int64(downloader.payload.count))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedBinary.path))
    }

    /// A correctly-signed binary from the wrong publisher — the case a checksum
    /// served by the same compromised host could not catch.
    func test_a_binary_signed_by_someone_else_is_refused() async throws {
        let downloader = FakeDownloader()
        let digest = ClaudeBinaryVerification.sha256Hex(of: downloader.payload)
        downloader.manifestJSON = manifest(checksum: digest, size: nil)
        let verifier = FakeVerifier(identity: ClaudeSignatureIdentity(
            teamIdentifier: "XXXXXXXXXX",
            signingIdentifier: "com.example.not-claude",
            isValid: true))

        do {
            _ = try await makeInstaller(downloader: downloader, verifier: verifier).install()
            XCTFail("expected a publisher refusal")
        } catch let error as ClaudeInstallError {
            guard case .wrongPublisher = error else {
                return XCTFail("expected wrongPublisher, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedBinary.path))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty)
    }

    func test_an_unsigned_or_broken_signature_is_refused() async throws {
        let downloader = FakeDownloader()
        let digest = ClaudeBinaryVerification.sha256Hex(of: downloader.payload)
        downloader.manifestJSON = manifest(checksum: digest, size: nil)
        let verifier = FakeVerifier(identity: ClaudeSignatureIdentity(
            teamIdentifier: ClaudeManagedInstall.anthropicTeamIdentifier,
            signingIdentifier: ClaudeManagedInstall.claudeSigningIdentifier,
            isValid: false))

        do {
            _ = try await makeInstaller(downloader: downloader, verifier: verifier).install()
            XCTFail("expected a signature refusal")
        } catch let error as ClaudeInstallError {
            guard case .signatureInvalid = error else {
                return XCTFail("expected signatureInvalid, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedBinary.path))
    }

    /// An HTML error page from a captive portal, rather than a version string.
    func test_a_junk_version_response_fails_before_any_url_is_built_from_it() async throws {
        let downloader = FakeDownloader()
        downloader.version = "<!DOCTYPE html><html>Access denied</html>"
        let verifier = FakeVerifier(identity: FakeVerifier.anthropic)

        do {
            _ = try await makeInstaller(downloader: downloader, verifier: verifier).install()
            XCTFail("expected a version-lookup refusal")
        } catch let error as ClaudeInstallError {
            guard case .versionLookupFailed = error else {
                return XCTFail("expected versionLookupFailed, got \(error)")
            }
        }
        XCTAssertEqual(downloader.requestedURLs.count, 1, "no manifest fetch was attempted")
    }

    func test_a_manifest_without_this_platform_is_refused() async throws {
        let downloader = FakeDownloader()
        downloader.manifestJSON = """
        {"version": "2.1.263", "platforms": {"linux-x64": {"checksum": "\(String(repeating: "a", count: 64))"}}}
        """
        let verifier = FakeVerifier(identity: FakeVerifier.anthropic)

        do {
            _ = try await makeInstaller(downloader: downloader, verifier: verifier).install()
            XCTFail("expected a manifest refusal")
        } catch let error as ClaudeInstallError {
            guard case .manifestMissingPlatform = error else {
                return XCTFail("expected manifestMissingPlatform, got \(error)")
            }
        }
    }

    // MARK: - Reinstall and removal

    func test_reinstalling_replaces_an_existing_binary() async throws {
        try FileManager.default.createDirectory(at: installedBinary.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("old".utf8).write(to: installedBinary)

        let downloader = FakeDownloader()
        downloader.payload = Data("#!/bin/sh\necho new\n".utf8)
        let digest = ClaudeBinaryVerification.sha256Hex(of: downloader.payload)
        downloader.manifestJSON = manifest(checksum: digest, size: nil)
        let verifier = FakeVerifier(identity: FakeVerifier.anthropic)

        _ = try await makeInstaller(downloader: downloader, verifier: verifier).install()

        let contents = try Data(contentsOf: installedBinary)
        XCTAssertEqual(contents, downloader.payload)
        // The old file above was written 0644. `replaceItemAt` preserves the
        // DESTINATION's permissions by default, so without the re-chmod in
        // `moveIntoPlace` this reinstall would produce a non-executable binary
        // that `isInstalled` and `resolveExecutable` both refuse.
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installedBinary.path),
                      "a reinstall over a non-executable leftover must still produce an executable binary")
    }

    func test_removal_reports_whether_the_binary_is_actually_gone() throws {
        try FileManager.default.createDirectory(at: installedBinary.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("x".utf8).write(to: installedBinary)

        let installer = ClaudeBinaryInstaller(downloader: FakeDownloader(),
                                              verifier: FakeVerifier(identity: FakeVerifier.anthropic),
                                              fileManager: .default,
                                              appSupportRoot: root)
        XCTAssertTrue(installer.removeManagedBinary())
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedBinary.path))
        XCTAssertTrue(installer.removeManagedBinary(), "removing nothing still ends with nothing there")
    }

    // MARK: - Verification primitives

    func test_accept_distinguishes_a_broken_signature_from_a_wrong_publisher() {
        XCTAssertNil(ClaudeBinaryVerification.accept(FakeVerifier.anthropic))

        let broken = ClaudeSignatureIdentity(teamIdentifier: ClaudeManagedInstall.anthropicTeamIdentifier,
                                             signingIdentifier: ClaudeManagedInstall.claudeSigningIdentifier,
                                             isValid: false)
        guard case .signatureInvalid? = ClaudeBinaryVerification.accept(broken) else {
            return XCTFail("a broken signature and a wrong publisher send users to different places")
        }

        // Anthropic's team, but a different product from that team.
        let otherProduct = ClaudeSignatureIdentity(
            teamIdentifier: ClaudeManagedInstall.anthropicTeamIdentifier,
            signingIdentifier: "com.anthropic.something-else",
            isValid: true)
        guard case .wrongPublisher? = ClaudeBinaryVerification.accept(otherProduct) else {
            return XCTFail("the signing identifier pins WHICH Anthropic binary this is")
        }
    }

    func test_the_designated_requirement_anchors_to_apple_and_pins_both_identities() {
        let requirement = ClaudeBinaryVerification.designatedRequirement
        XCTAssertTrue(requirement.contains("anchor apple generic"),
                      "without the anchor, a self-signed binary claiming the team ID would pass")
        XCTAssertTrue(requirement.contains(ClaudeManagedInstall.anthropicTeamIdentifier))
        XCTAssertTrue(requirement.contains(ClaudeManagedInstall.claudeSigningIdentifier))
    }

    func test_digest_comparison_is_case_insensitive_and_length_strict() {
        let digest = String(repeating: "ab", count: 32)
        XCTAssertTrue(ClaudeBinaryVerification.digestsMatch(digest, digest.uppercased()))
        XCTAssertFalse(ClaudeBinaryVerification.digestsMatch(digest, String(digest.dropLast())))
        XCTAssertFalse(ClaudeBinaryVerification.digestsMatch("", ""))
    }

    func test_streaming_and_in_memory_hashes_agree() throws {
        // The binary is hashed in chunks to keep ~200 MB out of memory; that
        // must produce the same digest as hashing the bytes directly.
        let payload = Data((0..<(3 * (1 << 20) + 17)).map { UInt8($0 % 251) })
        let file = root.appendingPathComponent("payload.bin")
        try payload.write(to: file)

        XCTAssertEqual(try ClaudeBinaryVerification.sha256Hex(ofFileAt: file),
                       ClaudeBinaryVerification.sha256Hex(of: payload))
    }

    /// The real transport refuses an off-host URL before it opens a connection,
    /// so this needs no network.
    func test_the_real_downloader_refuses_an_untrusted_url() async {
        let downloader = URLSessionClaudeDownloader()
        do {
            _ = try await downloader.data(from: URL(string: "https://evil.example.com/latest")!)
            XCTFail("expected a refusal")
        } catch let error as ClaudeInstallError {
            guard case .untrustedURL = error else {
                return XCTFail("expected untrustedURL, got \(error)")
            }
        } catch {
            XCTFail("expected ClaudeInstallError, got \(error)")
        }
    }
}
