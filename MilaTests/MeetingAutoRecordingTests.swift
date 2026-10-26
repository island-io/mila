import XCTest
import Combine
import TranscriptionCore
@testable import Mila

@MainActor
final class MeetingAutoRecordingTests: XCTestCase {
    private final class Recorder: MeetingRecordingActions {
        var meetingRecordingURL: URL?
        var canStartMeetingRecording = true
        let changes = PassthroughSubject<Void, Never>()
        var meetingRecordingChanges: AnyPublisher<Void, Never> { changes.eraseToAnyPublisher() }
        var starts = 0
        var stops = 0
        var delayStart = false
        var continuation: CheckedContinuation<Void, Never>?
        func startMeetingRecording(isStillValid: @escaping () -> Bool) async -> URL? {
            starts += 1
            if delayStart { await withCheckedContinuation { continuation = $0 } }
            guard isStillValid(), meetingRecordingURL == nil else { return nil }
            meetingRecordingURL = URL(fileURLWithPath: "/tmp/meeting-\(UUID()).wav")
            changes.send()
            return meetingRecordingURL
        }
        func stopMeetingRecording(expectedURL: URL) async {
            guard meetingRecordingURL == expectedURL else { return }
            stops += 1
            meetingRecordingURL = nil
            changes.send()
        }
    }
    private var defaults: UserDefaults!
    private var suite: String!
    private var settings: MeetingDetectionSettings!
    private var detector: MeetingDetector!
    private var screenLockNotifications: NotificationCenter!
    private var screenLocked = false
    private var recorder: Recorder!
    private var coordinator: MeetingPromptCoordinator!
    private var zoom: MeetingDetector.App { MeetingDetector.supportedApps[0] }
    private var other: MeetingDetector.App { MeetingDetector.supportedApps[1] }

    override func setUp() async throws {
        suite = "MeetingAutoRecordingTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        settings = MeetingDetectionSettings(defaults: defaults)
        detector = MeetingDetector(endConfirmationPolls: 1)
        screenLockNotifications = NotificationCenter()
        screenLocked = false
        recorder = Recorder()
        coordinator = MeetingPromptCoordinator(detector: detector, settings: settings,
            actions: recorder, presentsPanels: false, pollsDetector: false,
            screenLockNotifications: screenLockNotifications,
            screenIsLocked: { [weak self] in self?.screenLocked ?? true })
        coordinator.start()
    }
    override func tearDown() async throws {
        coordinator.stop()
        recorder.continuation?.resume()
        recorder.continuation = nil
        defaults.removePersistentDomain(forName: suite)
    }
    private func settle(until condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Expected asynchronous transition did not occur")
    }
    private func startAuto() async throws -> URL {
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        detector.meetingStarted.send(zoom)
        let prompt = try XCTUnwrap(coordinator.pending)
        XCTAssertTrue(prompt.automatic)
        coordinator.performPrompt(id: prompt.id)
        await settle { self.recorder.meetingRecordingURL != nil }
        return try XCTUnwrap(recorder.meetingRecordingURL)
    }

    private func deliverScreenLock(_ locked: Bool) async {
        screenLocked = locked
        screenLockNotifications.post(name: Notification.Name(
            locked ? "com.apple.screenIsLocked" : "com.apple.screenIsUnlocked"), object: nil)
        // Drain the delivery hop without posting a real system lock event.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func test_screen_lock_cancels_auto_countdown_and_blocks_repeated_detection_until_unlock() async throws {
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        detector.meetingStarted.send(zoom)
        let stale = try XCTUnwrap(coordinator.pending)
        await deliverScreenLock(true)
        XCTAssertNil(coordinator.pending)
        coordinator.performPrompt(id: stale.id)
        detector.meetingStarted.send(zoom)
        XCTAssertNil(coordinator.pending)
        XCTAssertEqual(recorder.starts, 0)
        await deliverScreenLock(false)
        XCTAssertNil(coordinator.pending, "Unlock alone must not restart an old countdown")
        detector.meetingStarted.send(zoom)
        let fresh = try XCTUnwrap(coordinator.pending)
        XCTAssertNotEqual(fresh.id, stale.id)
        XCTAssertTrue(fresh.automatic)
        XCTAssertEqual(recorder.starts, 0, "A fresh countdown must precede capture")
    }

    func test_lock_state_recheck_blocks_timer_before_notification_delivery() throws {
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        detector.meetingStarted.send(zoom)
        let stale = try XCTUnwrap(coordinator.pending)
        screenLocked = true
        // No event posted: validStart must query the current session state.
        coordinator.performPrompt(id: stale.id)
        XCTAssertNil(coordinator.pending)
        XCTAssertEqual(recorder.starts, 0)
    }

    func test_starting_coordinator_while_locked_never_arms_an_auto_countdown() {
        coordinator.stop()
        screenLocked = true
        coordinator.start()
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        detector.meetingStarted.send(zoom)
        XCTAssertNil(coordinator.pending)
        XCTAssertEqual(recorder.starts, 0)
    }

    func test_screen_lock_revokes_pending_auto_stop_callback() async throws {
        let owned = try await startAuto()
        detector.meetingEnded.send(zoom)
        let stop = try XCTUnwrap(coordinator.pending)
        XCTAssertTrue(stop.automatic)
        await deliverScreenLock(true)
        XCTAssertNil(coordinator.pending)
        coordinator.performPrompt(id: stop.id)
        XCTAssertEqual(recorder.stops, 0, "The app delegate stops active capture separately")
        XCTAssertEqual(recorder.meetingRecordingURL, owned)
    }

    func test_managed_disabled_detection_cannot_be_enabled_by_auto_mode() {
        coordinator.stop()
        var managed = ManagedSettings.empty
        managed.meetingDetectionEnabled = false
        settings = MeetingDetectionSettings(defaults: defaults, managed: managed)
        coordinator = MeetingPromptCoordinator(detector: detector, settings: settings,
            actions: recorder, presentsPanels: false, pollsDetector: false,
            screenLockNotifications: screenLockNotifications,
            screenIsLocked: { [weak self] in self?.screenLocked ?? true })
        coordinator.start()
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        settings.enabled = true
        detector.meetingStarted.send(zoom)
        XCTAssertFalse(settings.enabled)
        XCTAssertNil(coordinator.pending)
        XCTAssertEqual(recorder.starts, 0)
    }

    func test_enable_auto_requires_a_fresh_countdown_before_capture() throws {
        detector.meetingStarted.send(zoom)
        let ask = try XCTUnwrap(coordinator.pending)
        coordinator.performPrompt(id: ask.id, enableAuto: true)
        let automatic = try XCTUnwrap(coordinator.pending)
        XCTAssertTrue(automatic.automatic)
        XCTAssertNotEqual(automatic.id, ask.id)
        XCTAssertEqual(settings.mode(forBundleID: zoom.bundleID), .auto)
        XCTAssertEqual(recorder.starts, 0, "Preference change must not immediately capture")
        coordinator.cancelPrompt(id: automatic.id)
        XCTAssertEqual(recorder.starts, 0)
    }
    func test_long_delivery_gap_cancels_even_when_interaction_was_paused() {
        var countdown = MeetingPromptCountdown()
        XCTAssertEqual(countdown.advance(by: 60, paused: true, automatic: true), .dismiss,
                       "Sleep or a long interruption cancels unattended automation")
    }

    func test_default_ask_and_off_never_schedule_automatic_recording() throws {
        detector.meetingStarted.send(zoom)
        XCTAssertFalse(try XCTUnwrap(coordinator.pending).automatic)
        coordinator.cancelPrompt(id: try XCTUnwrap(coordinator.pending).id)
        settings.setMode(.off, forBundleID: zoom.bundleID)
        detector.meetingStarted.send(zoom)
        XCTAssertNil(coordinator.pending)
        XCTAssertEqual(recorder.starts, 0)
    }
    func test_start_and_owned_stop_are_exactly_once() async throws {
        _ = try await startAuto()
        detector.meetingEnded.send(zoom)
        let prompt = try XCTUnwrap(coordinator.pending)
        XCTAssertEqual(prompt.kind, .stop)
        XCTAssertTrue(prompt.automatic)
        coordinator.performPrompt(id: prompt.id)
        coordinator.performPrompt(id: prompt.id)
        await settle { self.recorder.stops == 1 }
        XCTAssertEqual(recorder.starts, 1)
    }
    func test_cancelled_start_callback_cannot_record() throws {
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        detector.meetingStarted.send(zoom)
        let id = try XCTUnwrap(coordinator.pending).id
        coordinator.cancelPrompt(id: id)
        coordinator.performPrompt(id: id)
        XCTAssertEqual(recorder.starts, 0)
    }
    func test_end_rejoin_invalidates_old_start_callback() throws {
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        detector.meetingStarted.send(zoom)
        let old = try XCTUnwrap(coordinator.pending)
        detector.meetingEnded.send(zoom)
        detector.meetingStarted.send(zoom)
        let current = try XCTUnwrap(coordinator.pending)
        XCTAssertNotEqual(old.meetingID, current.meetingID)
        coordinator.performPrompt(id: old.id)
        XCTAssertEqual(recorder.starts, 0)
        XCTAssertEqual(coordinator.pending?.id, current.id)
    }
    func test_revoke_then_regrant_synchronously_does_not_revive_prompt() throws {
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        detector.meetingStarted.send(zoom)
        let id = try XCTUnwrap(coordinator.pending).id
        settings.setMode(.ask, forBundleID: zoom.bundleID)
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        coordinator.performPrompt(id: id)
        XCTAssertNil(coordinator.pending)
        XCTAssertEqual(recorder.starts, 0)
    }
    func test_manual_start_while_prompt_visible_cannot_be_toggled_off() async throws {
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        detector.meetingStarted.send(zoom)
        let id = try XCTUnwrap(coordinator.pending).id
        let manualURL = URL(fileURLWithPath: "/tmp/manual.wav")
        recorder.meetingRecordingURL = manualURL
        coordinator.performPrompt(id: id, enableAuto: true)
        XCTAssertEqual(recorder.meetingRecordingURL, manualURL)
        XCTAssertEqual(recorder.starts, 0)
        XCTAssertEqual(recorder.stops, 0)
    }
    func test_manual_recording_gets_explicit_stop_even_in_auto_mode() throws {
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        recorder.meetingRecordingURL = URL(fileURLWithPath: "/tmp/manual.wav")
        detector.meetingStarted.send(zoom)
        detector.meetingEnded.send(zoom)
        XCTAssertFalse(try XCTUnwrap(coordinator.pending).automatic)
        XCTAssertEqual(recorder.stops, 0)
    }
    func test_keep_recording_cancels_automatic_stop() async throws {
        let url = try await startAuto()
        detector.meetingEnded.send(zoom)
        let id = try XCTUnwrap(coordinator.pending).id
        coordinator.cancelPrompt(id: id)
        coordinator.performPrompt(id: id)
        XCTAssertEqual(recorder.meetingRecordingURL, url)
        XCTAssertEqual(recorder.stops, 0)
    }
    func test_revoking_auto_keeps_active_recording_and_releases_ownership() async throws {
        let url = try await startAuto()
        settings.setMode(.off, forBundleID: zoom.bundleID)
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        detector.meetingEnded.send(zoom)
        XCTAssertEqual(recorder.meetingRecordingURL, url)
        XCTAssertFalse(try XCTUnwrap(coordinator.pending).automatic)
        XCTAssertEqual(recorder.stops, 0)
    }
    func test_global_disable_revokes_pending_stop_without_stopping() async throws {
        let url = try await startAuto()
        detector.meetingEnded.send(zoom)
        let id = try XCTUnwrap(coordinator.pending).id
        settings.enabled = false
        settings.enabled = true
        coordinator.performPrompt(id: id)
        XCTAssertNil(coordinator.pending)
        XCTAssertEqual(recorder.meetingRecordingURL, url)
        XCTAssertEqual(recorder.stops, 0)
    }
    func test_rejoin_cancels_stop_and_does_not_take_ownership_of_previous_call() async throws {
        let url = try await startAuto()
        detector.meetingEnded.send(zoom)
        let id = try XCTUnwrap(coordinator.pending).id
        detector.meetingStarted.send(zoom)
        coordinator.performPrompt(id: id)
        XCTAssertNil(coordinator.pending)
        detector.meetingEnded.send(zoom)
        XCTAssertFalse(try XCTUnwrap(coordinator.pending).automatic)
        XCTAssertEqual(recorder.meetingRecordingURL, url)
    }
    func test_other_active_call_prevents_automatic_stop() async throws {
        _ = try await startAuto()
        detector.meetingStarted.send(other)
        detector.meetingEnded.send(zoom)
        XCTAssertFalse(try XCTUnwrap(coordinator.pending).automatic)
        XCTAssertEqual(recorder.stops, 0)
    }
    func test_other_app_cannot_claim_recording() async throws {
        _ = try await startAuto()
        settings.setMode(.auto, forBundleID: other.bundleID)
        detector.meetingStarted.send(other)
        detector.meetingEnded.send(other)
        XCTAssertFalse(try XCTUnwrap(coordinator.pending).automatic)
    }
    func test_replaced_recording_is_not_stopped_by_stale_callback() async throws {
        _ = try await startAuto()
        detector.meetingEnded.send(zoom)
        let id = try XCTUnwrap(coordinator.pending).id
        let replacement = URL(fileURLWithPath: "/tmp/replacement.wav")
        recorder.meetingRecordingURL = replacement
        coordinator.performPrompt(id: id)
        XCTAssertEqual(recorder.meetingRecordingURL, replacement)
        XCTAssertEqual(recorder.stops, 0)
    }
    func test_revocation_during_delayed_start_prevents_capture() async throws {
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        recorder.delayStart = true
        detector.meetingStarted.send(zoom)
        coordinator.performPrompt(id: try XCTUnwrap(coordinator.pending).id)
        await settle { self.recorder.continuation != nil }
        settings.setMode(.off, forBundleID: zoom.bundleID)
        recorder.continuation?.resume()
        recorder.continuation = nil
        await Task.yield()
        XCTAssertNil(recorder.meetingRecordingURL)
        XCTAssertEqual(recorder.stops, 0)
    }
    func test_busy_start_falls_back_to_explicit_action() throws {
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        recorder.canStartMeetingRecording = false
        detector.meetingStarted.send(zoom)
        let prompt = try XCTUnwrap(coordinator.pending)
        XCTAssertFalse(prompt.automatic)
        XCTAssertTrue(prompt.startUnavailable)
        coordinator.performPrompt(id: prompt.id)
        XCTAssertFalse(try XCTUnwrap(coordinator.pending).automatic)
        XCTAssertEqual(recorder.starts, 0)
    }
    func test_coordinator_stop_revokes_callbacks_and_start_is_idempotent() throws {
        coordinator.start()
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        detector.meetingStarted.send(zoom)
        let id = try XCTUnwrap(coordinator.pending).id
        coordinator.stop()
        coordinator.performPrompt(id: id)
        detector.meetingStarted.send(zoom)
        XCTAssertNil(coordinator.pending)
        XCTAssertEqual(recorder.starts, 0)
    }
    func test_countdown_pause_cancel_and_exactly_once() {
        var countdown = MeetingPromptCountdown()
        for _ in 0..<9 { XCTAssertEqual(countdown.advance(by: 1, paused: false, automatic: true), .waiting) }
        for _ in 0..<15 { XCTAssertEqual(countdown.advance(by: 1, paused: true, automatic: true), .waiting) }
        XCTAssertEqual(countdown.elapsed, 9)
        XCTAssertEqual(countdown.advance(by: 1, paused: false, automatic: true), .primary)
        XCTAssertEqual(countdown.advance(by: 1, paused: false, automatic: true), .waiting)
        var cancelled = MeetingPromptCountdown()
        cancelled.cancel()
        XCTAssertEqual(cancelled.advance(by: 10, paused: false, automatic: true), .waiting)
    }
    func test_ask_timeout_dismisses_and_automatic_delivery_gap_cancels() {
        var ask = MeetingPromptCountdown()
        XCTAssertEqual(ask.advance(by: 10, paused: false, automatic: false), .dismiss)
        var auto = MeetingPromptCountdown()
        XCTAssertEqual(auto.advance(by: 60, paused: false, automatic: true), .dismiss)
        XCTAssertEqual(auto.advance(by: 1, paused: false, automatic: true), .waiting)
    }
    func test_modes_persist_and_off_cannot_leave_auto_authorized() {
        XCTAssertEqual(settings.mode(forBundleID: zoom.bundleID), .ask)
        for mode in [MeetingDetectionSettings.AppMode.auto, .off, .ask] {
            settings.setMode(mode, forBundleID: zoom.bundleID)
            let reloaded = MeetingDetectionSettings(defaults: defaults)
            XCTAssertEqual(reloaded.mode(forBundleID: zoom.bundleID), mode)
            XCTAssertEqual(reloaded.isAutoStart(forBundleID: zoom.bundleID), mode == .auto)
        }
    }

    // MARK: - Declined meeting generations (#354)

    /// The detector re-fires `meetingStarted` after any brief inactive poll,
    /// with NO confirmed `meetingEnded`. A generation the user explicitly
    /// cancelled must not re-present a countdown — or, in Auto, capture.
    func test_cancelled_auto_start_suppresses_repeated_start_for_same_generation() throws {
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        detector.meetingStarted.send(zoom)
        let prompt = try XCTUnwrap(coordinator.pending)
        XCTAssertTrue(prompt.automatic)
        coordinator.cancelPrompt(id: prompt.id)
        XCTAssertNil(coordinator.pending)

        // Same meeting identity, no confirmed end: must stay suppressed.
        detector.meetingStarted.send(zoom)
        XCTAssertNil(coordinator.pending, "a declined meeting generation must not re-present")
        XCTAssertEqual(recorder.starts, 0, "a declined automatic start must never capture")

        // A stale callback for the cancelled prompt is a no-op, too.
        coordinator.performPrompt(id: prompt.id)
        XCTAssertEqual(recorder.starts, 0)
    }

    /// A genuine end retires only that generation; rejoining mints a fresh
    /// identity and gets a fresh, eligible countdown.
    func test_confirmed_end_and_rejoin_permits_a_fresh_countdown() throws {
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        detector.meetingStarted.send(zoom)
        let first = try XCTUnwrap(coordinator.pending)
        coordinator.cancelPrompt(id: first.id)
        XCTAssertNil(coordinator.pending)

        detector.meetingEnded.send(zoom)
        detector.meetingStarted.send(zoom)
        let second = try XCTUnwrap(coordinator.pending)
        XCTAssertNotEqual(second.meetingID, first.meetingID,
                          "a rejoin is a new meeting generation")
        XCTAssertTrue(second.automatic)
        XCTAssertEqual(recorder.starts, 0)
        coordinator.cancelPrompt(id: second.id)
    }

    /// The countdown's own timeout is not a user decline: an unattended
    /// prompt must not silence the generation.
    func test_countdown_timeout_does_not_decline_the_generation() throws {
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        detector.meetingStarted.send(zoom)
        let prompt = try XCTUnwrap(coordinator.pending)
        XCTAssertTrue(prompt.automatic)
        coordinator.expirePrompt(id: prompt.id)
        XCTAssertNil(coordinator.pending)

        detector.meetingStarted.send(zoom)
        let again = try XCTUnwrap(coordinator.pending,
                                  "an unattended timeout must not suppress the generation")
        XCTAssertTrue(again.automatic)
        XCTAssertEqual(recorder.starts, 0)
        coordinator.cancelPrompt(id: again.id)
    }

    /// Declining one app must not suppress another.
    func test_declining_one_app_does_not_suppress_another() throws {
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        settings.setMode(.auto, forBundleID: other.bundleID)
        detector.meetingStarted.send(zoom)
        coordinator.cancelPrompt(id: try XCTUnwrap(coordinator.pending).id)
        XCTAssertNil(coordinator.pending)

        detector.meetingStarted.send(other)
        let next = try XCTUnwrap(coordinator.pending)
        XCTAssertEqual(next.app.bundleID, other.bundleID)
        XCTAssertTrue(next.automatic)
        coordinator.cancelPrompt(id: next.id)
    }

    func test_other_app_mode_changes_and_unchanged_auto_preserve_declined_generation() throws {
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        detector.meetingStarted.send(zoom)
        let cancelled = try XCTUnwrap(coordinator.pending)
        coordinator.cancelPrompt(id: cancelled.id)

        for mode in [MeetingDetectionSettings.AppMode.auto, .ask, .off] {
            settings.setMode(mode, forBundleID: other.bundleID)
            detector.meetingStarted.send(zoom)
            XCTAssertNil(coordinator.pending, "Changing another app must preserve this decline")
        }
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        detector.meetingStarted.send(zoom)
        XCTAssertNil(coordinator.pending, "Republishing unchanged Auto must preserve this decline")
        XCTAssertEqual(recorder.starts, 0)
    }

    func test_fresh_auto_opt_in_rearms_only_that_app() throws {
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        detector.meetingStarted.send(zoom)
        let cancelled = try XCTUnwrap(coordinator.pending)
        coordinator.cancelPrompt(id: cancelled.id)

        settings.setMode(.ask, forBundleID: zoom.bundleID)
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        detector.meetingStarted.send(zoom)
        let fresh = try XCTUnwrap(coordinator.pending)
        XCTAssertTrue(fresh.automatic)
        XCTAssertEqual(fresh.meetingID, cancelled.meetingID)
        XCTAssertNotEqual(fresh.id, cancelled.id)
        XCTAssertEqual(recorder.starts, 0, "A fresh opt-in still requires its countdown")
    }

    /// A global disable is a true lifecycle reset: declined generations are
    /// dropped, not turned into permanent app silence.
    func test_global_disable_clears_declined_generations() throws {
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        detector.meetingStarted.send(zoom)
        coordinator.cancelPrompt(id: try XCTUnwrap(coordinator.pending).id)
        XCTAssertNil(coordinator.pending)

        settings.enabled = false
        settings.enabled = true
        detector.meetingStarted.send(zoom)
        let again = try XCTUnwrap(coordinator.pending,
                                  "global disable must reset declined state")
        XCTAssertEqual(recorder.starts, 0)
        coordinator.cancelPrompt(id: again.id)
    }

    func test_real_capture_rechecks_revocation_after_bringup_and_removes_partial_file() async throws {
        let session = RecordingSession()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cancelled-\(UUID()).wav")
        var valid = true
        session.system.bringUpOverride = { valid = false }
        do {
            try await session.start(source: .systemAudio, outputURL: url, isStillValid: { valid })
            XCTFail("Revoked start must not publish a recording")
        } catch is RecordingSession.StartCancelled {
            XCTAssertEqual(session.state, .idle)
            XCTAssertNil(session.fileURL)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }
    func test_real_capture_reserves_startup_before_first_await() async throws {
        let session = RecordingSession()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reserved-\(UUID()).wav")
        let otherURL = FileManager.default.temporaryDirectory.appendingPathComponent("other-\(UUID()).wav")
        var entered = false
        var release: CheckedContinuation<Void, Never>?
        session.system.bringUpOverride = {
            entered = true
            await withCheckedContinuation { release = $0 }
        }
        let first = Task { try await session.start(source: .systemAudio, outputURL: url) }
        await settle { entered }
        do {
            try await session.start(source: .systemAudio, outputURL: otherURL)
            XCTFail("Second startup must be rejected")
        } catch is RecordingSession.StartCancelled {}
        release?.resume()
        try await first.value
        XCTAssertEqual(session.fileURL, url)
        XCTAssertEqual(session.state, .recording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherURL.path))
        await session.cancelAll()
        try? FileManager.default.removeItem(at: url)
    }

    /// A token already tripped when `start` is entered must stop the bring-up
    /// at its first check — no engine, no file, no recording. This is the
    /// "already-cancelled entry" half of the controller's cancellation bridge
    /// (#354).
    func test_pre_cancelled_token_stops_the_bring_up_before_capture() async throws {
        let session = RecordingSession()
        session.mic.bringUpOverride = { }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pre-cancelled-\(UUID()).wav")
        let token = CaptureStartCancellation()
        token.cancel()

        do {
            try await session.start(source: .microphone, outputURL: url, cancellation: token)
            XCTFail("A pre-cancelled token must stop the start")
        } catch is CaptureStartCancellation.Cancelled {
            XCTAssertEqual(session.mic.captureStartCount, 0)
            XCTAssertFalse(session.mic.isRunning)
            XCTAssertEqual(session.state, .idle)
            XCTAssertNil(session.fileURL)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

}

/// Drives the coordinator through the REAL `QuickActionsController` +
/// `RecordingSession` (only the permission gate and the capture bring-up are
/// stubbed), so the automatic start/stop path is exercised on the seams the
/// merge touched — not the `Recorder` stub above.
@MainActor
final class MeetingAutoRecordingControllerTests: XCTestCase {
    private var tempRoot: URL!
    private var store: RecordingStore!
    private var manager: ModelManager!
    private var service: TranscriptionService!
    private var session: RecordingSession!
    private var settings: MeetingDetectionSettings!
    private var detector: MeetingDetector!
    private var screenLockNotifications: NotificationCenter!
    private var screenLocked = false
    private var controller: QuickActionsController!
    private var coordinator: MeetingPromptCoordinator!
    private var defaults: UserDefaults!
    private var suite: String!
    private var zoom: MeetingDetector.App { MeetingDetector.supportedApps[0] }

    override func setUp() async throws {
        suite = "MeetingAutoRecordingControllerTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        settings = MeetingDetectionSettings(defaults: defaults)
        detector = MeetingDetector(endConfirmationPolls: 1)
        screenLockNotifications = NotificationCenter()
        screenLocked = false

        tempRoot = TestSupport.makeTempRoot(label: "MeetingAutoRecordingControllerTests")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = RecordingStore(rootDirectory: tempRoot)
        try FileManager.default.createDirectory(at: store.recordingsDirectory,
                                                withIntermediateDirectories: true)
        manager = TestSupport.isolatedModelManager(
            modelsDirectory: tempRoot.appendingPathComponent("Models"),
            label: "MeetingAutoRecordingControllerTests")
        try TestSupport.installFakeModel(into: manager)
        service = TranscriptionService(
            store: store,
            modelManager: manager,
            diarizationSettings: DiarizationSettings(
                defaults: .init(suiteName: "MeetingAutoRecordingControllerTests.diarization")!),
            remoteSettings: TestSupport.isolatedRemoteSettings(label: "MeetingAutoRecordingControllerTests"),
            engine: StubWhisperEngine())
        session = RecordingSession()
        controller = QuickActionsController(
            session: session,
            store: store,
            transcription: service,
            languageSettings: RecordingLanguageSettings(
                defaults: UserDefaults(suiteName: "MeetingAutoRecordingControllerTests.language")!),
            postRecording: PostRecordingCoordinator(
                store: store,
                transcription: service,
                llm: LLMSettings(defaults: UserDefaults(suiteName: "MeetingAutoRecordingControllerTests.llm")!)))
        controller.microphonePermissionOverride = { true }
        session.mic.bringUpOverride = { }
        session.system.bringUpOverride = { }

        coordinator = MeetingPromptCoordinator(detector: detector, settings: settings,
            actions: controller, presentsPanels: false, pollsDetector: false,
            screenLockNotifications: screenLockNotifications,
            screenIsLocked: { [weak self] in self?.screenLocked ?? true })
        coordinator.start()
    }

    override func tearDown() async throws {
        coordinator.stop()
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        defaults?.removePersistentDomain(forName: suite)
    }

    private func waitUntil(timeout: TimeInterval = 5,
                           _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    /// Bounded wait for a fake bring-up to have provably entered its gate —
    /// never an unbounded `await`, so a bring-up that fails to start fails the
    /// test rather than hanging it.
    private func waitForGateEntry(_ gate: MeetingStartGate,
                                  timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await gate.isEntered() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await gate.isEntered()
    }

    func test_auto_mode_starts_and_stops_the_real_recording() async throws {
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        detector.meetingStarted.send(zoom)
        let start = try XCTUnwrap(coordinator.pending)
        XCTAssertTrue(start.automatic)
        coordinator.performPrompt(id: start.id)

        let recording = await waitUntil { self.controller.isRecording }
        XCTAssertTrue(recording, "the automatic start must bring the real session up")
        XCTAssertEqual(session.source, .meeting)

        detector.meetingEnded.send(zoom)
        let stop = try XCTUnwrap(coordinator.pending)
        XCTAssertTrue(stop.automatic)
        coordinator.performPrompt(id: stop.id)
        let stopped = await waitUntil { !self.controller.isRecording }
        XCTAssertTrue(stopped)

        await controller.awaitFinalizeTails()
        await service.waitForIdle()
    }

    func test_screen_lock_during_real_bringup_never_opens_the_microphone() async throws {
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        let gate = MeetingStartGate()
        session.mic.bringUpOverride = { await gate.wait() }
        session.mic.bringUpTimeout = 30
        detector.meetingStarted.send(zoom)
        coordinator.performPrompt(id: try XCTUnwrap(coordinator.pending).id)
        let entered = await waitForGateEntry(gate)
        XCTAssertTrue(entered)
        screenLocked = true
        screenLockNotifications.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        await gate.open()
        let finished = await waitUntil { !controller.isStartingRecording }
        XCTAssertTrue(finished)
        XCTAssertEqual(session.mic.captureStartCount, 0)
        XCTAssertFalse(controller.isRecording)
        XCTAssertNil(session.fileURL)
        XCTAssertTrue(store.recordings.isEmpty)
        XCTAssertNil(service.lastError)
    }

    func test_meeting_end_during_a_real_startup_never_opens_the_microphone() async throws {
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        let gate = MeetingStartGate()
        session.mic.bringUpOverride = { await gate.wait() }
        session.mic.bringUpTimeout = 30

        detector.meetingStarted.send(zoom)
        let start = try XCTUnwrap(coordinator.pending)
        coordinator.performPrompt(id: start.id)
        let entered = await waitForGateEntry(gate)
        XCTAssertTrue(entered, "the microphone bring-up must be suspended inside the gate")
        let starting = await waitUntil { self.controller.isStartingRecording }
        XCTAssertTrue(starting)

        // Consent revoked while capture is still coming up.
        detector.meetingEnded.send(zoom)
        await gate.open()
        let finished = await waitUntil { !self.controller.isStartingRecording }
        XCTAssertTrue(finished)

        XCTAssertFalse(controller.isRecording)
        XCTAssertEqual(session.mic.captureStartCount, 0,
                       "a revoked start must never open the microphone, even transiently")
        XCTAssertNil(session.fileURL)
        XCTAssertEqual(controller.activeJob, .none)
        XCTAssertTrue(store.recordings.isEmpty)
        XCTAssertNil(service.lastError, "a cancelled automatic start must be silent")
        await controller.awaitFinalizeTails()
        await service.waitForIdle()
    }

    /// The fix's core claim: `startTask.cancel()` reaches the capture token
    /// synchronously, while the microphone bring-up is still suspended, so the
    /// engine never starts and no WAV/row/error survives.
    func test_revoked_auto_start_never_opens_the_microphone() async throws {
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        let gate = MeetingStartGate()
        session.mic.bringUpOverride = { await gate.wait() }
        session.mic.bringUpTimeout = 30
        session.system.bringUpOverride = { }

        detector.meetingStarted.send(zoom)
        let start = try XCTUnwrap(coordinator.pending)
        XCTAssertTrue(start.automatic)
        coordinator.performPrompt(id: start.id)
        let entered = await waitForGateEntry(gate)
        XCTAssertTrue(entered, "the microphone bring-up must be suspended inside the gate")

        settings.setMode(.off, forBundleID: zoom.bundleID)
        await gate.open()

        let finished = await waitUntil { !self.controller.isStartingRecording }
        XCTAssertTrue(finished)
        XCTAssertEqual(session.mic.captureStartCount, 0,
                       "the revoked start must never have started the engine")
        XCTAssertFalse(session.mic.isRunning)
        XCTAssertFalse(controller.isRecording)
        XCTAssertNil(session.fileURL)
        XCTAssertEqual(controller.activeJob, .none)
        XCTAssertTrue(store.recordings.isEmpty)
        XCTAssertNil(service.lastError)
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: store.recordingsDirectory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "wav" } ?? []
        XCTAssertEqual(leftovers, [], "the never-used WAV must not survive")
        await controller.awaitFinalizeTails()
        await service.waitForIdle()
    }

    /// The microphone is already up and the revocation lands while the SYSTEM
    /// leg is still being brought up. The system stream must never publish
    /// `isRunning == true` — a final `false` alone would hide a transient
    /// unauthorized capture — and the live mic must be torn down.
    func test_revoked_auto_start_during_the_system_leg_never_opens_it() async throws {
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        session.mic.bringUpOverride = { }
        let gate = MeetingStartGate()
        session.system.bringUpOverride = { await gate.wait() }
        session.mic.bringUpTimeout = 30

        var systemRunningValues: [Bool] = []
        let systemRunning = session.system.$isRunning.sink { systemRunningValues.append($0) }
        defer { systemRunning.cancel() }

        detector.meetingStarted.send(zoom)
        let start = try XCTUnwrap(coordinator.pending)
        coordinator.performPrompt(id: start.id)

        let micUp = await waitUntil { self.session.mic.isRunning }
        XCTAssertTrue(micUp, "the microphone leg comes up first, then the system leg waits")
        let entered = await waitForGateEntry(gate)
        XCTAssertTrue(entered, "the system bring-up must be suspended inside the gate")
        XCTAssertEqual(session.mic.captureStartCount, 1)
        XCTAssertTrue(controller.isStartingRecording)

        settings.setMode(.off, forBundleID: zoom.bundleID)
        await gate.open()

        let finished = await waitUntil { !self.controller.isStartingRecording }
        XCTAssertTrue(finished)
        XCTAssertFalse(systemRunningValues.contains(true),
                       "the system stream must never have started, saw \(systemRunningValues)")
        XCTAssertFalse(session.system.isRunning)
        XCTAssertFalse(session.mic.isRunning, "the mic that came up must be taken down again")
        XCTAssertFalse(controller.isRecording)
        XCTAssertNil(session.fileURL)
        XCTAssertEqual(controller.activeJob, .none)
        XCTAssertTrue(store.recordings.isEmpty)
        XCTAssertNil(service.lastError)
        await controller.awaitFinalizeTails()
        await service.waitForIdle()
    }

    func test_already_cancelled_caller_never_opens_capture_with_valid_consent() async throws {
        let entry = MeetingStartGate()
        let start = Task { @MainActor [self] in
            await entry.wait()
            return await controller.startMeetingRecording(isStillValid: { true })
        }
        let entered = await waitForGateEntry(entry)
        XCTAssertTrue(entered)
        start.cancel()
        await entry.open()
        let result = await start.value
        XCTAssertNil(result)
        XCTAssertEqual(session.mic.captureStartCount, 0)
        XCTAssertFalse(session.mic.isRunning)
        XCTAssertFalse(session.system.isRunning)
        XCTAssertNil(session.fileURL)
        XCTAssertEqual(controller.activeJob, .none)
        XCTAssertTrue(store.recordings.isEmpty)
        XCTAssertNil(service.lastError)
    }

    /// A cancelled automatic start must not wedge a later manual start: the
    /// manual path runs in its own, uncancelled task.
    func test_manual_start_still_succeeds_after_a_revoked_auto_start() async throws {
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        let gate = MeetingStartGate()
        session.mic.bringUpOverride = { await gate.wait() }
        session.mic.bringUpTimeout = 30

        detector.meetingStarted.send(zoom)
        let start = try XCTUnwrap(coordinator.pending)
        coordinator.performPrompt(id: start.id)
        let entered = await waitForGateEntry(gate)
        XCTAssertTrue(entered)
        settings.setMode(.off, forBundleID: zoom.bundleID)
        await gate.open()
        _ = await waitUntil {
            !self.controller.isStartingRecording && !self.controller.captureStartInFlight
        }

        // The prior attempt is gone; a manual start is its own task.
        session.mic.bringUpOverride = { }
        await controller.toggleRecord(withSystemAudio: false)
        XCTAssertEqual(controller.activeJob, .recording(withSystemAudio: false))
        XCTAssertTrue(controller.isRecording)
        XCTAssertNil(service.lastError)

        await controller.stopRecording()
        await controller.awaitFinalizeTails()
        await service.waitForIdle()
    }
}

/// Holds a fake bring-up open until the test opens it, and reports when a
/// bring-up has definitely ENTERED the override — so a test can revoke while
/// capture is provably suspended rather than merely scheduled. File-scope so
/// the bring-up task can suspend on it.
private actor MeetingStartGate {
    private var opened = false
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func isEntered() -> Bool { entered }

    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
