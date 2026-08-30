import AppKit
import Combine
import CoreAudio
import CoreGraphics
import OSLog

/// Detects when the user joined a meeting in a supported app, so the
/// app-level prompt coordinator can offer to start transcribing.
///
/// **Primary signal — microphone capture (macOS 14.4+).** During *any*
/// Zoom meeting the Zoom process is actively capturing the mic. The Core
/// Audio per-process API (`kAudioProcessPropertyIsRunningInput`) reports
/// that per bundle ID, with **no permission prompt** and crucially
/// **independent of the window title** — so it fires for instant,
/// scheduled, and join-by-link meetings alike, and it re-arms naturally
/// (capture stops the moment you leave). This replaced a brittle window-
/// title match (`title contains "zoom meeting"`) that silently failed for
/// named/scheduled meetings and needed Screen Recording permission.
///
/// **Fallback — window title (older macOS / API unavailable).** Where the
/// per-process audio API isn't present we fall back to scanning Zoom's
/// on-screen window titles via `CGWindowListCopyWindowInfo` (needs Screen
/// Recording permission for titles; silently skipped without it).
///
/// Detection is a low-frequency poll (every 3 s), not an event
/// subscription — neither the audio nor the window signal posts a "user
/// joined a meeting" notification.
@MainActor
final class MeetingDetector: ObservableObject {
    private static let log = Logger(
        subsystem: "io.island.whisper.IslandWhisper", category: "MeetingDetector")

    /// One supported app. `bundleID` is the canonical ID used for the
    /// prompt's snooze / silence keys and display; `captureBundlePrefixes`
    /// are matched (by prefix) against the bundle IDs of processes that are
    /// actively capturing the mic; `meetingTitleHints` is the window-title
    /// fallback used only when the audio API is unavailable.
    struct App: Hashable {
        /// Stable identity key for this detector entry — used in the
        /// per-app silence list, the state machine's `firedFor` /
        /// `endArmed` sets, and Settings display. For native apps this
        /// is the app's bundle ID; for browser-based meetings it is a
        /// synthetic ID like `"meet.google.com"`.
        let bundleID: String
        let displayName: String
        /// Bundle IDs of the macOS apps that host this meeting type.
        /// For native apps (Zoom, Teams) this is one entry matching
        /// `bundleID`. For browser-based meetings (Google Meet) this
        /// lists every supported browser.
        let appBundleIDs: [String]
        /// Any running audio process whose bundle ID has one of these
        /// prefixes AND is capturing mic input ⇒ this app is in a
        /// meeting. A prefix (not exact) because Zoom may capture
        /// under a helper (`us.zoom.*`). Empty for browser-based
        /// meetings — see `helperBundlePrefixes`.
        let captureBundlePrefixes: [String]
        /// Additional bundle-ID prefixes for helper processes that
        /// capture audio on behalf of this app. Browsers delegate mic
        /// capture to helper subprocesses whose bundle IDs differ from
        /// the main app (e.g. Safari → `com.apple.WebKit`, Arc →
        /// `company.thebrowser.browser.helper`). Checked alongside
        /// `appBundleIDs` during mic-capture matching (case-insensitive).
        /// Empty for native apps that capture under their own prefix.
        let helperBundlePrefixes: [String]
        /// Lowercased window-title substrings. For native apps (Zoom,
        /// Teams) this is a fallback when the mic-capture API is
        /// unavailable. For browsers (empty `captureBundlePrefixes`) it
        /// is the fallback on older macOS where the mic-capture API
        /// doesn't exist. On macOS 14.4+ browsers use mic capture as
        /// the primary signal (titles are unreliable on Tahoe). A hint
        /// must identify a *meeting* window specifically, not merely the
        /// app being open — the fallback treats a match as "in a call".
        /// Empty ⇒ no usable meeting-specific title exists for this app, so
        /// the fallback never claims a meeting for it (the Core Audio
        /// signal remains, and no detection beats a false one).
        let meetingTitleHints: [String]
    }

    /// Supported meeting apps. Adding a new app (e.g. Google Meet) is just
    /// another entry here — they'd use the same mic-capture signal, keyed
    /// on their own bundle IDs.
    static let supportedApps: [App] = [
        App(
            bundleID: "us.zoom.xos",
            displayName: "Zoom",
            appBundleIDs: ["us.zoom.xos"],
            captureBundlePrefixes: ["us.zoom"],
            helperBundlePrefixes: [],
            meetingTitleHints: ["zoom meeting"]
        ),
        App(
            bundleID: "com.microsoft.teams2",
            displayName: "Microsoft Teams",
            appBundleIDs: ["com.microsoft.teams2"],
            captureBundlePrefixes: ["com.microsoft.teams2"],
            // Deliberately none. Zoom can use a title hint because its
            // meeting window is titled "Zoom Meeting" while the idle app
            // window is not; every Teams window — chat, calendar, the
            // meeting itself — is titled "… | Microsoft Teams", so any
            // hint broad enough to catch a call also fires for Teams
            // merely being open, which for most people is all day. On the
            // fallback path that would mean a bogus "start transcribing?"
            // on launch and, mid-recording, a bogus "meeting ended → stop
            // recording?" the moment that window went away. Teams is
            // therefore detected by mic capture only (macOS 14.4+).
            helperBundlePrefixes: [],
            meetingTitleHints: []
        ),
        // Google Meet runs inside a browser. Mic capture detects
        // which browser is actively using the microphone; helper
        // prefixes catch the subprocess that actually captures audio.
        App(
            bundleID: "meet.google.com",
            displayName: "Google Meet (Chrome, Safari, Arc, Island)",
            appBundleIDs: [
                "com.google.Chrome",
                "com.apple.Safari",
                "company.thebrowser.Browser",
                "io.island.Island",
            ],
            captureBundlePrefixes: [],
            helperBundlePrefixes: [
                "com.google.chrome",
                "com.apple.webkit",
                "company.thebrowser",
                "io.island",
            ],
            meetingTitleHints: ["meet.google.com", "meet -"]
        ),
    ]

    /// Fired exactly once per meeting — the first poll that sees a
    /// supported app in a meeting. Re-armed when that app stops being in a
    /// meeting, so leaving and rejoining a call surfaces a fresh prompt.
    let meetingStarted = PassthroughSubject<App, Never>()

    /// Fired exactly once when a previously-active meeting goes inactive —
    /// the inverse of `meetingStarted`. Debounced (see
    /// `endConfirmationPolls`) so a momentary mic drop by Zoom doesn't
    /// masquerade as the meeting ending. The coordinator uses this to ask
    /// whether to STOP an in-flight recording.
    let meetingEnded = PassthroughSubject<App, Never>()

    /// How many consecutive polls a previously-active meeting must read as
    /// inactive before we treat it as genuinely ended. At a 3 s poll this
    /// is ~6 s of sustained silence — long enough to ride out Zoom briefly
    /// releasing the mic (mute/unmute, device switch) without a false
    /// "meeting ended". Internal so tests can drive the transition with a
    /// known threshold.
    let endConfirmationPolls: Int

    private var pollTask: Task<Void, Never>?
    /// Canonical bundle IDs we've already prompted for in the current run
    /// of a meeting. Cleared (re-armed) when the meeting ends.
    private var firedFor: Set<String> = []
    /// Canonical bundle IDs we've seen in a meeting AND not yet fired a
    /// `meetingEnded` for. A bundle ID stays here from the first active
    /// poll until the end transition is confirmed and emitted, so we emit
    /// `meetingEnded` exactly once per meeting.
    private var endArmed: Set<String> = []
    /// Per-app count of consecutive polls observed inactive while still
    /// `endArmed`. Reset to zero on any active poll; once it reaches
    /// `endConfirmationPolls` we emit `meetingEnded` and disarm.
    private var inactiveStreak: [String: Int] = [:]
    /// Logged once so we know which detection path is live in the field.
    private var loggedMode = false

    init(endConfirmationPolls: Int = 2) {
        self.endConfirmationPolls = max(1, endConfirmationPolls)
    }

    func start() {
        guard pollTask == nil else { return }
        Self.log.notice("starting meeting detector (poll every 3s)")
        pollTask = Task { @MainActor [weak self] in
            // Small initial delay so we don't fire during app launch (the
            // user may already be in a meeting — no need to nag them in
            // the first second).
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            while let self, !Task.isCancelled {
                self.pollOnce()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func stop() {
        Self.log.notice("stopping meeting detector")
        pollTask?.cancel()
        pollTask = nil
        firedFor.removeAll()
        endArmed.removeAll()
        inactiveStreak.removeAll()
    }

    /// Exposed for tests and one-shot manual triggers (e.g. a future
    /// "Test the meeting prompt" button in Settings).
    func pollOnce() {
        // Primary path: which bundle IDs are capturing the mic right now?
        // nil ⇒ the per-process audio API isn't available (older macOS).
        let capturing = bundleIDsCapturingMicInput()
        if !loggedMode {
            loggedMode = true
            Self.log.notice("detection mode: \(capturing == nil ? "window-title (fallback)" : "mic-capture", privacy: .public)")
        }

        var activeMeetings: Set<String> = []
        for app in Self.supportedApps {
            let inMeeting: Bool
            if app.captureBundlePrefixes.isEmpty {
                // Browser-based meetings (Google Meet, etc.): detect
                // via mic capture — the browser (or its helper) is
                // actively capturing the microphone during a call.
                //
                // Window-title matching would be more precise but macOS
                // 26 (Tahoe) hides titles from CGWindowListCopyWindowInfo
                // even with Screen Recording permission, making it
                // unreliable. Mic capture is the only cross-version
                // signal that works.
                //
                // Case-insensitive prefix: browser helpers use a
                // lowercased bundle ID (e.g. Arc's mic-capture process
                // is "company.thebrowser.browser.helper").
                if let capturing {
                    let allPrefixes = app.appBundleIDs.map { $0.lowercased() }
                        + app.helperBundlePrefixes.map { $0.lowercased() }
                    inMeeting = capturing.contains { bid in
                        let lowered = bid.lowercased()
                        return allPrefixes.contains { lowered.hasPrefix($0) }
                    }
                } else {
                    // No mic-capture API (older macOS): fall back to
                    // title-only detection.
                    inMeeting = isRunning(app) && hasMeetingWindow(for: app, includeOffScreen: true)
                }
            } else if let capturing {
                inMeeting = app.captureBundlePrefixes.contains { prefix in
                    capturing.contains { $0.hasPrefix(prefix) }
                }
            } else {
                inMeeting = isRunning(app) && hasMeetingWindow(for: app)
            }
            if inMeeting { activeMeetings.insert(app.bundleID) }
        }
        processActiveMeetings(activeMeetings)
    }

    /// Test seam: drive the state machine directly with a set of "in a
    /// meeting" bundle IDs, bypassing Core Audio. Lets unit tests exercise
    /// the start/end transitions (and the end-debounce) deterministically
    /// without a real Zoom or any audio hardware.
    func simulatePollForTesting(activeBundleIDs: Set<String>) {
        processActiveMeetings(activeBundleIDs)
    }

    /// The pure transition core shared by the live poll and the test seam:
    /// given the set of bundle IDs currently in a meeting, fire
    /// `meetingStarted` on the rising edge and `meetingEnded` on a
    /// debounced falling edge.
    private func processActiveMeetings(_ activeMeetings: Set<String>) {
        for app in Self.supportedApps where activeMeetings.contains(app.bundleID) {
            // A meeting is (still) live — arm the end-detector and
            // clear any in-progress inactivity streak so a brief mic
            // drop that already recovered doesn't count toward "ended".
            endArmed.insert(app.bundleID)
            inactiveStreak[app.bundleID] = 0
            if !firedFor.contains(app.bundleID) {
                firedFor.insert(app.bundleID)
                Self.log.notice("meeting detected: \(app.displayName, privacy: .public) → firing prompt")
                meetingStarted.send(app)
            }
        }

        // Re-arm the START prompt for any app that left its meeting —
        // leaving a call and joining a new one should produce a fresh
        // prompt. This is immediate (no debounce): re-arming early is
        // harmless because the next *start* still requires a fresh active
        // poll.
        let ended = firedFor.subtracting(activeMeetings)
        if !ended.isEmpty {
            Self.log.notice("meeting ended, re-armed: \(ended, privacy: .public)")
        }
        firedFor = firedFor.intersection(activeMeetings)

        // Drive the debounced active→inactive transition that powers the
        // STOP prompt. Unlike the re-arm above, this only fires after the
        // meeting has read inactive for `endConfirmationPolls` consecutive
        // polls, so a momentary Zoom mic release doesn't look like the call
        // ending.
        for bundleID in endArmed where !activeMeetings.contains(bundleID) {
            let streak = (inactiveStreak[bundleID] ?? 0) + 1
            if streak >= endConfirmationPolls {
                inactiveStreak[bundleID] = nil
                endArmed.remove(bundleID)
                if let app = Self.supportedApps.first(where: { $0.bundleID == bundleID }) {
                    Self.log.notice("meeting ended (confirmed): \(app.displayName, privacy: .public) → firing stop prompt")
                    meetingEnded.send(app)
                }
            } else {
                inactiveStreak[bundleID] = streak
            }
        }
    }

    private func isRunning(_ app: App) -> Bool {
        NSWorkspace.shared.runningApplications
            .contains { bid in app.appBundleIDs.contains(bid.bundleIdentifier ?? "") }
    }

    // MARK: - Primary signal: per-process mic capture (Core Audio)

    /// Bundle IDs of processes currently capturing microphone input, via
    /// the Core Audio per-process object API. Returns `nil` when that API
    /// is unavailable (older macOS) so the caller falls back to window
    /// titles. Reading capture *state* (not the audio samples) needs no
    /// permission and triggers no TCC prompt.
    private func bundleIDsCapturingMicInput() -> Set<String>? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(system, &listAddr) else { return nil }

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &listAddr, 0, nil, &size) == noErr,
              size > 0 else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var processes = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &listAddr, 0, nil, &size, &processes) == noErr
        else { return nil }

        var capturing: Set<String> = []
        for proc in processes where isRunningInput(proc) {
            if let bundleID = processBundleID(proc) {
                capturing.insert(bundleID)
            }
        }
        return capturing
    }

    private func isRunningInput(_ object: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &addr) else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr
        else { return false }
        return value != 0
    }

    private func processBundleID(_ object: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &addr) else { return nil }
        var cfString: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &cfString) == noErr,
              let cfString else { return nil }
        return cfString.takeRetainedValue() as String
    }

    // MARK: - Fallback signal: window title (older macOS)

    /// True iff a window owned by an app with the given bundle ID has a
    /// title containing one of `app.meetingTitleHints`. Without Screen
    /// Recording permission, window titles for other processes come back
    /// nil — in that case we conservatively return false. An app with no
    /// hints opts out of this fallback entirely.
    ///
    /// `includeOffScreen` broadens the search to minimized and off-screen
    /// windows. Used for title-only apps (browsers) where the user may
    /// minimize the browser during a call — `.optionOnScreenOnly` would
    /// miss the Meet tab and falsely end the meeting.
    private func hasMeetingWindow(for app: App, includeOffScreen: Bool = false) -> Bool {
        guard !app.meetingTitleHints.isEmpty else { return false }

        let runningPIDs = NSWorkspace.shared.runningApplications
            .filter { bid in app.appBundleIDs.contains(bid.bundleIdentifier ?? "") }
            .map { $0.processIdentifier }
        guard !runningPIDs.isEmpty else { return false }

        let options: CGWindowListOption = includeOffScreen
            ? [.excludeDesktopElements]
            : [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return false }
        for window in info {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  runningPIDs.contains(pid) else { continue }
            guard let title = window[kCGWindowName as String] as? String,
                  !title.isEmpty else { continue }
            let lower = title.lowercased()
            if app.meetingTitleHints.contains(where: { lower.contains($0) }) {
                return true
            }
        }
        return false
    }
}
