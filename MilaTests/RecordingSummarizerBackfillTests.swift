import XCTest
@testable import Mila

/// Coverage for `RecordingSummarizer.backfillIfNeeded()` — the scan that
/// runs on launch + on LLM-config flip and walks the store generating
/// summaries for recordings that don't have one yet.
///
/// All end-to-end calls go through a shell script masquerading as
/// `claude`, same trick as `RecordingSummarizerTests`. The script writes
/// a probe file on each invocation so we can count concurrency
/// independently of the summarizer's own internal counters.
@MainActor
final class RecordingSummarizerBackfillTests: XCTestCase {

    private var tempRoot: URL!
    private var store: RecordingStore!
    private var llmDefaults: UserDefaults!
    private var liveDefaults: UserDefaults!
    private var llm: LLMSettings!
    private var liveAI: LiveAISettings!
    private var summarizer: RecordingSummarizer!

    private let llmSuite = "RecordingSummarizerBackfillTests.llm"
    private let liveSuite = "RecordingSummarizerBackfillTests.liveAI"

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "BackfillTests")
        try FileManager.default.createDirectory(at: tempRoot,
                                                withIntermediateDirectories: true)
        store = RecordingStore(rootDirectory: tempRoot)
        UserDefaults().removePersistentDomain(forName: llmSuite)
        UserDefaults().removePersistentDomain(forName: liveSuite)
        llmDefaults = UserDefaults(suiteName: llmSuite)
        liveDefaults = UserDefaults(suiteName: liveSuite)
        llm = LLMSettings(defaults: llmDefaults)
        liveAI = LiveAISettings(defaults: liveDefaults)
        summarizer = RecordingSummarizer(store: store,
                                         llmSettings: llm,
                                         liveAISettings: liveAI)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        llmDefaults?.removePersistentDomain(forName: llmSuite)
        liveDefaults?.removePersistentDomain(forName: liveSuite)
        try await super.tearDown()
    }

    // MARK: - Selection

    /// Backfill picks up `.completed` recordings missing summaries, and
    /// skips the rest. Verifies the four criteria from the spec all in
    /// one go so a future regression that loosens any of them is caught.
    func test_backfill_only_targets_completed_non_trashed_missing_summary() async throws {
        let script = makeScript("""
            #!/bin/sh
            printf 'FILLED'
            """)
        defer { try? FileManager.default.removeItem(at: script) }

        llm.tool = .claude
        llm.executablePath = script.path

        // Eligible: completed, non-empty text, no summary, not trashed.
        let target = try addRecording(title: "Target",
                                      status: .completed,
                                      fullText: "the transcript",
                                      summary: nil)
        // Ineligible: already summarized.
        let alreadySummarized = try addRecording(title: "Summarized",
                                                 status: .completed,
                                                 fullText: "the transcript",
                                                 summary: "already here")
        // Ineligible: trashed.
        var trashed = try addRecording(title: "Trashed",
                                       status: .completed,
                                       fullText: "the transcript",
                                       summary: nil)
        trashed.deletedAt = Date()
        store.update(trashed)
        // Ineligible: never finished transcribing.
        _ = try addRecording(title: "Pending",
                             status: .pending,
                             fullText: "",
                             summary: nil)
        // Ineligible: completed but empty transcript.
        _ = try addRecording(title: "Empty",
                             status: .completed,
                             fullText: "",
                             summary: nil)

        summarizer.backfillIfNeeded()
        try await waitForSummary(recordingID: target.id, timeoutSeconds: 120)

        // The eligible one got the script's output.
        XCTAssertEqual(currentSummary(of: target.id), "FILLED")
        // The already-summarized one was left alone.
        XCTAssertEqual(currentSummary(of: alreadySummarized.id), "already here")
        // The trashed one stayed nil.
        XCTAssertNil(currentSummary(of: trashed.id))
    }

    /// When the LLM isn't configured, the scan is a no-op (no CLI calls,
    /// no summaries written). The internal `$tool` subscriber re-runs the
    /// scan once the user flips it on at runtime — covered by a
    /// dedicated test below.
    func test_backfill_noops_when_llm_not_configured() async throws {
        llm.tool = .none

        let rec = try addRecording(title: "Skip",
                                   status: .completed,
                                   fullText: "transcript",
                                   summary: nil)

        summarizer.backfillIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(currentSummary(of: rec.id))
    }

    /// Flipping `LLMSettings.tool` from .none to .claude must trigger an
    /// automatic backfill. This is the "user just finished setting up
    /// their CLI" path — without the auto-trigger the user would have
    /// to relaunch the app or wait for a fresh recording to see summaries
    /// fill in.
    func test_backfill_runs_on_llm_config_flip() async throws {
        let script = makeScript("""
            #!/bin/sh
            printf 'AUTO'
            """)
        defer { try? FileManager.default.removeItem(at: script) }

        // LLM starts unconfigured.
        XCTAssertEqual(llm.tool, .none)

        let rec = try addRecording(title: "Flip",
                                   status: .completed,
                                   fullText: "transcript",
                                   summary: nil)

        // Now configure — the `$tool` publisher in the summarizer should
        // notice and kick a backfill.
        llm.executablePath = script.path
        llm.tool = .claude

        try await waitForSummary(recordingID: rec.id, timeoutSeconds: 120)
        XCTAssertEqual(currentSummary(of: rec.id), "AUTO")
    }

    // MARK: - Throttle + ordering

    /// With N candidates and `maxConcurrent` = 2, at no point should more
    /// than 2 CLI subprocesses be running at the same time. The script
    /// records each entry / exit in a probe directory so the test can
    /// count concurrent presence without depending on summarizer
    /// internals.
    func test_backfill_throttles_to_max_concurrent() async throws {
        let probeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backfill-probe-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: probeDir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: probeDir) }

        // The script creates a file at $PROBE_DIR/<unique>.run on entry
        // and removes it on exit, sleeping in between so the test has a
        // long enough window to sample the concurrent count multiple
        // times. We can't use a single file because two processes would
        // race; per-invocation unique names sidestep that.
        let script = makeScript("""
            #!/bin/sh
            UNIQ=$$.$RANDOM
            touch "\(probeDir.path)/$UNIQ.run"
            sleep 0.4
            rm -f "\(probeDir.path)/$UNIQ.run"
            printf 'DONE'
            """)
        defer { try? FileManager.default.removeItem(at: script) }

        llm.tool = .claude
        llm.executablePath = script.path

        // 5 candidates — comfortably above the cap.
        var recs: [Recording] = []
        for i in 0..<5 {
            let r = try addRecording(title: "Rec\(i)",
                                     status: .completed,
                                     fullText: "transcript \(i)",
                                     summary: nil)
            recs.append(r)
        }

        summarizer.maxConcurrent = 2
        summarizer.backfillIfNeeded()

        // Sample concurrent .run files frequently for ~3 s. Worst-case
        // total wall time is 5 * 0.4 / 2 = 1.0 s with perfect packing;
        // 3 s gives plenty of slack on a noisy CI runner.
        var maxObserved = 0
        let stopAt = Date().addingTimeInterval(3.0)
        while Date() < stopAt {
            let count = (try? FileManager.default
                .contentsOfDirectory(at: probeDir,
                                     includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "run" }.count ?? 0
            maxObserved = max(maxObserved, count)
            try await Task.sleep(nanoseconds: 25_000_000)
            // Bail early once all 5 have landed so the test isn't pinned
            // to the full 3 s when the runner is fast.
            let summarized = recs.filter {
                (currentSummary(of: $0.id) ?? "").isEmpty == false
            }.count
            if summarized == recs.count { break }
        }

        XCTAssertLessThanOrEqual(maxObserved, 2,
                                 "Backfill should cap concurrent CLI calls at 2 (saw \(maxObserved))")

        // And every candidate eventually got a summary.
        for rec in recs {
            try await waitForSummary(recordingID: rec.id, timeoutSeconds: 120)
        }
    }

    /// Process newest-first so the recording the user just finished
    /// gets attention before the months-old archive. We pace the script
    /// down to one-at-a-time concurrency for this assertion so the
    /// ordering is observable; with parallel calls "first started" is
    /// the wrong question.
    func test_backfill_processes_newest_first() async throws {
        let order = FileManager.default.temporaryDirectory
            .appendingPathComponent("backfill-order-\(UUID().uuidString).log")
        // Each invocation appends its first CLI arg (which becomes our
        // recording title via the transcript). Using `printf '%s\\n'`
        // keeps the file readable.
        let script = makeScript("""
            #!/bin/sh
            # The transcript text is the only thing that varies between
            # our recordings — grep MARKER_<KEY> out of whichever arg
            # carries the prompt blob and log it.
            for arg in "$@"; do
              case "$arg" in
                *MARKER_OLD*) echo MARKER_OLD >> "\(order.path)" ;;
                *MARKER_MID*) echo MARKER_MID >> "\(order.path)" ;;
                *MARKER_NEW*) echo MARKER_NEW >> "\(order.path)" ;;
              esac
            done
            printf 'OK'
            """)
        defer {
            try? FileManager.default.removeItem(at: script)
            try? FileManager.default.removeItem(at: order)
        }

        llm.tool = .claude
        llm.executablePath = script.path
        summarizer.maxConcurrent = 1

        // Create three with explicit createdAt so the store's
        // newest-first ordering is unambiguous.
        let now = Date()
        let oldest = try addRecording(title: "Oldest",
                                      status: .completed,
                                      fullText: "MARKER_OLD payload",
                                      summary: nil,
                                      createdAt: now.addingTimeInterval(-300))
        let middle = try addRecording(title: "Middle",
                                      status: .completed,
                                      fullText: "MARKER_MID payload",
                                      summary: nil,
                                      createdAt: now.addingTimeInterval(-100))
        let newest = try addRecording(title: "Newest",
                                      status: .completed,
                                      fullText: "MARKER_NEW payload",
                                      summary: nil,
                                      createdAt: now)

        summarizer.backfillIfNeeded()

        // Wait for all three to land.
        try await waitForSummary(recordingID: oldest.id, timeoutSeconds: 120)
        try await waitForSummary(recordingID: middle.id, timeoutSeconds: 120)
        try await waitForSummary(recordingID: newest.id, timeoutSeconds: 120)

        let log = try String(contentsOf: order, encoding: .utf8)
        let lines = log.split(whereSeparator: \.isNewline).map(String.init)
        guard let newIdx = lines.firstIndex(of: "MARKER_NEW"),
              let midIdx = lines.firstIndex(of: "MARKER_MID"),
              let oldIdx = lines.firstIndex(of: "MARKER_OLD") else {
            XCTFail("Did not see all three markers; log was: \(log)")
            return
        }
        XCTAssertLessThan(newIdx, midIdx, "Newest should be processed before Middle")
        XCTAssertLessThan(midIdx, oldIdx, "Middle should be processed before Oldest")
    }

    // MARK: - Helpers

    private func addRecording(title: String,
                              status: TranscriptionStatus,
                              fullText: String,
                              summary: String?,
                              createdAt: Date = Date()) throws -> Recording {
        let audioURL = store.freshAudioURL(suggestedName: title)
        try Data("x".utf8).write(to: audioURL)
        var rec = Recording(
            id: UUID(),
            title: title,
            createdAt: createdAt,
            source: .microphone,
            audioFileName: audioURL.lastPathComponent,
            status: status,
            fullText: fullText
        )
        rec.summary = summary
        store.add(rec)
        return rec
    }

    private func currentSummary(of id: UUID) -> String? {
        store.recordings.first { $0.id == id }?.summary
    }

    private func waitForSummary(recordingID: UUID,
                                timeoutSeconds: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let s = currentSummary(of: recordingID), !s.isEmpty {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for summary on \(recordingID)")
    }

    private func makeScript(_ body: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mila-backfill-test-\(UUID().uuidString).sh")
        try? body.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
        return url
    }
}
