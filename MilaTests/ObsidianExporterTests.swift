import XCTest
@testable import Mila

@MainActor
final class ObsidianExporterTests: XCTestCase {

    private var tempRoot: URL!
    private var vault: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: ObsidianVaultSettings!
    private var exporter: ObsidianExporter!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MilaObsidianExporterTests-\(UUID())", isDirectory: true)
        vault = tempRoot.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        suiteName = "ObsidianExporterTests.\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)
        settings = ObsidianVaultSettings(defaults: defaults)
        settings.enabled = true
        settings.subfolder = ""   // vault root for most tests
        XCTAssertTrue(settings.setVault(vault))
        exporter = ObsidianExporter(settings: settings, defaults: defaults)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        if let suiteName { defaults.removePersistentDomain(forName: suiteName) }
        try await super.tearDown()
    }

    private func makeRecording(title: String = "Team Sync",
                               createdAt: Date = Date(timeIntervalSince1970: 1_767_312_000), // 2026-01-02 UTC-ish
                               summary: String? = nil,
                               fullText: String = "",
                               folder: String? = nil,
                               actionItems: [ActionItem]? = nil) -> Recording {
        var rec = Recording(title: title,
                            createdAt: createdAt,
                            source: .microphone,
                            audioFileName: "a.wav",
                            fullText: fullText)
        rec.summary = summary
        rec.actionItems = actionItems
        rec.folder = folder
        return rec
    }

    private func action(_ text: String) -> ActionItem {
        ActionItem(id: UUID().uuidString, text: text, speaker: nil,
                   timestampSeconds: 0, source: .llmInferred, addedAt: Date())
    }

    // MARK: - Formatting

    func test_markdown_uses_summary_and_action_items() {
        let rec = makeRecording(summary: "We decided to ship next week.",
                                fullText: "long transcript here",
                                actionItems: [action("Ship it"), action("Email Sam")])
        let md = ObsidianExporter.markdown(for: rec)
        XCTAssertTrue(md.contains("# Team Sync"))
        XCTAssertTrue(md.contains("We decided to ship next week."))
        XCTAssertTrue(md.contains("- [ ] Ship it"))
        XCTAssertTrue(md.contains("- [ ] Email Sam"))
        XCTAssertFalse(md.contains("## Transcript"),
                       "When a summary exists the transcript body is omitted")
    }

    func test_markdown_falls_back_to_transcript_without_summary() {
        let rec = makeRecording(summary: nil, fullText: "hello world transcript",
                                actionItems: [action("Do thing")])
        let md = ObsidianExporter.markdown(for: rec)
        XCTAssertTrue(md.contains("## Transcript"))
        XCTAssertTrue(md.contains("hello world transcript"))
        XCTAssertTrue(md.contains("- [ ] Do thing"))
    }

    func test_hasContent_false_when_nothing_present() {
        let empty = makeRecording(summary: nil, fullText: "", actionItems: nil)
        XCTAssertFalse(ObsidianExporter.hasContent(empty))
        XCTAssertTrue(ObsidianExporter.hasContent(makeRecording(fullText: "x")))
    }

    func test_fileName_is_date_and_sanitized_title() {
        let rec = makeRecording(title: "My/Meeting: Q3?")
        let name = ObsidianExporter.fileName(for: rec)
        XCTAssertTrue(name.hasSuffix(".md"))
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertFalse(name.contains("?"))
        XCTAssertTrue(name.contains("My Meeting Q3"))
    }

    /// A title made entirely of stripped characters must still produce a
    /// usable, visible, non-relative filename — never "", ".md", "..md" or a
    /// dotfile. The date prefix is what guarantees it.
    func test_fileName_survives_hostile_titles() {
        for hostile in ["", "   ", "///", "..", ".", "...", "\u{0000}\u{0007}", "<>|?*\"\\"] {
            let name = ObsidianExporter.fileName(for: makeRecording(title: hostile))
            XCTAssertTrue(name.hasPrefix("2026-01-02"),
                          "\(hostile.debugDescription) should keep the date prefix, got \(name)")
            XCTAssertTrue(name.hasSuffix(".md"))
            XCTAssertFalse(name.hasPrefix("."), "must never be a dotfile: \(name)")
            XCTAssertNotEqual(name, "..md")
            XCTAssertFalse(name.contains("/"))
        }
    }

    /// APFS caps a path component at 255 bytes. A pathological title must be
    /// truncated rather than making the write fail.
    func test_fileName_is_capped_to_a_writable_length() throws {
        let long = String(repeating: "עברית ", count: 200)   // multi-byte, ~2200 bytes
        let name = ObsidianExporter.fileName(for: makeRecording(title: long))
        XCTAssertLessThanOrEqual(name.utf8.count, 255)
        // And it actually writes.
        let rec = makeRecording(title: long, summary: "S")
        XCTAssertNotNil(exporter.export(rec))
    }

    /// A Mila folder literally named ".." must not walk out of the configured
    /// subfolder. `sanitizedTitle` alone would have let it through.
    func test_export_folder_named_dotdot_cannot_escape_the_subfolder() throws {
        settings.subfolder = "Notes"
        let base = vault.appendingPathComponent("Notes").standardizedFileURL.path
        for hostile in ["..", ".", "../..", ".hidden"] {
            let rec = makeRecording(title: "T-\(hostile)", summary: "S", folder: hostile)
            let url = try XCTUnwrap(exporter.export(rec))
            let dir = url.deletingLastPathComponent().standardizedFileURL.path
            XCTAssertTrue(dir == base || dir.hasPrefix(base + "/"),
                          "folder \(hostile.debugDescription) escaped to \(dir)")
            XCTAssertFalse(url.lastPathComponent.hasPrefix("."))
        }
    }

    /// The summary hook can land after the user has trashed the recording
    /// (the LLM call was still in flight). A trashed recording is never filed.
    func test_export_skips_a_trashed_recording() {
        var rec = makeRecording(summary: "S")
        rec.deletedAt = Date()
        XCTAssertNil(exporter.export(rec))
        XCTAssertEqual(exporter.exportAll([rec]), 0)
    }

    // MARK: - Writing

    func test_export_writes_note_into_vault() throws {
        let rec = makeRecording(summary: "S", actionItems: [action("A")])
        let url = try XCTUnwrap(exporter.export(rec))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("# Team Sync"))
        XCTAssertTrue(contents.contains("- [ ] A"))
    }

    func test_export_creates_configured_subfolder() throws {
        settings.subfolder = "Notes/Sub"
        let rec = makeRecording(summary: "S")
        let url = try XCTUnwrap(exporter.export(rec))
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL,
                       vault.appendingPathComponent("Notes/Sub").standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func test_export_noop_when_disabled() {
        settings.enabled = false
        XCTAssertNil(exporter.export(makeRecording(summary: "S")))
    }

    func test_export_noop_when_recording_is_empty() {
        XCTAssertNil(exporter.export(makeRecording(summary: nil, fullText: "", actionItems: nil)))
    }

    func test_reexport_with_changed_title_removes_the_old_file() throws {
        var rec = makeRecording(title: "First", summary: "S")
        let firstURL = try XCTUnwrap(exporter.export(rec))
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))

        rec.title = "Second"   // same id + date, new title
        let secondURL = try XCTUnwrap(exporter.export(rec))
        XCTAssertNotEqual(firstURL.path, secondURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path),
                       "The previously-written note for this recording must be removed")
    }

    func test_export_mirrors_mila_folder_under_subfolder() throws {
        settings.subfolder = "Notes"
        let rec = makeRecording(summary: "S", folder: "Client: Acme")
        let url = try XCTUnwrap(exporter.export(rec))
        // Folder name is sanitized (":" stripped) and nested under the subfolder.
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL,
                       vault.appendingPathComponent("Notes/Client Acme").standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func test_export_unfiled_recording_lands_in_base_dir() throws {
        settings.subfolder = "Notes"
        let rec = makeRecording(summary: "S", folder: nil)
        let url = try XCTUnwrap(exporter.export(rec))
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL,
                       vault.appendingPathComponent("Notes").standardizedFileURL)
    }

    // MARK: - Backfill (exportAll)

    func test_exportAll_writes_all_with_content_and_skips_empty() throws {
        let a = makeRecording(title: "Alpha", summary: "S")
        let b = makeRecording(title: "Beta", fullText: "transcript", folder: "Work")
        let empty = makeRecording(title: "Empty", summary: nil, fullText: "", actionItems: nil)
        let count = exporter.exportAll([a, b, empty])
        XCTAssertEqual(count, 2, "the empty recording should be skipped")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: vault.appendingPathComponent("2026-01-02 Alpha.md").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: vault.appendingPathComponent("Work/2026-01-02 Beta.md").path),
            "a filed recording should nest under its Mila folder")
    }

    func test_exportAll_noop_when_disabled() {
        settings.enabled = false
        XCTAssertEqual(exporter.exportAll([makeRecording(summary: "S")]), 0)
    }

    // MARK: - Pending gate

    func test_pending_gate() {
        let id = UUID()
        XCTAssertFalse(exporter.isPending(id))
        exporter.markPending(id)
        XCTAssertTrue(exporter.isPending(id))
        exporter.clearPending(id)
        XCTAssertFalse(exporter.isPending(id))
    }
}
