import XCTest
@testable import Mila

/// The pure rules behind the managed Claude install (issue #271): which release
/// artifact is fetched, which URLs Mila will talk to, which binary a run picks,
/// and — the one with teeth — which child processes are handed the stored
/// credential.
///
/// Nothing here touches the network, the Keychain or a real `claude`.
final class ClaudeManagedInstallTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeManagedInstallTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A file that `isExecutableFile` will accept, so resolution tests exercise
    /// the real check rather than a stub.
    @discardableResult
    private func makeExecutable(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path)
        return url
    }

    // MARK: - Version and platform guards

    func test_version_guard_accepts_release_and_prerelease_shapes() {
        XCTAssertTrue(ClaudeManagedInstall.isPlausibleVersion("2.1.263"))
        XCTAssertTrue(ClaudeManagedInstall.isPlausibleVersion("0.0.1"))
        XCTAssertTrue(ClaudeManagedInstall.isPlausibleVersion("2.1.263-beta.1"))
    }

    /// The guard exists because the version string comes off the network and is
    /// then interpolated into a URL path. Traversal is the case that matters.
    func test_version_guard_refuses_traversal_and_junk() {
        XCTAssertFalse(ClaudeManagedInstall.isPlausibleVersion("2.1.263/../../evil"))
        XCTAssertFalse(ClaudeManagedInstall.isPlausibleVersion("../../etc"))
        XCTAssertFalse(ClaudeManagedInstall.isPlausibleVersion("<!DOCTYPE html>"))
        XCTAssertFalse(ClaudeManagedInstall.isPlausibleVersion(""))
        XCTAssertFalse(ClaudeManagedInstall.isPlausibleVersion("2.1"))
        XCTAssertFalse(ClaudeManagedInstall.isPlausibleVersion("v2.1.263"))
        XCTAssertFalse(ClaudeManagedInstall.isPlausibleVersion(String(repeating: "1", count: 200)))
    }

    func test_manifest_and_binary_urls_match_the_official_installer_layout() throws {
        let manifest = try XCTUnwrap(ClaudeManagedInstall.manifestURL(version: "2.1.263"))
        XCTAssertEqual(manifest.absoluteString,
                       "https://downloads.claude.ai/claude-code-releases/2.1.263/manifest.json")

        let binary = try XCTUnwrap(ClaudeManagedInstall.binaryDownloadURL(version: "2.1.263",
                                                                         platform: "darwin-arm64"))
        XCTAssertEqual(binary.absoluteString,
                       "https://downloads.claude.ai/claude-code-releases/2.1.263/darwin-arm64/claude")

        XCTAssertEqual(ClaudeManagedInstall.latestVersionURL.absoluteString,
                       "https://downloads.claude.ai/claude-code-releases/latest")
    }

    func test_url_builders_refuse_a_bad_version_or_platform() {
        XCTAssertNil(ClaudeManagedInstall.manifestURL(version: "../evil"))
        XCTAssertNil(ClaudeManagedInstall.binaryDownloadURL(version: "2.1.263",
                                                            platform: "linux-x64"))
        XCTAssertNil(ClaudeManagedInstall.binaryDownloadURL(version: "2.1.263",
                                                            platform: "../../etc"))
    }

    func test_only_https_on_the_release_host_is_trusted() {
        XCTAssertTrue(ClaudeManagedInstall.isTrusted(
            URL(string: "https://downloads.claude.ai/claude-code-releases/latest")!))

        // http, a lookalike subdomain, a different host, and a userinfo trick.
        XCTAssertFalse(ClaudeManagedInstall.isTrusted(
            URL(string: "http://downloads.claude.ai/claude-code-releases/latest")!))
        XCTAssertFalse(ClaudeManagedInstall.isTrusted(
            URL(string: "https://downloads.claude.ai.evil.com/x")!))
        XCTAssertFalse(ClaudeManagedInstall.isTrusted(
            URL(string: "https://evil.com/claude-code-releases/latest")!))
        XCTAssertFalse(ClaudeManagedInstall.isTrusted(
            URL(string: "https://downloads.claude.ai@evil.com/x")!))
    }

    /// Mirrors `install.sh`: arm64 natively, x64 natively, and — the correction
    /// that is easy to miss — the NATIVE arm64 build when an x86_64 process is
    /// running translated under Rosetta on Apple Silicon.
    func test_platform_key_follows_the_machine_including_rosetta() {
        XCTAssertEqual(ClaudeManagedInstall.platformKey(machine: "arm64", isTranslated: false),
                       "darwin-arm64")
        XCTAssertEqual(ClaudeManagedInstall.platformKey(machine: "x86_64", isTranslated: false),
                       "darwin-x64")
        XCTAssertEqual(ClaudeManagedInstall.platformKey(machine: "x86_64", isTranslated: true),
                       "darwin-arm64")
        XCTAssertNil(ClaudeManagedInstall.platformKey(machine: "ppc", isTranslated: false))
    }

    // MARK: - Manifest decoding

    func test_manifest_reads_the_platform_checksum_and_ignores_unknown_fields() throws {
        let json = """
        {
          "version": "2.1.263",
          "commit": "deadbeef",
          "somethingNew": {"we": "ignore"},
          "platforms": {
            "darwin-arm64": {"checksum": "\(String(repeating: "a", count: 64))", "size": 1234},
            "linux-x64": {"checksum": "\(String(repeating: "b", count: 64))", "size": 99}
          }
        }
        """
        let manifest = try JSONDecoder().decode(ClaudeManagedInstall.ReleaseManifest.self,
                                                from: Data(json.utf8))
        XCTAssertEqual(manifest.checksum(for: "darwin-arm64"), String(repeating: "a", count: 64))
        XCTAssertEqual(manifest.expectedSize(for: "darwin-arm64"), 1234)
        XCTAssertNil(manifest.checksum(for: "darwin-x64"), "platform absent from the manifest")
    }

    /// A malformed checksum reads as ABSENT, not as a value to compare against —
    /// otherwise every download "fails verification" and the message blames the
    /// download rather than the manifest.
    func test_manifest_treats_a_malformed_checksum_as_missing() throws {
        let json = """
        {"platforms": {"darwin-arm64": {"checksum": "not-a-digest", "size": 10},
                       "darwin-x64": {"checksum": "\(String(repeating: "z", count: 64))", "size": 10}}}
        """
        let manifest = try JSONDecoder().decode(ClaudeManagedInstall.ReleaseManifest.self,
                                                from: Data(json.utf8))
        XCTAssertNil(manifest.checksum(for: "darwin-arm64"), "too short and non-hex")
        XCTAssertNil(manifest.checksum(for: "darwin-x64"), "right length but not hex")
    }

    // MARK: - Executable resolution order

    func test_managed_install_is_preferred_over_the_path_search() throws {
        let managed = try makeExecutable(root.appendingPathComponent("managed/claude"))
        let onPath = try makeExecutable(root.appendingPathComponent("usr-local-bin/claude"))

        let resolved = try LLMRunner.resolveExecutable(tool: .claude,
                                                       override: nil,
                                                       managedBinary: managed,
                                                       lookup: { _ in onPath })
        XCTAssertEqual(resolved.path, managed.path,
                       "a user who pressed Set up Claude must get the binary Mila installed")
    }

    func test_path_search_is_used_when_nothing_is_managed() throws {
        let onPath = try makeExecutable(root.appendingPathComponent("usr-local-bin/claude"))
        let missing = root.appendingPathComponent("managed/claude")

        let resolved = try LLMRunner.resolveExecutable(tool: .claude,
                                                       override: nil,
                                                       managedBinary: missing,
                                                       lookup: { _ in onPath })
        XCTAssertEqual(resolved.path, onPath.path)
    }

    /// The override is Mila's own "run this one instead" control. A managed
    /// install that silently beat it would make the field impossible to use.
    func test_explicit_override_still_beats_the_managed_install() throws {
        let managed = try makeExecutable(root.appendingPathComponent("managed/claude"))
        let custom = try makeExecutable(root.appendingPathComponent("custom/claude-shim"))

        let resolved = try LLMRunner.resolveExecutable(tool: .claude,
                                                       override: custom.path,
                                                       managedBinary: managed,
                                                       lookup: { _ in nil })
        XCTAssertEqual(resolved.path, custom.path)
    }

    /// Only `.claude` has a managed install; the other CLIs are whatever the
    /// user installed. Without this the managed `claude` would be launched as
    /// `cursor-agent`.
    func test_other_tools_ignore_the_managed_binary() throws {
        let managed = try makeExecutable(root.appendingPathComponent("managed/claude"))
        let cursor = try makeExecutable(root.appendingPathComponent("usr-local-bin/cursor-agent"))

        let resolved = try LLMRunner.resolveExecutable(tool: .cursor,
                                                       override: nil,
                                                       managedBinary: managed,
                                                       lookup: { _ in cursor })
        XCTAssertEqual(resolved.path, cursor.path)
    }

    func test_resolution_throws_when_there_is_nothing_to_run() {
        let missing = root.appendingPathComponent("managed/claude")
        XCTAssertThrowsError(try LLMRunner.resolveExecutable(tool: .claude,
                                                             override: nil,
                                                             managedBinary: missing,
                                                             lookup: { _ in nil }))
    }

    // MARK: - Token injection

    func test_token_is_injected_only_for_the_managed_binary() throws {
        let managed = try makeExecutable(root.appendingPathComponent("managed/claude"))

        let env = LLMRunner.childEnvironment(for: managed,
                                             base: ["PATH": "/usr/bin"],
                                             managedBinary: managed,
                                             managedToken: { "sk-ant-oat-secret" })
        XCTAssertEqual(env[ClaudeManagedInstall.oauthTokenEnvironmentKey], "sk-ant-oat-secret")
    }

    /// The failure that would be silent and confusing: overriding the login a
    /// user already has on their own `claude`, possibly for a different account.
    func test_a_system_claude_never_receives_milas_token() throws {
        let managed = try makeExecutable(root.appendingPathComponent("managed/claude"))
        let system = try makeExecutable(root.appendingPathComponent("usr-local-bin/claude"))

        let env = LLMRunner.childEnvironment(for: system,
                                             base: ["PATH": "/usr/bin"],
                                             managedBinary: managed,
                                             managedToken: { "sk-ant-oat-secret" })
        XCTAssertNil(env[ClaudeManagedInstall.oauthTokenEnvironmentKey])
    }

    /// The user's own deliberate configuration is left alone — Mila neither
    /// overwrites nor unsets it for a binary that is not the managed one.
    func test_an_inherited_token_is_left_untouched_for_a_system_binary() throws {
        let managed = try makeExecutable(root.appendingPathComponent("managed/claude"))
        let system = try makeExecutable(root.appendingPathComponent("usr-local-bin/claude"))

        let env = LLMRunner.childEnvironment(
            for: system,
            base: ["PATH": "/usr/bin",
                   ClaudeManagedInstall.oauthTokenEnvironmentKey: "user-set-value"],
            managedBinary: managed,
            managedToken: { "sk-ant-oat-secret" })
        XCTAssertEqual(env[ClaudeManagedInstall.oauthTokenEnvironmentKey], "user-set-value")
    }

    /// The Keychain read is behind a closure so it happens only when it can
    /// matter. A run of `cursor-agent` or a system `claude` must not prompt or
    /// touch the keychain at all.
    func test_the_keychain_is_not_read_when_the_binary_is_not_managed() throws {
        let managed = try makeExecutable(root.appendingPathComponent("managed/claude"))
        let system = try makeExecutable(root.appendingPathComponent("usr-local-bin/claude"))

        var reads = 0
        _ = LLMRunner.childEnvironment(for: system,
                                       base: ["PATH": "/usr/bin"],
                                       managedBinary: managed,
                                       managedToken: { reads += 1; return "sk-ant-oat-secret" })
        XCTAssertEqual(reads, 0, "no keychain access for a binary Mila did not install")

        _ = LLMRunner.childEnvironment(for: managed,
                                       base: ["PATH": "/usr/bin"],
                                       managedBinary: managed,
                                       managedToken: { reads += 1; return "sk-ant-oat-secret" })
        XCTAssertEqual(reads, 1, "read exactly once for the managed binary")
    }

    func test_no_token_no_variable() throws {
        let managed = try makeExecutable(root.appendingPathComponent("managed/claude"))

        XCTAssertNil(LLMRunner.childEnvironment(for: managed,
                                                base: ["PATH": "/usr/bin"],
                                                managedBinary: managed,
                                                managedToken: { nil })[
            ClaudeManagedInstall.oauthTokenEnvironmentKey])

        XCTAssertNil(LLMRunner.childEnvironment(for: managed,
                                                base: ["PATH": "/usr/bin"],
                                                managedBinary: managed,
                                                managedToken: { "   " })[
            ClaudeManagedInstall.oauthTokenEnvironmentKey])
    }

    /// An "Executable" override pointing AT the managed binary is the same file,
    /// so it still gets the credential — the comparison is on resolved paths,
    /// not on how the URL was spelled.
    func test_an_unstandardized_path_to_the_managed_binary_still_matches() throws {
        let managed = try makeExecutable(root.appendingPathComponent("managed/claude"))
        let awkward = root.appendingPathComponent("managed/./claude")

        let additions = ClaudeManagedInstall.environmentAdditions(executable: awkward,
                                                                  managedBinary: managed,
                                                                  token: "sk-ant-oat-secret")
        XCTAssertEqual(additions[ClaudeManagedInstall.oauthTokenEnvironmentKey],
                       "sk-ant-oat-secret")
    }

    // MARK: - Layout

    func test_the_managed_binary_lives_under_milas_own_bin_directory() {
        let binary = ClaudeManagedInstall.binaryURL(appSupportRoot: root)
        XCTAssertEqual(binary.path, root.appendingPathComponent("Mila/bin/claude").path)
    }

    /// Staging must not be reachable by resolution: an unverified download must
    /// never be findable by anything that would run it.
    func test_staging_is_not_the_resolved_binary_path() {
        let staging = ClaudeManagedInstall.stagingDirectory(appSupportRoot: root)
        let binary = ClaudeManagedInstall.binaryURL(appSupportRoot: root)
        XCTAssertNotEqual(staging.path, binary.deletingLastPathComponent().path)
        XCTAssertFalse(binary.path.hasPrefix(staging.path))
    }
}
