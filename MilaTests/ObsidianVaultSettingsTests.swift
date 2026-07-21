import XCTest
@testable import Mila

@MainActor
final class ObsidianVaultSettingsTests: XCTestCase {

    private var tempRoot: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MilaObsidianVaultTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        suiteName = "ObsidianVaultSettingsTests.\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        if let suiteName { defaults.removePersistentDomain(forName: suiteName) }
        try await super.tearDown()
    }

    func test_defaults_are_off_with_transcripts_subfolder_and_main_branch() {
        let settings = ObsidianVaultSettings(defaults: defaults)
        XCTAssertFalse(settings.enabled)
        XCTAssertNil(settings.vaultURL)
        XCTAssertEqual(settings.subfolder, "Transcripts")
        XCTAssertFalse(settings.gitSyncEnabled)
        XCTAssertEqual(settings.gitBranch, "main")
    }

    func test_setVault_persists_bookmark_and_resolves_on_relaunch() throws {
        let vault = tempRoot.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)

        let first = ObsidianVaultSettings(defaults: defaults)
        XCTAssertTrue(first.setVault(vault))
        XCTAssertEqual(first.vaultURL?.standardizedFileURL, vault.standardizedFileURL)

        let second = ObsidianVaultSettings(defaults: defaults)
        XCTAssertEqual(second.vaultURL?.standardizedFileURL, vault.standardizedFileURL)
    }

    func test_clearVault_removes_the_bookmark() throws {
        let vault = tempRoot.appendingPathComponent("Vault2", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)

        let settings = ObsidianVaultSettings(defaults: defaults)
        XCTAssertTrue(settings.setVault(vault))
        settings.clearVault()
        XCTAssertNil(settings.vaultURL)
        XCTAssertNil(defaults.data(forKey: ObsidianVaultSettings.bookmarkKey))
    }

    func test_resolution_falls_back_when_folder_deleted() throws {
        let vault = tempRoot.appendingPathComponent("Gone", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)

        let first = ObsidianVaultSettings(defaults: defaults)
        XCTAssertTrue(first.setVault(vault))
        try FileManager.default.removeItem(at: vault)

        let second = ObsidianVaultSettings(defaults: defaults)
        XCTAssertNil(second.vaultURL)
    }

    func test_enabled_subfolder_git_persist_across_instances() {
        let first = ObsidianVaultSettings(defaults: defaults)
        first.enabled = true
        first.subfolder = "Meetings/2026"
        first.gitSyncEnabled = true
        first.gitBranch = "notes"

        let second = ObsidianVaultSettings(defaults: defaults)
        XCTAssertTrue(second.enabled)
        XCTAssertEqual(second.subfolder, "Meetings/2026")
        XCTAssertTrue(second.gitSyncEnabled)
        XCTAssertEqual(second.gitBranch, "notes")
    }

    func test_destinationDirectory_appends_subfolder_and_strips_slashes() throws {
        let vault = tempRoot.appendingPathComponent("VaultD", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let settings = ObsidianVaultSettings(defaults: defaults)
        XCTAssertTrue(settings.setVault(vault))
        // Compare against the RESOLVED vault URL (bookmark resolution can
        // return a /private-prefixed path) and via `.path`, which drops the
        // trailing slash `appendingPathComponent(isDirectory:)` adds.
        let base = try XCTUnwrap(settings.vaultURL)

        settings.subfolder = "/Transcripts/"
        XCTAssertEqual(settings.destinationDirectory?.standardizedFileURL.path,
                       base.appendingPathComponent("Transcripts").standardizedFileURL.path)

        settings.subfolder = "   "
        XCTAssertEqual(settings.destinationDirectory?.standardizedFileURL.path,
                       base.standardizedFileURL.path,
                       "Blank subfolder should target the vault root")
    }
}
