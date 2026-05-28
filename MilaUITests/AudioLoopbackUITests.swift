import XCTest

/// End-to-end audio loopback test. Drives Mila through a real
/// 2-minute recording while a known WAV plays on a virtual audio
/// device (BlackHole) that's been set as the system default input.
/// Snapshots state every 10s, asserts transcription is progressing
/// (not stuck) across the whole timeline.
///
/// Catches regressions in:
///   * RecordingSession.onLiveSamples → LiveTranscriber.ingest wiring
///   * VAD threshold-vs-ambient tuning (the fixture mixes low-amplitude
///     noise so "silence" between phrases isn't pure zero — same as a
///     real conversation environment)
///   * Per-language transcription (en + he)
///
/// Gated on `MILA_LOOPBACK_E2E=1` so a local UI-test run without
/// BlackHole installed SKIPs cleanly.
final class AudioLoopbackUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_english_two_minute_recording_progresses() throws {
        try runTwoMinuteRecording(
            languageFlag: "--ui-test-recording-lang-en",
            language: "en",
            expectedTokens: ["search", "auth", "billing", "thursday"],
            shortTokens: ["hi", "yes", "ok", "done", "great"]
        )
    }

    func test_hebrew_two_minute_recording_progresses() throws {
        try runTwoMinuteRecording(
            languageFlag: "--ui-test-recording-lang-he",
            language: "he",
            // Distinct Hebrew tokens from the fixture: "מערכת", "חיפוש",
            // "חמישי" (Thursday) cover both long phrases and a unique
            // calendar reference. Case-folded match.
            expectedTokens: ["חיפוש", "מערכת", "חמישי"],
            // Hebrew fixture's short lines: "היי", "כן", "בסדר", "סיימנו",
            // "מצוין".
            shortTokens: ["היי", "כן", "בסדר", "סיימנו", "מצוין"]
        )
    }

    // MARK: - Core driver

    private func runTwoMinuteRecording(
        languageFlag: String,
        language: String,
        expectedTokens: [String],
        shortTokens: [String]
    ) throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MILA_LOOPBACK_E2E"] == "1",
            "Set MILA_LOOPBACK_E2E=1 to run; needs BlackHole as default input + fixture playing"
        )

        let app = XCUIApplication()
        app.launchArguments = ["--uitests", languageFlag]
        app.launch()

        let recordButton = app.buttons["home.record.hero"]
        XCTAssertTrue(recordButton.waitForExistence(timeout: 10),
                      "[\(language)] Record CTA never appeared on Home")
        recordButton.tap()

        // Wait for the first segment to land before we start snapshotting
        // — gives whisper time to warm up.
        let firstSegment = app.staticTexts.matching(identifier: "liveTranscript.segment").firstMatch
        XCTAssertTrue(firstSegment.waitForExistence(timeout: 30),
                      "[\(language)] No live segment after 30s — wiring or VAD threshold broken")

        // Snapshot every 10s for 120s (12 snapshots). Track segment
        // count per snapshot — counts MUST be monotonically non-
        // decreasing AND eventually reach a healthy total (≥8). If
        // counts stall for more than 30s in the middle, the VAD got
        // stuck.
        var counts: [(t: Int, count: Int)] = []
        for snapshotIdx in 1...12 {
            Thread.sleep(forTimeInterval: 10.0)
            let count = app.staticTexts
                .matching(identifier: "liveTranscript.segment")
                .allElementsBoundByIndex
                .count
            counts.append((t: snapshotIdx * 10, count: count))
            snap(app: app, name: "[\(language)] t=\(snapshotIdx * 10)s segments=\(count)")
            print("AudioLoopbackUITests[\(language)]: t=\(snapshotIdx * 10)s segments=\(count)")
        }

        // Monotonic non-decreasing — segments are append-only in the UI.
        for i in 1..<counts.count {
            XCTAssertGreaterThanOrEqual(
                counts[i].count, counts[i - 1].count,
                "[\(language)] Segment count went DOWN between t=\(counts[i-1].t)s (\(counts[i-1].count)) and t=\(counts[i].t)s (\(counts[i].count))"
            )
        }

        // No stall > 30s. A real conversation produces a new segment
        // every 5-15s; if there's a 30s window with zero new segments
        // mid-recording the detector is stuck.
        for i in 3..<counts.count {
            let windowStart = counts[i - 3].count
            let windowEnd = counts[i].count
            XCTAssertGreaterThan(
                windowEnd, windowStart,
                "[\(language)] No new segments for 30s window (t=\(counts[i-3].t)s..\(counts[i].t)s, count stuck at \(windowStart)). VAD probably stuck in .speech or threshold mismatched."
            )
        }

        // Final count ≥ 8 — fixture has 18 lines, expect comfortably more
        // than half through 120s.
        let finalCount = counts.last?.count ?? 0
        XCTAssertGreaterThanOrEqual(
            finalCount, 8,
            "[\(language)] Final segment count \(finalCount) is too low. VAD likely dropped most speech."
        )

        // Content check — verify language-specific tokens landed. We
        // use the segment labels which carry the rendered text.
        let segmentElements = app.staticTexts
            .matching(identifier: "liveTranscript.segment")
            .allElementsBoundByIndex
        let transcript = segmentElements
            .compactMap { $0.label.isEmpty ? $0.value as? String : $0.label }
            .joined(separator: " ")
            .lowercased()
        print("AudioLoopbackUITests[\(language)]: ===TRANSCRIPT_START===")
        print(transcript)
        print("AudioLoopbackUITests[\(language)]: ===TRANSCRIPT_END===")

        let foundLong = expectedTokens.filter { transcript.contains($0.lowercased()) }
        XCTAssertGreaterThanOrEqual(
            foundLong.count, 2,
            "[\(language)] Long-utterance tokens almost absent (found \(foundLong) of \(expectedTokens))."
        )
        let foundShort = shortTokens.filter { transcript.contains($0.lowercased()) }
        XCTAssertGreaterThanOrEqual(
            foundShort.count, 2,
            "[\(language)] Short-utterance tokens missing (found \(foundShort) of \(shortTokens))."
        )

        // Summary verification — Live AI's summary pane should populate
        // by 120s IF the LLM CLI is configured. CI doesn't have one
        // wired up yet, so this is a soft check that doesn't fail the
        // run; it logs whether the pane has content for visibility.
        let summaryEl = app.staticTexts.matching(identifier: "liveAI.summary").firstMatch
        if summaryEl.exists {
            let summaryText = summaryEl.label
            print("AudioLoopbackUITests[\(language)]: summary len=\(summaryText.count)")
            if ProcessInfo.processInfo.environment["MILA_REQUIRE_LIVE_AI_SUMMARY"] == "1" {
                XCTAssertFalse(summaryText.isEmpty,
                               "[\(language)] LLM summary pane is empty after 2 min — Live AI didn't run")
            }
        }
    }

    private func snap(app: XCUIApplication, name: String) {
        let shot = app.windows.firstMatch.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }
}
