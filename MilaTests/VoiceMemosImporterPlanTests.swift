import XCTest
@testable import Mila

/// Unit tests for `VoiceMemosImporter.plan` — the pure scan classifier that
/// gates the visible "Syncing…" state (issue #57, the "Last synced" flicker).
/// The importer only flips `isSyncing` / re-stamps "Last synced" when
/// `plan.hasVisibleWork` is true, so proving an all-already-imported scan
/// yields no visible work is proving the flicker fix at the logic level —
/// without needing FSEvents or a live database.
@MainActor
final class VoiceMemosImporterPlanTests: XCTestCase {

    private let cutoff = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private func memo(_ id: String,
                      folderUUID: String? = "FOLDER-1",
                      duration: Double = 30,
                      date: Date? = nil,
                      ext: String = "m4a") -> VoiceMemosLibrary.Memo {
        VoiceMemosLibrary.Memo(
            uniqueID: id,
            fileURL: URL(fileURLWithPath: "/tmp/\(id).\(ext)"),
            folderUUID: folderUUID,
            title: "Memo \(id)",
            duration: duration,
            date: date ?? cutoff.addingTimeInterval(1_000)
        )
    }

    /// Every candidate is already imported → nothing to do, and crucially no
    /// visible work, so an idle rescan never flips the UI.
    func test_plan_allAlreadyImported_hasNoVisibleWork() {
        let memos = [memo("a"), memo("b")]
        let plan = VoiceMemosImporter.plan(
            memos: memos,
            alreadyImported: ["a", "b"],
            startDate: cutoff,
            minDuration: 3.0,
            fileExists: { _ in true })

        XCTAssertFalse(plan.hasVisibleWork)
        XCTAssertTrue(plan.toImport.isEmpty)
        XCTAssertEqual(plan.summary, VoiceMemosImporter.SyncSummary())
    }

    /// A fresh eligible memo is real work → visible.
    func test_plan_eligibleMemo_hasVisibleWork() {
        let plan = VoiceMemosImporter.plan(
            memos: [memo("a")],
            alreadyImported: [],
            startDate: cutoff,
            minDuration: 3.0,
            fileExists: { _ in true })

        XCTAssertTrue(plan.hasVisibleWork)
        XCTAssertEqual(plan.toImport.map(\.uniqueID), ["a"])
    }

    /// Each held-back reason is tallied under the right bucket, and none of
    /// them count as visible work.
    func test_plan_classifiesEachSkipReason() {
        let memos = [
            memo("old", date: cutoff.addingTimeInterval(-1)),        // before cutoff
            memo("comp", ext: "composition"),                        // multi-take
            memo("short", duration: 1.0),                            // too short
            memo("missing"),                                         // not downloaded
            memo("ok")                                               // eligible
        ]
        let plan = VoiceMemosImporter.plan(
            memos: memos,
            alreadyImported: [],
            startDate: cutoff,
            minDuration: 3.0,
            fileExists: { $0.lastPathComponent != "missing.m4a" })

        XCTAssertEqual(plan.summary.skippedOlder, 1)
        XCTAssertEqual(plan.summary.skippedComposition, 1)
        XCTAssertEqual(plan.summary.skippedShort, 1)
        XCTAssertEqual(plan.summary.skippedMissing, 1)
        XCTAssertEqual(plan.toImport.map(\.uniqueID), ["ok"])
        XCTAssertTrue(plan.hasVisibleWork)
    }

    /// The start-date cutoff is checked first, so an old memo that is also too
    /// short is counted as "before start date" (matching the status line's
    /// intent that the cutoff count reflects the user's date choice).
    func test_plan_startDateCutoffTakesPrecedenceOverDuration() {
        let plan = VoiceMemosImporter.plan(
            memos: [memo("old-and-short", duration: 1.0, date: cutoff.addingTimeInterval(-1))],
            alreadyImported: [],
            startDate: cutoff,
            minDuration: 3.0,
            fileExists: { _ in true })

        XCTAssertEqual(plan.summary.skippedOlder, 1)
        XCTAssertEqual(plan.summary.skippedShort, 0)
        XCTAssertFalse(plan.hasVisibleWork)
    }
}
