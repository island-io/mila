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
                                         runLLM: { _, _, _, _, _, _, _ in "A tidy summary." })
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
}
