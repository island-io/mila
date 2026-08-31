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
/// **Browser-hosted meetings (Google Meet).** Meet has no app of its own —
/// it is a tab in Chrome, Safari, Arc or Island — so the entry lists the
/// browsers that host it (`appBundleIDs`) and the helper processes they
/// actually capture under (`helperBundlePrefixes`). It rides the same two
/// signals in the same order, which has one consequence worth stating
/// plainly: **mic capture proves a browser is in a live audio session, not
/// that the session is Google Meet.** A Slack huddle or WhatsApp Web call
/// in a supported browser reads as a Meet meeting on the primary path. That
/// is accepted deliberately — the prompt it produces is a 10-second
/// auto-dismissing offer to transcribe a call the user really is in, and the
/// alternative (title matching as the primary signal) trades it for a worse
/// failure: a window title only ever reflects the *frontmost tab*, so
/// switching tabs mid-call would read as the meeting having ended and offer
/// to stop a recording that should keep running. See the notes on
/// `helperBundlePrefixes` for the identity trap this creates.
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
        ///
        /// **Keep every prefix here as long as the app it identifies.** A
        /// prefix is matched against *all* mic-capturing processes on the
        /// machine, Mila's own included: Mila is `io.island.whisper.…` and
        /// captures the mic both while recording and while the Settings VU
        /// meter is live, so a prefix of `io.island` (rather than
        /// `io.island.Island` for the Island browser) makes Mila detect
        /// *itself* as a meeting and prompt the user about a call that is
        /// just their own audio settings pane.
        /// `MeetingDetectorBrowserDetectionTests` pins this.
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

        /// True for an entry that lives inside another app (a browser tab)
        /// rather than owning a process of its own — it captures under a
        /// host's bundle ID, so it declares no `captureBundlePrefixes`.
        ///
        /// Only the window-title path needs to know: a browser window
        /// minimized during a call must still count, or the fallback reads a
        /// minimized Meet tab as the meeting having ended. A native app's
        /// meeting window is its own, so the narrower on-screen-only search
        /// stays for those (unchanged behaviour for Zoom).
        var isBrowserHosted: Bool { captureBundlePrefixes.isEmpty }
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
        // Google Meet runs inside a browser, so the entry names the browsers
        // that host it and rides the same mic-capture signal as the native
        // apps: whichever of them is actively capturing the microphone (in
        // its own process or a helper) is in a call.
        //
        // `bundleID` is synthetic — no process has this ID. It is the
        // silence/snooze key and the badge key, and it deliberately does not
        // name a browser, because silencing "Google Meet" must not silence
        // every recording made from Chrome.
        App(
            bundleID: "meet.google.com",
            displayName: "Google Meet",
            appBundleIDs: [
                "com.google.Chrome",
                "com.apple.Safari",
                "company.thebrowser.Browser",
                // The Island browser. NOT `io.island` — see the warning on
                // `helperBundlePrefixes`; that prefix also owns Mila.
                "io.island.Island",
            ],
            captureBundlePrefixes: [],
            // Just the one. Chrome, Arc and Island capture under a `.helper`
            // subprocess (`com.google.Chrome.helper`,
            // `company.thebrowser.browser.helper`) which their own bundle ID
            // above already prefixes, so listing those again adds nothing —
            // and listing them *shorter* than the browser's own ID (say
            // `company.thebrowser`, which also owns Dia) only widens what
            // counts as Meet. Safari is the exception that needs an entry:
            // its capture process is `com.apple.WebKit.GPU`, which
            // `com.apple.Safari` does not prefix. It is also the broadest
            // prefix here — a WKWebView capturing audio inside some *other*
            // app would read as Meet.
            helperBundlePrefixes: ["com.apple.webkit"],
            // `Meet - <code>` is the in-call window title; the bare URL shows
            // while the page loads. Reached only on macOS < 14.4 (no
            // per-process audio API), which is why `meet -` is tolerable
            // despite also matching a page titled e.g. "Track Meet -
            // Results": on 14.4+ this list is never consulted. Deliberately
            // no `google meet` hint — that is the *lobby* title, where the
            // user has not joined anything yet.
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
            if let capturing {
                inMeeting = Self.micCaptureIndicatesMeeting(app, capturing: capturing)
            } else {
                // No mic-capture API (macOS < 14.4): the window title is all
                // there is. Both guards short-circuit before
                // `windowTitles(for:)`, so an app that isn't running — or
                // that opted out of this path by declaring no hints, like
                // Teams — costs no window enumeration on a 3-second poll.
                inMeeting = isRunning(app)
                    && !app.meetingTitleHints.isEmpty
                    && Self.titleIndicatesMeeting(
                        app,
                        titles: windowTitles(for: app, includeOffScreen: app.isBrowserHosted))
            }
            if inMeeting { activeMeetings.insert(app.bundleID) }
        }
        processActiveMeetings(activeMeetings)
    }

    // MARK: - Pure matching (the two signals, without the world)

    /// True iff one of the processes currently capturing mic input belongs to
    /// `app` — its own bundle ID, its host app's, or one of the helper
    /// subprocesses it captures through.
    ///
    /// Pure and `static` on purpose: this is the decision that says "you are
    /// in a meeting", and it is the one part of the detector that can be
    /// tested exhaustively without Core Audio, a browser, or a microphone.
    /// Matching is prefix-based (an app may capture under a helper ID) and
    /// case-insensitive on both sides — bundle IDs are conventionally
    /// lowercase but nothing enforces it, the same reason
    /// `MeetingApp.matching(bundleID:)` lowercases.
    ///
    /// Because a prefix match is open-ended to the right, every prefix has to
    /// be long enough to name one app and no more; `io.island` would claim
    /// Mila itself. `MeetingDetectorBrowserDetectionTests` holds that line.
    static func micCaptureIndicatesMeeting(_ app: App, capturing: Set<String>) -> Bool {
        let prefixes = (app.captureBundlePrefixes + app.appBundleIDs + app.helperBundlePrefixes)
            .map { $0.lowercased() }
        return capturing.contains { bundleID in
            let lowered = bundleID.lowercased()
            return prefixes.contains { lowered.hasPrefix($0) }
        }
    }

    /// True iff one of `titles` looks like one of `app`'s meeting windows.
    /// `titles` are the raw window titles as `CGWindowListCopyWindowInfo`
    /// reports them; hints are lowercased substrings, so the comparison
    /// lowercases the title. An app with no hints opts out entirely (Teams),
    /// which is why an empty hint list must never be read as "match
    /// anything".
    static func titleIndicatesMeeting(_ app: App, titles: [String]) -> Bool {
        guard !app.meetingTitleHints.isEmpty else { return false }
        return titles.contains { title in
            let lower = title.lowercased()
            return app.meetingTitleHints.contains { lower.contains($0) }
        }
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

    /// Titles of the windows owned by any of `app.appBundleIDs`. Without
    /// Screen Recording permission, window titles for other processes come
    /// back nil, so this returns an empty array and the caller detects
    /// nothing — the same conservative outcome as before, just expressed as
    /// "no evidence" rather than "no meeting".
    ///
    /// Split from the hint matching (`titleIndicatesMeeting`) so the matching
    /// half is a pure function tests can drive with realistic titles; this
    /// half is the part that needs a real WindowServer.
    ///
    /// `includeOffScreen` broadens the search to minimized and off-screen
    /// windows, for browser-hosted meetings where the user may minimize the
    /// browser during a call — `.optionOnScreenOnly` would miss the Meet tab
    /// and falsely end the meeting.
    ///
    /// Titles are user content (a tab title names a document, a client, a
    /// meeting) and are deliberately never logged — see
    /// `bugbot-rules/no-user-content-in-logs.md`.
    private func windowTitles(for app: App, includeOffScreen: Bool = false) -> [String] {
        let runningPIDs = NSWorkspace.shared.runningApplications
            .filter { app.appBundleIDs.contains($0.bundleIdentifier ?? "") }
            .map { $0.processIdentifier }
        guard !runningPIDs.isEmpty else { return [] }

        let options: CGWindowListOption = includeOffScreen
            ? [.excludeDesktopElements]
            : [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        return info.compactMap { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  runningPIDs.contains(pid) else { return nil }
            guard let title = window[kCGWindowName as String] as? String,
                  !title.isEmpty else { return nil }
            return title
        }
    }
}
