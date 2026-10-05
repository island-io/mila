import XCTest

/// Runs against isolated recordings and synthetic fixture audio; no microphone
/// capture or external AI service. Opt in with MILA_BATCH_UI_E2E=1.
final class BatchOnlyRecordingUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_batch_only_saves_and_reopens_fixture_transcript() throws {
        try verifyBatchRecording(lowEndHardware: false)
    }

    func test_batch_only_shows_recording_and_saves_on_low_end_hardware() throws {
        try verifyBatchRecording(lowEndHardware: true)
    }

    private func verifyBatchRecording(lowEndHardware: Bool) throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["MILA_BATCH_UI_E2E"] == "1",
                          "Set MILA_BATCH_UI_E2E=1 with fixture and tiny-model paths")
        let fixture = try XCTUnwrap(environment["MILA_FIXTURE_WAV_PATH"])
        let model = try XCTUnwrap(environment["MILA_TINY_MODEL_PATH"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture))
        XCTAssertTrue(FileManager.default.fileExists(atPath: model))

        let app = XCUIApplication()
        // The app installs these fixture preferences in the volatile argument
        // domain; launch arguments contain only explicit test flags.
        app.launchArguments = [
            "--ui-test-clean-store",
            "--ui-test-batch-recording",
            "--ui-test-inject-fixture-wav=\(fixture)",
            "--ui-test-tiny-model-path=\(model)"
        ]
        if lowEndHardware {
            app.launchArguments.append("--ui-test-low-end-hardware")
        }
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10),
                      "Fixture startup must create the main window")

        let placeholder = element(app, "recording.batchOnly.placeholder")
        XCTAssertTrue(placeholder.waitForExistence(timeout: 30),
                      "Captured batch mode must show its recording explanation")
        XCTAssertFalse(element(app, "liveTranscript.segment").exists,
                       "Batch capture must not expose a live transcript")
        XCTAssertFalse(app.staticTexts["Recording — Live AI"].exists)
        attach(app, "batch-recording")

        let settingsLink = element(app, "sidebar.settings.link")
        XCTAssertTrue(settingsLink.waitForExistence(timeout: 10))
        settingsLink.click()
        let meetings = element(app, "settings.section.meetings")
        XCTAssertTrue(meetings.waitForExistence(timeout: 15))
        meetings.click()
        let toggle = element(app, "recording.batchOnly.toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "recording.batchOnly.nextRecording").exists)
        attach(app, "batch-setting")
        let settings = app.windows.containing(.any, identifier: "settings.section.meetings").firstMatch
        XCTAssertTrue(settings.exists)
        settings.buttons[XCUIIdentifierCloseWindow].click()

        let stop = element(app, "liveAI.stop")
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        stop.click()
        // This test intentionally does NOT use --ui-test-finalize-regression,
        // which suppresses the rename sheet independently of batch mode.
        XCTAssertTrue(element(app, "detail.title.label").waitForExistence(timeout: 20),
                      "Stop should select the saved recording")
        XCTAssertFalse(app.staticTexts["Name this recording"].exists,
                       "Batch Stop must save without opening the rename sheet")
        attach(app, "batch-saved")

        let history = element(app, "sidebar.folder.default")
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.click()
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'history.row.'"))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let transcriptArrived = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let text = row.label + " " + (row.value as? String ?? "")
                return text.localizedCaseInsensitiveContains("staging")
                    || text.localizedCaseInsensitiveContains("Friday")
            }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [transcriptArrived], timeout: 120), .completed,
                       "The saved fixture must receive its real batch transcript")
        row.click()
        XCTAssertTrue(element(app, "detail.title.label").waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Name this recording"].exists)
        // macOS exposes SwiftUI transcript Text through AXValue on some
        // versions, while other versions use AXLabel.
        let transcript = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'staging' OR label CONTAINS[c] 'Friday' "
                        + "OR value CONTAINS[c] 'staging' OR value CONTAINS[c] 'Friday'")).firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 10),
                      "Reopening the recording must show the completed transcript")
        attach(app, "batch-transcript-reopened")
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
