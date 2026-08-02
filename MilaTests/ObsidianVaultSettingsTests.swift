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

    /// Pins the shipped contract: on a fresh install the feature is off, has no
    /// vault, and the exporter is inert — nothing is written even if something
    /// calls it. The one thing this can't assert is the UI (no XCUITest here);
    /// `ObsidianSettingsSection` renders only its toggle while `enabled` is
    /// false, and the app adds no other Obsidian affordance anywhere.
    func test_fresh_install_is_disabled_and_exports_nothing() throws {
        let settings = ObsidianVaultSettings(defaults: defaults)
        let exporter = ObsidianExporter(settings: settings, defaults: defaults)

        XCTAssertFalse(settings.enabled, "the feature must be opt-in")
        XCTAssertNil(settings.vaultURL, "no vault until the user picks one")
        XCTAssertNil(settings.destinationDirectory)

        var rec = Recording(title: "Team Sync", source: .microphone,
                            audioFileName: "a.wav", fullText: "a transcript")
        rec.summary = "A summary."
        XCTAssertNil(exporter.export(rec))
        XCTAssertEqual(exporter.exportAll([rec]), 0)

        // Enabling alone still isn't enough — a vault is required.
        settings.enabled = true
        XCTAssertNil(settings.vaultURL)
        XCTAssertNil(exporter.export(rec))
        XCTAssertEqual(exporter.exportAll([rec]), 0)
    }

    /// `subfolder` is a free-text field. A typed relative path must resolve
    /// inside the vault, never above it.
    func test_subfolder_cannot_escape_the_vault() throws {
        let vault = tempRoot.appendingPathComponent("VaultEscape", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let settings = ObsidianVaultSettings(defaults: defaults)
        XCTAssertTrue(settings.setVault(vault))
        // `standardized`, not `standardizedFileURL`, throughout: the latter
        // consults the filesystem and drops a `/private` prefix only when the
        // path exists, so it renders an existing vault as `/var/…` and a
        // not-yet-created destination under it as `/private/var/…` — the two
        // then never compare equal. `standardized` is purely lexical, which is
        // also exactly what a traversal assertion needs (`vault/..` must
        // collapse so an escape is visible).
        let base = try XCTUnwrap(settings.vaultURL).standardized.path

        // Traversal shapes. The dot-plus-space and dot-slash-dot families
        // matter as much as bare `..`: a sanitizer that strips leading dots
        // only leaves `".."` behind for ". .." (it stops at the space) and for
        // "../.." (whose `/` becomes a space before the dots are stripped).
        for hostile in ["../../Desktop", "..", "./..", "../Notes", "Notes/../..", ".",
                        ". ..", "Notes/. ../. ..", ". . ..", ".\t..", "..\\..",
                        " ..", ".. ", "....", ". . . ."] {
            settings.subfolder = hostile
            let dest = try XCTUnwrap(settings.destinationDirectory).standardized.path
            XCTAssertTrue(dest == base || dest.hasPrefix(base + "/"),
                          "subfolder \(hostile.debugDescription) escaped to \(dest)")
        }

        // A legitimate nested path still works, and a hidden component is
        // un-hidden rather than dropped.
        settings.subfolder = "Notes/Meetings"
        XCTAssertEqual(try XCTUnwrap(settings.destinationDirectory).standardized.path,
                       base + "/Notes/Meetings")
        settings.subfolder = ".secret"
        XCTAssertEqual(try XCTUnwrap(settings.destinationDirectory).standardized.path,
                       base + "/secret")
    }

    func test_path_sanitizer_component_rules() {
        XCTAssertEqual(ObsidianPathSanitizer.directoryComponent(".."), "")
        XCTAssertEqual(ObsidianPathSanitizer.directoryComponent("."), "")
        XCTAssertEqual(ObsidianPathSanitizer.directoryComponent(".hidden"), "hidden")
        XCTAssertEqual(ObsidianPathSanitizer.directoryComponent("Client: Acme"), "Client Acme")
        XCTAssertEqual(ObsidianPathSanitizer.relativePath("../../a/./b"), "a/b")
        XCTAssertEqual(ObsidianPathSanitizer.relativePath("///"), "")
        XCTAssertLessThanOrEqual(
            ObsidianPathSanitizer.nameFragment(String(repeating: "é", count: 500)).utf8.count, 180)
    }

    /// The dot-stripping rule, pinned input by input. Every one of these
    /// reduced to a live `".."` under the leading-dots-only rule.
    func test_path_sanitizer_cannot_produce_a_traversal_component() {
        for hostile in [". ..", ".\t..", ". . ..", "../..", "..\\..", " ..", ".. ",
                        "....", ". . . .", ".  ..", "./..", "..;..", "\t. ..\t"] {
            let component = ObsidianPathSanitizer.directoryComponent(hostile)
            XCTAssertNotEqual(component, "..", "\(hostile.debugDescription) survived as ..")
            XCTAssertNotEqual(component, ".", "\(hostile.debugDescription) survived as .")
            XCTAssertFalse(component.hasPrefix("."),
                           "\(hostile.debugDescription) produced a dotfile: \(component)")
        }
        XCTAssertEqual(ObsidianPathSanitizer.directoryComponent(". .."), "")
        XCTAssertEqual(ObsidianPathSanitizer.directoryComponent("../.."), "")
        XCTAssertEqual(ObsidianPathSanitizer.directoryComponent(". . .."), "")
        XCTAssertEqual(ObsidianPathSanitizer.relativePath("a/. ../. ../Desktop"), "a/Desktop")
        XCTAssertEqual(ObsidianPathSanitizer.relativePath("Notes/. ../. .."), "Notes")

        // A dot that isn't leading is an ordinary character, not a threat.
        XCTAssertEqual(ObsidianPathSanitizer.directoryComponent("2026.01 Notes"), "2026.01 Notes")
        XCTAssertEqual(ObsidianPathSanitizer.directoryComponent(".. Real Name"), "Real Name")
    }

    /// The containment guard the exporter leans on at write time.
    func test_isContained_rejects_escapes() {
        let root = URL(fileURLWithPath: "/private/tmp/Vault")
        XCTAssertTrue(ObsidianPathSanitizer.isContained(root, in: root))
        XCTAssertTrue(ObsidianPathSanitizer.isContained(
            root.appendingPathComponent("Notes/a.md"), in: root))
        XCTAssertFalse(ObsidianPathSanitizer.isContained(
            root.appendingPathComponent(".."), in: root))
        XCTAssertFalse(ObsidianPathSanitizer.isContained(
            root.appendingPathComponent("Notes/../../Desktop"), in: root))
        // A sibling whose path merely starts with the same characters.
        XCTAssertFalse(ObsidianPathSanitizer.isContained(
            URL(fileURLWithPath: "/private/tmp/VaultOther"), in: root))
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
