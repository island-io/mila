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

    /// 2026-01-02T12:00:00Z. Midday rather than the midnight this used to be,
    /// so the fixture doesn't sit on a date boundary that a local time zone can
    /// push either way.
    private static let fixtureDate = Date(timeIntervalSince1970: 1_767_355_200)

    /// The date `ObsidianExporter.fileName` will actually produce for
    /// `fixtureDate`. Derived, not hard-coded: `fileName` formats in the local
    /// time zone by design (a user's note should carry the date they recorded
    /// it), so a literal "2026-01-02" would still be wrong at UTC+13/+14 even
    /// with a midday fixture. Deriving it pins the contract — "the filename
    /// starts with the recording's local date" — in every zone.
    private static let expectedDatePrefix: String = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: fixtureDate)
    }()

    private func makeRecording(title: String = "Team Sync",
                               createdAt: Date = ObsidianExporterTests.fixtureDate,
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
            XCTAssertTrue(name.hasPrefix(Self.expectedDatePrefix),
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
        // Two rules, both learned the hard way:
        //
        //  * Derive the expectation from `settings.vaultURL`, not from the raw
        //    `vault` this test created. `setVault` round-trips through a
        //    security-scoped bookmark, which resolves `/var/folders/…` to its
        //    real `/private/var/folders/…`. The exporter writes under the
        //    resolved one, so comparing against the raw one compares two
        //    spellings of the same directory.
        //  * `standardized` (lexical), not `standardizedFileURL`: the latter
        //    consults the filesystem and strips a `/private` prefix only for
        //    paths that already exist, so it normalizes an existing directory
        //    and a fresh one differently.
        let vaultRoot = try XCTUnwrap(settings.vaultURL)
        let base = vaultRoot.appendingPathComponent("Notes").standardized.path
        // "../.." is the one that shipped broken: `nameFragment` turns its "/"
        // into a space, so a leading-dots-only strip stopped at that space and
        // handed back a live "..".
        for hostile in ["..", ".", "../..", ".hidden", ". ..", ".\t..", ". . ..",
                        "....", " ..", "..\\..", ".. "] {
            let rec = makeRecording(title: "T-\(hostile)", summary: "S", folder: hostile)
            let url = try XCTUnwrap(exporter.export(rec))
            let dir = url.deletingLastPathComponent().standardized.path
            XCTAssertTrue(dir == base || dir.hasPrefix(base + "/"),
                          "folder \(hostile.debugDescription) escaped to \(dir)")
            XCTAssertFalse(url.lastPathComponent.hasPrefix("."))
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "folder \(hostile.debugDescription) reported a path it did not write")
        }
    }

    /// The hostile title/folder combination, checked at the level that
    /// actually matters: nothing lands outside the vault, whatever the inputs.
    func test_export_never_writes_outside_the_vault() throws {
        // Resolved vault, not the raw one — see the note above.
        let vaultRoot = try XCTUnwrap(settings.vaultURL)
        settings.subfolder = ". .."
        for folder in ["..", ". ..", "../..", nil] {
            let rec = makeRecording(title: ".. ../..", summary: "S", folder: folder)
            let url = try XCTUnwrap(exporter.export(rec))
            XCTAssertTrue(ObsidianPathSanitizer.isContained(url, in: vaultRoot),
                          "wrote outside the vault: \(url.path)")
        }
    }

    /// The traversal hole one layer below the naming rules: a Mila folder (or a
    /// typed subfolder) whose name matches a **symlink inside the vault** that
    /// points outside it. Nothing here is a `..` — the path is spelled entirely
    /// under the vault — so only resolving the link catches it.
    func test_export_refuses_a_folder_that_symlinks_out_of_the_vault() throws {
        let fm = FileManager.default
        let vaultRoot = try XCTUnwrap(settings.vaultURL)
        let outside = tempRoot.appendingPathComponent("Outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: vaultRoot.appendingPathComponent("Escape"),
                                  withDestinationURL: outside)
        try fm.createSymbolicLink(atPath: vaultRoot.appendingPathComponent("Up").path,
                                  withDestinationPath: "../Outside")

        for hostile in ["Escape", "Up"] {
            let rec = makeRecording(title: "Leak \(hostile)", summary: "S", folder: hostile)
            XCTAssertNil(exporter.export(rec),
                         "folder \(hostile) wrote through a symlink out of the vault")
        }
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: outside.path).isEmpty,
                      "a note escaped the vault")

        // The same shape via the free-text subfolder field.
        settings.subfolder = "Escape"
        XCTAssertNil(exporter.export(makeRecording(title: "Leak subfolder", summary: "S")))
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: outside.path).isEmpty)

        // And an ordinary subfolder is untouched by any of this.
        settings.subfolder = ""
        let ok = try XCTUnwrap(exporter.export(
            makeRecording(title: "Fine", summary: "S", folder: "Meetings")))
        XCTAssertTrue(ObsidianPathSanitizer.isContained(ok, in: vaultRoot))
        XCTAssertTrue(fm.fileExists(atPath: ok.path))
    }

    /// A symlink whose target is *inside* the vault is a legitimate way to
    /// organise one, and resolving it lands the note in the vault regardless —
    /// so it is allowed rather than refused.
    func test_export_allows_a_folder_symlinked_within_the_vault() throws {
        let fm = FileManager.default
        let vaultRoot = try XCTUnwrap(settings.vaultURL)
        let real = vaultRoot.appendingPathComponent("Real", isDirectory: true)
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: vaultRoot.appendingPathComponent("Alias"),
                                  withDestinationURL: real)

        let url = try XCTUnwrap(exporter.export(
            makeRecording(title: "Aliased", summary: "S", folder: "Alias")))
        XCTAssertTrue(fm.fileExists(atPath: real.appendingPathComponent(url.lastPathComponent).path),
                      "the note should land in the symlink's target inside the vault")
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
            atPath: vault.appendingPathComponent("\(Self.expectedDatePrefix) Alpha.md").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: vault.appendingPathComponent("Work/\(Self.expectedDatePrefix) Beta.md").path),
            "a filed recording should nest under its Mila folder")
    }

    func test_exportAll_noop_when_disabled() {
        settings.enabled = false
        XCTAssertEqual(exporter.exportAll([makeRecording(summary: "S")]), 0)
    }

    /// A rename changes *two* paths (the new file plus the removed old one) for
    /// a single written note. The returned count — which the Settings backfill
    /// label and the git commit subject both quote — must count notes, not
    /// paths.
    func test_exportAll_counts_notes_not_changed_paths() throws {
        var rec = makeRecording(title: "Before", summary: "S")
        XCTAssertEqual(exporter.exportAll([rec]), 1)
        rec.title = "After"
        XCTAssertEqual(exporter.exportAll([rec]), 1,
                       "a rename is still one note, not two changed paths")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: vault.appendingPathComponent("\(Self.expectedDatePrefix) Before.md").path),
            "the old note should be removed by the rename")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: vault.appendingPathComponent("\(Self.expectedDatePrefix) After.md").path))
    }

    // MARK: - Filename collisions

    /// Titles are not unique. They default to the capture source — see
    /// `QuickActionsController`, which titles a system-audio capture with the
    /// foreground app's name or "System Audio" — so two captures on the same
    /// day routinely want the same `<date> <title>.md`. Before this was
    /// handled, the second export silently overwrote the first and one note
    /// was lost: the index is keyed by recording ID, so both recordings held
    /// an entry pointing at the same file and the rename cleanup saw nothing
    /// wrong.
    func test_two_same_day_same_title_recordings_get_distinct_notes() throws {
        let first = makeRecording(title: "System Audio", summary: "First meeting")
        let second = makeRecording(title: "System Audio", summary: "Second meeting")
        XCTAssertNotEqual(first.id, second.id)

        let firstURL = try XCTUnwrap(exporter.export(first))
        let secondURL = try XCTUnwrap(exporter.export(second))

        XCTAssertNotEqual(firstURL.path, secondURL.path,
                          "the second recording must not land on the first one's note")
        XCTAssertEqual(try String(contentsOf: firstURL, encoding: .utf8).contains("First meeting"),
                       true, "the first note was overwritten")
        XCTAssertTrue(try String(contentsOf: secondURL, encoding: .utf8).contains("Second meeting"))

        // The first one keeps the clean name; only the loser of the race is
        // suffixed, and it is suffixed from its own ID.
        XCTAssertEqual(firstURL.lastPathComponent, "\(Self.expectedDatePrefix) System Audio.md")
        XCTAssertTrue(secondURL.lastPathComponent.hasPrefix("\(Self.expectedDatePrefix) System Audio "))
        XCTAssertTrue(secondURL.lastPathComponent
            .contains(second.id.uuidString.lowercased().prefix(8)))

        XCTAssertEqual(try Self.notes(in: vault).count, 2)
    }

    /// The idempotency half: re-exporting either recording (a re-transcription,
    /// a late summary, a backfill sweep) must overwrite *its own* note rather
    /// than mint a third. The disambiguated name has to be remembered and
    /// reused, not recomputed against whatever is on disk at the time.
    func test_reexport_after_a_collision_overwrites_each_recordings_own_note() throws {
        var first = makeRecording(title: "System Audio", summary: "First v1")
        var second = makeRecording(title: "System Audio", summary: "Second v1")
        let firstURL = try XCTUnwrap(exporter.export(first))
        let secondURL = try XCTUnwrap(exporter.export(second))

        // Re-export in the opposite order, to prove the choice doesn't depend
        // on who happens to run first.
        second.summary = "Second v2"
        first.summary = "First v2"
        XCTAssertEqual(try XCTUnwrap(exporter.export(second)).path, secondURL.path)
        XCTAssertEqual(try XCTUnwrap(exporter.export(first)).path, firstURL.path)

        XCTAssertEqual(try Self.notes(in: vault).count, 2, "a re-export must not create a third note")
        XCTAssertTrue(try String(contentsOf: firstURL, encoding: .utf8).contains("First v2"))
        XCTAssertTrue(try String(contentsOf: secondURL, encoding: .utf8).contains("Second v2"))
    }

    /// Same collision, arriving through the backfill path in a single batch —
    /// where the index is threaded in memory and only persisted at the end, so
    /// the in-batch claim is the only thing standing between the two notes.
    func test_exportAll_disambiguates_same_day_same_title_recordings() throws {
        let a = makeRecording(title: "System Audio", summary: "A")
        let b = makeRecording(title: "System Audio", summary: "B")
        let c = makeRecording(title: "System Audio", summary: "C")

        XCTAssertEqual(exporter.exportAll([a, b, c]), 3)
        XCTAssertEqual(try Self.notes(in: vault).count, 3)

        // And running the same sweep again is a no-op on the file count.
        XCTAssertEqual(exporter.exportAll([a, b, c]), 3)
        XCTAssertEqual(try Self.notes(in: vault).count, 3)
    }

    /// The suffix sticks even once the plain name frees up. Recomputing
    /// availability on every run would move the note back, renaming a file in
    /// the user's vault (and breaking their links to it) because an unrelated
    /// note was deleted.
    func test_disambiguated_note_keeps_its_name_after_the_plain_one_frees_up() throws {
        var first = makeRecording(title: "System Audio", summary: "First")
        let second = makeRecording(title: "System Audio", summary: "Second")
        let firstURL = try XCTUnwrap(exporter.export(first))
        let secondURL = try XCTUnwrap(exporter.export(second))

        // The plain name is released — the first recording is retitled.
        first.title = "Renamed"
        XCTAssertNotNil(exporter.export(first))
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))

        XCTAssertEqual(try XCTUnwrap(exporter.export(second)).path, secondURL.path,
                       "the disambiguated note must not migrate back to the plain name")
    }

    /// A file the exporter has no record of — a note from a build before the
    /// index existed, a copy landing over git sync, or something the user wrote
    /// by hand — is not ours to clobber either. The index can't know about it,
    /// so the on-disk check is what catches this one.
    func test_export_does_not_clobber_an_unknown_file_with_the_same_name() throws {
        let vaultRoot = try XCTUnwrap(settings.vaultURL)
        let squatter = vaultRoot.appendingPathComponent("\(Self.expectedDatePrefix) System Audio.md")
        try "hand-written".write(to: squatter, atomically: true, encoding: .utf8)

        let rec = makeRecording(title: "System Audio", summary: "Mine")
        let url = try XCTUnwrap(exporter.export(rec))
        XCTAssertNotEqual(url.path, squatter.path)
        XCTAssertEqual(try String(contentsOf: squatter, encoding: .utf8), "hand-written")

        // Still idempotent against it.
        XCTAssertEqual(try XCTUnwrap(exporter.export(rec)).path, url.path)
        XCTAssertEqual(try Self.notes(in: vaultRoot).count, 2)
    }

    /// Candidate names are derived from the recording, so they're stable across
    /// runs, and every one of them stays a legal path component.
    func test_nameCandidates_are_distinct_stable_and_writable() {
        let rec = makeRecording(title: String(repeating: "עברית ", count: 200))
        let candidates = ObsidianExporter.nameCandidates(for: rec)
        XCTAssertEqual(candidates, ObsidianExporter.nameCandidates(for: rec), "must be deterministic")
        XCTAssertEqual(Set(candidates).count, candidates.count, "candidates must be distinct")
        XCTAssertEqual(candidates.first, ObsidianExporter.fileName(for: rec))
        for name in candidates {
            XCTAssertTrue(name.hasSuffix(".md"))
            XCTAssertFalse(name.contains("/"))
            XCTAssertFalse(name.hasPrefix("."))
            XCTAssertLessThanOrEqual(name.utf8.count, 255, name)
        }
        // Distinct recordings never share the last-resort candidate.
        let other = makeRecording(title: "Same")
        let another = makeRecording(title: "Same")
        XCTAssertNotEqual(ObsidianExporter.nameCandidates(for: other).last,
                          ObsidianExporter.nameCandidates(for: another).last)
    }

    /// Every `.md` under `dir`, recursively.
    private static func notes(in dir: URL) throws -> [URL] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "md" }
    }

    // MARK: - Written index

    /// The index stores a path *relative to the vault it was written into*. If
    /// the key isn't scoped to that vault, switching vaults and then renaming
    /// makes the rename cleanup delete `<newVault>/<oldRelativePath>` — some
    /// unrelated file — and orphan the real note in the old vault.
    func test_rename_after_a_vault_switch_does_not_delete_in_the_new_vault() throws {
        var rec = makeRecording(title: "Before", summary: "S")
        XCTAssertNotNil(exporter.export(rec))

        // A second vault, holding a same-named file the user owns.
        let other = tempRoot.appendingPathComponent("OtherVault", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let bystander = other.appendingPathComponent("\(Self.expectedDatePrefix) Before.md")
        try "not ours".write(to: bystander, atomically: true, encoding: .utf8)
        XCTAssertTrue(settings.setVault(other))

        rec.title = "After"
        XCTAssertNotNil(exporter.export(rec))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bystander.path),
                      "a rename in a different vault must not delete a file in this one")
        XCTAssertEqual(try String(contentsOf: bystander, encoding: .utf8), "not ours")
        // And the note that really was ours is still where we left it.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: vault.appendingPathComponent("\(Self.expectedDatePrefix) Before.md").path))
    }

    /// A pre-scoping (bare-UUID) index entry is adopted for the current vault
    /// when the file it names is actually there, so an upgrade doesn't leave a
    /// duplicate behind on the first rename.
    func test_legacy_index_entry_is_migrated_when_the_file_is_present() throws {
        var rec = makeRecording(title: "Before", summary: "S")
        let old = try XCTUnwrap(exporter.export(rec))

        // Rewrite the index the way the pre-scoping build stored it.
        defaults.set([rec.id.uuidString: old.lastPathComponent],
                     forKey: ObsidianExporter.writtenIndexKey)

        rec.title = "After"
        XCTAssertNotNil(exporter.export(rec))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path),
                       "the legacy entry should still drive the rename cleanup")
    }

    // MARK: - Markdown line safety

    /// Headings and checklist items are line-based: a newline in a title or an
    /// action item would otherwise split the construct.
    func test_markdown_flattens_newlines_in_heading_and_action_items() {
        let rec = makeRecording(title: "Team\nSync", summary: "S",
                                actionItems: [action("Ship it\nby Friday")])
        let md = ObsidianExporter.markdown(for: rec)
        let lines = md.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "# Team Sync")
        XCTAssertTrue(lines.contains("- [ ] Ship it by Friday"))

        // Whatever the line ending, nothing survives that could break a
        // line-based construct.
        for raw in ["A\nB", "A\r\nB", "A\rB", "A\u{2028}B"] {
            let flat = ObsidianExporter.singleLine(raw)
            XCTAssertFalse(flat.contains("\n"), raw.debugDescription)
            XCTAssertFalse(flat.contains("\r"), raw.debugDescription)
            XCTAssertTrue(flat.hasPrefix("A"), raw.debugDescription)
            XCTAssertTrue(flat.hasSuffix("B"), raw.debugDescription)
        }
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
