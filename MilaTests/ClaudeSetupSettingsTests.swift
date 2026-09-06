import XCTest
@testable import Mila

/// In-memory `ClaudeTokenStoring`, plus a switch to make `delete` fail — the
/// case the sign-out affordance exists to handle honestly.
private final class InMemoryTokenStore: ClaudeTokenStoring {
    private var token: String?
    var refuseDelete = false
    var refuseSave = false

    init(token: String? = nil) { self.token = token }

    func load() -> String? { token }

    @discardableResult
    func save(_ token: String) -> Bool {
        guard !refuseSave else { return false }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        self.token = trimmed
        return true
    }

    @discardableResult
    func delete() -> Bool {
        guard !refuseDelete else { return false }
        token = nil
        return true
    }
}

/// `ClaudeSetupSettings` — the status the Settings row renders, the persisted
/// verification, and sign-out (issue #271).
@MainActor
final class ClaudeSetupSettingsTests: XCTestCase {

    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeSetupSettingsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Isolated suite, per CLAUDE.md: never `.standard`.
        suiteName = "ClaudeSetupSettingsTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    /// Put an executable at the managed path, so `isInstalled` is answered by
    /// the real filesystem check rather than a stub.
    private func installFakeBinary() throws {
        let binary = ClaudeManagedInstall.binaryURL(appSupportRoot: root)
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: binary.path)
    }

    private func makeSettings(tokenStore: ClaudeTokenStoring,
                              testResult: LLMTestResult = LLMTestResult(succeeded: true))
    -> ClaudeSetupSettings {
        ClaudeSetupSettings(defaults: defaults,
                            tokenStore: tokenStore,
                            appSupportRoot: root,
                            openURL: { _ in XCTFail("no browser should open in a test") },
                            runTest: { _, _ in testResult })
    }

    // MARK: - Status

    func test_status_is_not_set_up_with_no_binary() {
        let settings = makeSettings(tokenStore: InMemoryTokenStore())
        XCTAssertEqual(settings.status, .notSetUp)
        XCTAssertFalse(settings.status.isReady)
    }

    func test_status_is_installed_but_not_signed_in_without_a_token() throws {
        try installFakeBinary()
        let settings = makeSettings(tokenStore: InMemoryTokenStore())
        XCTAssertEqual(settings.status, .installedNotSignedIn)
        XCTAssertFalse(settings.status.isReady)
    }

    /// A token alone is "signed in", not "signed in and working" — nothing has
    /// been run yet.
    func test_status_is_signed_in_unverified_with_a_token_but_no_test() throws {
        try installFakeBinary()
        let settings = makeSettings(tokenStore: InMemoryTokenStore(token: "sk-ant-oat-x"))
        XCTAssertEqual(settings.status, .signedIn(verified: false))
        XCTAssertTrue(settings.status.isReady)
    }

    func test_a_passing_test_upgrades_the_status_to_verified() async throws {
        try installFakeBinary()
        let settings = makeSettings(tokenStore: InMemoryTokenStore(token: "sk-ant-oat-x"))

        await settings.test()

        XCTAssertTrue(settings.verified)
        XCTAssertEqual(settings.status, .signedIn(verified: true))
    }

    func test_a_failing_test_clears_the_verification() async throws {
        try installFakeBinary()
        let settings = makeSettings(
            tokenStore: InMemoryTokenStore(token: "sk-ant-oat-x"),
            testResult: LLMTestResult(succeeded: false, setupError: "nope"))

        await settings.test()

        XCTAssertFalse(settings.verified)
        XCTAssertEqual(settings.status, .signedIn(verified: false))
    }

    // MARK: - Persisted verification

    /// The `DiarizationSettings` pattern: the persisted flag is restored only
    /// when every parameter it was recorded against still holds.
    func test_verification_survives_a_relaunch_when_nothing_changed() async throws {
        try installFakeBinary()
        defaults.set("2.1.263", forKey: ClaudeSetupSettings.Keys.installedVersion)

        let first = makeSettings(tokenStore: InMemoryTokenStore(token: "sk-ant-oat-x"))
        await first.test()
        XCTAssertTrue(first.verified)

        // A fresh object over the same defaults and the same install.
        let relaunched = makeSettings(tokenStore: InMemoryTokenStore(token: "sk-ant-oat-x"))
        XCTAssertTrue(relaunched.verified, "the proof was about this exact setup")
        XCTAssertEqual(relaunched.status, .signedIn(verified: true))
    }

    func test_verification_is_not_restored_after_the_version_changed() async throws {
        try installFakeBinary()
        defaults.set("2.1.263", forKey: ClaudeSetupSettings.Keys.installedVersion)

        let first = makeSettings(tokenStore: InMemoryTokenStore(token: "sk-ant-oat-x"))
        await first.test()
        XCTAssertTrue(first.verified)

        // A reinstall brought different bytes: the Test that passed was against
        // the previous binary.
        defaults.set("2.2.0", forKey: ClaudeSetupSettings.Keys.installedVersion)
        let relaunched = makeSettings(tokenStore: InMemoryTokenStore(token: "sk-ant-oat-x"))
        XCTAssertFalse(relaunched.verified)
    }

    func test_verification_is_not_restored_without_a_credential() async throws {
        try installFakeBinary()
        let first = makeSettings(tokenStore: InMemoryTokenStore(token: "sk-ant-oat-x"))
        await first.test()
        XCTAssertTrue(first.verified)

        let relaunched = makeSettings(tokenStore: InMemoryTokenStore(token: nil))
        XCTAssertFalse(relaunched.verified)
        XCTAssertEqual(relaunched.status, .installedNotSignedIn)
    }

    func test_verification_is_not_restored_without_a_binary() async throws {
        try installFakeBinary()
        let first = makeSettings(tokenStore: InMemoryTokenStore(token: "sk-ant-oat-x"))
        await first.test()
        XCTAssertTrue(first.verified)

        try FileManager.default.removeItem(at: ClaudeManagedInstall.binaryURL(appSupportRoot: root))
        let relaunched = makeSettings(tokenStore: InMemoryTokenStore(token: "sk-ant-oat-x"))
        XCTAssertFalse(relaunched.verified)
        XCTAssertEqual(relaunched.status, .notSetUp)
    }

    // MARK: - Sign out

    func test_signing_out_removes_the_credential_and_drops_the_verification() async throws {
        try installFakeBinary()
        let store = InMemoryTokenStore(token: "sk-ant-oat-x")
        let settings = makeSettings(tokenStore: store)
        await settings.test()
        XCTAssertTrue(settings.verified)

        settings.signOut()

        XCTAssertNil(store.load())
        XCTAssertFalse(settings.hasToken)
        XCTAssertFalse(settings.verified)
        XCTAssertFalse(settings.signOutFailed)
        XCTAssertEqual(settings.status, .installedNotSignedIn,
                       "the binary is still installed — only the credential went")
    }

    /// The one state that must never be shown: "signed out" over a credential
    /// that is still in the Keychain.
    func test_a_failed_sign_out_keeps_showing_signed_in() throws {
        try installFakeBinary()
        let store = InMemoryTokenStore(token: "sk-ant-oat-x")
        store.refuseDelete = true
        let settings = makeSettings(tokenStore: store)

        settings.signOut()

        XCTAssertTrue(settings.signOutFailed)
        XCTAssertTrue(settings.hasToken)
        XCTAssertEqual(settings.status, .signedIn(verified: false),
                       "the UI must not claim a removal that did not happen")
        XCTAssertNotNil(store.load())
    }

    func test_signing_out_can_also_delete_the_binary() throws {
        try installFakeBinary()
        let settings = makeSettings(tokenStore: InMemoryTokenStore(token: "sk-ant-oat-x"))

        settings.signOut(removeBinary: true)

        XCTAssertEqual(settings.status, .notSetUp)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ClaudeManagedInstall.binaryURL(appSupportRoot: root).path))
        XCTAssertNil(settings.installedVersion)
    }

    // MARK: - The credential never reaches UserDefaults

    /// `defaults read` must not print this, and it must not ride along in a
    /// preferences backup.
    func test_no_defaults_key_ever_holds_the_token() async throws {
        try installFakeBinary()
        let secret = "sk-ant-oat01-" + String(repeating: "Z9y8X7w6", count: 8)
        let settings = makeSettings(tokenStore: InMemoryTokenStore(token: secret))
        await settings.test()
        settings.signOut()

        let dump = defaults.dictionaryRepresentation()
        for (key, value) in dump {
            XCTAssertFalse("\(value)".contains(secret),
                           "the credential must never be written to defaults (key \(key))")
        }
    }

    // MARK: - Keychain store

    /// The real store against the real Keychain, on an isolated item — the same
    /// treatment `MilaConfigTests` and `OpenAICompatibleTests` give theirs.
    func test_keychain_store_round_trips_and_verifies_its_delete() throws {
        let key = "ClaudeSetupSettingsTests.\(UUID().uuidString).token"
        let store = KeychainClaudeTokenStore(key: key)
        defer { KeychainHelper.delete(key: key) }

        XCTAssertNil(store.load(), "nothing stored yet")

        guard store.save("sk-ant-oat01-round-trip") else {
            throw XCTSkip("the login keychain is not writable in this environment")
        }
        XCTAssertEqual(store.load(), "sk-ant-oat01-round-trip")

        XCTAssertTrue(store.delete())
        XCTAssertNil(store.load())
        XCTAssertTrue(store.delete(), "deleting nothing still ends with nothing there")
    }

    func test_keychain_store_trims_and_refuses_an_empty_token() throws {
        let key = "ClaudeSetupSettingsTests.\(UUID().uuidString).token"
        let store = KeychainClaudeTokenStore(key: key)
        defer { KeychainHelper.delete(key: key) }

        XCTAssertFalse(store.save("   "), "an empty credential is not a credential")
        XCTAssertNil(store.load())

        guard store.save("  sk-ant-oat01-padded \n") else {
            throw XCTSkip("the login keychain is not writable in this environment")
        }
        XCTAssertEqual(store.load(), "sk-ant-oat01-padded",
                       "a code copied out of a browser brings whitespace with it")
    }

    /// The app's real credential lives under a namespaced Keychain account, and
    /// the production store is the Keychain one.
    ///
    /// Asserted by construction rather than by writing: this is the ONE item a
    /// test must never touch, because clobbering it would sign the developer
    /// running the suite out of their own Mila.
    func test_the_production_store_is_the_keychain_one_under_a_namespaced_key() {
        XCTAssertEqual(KeychainClaudeTokenStore.defaultKey, "claudeSetup.oauthToken")

        let production: ClaudeTokenStoring = KeychainClaudeTokenStore()
        XCTAssertTrue(production is KeychainClaudeTokenStore,
                      "the default credential store must be Keychain-backed, never UserDefaults")
    }
}
