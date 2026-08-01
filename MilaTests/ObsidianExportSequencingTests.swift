import XCTest
@testable import Mila

/// Verifies the sequencing contract between `RecordingSummarizer` and
/// `ObsidianExporter`: a fresh completion is marked pending and exported only
/// once the summary is ready, while a summary produced without being marked
/// pending (e.g. launch-time backfill) is NOT exported — no vault spam.
@MainActor
final class ObsidianExportSequencingTests: XCTestCase {

    private var tempRoot: URL!
    private var vault: URL!
    private var store: RecordingStore!
    private var llmDefaults: UserDefaults!
    private var liveDefaults: UserDefaults!
    private var obsidianDefaults: UserDefaults!
    private var suiteNames: [String] = []
    private var llm: LLMSettings!
    private var liveAI: LiveAISettings!
    private var settings: ObsidianVaultSettings!
    private var exporter: ObsidianExporter!
    private var summarizer: RecordingSummarizer!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MilaObsidianSeqTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        vault = tempRoot.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        store = RecordingStore(rootDirectory: tempRoot.appendingPathComponent("AppSupport", isDirectory: true))

        let llmSuite = "ObsidianSeq.llm.\(UUID())"
        let liveSuite = "ObsidianSeq.live.\(UUID())"
        let obsSuite = "ObsidianSeq.obs.\(UUID())"
        suiteNames = [llmSuite, liveSuite, obsSuite]
        llmDefaults = UserDefaults(suiteName: llmSuite)
        liveDefaults = UserDefaults(suiteName: liveSuite)
        obsidianDefaults = UserDefaults(suiteName: obsSuite)
        llm = LLMSettings(defaults: llmDefaults)
        llm.tool = .claude
        liveAI = LiveAISettings(defaults: liveDefaults)
        liveAI.model = ""

        settings = ObsidianVaultSettings(defaults: obsidianDefaults)
        settings.enabled = true
        settings.subfolder = ""
        XCTAssertTrue(settings.setVault(vault))
        exporter = ObsidianExporter(settings: settings, defaults: obsidianDefaults)

        // Wire the hook exactly like MilaApp does.
        summarizer = RecordingSummarizer(store: store, llmSettings: llm, liveAISettings: liveAI,
                                         runLLM: { _, _, _, _, _, _, _, _, _, _, _ in "A tidy summary." })
        summarizer.onSummaryFinished = { [weak exporter] rec in
            guard let exporter, exporter.isPending(rec.id) else { return }
            exporter.export(rec)
            exporter.clearPending(rec.id)
        }
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        try await super.tearDown()
    }

    /// Rebuild the summarizer with a stub that fails, keeping the same hook
    /// wiring MilaApp uses. Models "the LLM call blew up" and, combined with a
    /// delete, "the user cancelled/deleted while it was in flight".
    private func useFailingLLM() {
        struct StubFailure: Error {}
        summarizer = RecordingSummarizer(store: store, llmSettings: llm, liveAISettings: liveAI,
                                         runLLM: { _, _, _, _, _, _, _, _, _, _, _ in
                                             throw StubFailure()
                                         })
        summarizer.onSummaryFinished = { [weak exporter] rec in
            guard let exporter, exporter.isPending(rec.id) else { return }
            exporter.export(rec)
            exporter.clearPending(rec.id)
        }
    }

    private func addRecording(fullText: String = "some transcript") -> Recording {
        let audioURL = store.freshAudioURL(suggestedName: "Rec")
        try? Data("x".utf8).write(to: audioURL)
        let rec = Recording(title: "Rec", source: .microphone,
                            audioFileName: audioURL.lastPathComponent, fullText: fullText)
        store.add(rec)
        return rec
    }

    func test_pending_recording_is_exported_after_summary() async throws {
        let rec = addRecording()
        exporter.markPending(rec.id)
        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        let expected = vault.appendingPathComponent(ObsidianExporter.fileName(for: rec))
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path),
                      "a pending recording should be written once its summary lands")
        let contents = try String(contentsOf: expected, encoding: .utf8)
        XCTAssertTrue(contents.contains("A tidy summary."))
    }

    func test_non_pending_summary_is_not_exported() async throws {
        let rec = addRecording()
        // No markPending — models a backfill sweep.
        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        let expected = vault.appendingPathComponent(ObsidianExporter.fileName(for: rec))
        XCTAssertFalse(FileManager.default.fileExists(atPath: expected.path),
                       "a summary produced without a pending mark must not be filed")
    }

    func test_pending_export_falls_back_to_transcript_when_summaries_disabled() async throws {
        llm.summaryEnabled = false   // no summary will be generated
        let rec = addRecording(fullText: "the raw transcript body")
        exporter.markPending(rec.id)
        // summarizeIfNeeded skips synchronously and fires onSummaryFinished.
        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        let expected = vault.appendingPathComponent(ObsidianExporter.fileName(for: rec))
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
        let contents = try String(contentsOf: expected, encoding: .utf8)
        XCTAssertTrue(contents.contains("## Transcript"))
        XCTAssertTrue(contents.contains("the raw transcript body"))
    }

    /// A failed summary still resolves the pending export — it must not hang
    /// waiting for a summary that will never arrive.
    func test_failed_summary_still_exports_the_transcript() async throws {
        useFailingLLM()
        let rec = addRecording(fullText: "the raw transcript body")
        exporter.markPending(rec.id)
        summarizer.summarizeIfNeeded(rec)
        await summarizer.awaitInFlight(rec.id)

        let expected = vault.appendingPathComponent(ObsidianExporter.fileName(for: rec))
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path),
                      "a failed summary must fall back, not stall the export")
        XCTAssertFalse(exporter.isPending(rec.id), "the pending mark must be cleared")
    }

    /// Deleted mid-flight: the failure path must not fire the hook with the
    /// stale enqueue-time copy, or a recording the user just deleted lands in
    /// the vault anyway.
    func test_recording_deleted_mid_flight_is_not_exported() async throws {
        useFailingLLM()
        let rec = addRecording(fullText: "the raw transcript body")
        exporter.markPending(rec.id)
        summarizer.summarizeIfNeeded(rec)
        store.permanentlyDelete(rec)
        await summarizer.awaitInFlight(rec.id)

        let expected = vault.appendingPathComponent(ObsidianExporter.fileName(for: rec))
        XCTAssertFalse(FileManager.default.fileExists(atPath: expected.path),
                       "a recording deleted mid-flight must not be filed")
    }

    /// Trashed mid-flight: the hook does fire (the row is still in the store),
    /// but the exporter refuses to file a trashed recording.
    func test_recording_trashed_mid_flight_is_not_exported() async throws {
        let rec = addRecording()
        exporter.markPending(rec.id)
        summarizer.summarizeIfNeeded(rec)
        store.softDelete(rec)
        await summarizer.awaitInFlight(rec.id)

        let expected = vault.appendingPathComponent(ObsidianExporter.fileName(for: rec))
        XCTAssertFalse(FileManager.default.fileExists(atPath: expected.path),
                       "a recording trashed mid-flight must not be filed")
    }

    /// The hook fires exactly once per attempt: a second export for the same
    /// recording only happens on a second, deliberate summarize attempt.
    func test_hook_fires_once_per_attempt() async throws {
        final class Recorder { var ids: [UUID] = [] }
        let fired = Recorder()
        summarizer.onSummaryFinished = { fired.ids.append($0.id) }
        let rec = addRecording()
        summarizer.summarizeIfNeeded(rec)
        // A duplicate call while the first is in flight is deduped and must
        // NOT produce a second signal.
        summarizer.summarizeIfNeeded(rec)
        summarizer.regenerate(rec)
        await summarizer.awaitInFlight(rec.id)

        XCTAssertEqual(fired.ids, [rec.id], "one attempt in flight must yield exactly one signal")
    }
}
