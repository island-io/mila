import XCTest

/// Native UI verification for an isolated test host. Uses the existing WAV
/// fixture pump and a local tiny model; the finalize-regression flag is
/// deliberately absent because it suppresses the ordinary naming sheet.
final class AutoSaveRecordingUITests: XCTestCase {
    private var app: XCUIApplication?
    private var suiteID: UUID!
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        suiteID = UUID()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mila.AutoSaveUITests.\(suiteID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        app?.terminate()
        // Only the suite and temporary directory created by THIS test.
        if let suiteID {
            UserDefaults().removePersistentDomain(forName: "Mila.AutoSaveUITests.\(suiteID.uuidString)")
        }
        if let tempRoot { try FileManager.default.removeItem(at: tempRoot) }
        try super.tearDownWithError()
    }

    func test_Audio_preference_persists_and_controls_ordinary_fixture_Stop() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MILA_FIXTURE_E2E"] == "1",
                          "Requires an unlocked Mac and MILA_FIXTURE_E2E=1 with local WAV/tiny model paths.")
        let wav = try localFixturePath("MILA_FIXTURE_WAV_PATH")
        let tiny = try localFixturePath("MILA_TINY_MODEL_PATH")

        // Reach the real Audio control, enable it, then relaunch the SAME suite.
        let initial = launch()
        let initialToggle = openAudioSettings(initial)
        assertToggle(initialToggle, isOn: false)
        initialToggle.click()
        assertToggle(initialToggle, isOn: true)
        initial.terminate()

        let enabled = launch(wav: wav, tiny: tiny)
        let restoredOn = openAudioSettings(enabled)
        assertToggle(restoredOn, isOn: true)
        enabled.typeKey("w", modifierFlags: .command) // Close Settings, keep main window.
        let transcriptAnchor = stopFixture(enabled)

        let title = element(enabled, "detail.title.label")
        XCTAssertTrue(title.waitForExistence(timeout: 60), "Auto-save must select the saved recording detail")
        XCTAssertFalse(namingSheet(enabled).exists)
        XCTAssertEqual(enabled.sheets.count, 0, "Auto-save must skip the ordinary naming sheet")
        XCTAssertFalse(element(enabled, "main.autoSuggestingTitle").exists,
                       "AI title suggestions are disabled for this fixture")
        XCTAssertTrue(savedTranscript(enabled, containing: transcriptAnchor).waitForExistence(timeout: 10))
        let savedTitle = title.label.isEmpty ? (title.value as? String ?? "") : title.label
        XCTAssertFalse(savedTitle.isEmpty)

        // Reopen within this launch: clean-store intentionally resets rows on relaunch.
        let home = enabled.staticTexts["Home"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        home.click()
        XCTAssertTrue(element(enabled, "home.record.hero").waitForExistence(timeout: 10))
        XCTAssertFalse(title.exists, "The one-shot reveal must not select again after navigating away")
        element(enabled, "sidebar.folder.default").click()
        let row = element(enabled, "history.row.\(savedTitle)")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(savedTranscript(enabled, containing: transcriptAnchor).waitForExistence(timeout: 5),
                      "The reopened recording must retain fixture transcript text")

        // Rename using the existing inline editor, then reopen the renamed row.
        title.click()
        let field = enabled.textFields["detail.title.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Auto-save UI renamed\r")
        element(enabled, "sidebar.folder.default").click()
        let renamed = element(enabled, "history.row.Auto-save UI renamed")
        XCTAssertTrue(renamed.waitForExistence(timeout: 5))
        renamed.click()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(savedTranscript(enabled, containing: transcriptAnchor).exists)

        let toggleOff = openAudioSettings(enabled)
        assertToggle(toggleOff, isOn: true)
        toggleOff.click()
        assertToggle(toggleOff, isOn: false)
        enabled.terminate()

        let disabled = launch(wav: wav, tiny: tiny)
        let restoredOff = openAudioSettings(disabled)
        assertToggle(restoredOff, isOn: false)
        disabled.typeKey("w", modifierFlags: .command)
        _ = stopFixture(disabled)
        XCTAssertTrue(namingSheet(disabled).waitForExistence(timeout: 60),
                      "With auto-save disabled, ordinary Stop must still ask for a name")
        disabled.terminate() // Do not save/discard or trigger any sheet LLM action.
    }

    private func launch(wav: String? = nil, tiny: String? = nil) -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments = [
            "--uitests", "--ui-test-clean-store", "--ui-test-recording-lang-en",
            "--ui-test-auto-save-suite=\(suiteID.uuidString)",
            "-liveAI.transcribeWhileRecording", "YES",
            "-liveAI.backgroundMode", "NO",
            "-liveAI.enabled", "NO",
            "-liveAI.useVAD", "YES",
            "-liveAI.useNeuralVAD", "NO",
            "-diarization.enabled", "NO",
            "-speakers.voiceRecognition.enabled", "NO",
            "-llm.tool", "none",
            "-llm.name.enabled", "NO",
            "-llm.summary.enabled", "NO",
            "-llm.action.enabled", "NO",
            "-transcription.backend", "local",
        ]
        if let wav { application.launchArguments.append("--ui-test-inject-fixture-wav=\(wav)") }
        if let tiny { application.launchArguments.append("--ui-test-tiny-model-path=\(tiny)") }
        // Existing clean-store/fake-recording seams use temporaryDirectory.
        // Keep their files under a test-owned directory for teardown.
        application.launchEnvironment["TMPDIR"] = tempRoot.path + "/"
        app = application
        application.launch()
        return application
    }

    private func openAudioSettings(_ application: XCUIApplication) -> XCUIElement {
        application.typeKey(",", modifierFlags: .command)
        let audio = element(application, "settings.section.audio")
        XCTAssertTrue(audio.waitForExistence(timeout: 10), "Audio must be reachable through Settings")
        audio.click()
        let toggle = element(application, "recordings.autoSave.toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        // Audio is in the standard Settings scroll view. Scroll only as needed
        // so the control remains reachable at the native minimum window size.
        let settingsWindow = application.windows.containing(.any, identifier: "settings.section.audio").firstMatch
        for _ in 0..<8 {
            if toggle.isHittable { break }
            settingsWindow.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -160)
        }
        XCTAssertTrue(toggle.isHittable, "Auto-save switch must be reachable without hover")
        XCTAssertTrue(toggle.isEnabled)
        // macOS exposes the native switch (26 pt), not its 44 pt SwiftUI
        // layout wrapper. Reachability and operation are checked on the switch;
        // an AX control-frame size is not a layout-wrapper measurement.
        return toggle
    }

    private func assertToggle(_ toggle: XCUIElement, isOn: Bool) {
        let expected = isOn ? "1" : "0"
        let predicate = NSPredicate { _, _ in
            if let value = toggle.value as? NSNumber { return value.boolValue == isOn }
            return (toggle.value as? String) == expected
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: toggle)],
                                     timeout: 5), .completed)
    }

    /// The existing pump starts the fake recording automatically. Verify both
    /// transcript and a hittable Stop before tapping; do not substitute a seam
    /// that bypasses naming. Pump/Stop reachability is a real native test gate.
    private func stopFixture(_ application: XCUIApplication) -> String {
        let segment = element(application, "liveTranscript.segment")
        XCTAssertTrue(segment.waitForExistence(timeout: 180), "Fixture must produce a live transcript")
        let text = (segment.label + " " + (segment.value as? String ?? "")).lowercased()
        let anchor = text.split(whereSeparator: { !$0.isLetter })
            .map(String.init).first { $0.count >= 4 && !$0.hasPrefix("speaker") } ?? ""
        XCTAssertFalse(anchor.isEmpty, "Need a transcript word to verify after reopening")
        let stop = element(application, "liveAI.stop")
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        let reachable = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in stop.isHittable && stop.isEnabled }, object: stop)
        XCTAssertEqual(XCTWaiter.wait(for: [reachable], timeout: 10), .completed,
                       "Stop must remain reachable while the existing fixture pump runs")
        stop.click()
        return anchor
    }

    private func element(_ application: XCUIApplication, _ identifier: String) -> XCUIElement {
        application.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func namingSheet(_ application: XCUIApplication) -> XCUIElement {
        application.staticTexts["Name this recording"].firstMatch
    }

    private func savedTranscript(_ application: XCUIApplication, containing word: String) -> XCUIElement {
        application.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", word, word)).firstMatch
    }

    private func localFixturePath(_ key: String) throws -> String {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment[key], "\(key) must identify a local fixture")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "Missing local fixture: \(key)")
        return path
    }
}
