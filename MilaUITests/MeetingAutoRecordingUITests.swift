import XCTest

/// Native settings/panel tests with synthetic detector/capture events. This
/// deliberately does not claim microphone, transcription, or saved-audio proof.
final class MeetingAutoRecordingUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func waitUntilGone(_ element: XCUIElement) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
    }
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-clean-store", "--ui-test-meeting-auto", "--ui-test-reset-meeting-auto"]
        app.launch()
        XCTAssertTrue(element(app, "meetingTest.start").waitForExistence(timeout: 20))
        return app
    }
    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 20) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@ OR value == %@", label, label), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed)
    }
    private func container(_ app: XCUIApplication, containing id: String) -> XCUIElement {
        let dialog = app.dialogs.containing(.any, identifier: id).firstMatch
        return dialog.exists ? dialog : app.windows.containing(.any, identifier: id).firstMatch
    }
    private func screenshot(_ app: XCUIApplication, containing id: String, name: String) {
        let window = container(app, containing: id)
        XCTAssertTrue(window.exists)
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func test_auto_countdown_starts_and_stops_once() {
        let app = launch()
        defer { app.terminate() }
        element(app, "meetingTest.auto").click()
        element(app, "meetingTest.start").click()
        XCTAssertTrue(element(app, "meetingPrompt.primary").waitForExistence(timeout: 5))
        waitForLabel(element(app, "meetingTest.state"), "Recording")
        waitForLabel(element(app, "meetingTest.counts"), "Starts: 1, stops: 0")
        element(app, "meetingTest.end").click()
        XCTAssertTrue(element(app, "meetingStopPrompt.primary").waitForExistence(timeout: 5))
        waitForLabel(element(app, "meetingTest.state"), "Idle")
        waitForLabel(element(app, "meetingTest.counts"), "Starts: 1, stops: 1")
    }
    func test_expanded_prompt_pauses_and_escape_cancels() {
        let app = launch()
        defer { app.terminate() }
        element(app, "meetingTest.auto").click()
        element(app, "meetingTest.start").click()
        let chevron = element(app, "meetingPrompt.chevron")
        XCTAssertTrue(chevron.waitForExistence(timeout: 5))
        chevron.click()
        let silence = element(app, "meetingPrompt.silence")
        XCTAssertTrue(silence.waitForExistence(timeout: 5))
        let window = container(app, containing: "meetingPrompt.silence")
        XCTAssertTrue(window.frame.contains(silence.frame), "Expanded actions must fit in the panel")
        waitForLabel(element(app, "meetingPrompt.countdown"), "Countdown paused — leave the prompt to continue.")
        screenshot(app, containing: "meetingPrompt.silence", name: "auto-start-expanded-paused")
        // Waiting beyond the grace period must not start while interacting.
        let noStart = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Recording' OR value == 'Recording'"), object: element(app, "meetingTest.state"))
        noStart.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [noStart], timeout: 11), .completed)
        app.typeKey(.escape, modifierFlags: [])
        waitUntilGone(element(app, "meetingPrompt.primary"))
        waitForLabel(element(app, "meetingTest.counts"), "Starts: 0, stops: 0")
    }
    func test_prompt_is_reachable_by_keyboard_and_escape_cancels() {
        let app = launch()
        defer { app.terminate() }
        element(app, "meetingTest.auto").click()
        element(app, "meetingTest.start").click()
        let subtitle = element(app, "meetingPrompt.countdown")
        XCTAssertTrue(subtitle.waitForExistence(timeout: 5))
        for _ in 0..<4 {
            app.typeKey("`", modifierFlags: .command)
            if (subtitle.label + (subtitle.value as? String ?? "")).contains("paused") { break }
        }
        XCTAssertTrue((subtitle.label + (subtitle.value as? String ?? "")).contains("paused"), "Keyboard window cycling must reach and pause the prompt")
        app.typeKey(.escape, modifierFlags: [])
        waitUntilGone(element(app, "meetingPrompt.primary"))
        waitForLabel(element(app, "meetingTest.counts"), "Starts: 0, stops: 0")
    }

    func test_cancel_start_and_keep_recording() {
        let app = launch()
        defer { app.terminate() }
        element(app, "meetingTest.auto").click()
        element(app, "meetingTest.start").click()
        let cancel = element(app, "meetingPrompt.dismiss")
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertEqual(cancel.label, "Cancel start")
        cancel.click()
        element(app, "meetingTest.end").click()
        element(app, "meetingTest.start").click()
        waitForLabel(element(app, "meetingTest.state"), "Recording")
        element(app, "meetingTest.end").click()
        let keep = element(app, "meetingStopPrompt.dismiss")
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        XCTAssertEqual(keep.label, "Keep recording")
        keep.click()
        waitUntilGone(keep)
        waitForLabel(element(app, "meetingTest.state"), "Recording")
        waitForLabel(element(app, "meetingTest.counts"), "Starts: 1, stops: 0")
    }
    func test_settings_auto_mode_persists_across_relaunch() {
        let app = launch()
        defer { app.terminate() }
        element(app, "meetingTest.ask").click()
        let settings = element(app, "sidebar.settings.link")
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.click()
        let meetings = element(app, "settings.section.meetings")
        XCTAssertTrue(meetings.waitForExistence(timeout: 10))
        meetings.click()
        let picker = element(app, "meetings.mode.us.zoom.xos")
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        let auto = picker.descendants(matching: .any).matching(NSPredicate(format: "label == 'Auto'")).firstMatch
        XCTAssertTrue(auto.exists)
        auto.click()
        screenshot(app, containing: "meetings.mode.us.zoom.xos", name: "meeting-auto-settings")
        app.terminate()
        app.launchArguments.removeAll { $0 == "--ui-test-reset-meeting-auto" }
        app.launch()
        XCTAssertTrue(element(app, "meetingTest.start").waitForExistence(timeout: 20))
        element(app, "meetingTest.start").click()
        let cancel = element(app, "meetingPrompt.dismiss")
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertEqual(cancel.label, "Cancel start", "Relaunch must retain Auto, not revert to Ask")
        cancel.click()
    }
}
