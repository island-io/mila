import AppKit
import SwiftUI
import Combine
import CoreGraphics

/// The production coordinator uses this same interface in deterministic tests.
@MainActor
protocol MeetingRecordingActions: AnyObject {
    var meetingRecordingURL: URL? { get }
    var canStartMeetingRecording: Bool { get }
    var meetingRecordingChanges: AnyPublisher<Void, Never> { get }
    func startMeetingRecording(isStillValid: @escaping () -> Bool) async -> URL?
    func stopMeetingRecording(expectedURL: URL) async
}

extension QuickActionsController: MeetingRecordingActions {
    var meetingRecordingURL: URL? { isRecording ? session.fileURL : nil }
    var canStartMeetingRecording: Bool {
        activeJob == .none && !captureStartInFlight && !isStoppingRecording
            && !transcription.isPreparingModel
    }
    var meetingRecordingChanges: AnyPublisher<Void, Never> {
        $activeJob.map { _ in () }.eraseToAnyPublisher()
    }
    func stopMeetingRecording(expectedURL: URL) async {
        guard meetingRecordingURL == expectedURL else { return }
        await stopRecording()
    }
}

enum MeetingPromptKind: Equatable { case start, stop }

/// A countdown belongs to one presented prompt. Large delivery gaps cancel an
/// automatic action instead of spending the user's entire grace period asleep.
struct MeetingPromptCountdown {
    enum Outcome: Equatable { case waiting, primary, dismiss }
    private(set) var elapsed: TimeInterval = 0
    private(set) var finished = false
    mutating func advance(by interval: TimeInterval, paused: Bool, automatic: Bool) -> Outcome {
        guard !finished else { return .waiting }
        guard interval.isFinite, interval >= 0 else { return .waiting }
        if automatic && interval > 2 {
            finished = true
            return .dismiss
        }
        guard !paused else { return .waiting }
        elapsed += interval
        guard elapsed >= 10 else { return .waiting }
        finished = true
        return automatic ? .primary : .dismiss
    }
    mutating func cancel() { finished = true }
}

@MainActor
final class MeetingPromptInteraction: ObservableObject {
    @Published var keyboardActive = false
}

private final class MeetingPromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// One prompt at a time. A callback must still own its generation before it can
/// act; dismissing a panel revokes its callbacks even during the close animation.
@MainActor
final class MeetingPromptCoordinator: ObservableObject {
    struct Prompt {
        let id = UUID()
        let app: MeetingDetector.App
        let kind: MeetingPromptKind
        let automatic: Bool
        let meetingID: UUID?
        let recordingURL: URL?
        var startUnavailable = false
    }
    private struct Ownership {
        let appID: String
        let meetingID: UUID
        let recordingURL: URL
    }
    private let detector: MeetingDetector
    private let settings: MeetingDetectionSettings
    private let actions: any MeetingRecordingActions
    private let presentsPanels: Bool
    private let pollsDetector: Bool
    private let screenLockNotifications: NotificationCenter
    private let screenIsLocked: () -> Bool
    private var screenLocked = false
    private var subscriptions: Set<AnyCancellable> = []
    private var running = false
    private var meetings: [String: UUID] = [:]

    /// Declines survive detector blips for this app/meeting identity. A confirmed
    /// end, lifecycle reset, or fresh opt-in retires them.
    private struct DeclinedStart: Hashable {
        let appID: String
        let meetingID: UUID
    }
    private var declinedStarts: Set<DeclinedStart> = []

    private var owner: Ownership?
    private var starting: Prompt?
    private var startTask: Task<Void, Never>?
    private var window: NSPanel?
    @Published private(set) var pending: Prompt?

    init(detector: MeetingDetector, settings: MeetingDetectionSettings,
         actions: any MeetingRecordingActions, presentsPanels: Bool = true,
         pollsDetector: Bool = true,
         screenLockNotifications: NotificationCenter = DistributedNotificationCenter.default(),
         screenIsLocked: @escaping () -> Bool = {
             guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
             return session["CGSSessionScreenIsLocked"] as? Bool ?? false
         }) {
        self.detector = detector
        self.settings = settings
        self.actions = actions
        self.presentsPanels = presentsPanels
        self.pollsDetector = pollsDetector
        self.screenLockNotifications = screenLockNotifications
        self.screenIsLocked = screenIsLocked
    }

    static func shouldShowStopPrompt(detectionEnabled: Bool, appSilenced: Bool,
                                    isRecording: Bool, promptAlreadyShowing: Bool) -> Bool {
        detectionEnabled && !appSilenced && isRecording && !promptAlreadyShowing
    }
    static func shouldDismissStopPrompt(stopPromptShowing: Bool, isRecording: Bool) -> Bool {
        stopPromptShowing && !isRecording
    }

    func start() {
        guard !running else { return }
        running = true
        screenLocked = screenIsLocked()
        // MeetingDetector and MeetingDetectionSettings are @MainActor;
        // their polling/mutation paths deliver these subjects on this actor.
        // Synchronous delivery prevents an ended/revoked request from firing
        // between the event and a later dispatch-queue hop.
        detector.meetingStarted.sink { [weak self] in self?.meetingStarted($0) }
            .store(in: &subscriptions)
        detector.meetingEnded.sink { [weak self] in self?.meetingEnded($0) }
            .store(in: &subscriptions)
        actions.meetingRecordingChanges.receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.recordingChanged() }.store(in: &subscriptions)
        // Use the incoming @Published value synchronously for revocation;
        // reading the property here would still see its pre-willSet value.
        settings.enabledChanges.sink { [weak self] enabled in
            guard let self, !enabled else { return }
            self.invalidatePendingActions()
            self.owner = nil
            self.meetings.removeAll()
            self.declinedStarts.removeAll()
        }.store(in: &subscriptions)
        settings.$autoStartBundleIDs.sink { [weak self] ids in
            guard let self else { return }
            // @Published delivers before willSet, so the stored value is the
            // previous set. Re-arm only the app newly opted in; republishing
            // unchanged IDs or changing another app must preserve declines.
            let newlyEnabledIDs = ids.subtracting(self.settings.autoStartBundleIDs)
            self.declinedStarts = Set(self.declinedStarts.filter { !newlyEnabledIDs.contains($0.appID) })
            self.revokeAutomation(except: ids)
        }.store(in: &subscriptions)
        settings.$disabledBundleIDs.sink { [weak self] ids in
            guard let self else { return }
            if let pending = self.pending, ids.contains(pending.app.bundleID) { self.dismissPrompt() }
            if let starting = self.starting, ids.contains(starting.app.bundleID) { self.cancelStarting() }
            if let owner = self.owner, ids.contains(owner.appID) { self.owner = nil }
        }.store(in: &subscriptions)
        settings.objectWillChange.receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.settingsChanged() }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.invalidatePendingActions() }.store(in: &subscriptions)
        screenLockNotifications.publisher(for: Notification.Name("com.apple.screenIsLocked"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.screenLocked = true
                self.invalidatePendingActions()
                self.owner = nil
            }.store(in: &subscriptions)
        screenLockNotifications.publisher(for: Notification.Name("com.apple.screenIsUnlocked"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.screenLocked = false }.store(in: &subscriptions)
        settingsChanged()
    }

    // Kept for the existing App call site; start() installs one cancellable
    // settings subscription, even if a SwiftUI scene mounts a second time.
    func bindEnabledChanges() { if !running { start() } }

    func stop() {
        running = false
        subscriptions.removeAll()
        invalidatePendingActions()
        meetings.removeAll()
        declinedStarts.removeAll()
        owner = nil
        if pollsDetector { detector.stop() }
    }

    private func allowed(_ appID: String) -> Bool {
        // Recheck at action/permission checkpoints: a timer must not win
        // the delivery hop from the lock notification to the main queue.
        running && !screenLocked && !screenIsLocked()
            && settings.enabled && settings.mode(forBundleID: appID) != .off
    }
    private func validStart(_ prompt: Prompt) -> Bool {
        allowed(prompt.app.bundleID)
            && meetings[prompt.app.bundleID] == prompt.meetingID
            && prompt.meetingID != nil
            && (!prompt.automatic || settings.mode(forBundleID: prompt.app.bundleID) == .auto)
    }
    private func validStop(_ prompt: Prompt) -> Bool {
        guard allowed(prompt.app.bundleID), let url = prompt.recordingURL,
              actions.meetingRecordingURL == url else { return false }
        if !prompt.automatic { return true }
        return settings.mode(forBundleID: prompt.app.bundleID) == .auto
            && meetings.isEmpty && owner?.appID == prompt.app.bundleID
            && owner?.recordingURL == url
    }

    private func meetingStarted(_ app: MeetingDetector.App) {
        guard running else { return }
        // A brief inactive poll can re-fire start before a confirmed end. Keep
        // the identity until the detector confirms that this meeting ended.
        if meetings[app.bundleID] == nil {
            meetings[app.bundleID] = UUID()
            // A rejoined call is a new meeting; the previous recording is
            // now controlled explicitly, even when it still has the same URL.
            if owner?.appID == app.bundleID { owner = nil }
        }
        if pending?.kind == .stop, pending?.automatic == true { dismissPrompt() }
        guard pending == nil, starting == nil, actions.meetingRecordingURL == nil,
              allowed(app.bundleID) else { return }
        // The detector re-fires `meetingStarted` after any brief inactive poll,
        // before it has confirmed an end, so the SAME `meetings` UUID can arrive
        // again. A generation the user explicitly declined must not re-present a
        // countdown (or, in Auto, capture) — only a confirmed end/rejoin may.
        if let meetingID = meetings[app.bundleID],
           declinedStarts.contains(DeclinedStart(appID: app.bundleID, meetingID: meetingID)) {
            return
        }
        let wantsAuto = settings.mode(forBundleID: app.bundleID) == .auto
        let automatic = wantsAuto && actions.canStartMeetingRecording
        present(Prompt(app: app, kind: .start, automatic: automatic,
                       meetingID: meetings[app.bundleID], recordingURL: nil,
                       startUnavailable: wantsAuto && !automatic))
    }

    private func meetingEnded(_ app: MeetingDetector.App) {
        let endedMeetingID = meetings.removeValue(forKey: app.bundleID)
        // The generation is over: retire its decline so a genuine rejoin (which
        // mints a fresh UUID anyway) and the bounded set both stay clean.
        if let endedMeetingID {
            declinedStarts.remove(DeclinedStart(appID: app.bundleID, meetingID: endedMeetingID))
        }
        if pending?.kind == .start, pending?.app.bundleID == app.bundleID { dismissPrompt() }
        if starting?.app.bundleID == app.bundleID { cancelStarting() }
        guard allowed(app.bundleID), pending == nil, let url = actions.meetingRecordingURL else { return }
        let automatic = settings.mode(forBundleID: app.bundleID) == .auto
            && owner?.appID == app.bundleID && owner?.meetingID == endedMeetingID
            && owner?.recordingURL == url && meetings.isEmpty
        present(Prompt(app: app, kind: .stop, automatic: automatic,
                       meetingID: nil, recordingURL: url))
    }

    private func recordingChanged() {
        let url = actions.meetingRecordingURL
        if owner?.recordingURL != url { owner = nil }
        guard let prompt = pending else { return }
        if (prompt.kind == .start && url != nil)
            || (prompt.kind == .stop && prompt.recordingURL != url) { dismissPrompt() }
    }

    private func revokeAutomation(except allowedIDs: Set<String>) {
        if let pending, pending.automatic, !allowedIDs.contains(pending.app.bundleID) { dismissPrompt() }
        if let starting, starting.automatic, !allowedIDs.contains(starting.app.bundleID) { cancelStarting() }
        if let owner, !allowedIDs.contains(owner.appID) { self.owner = nil }
    }

    private func settingsChanged() {
        if let owner, !allowed(owner.appID) || settings.mode(forBundleID: owner.appID) != .auto {
            self.owner = nil // revocation does not stop an already-active recording
        }
        if let pending, !allowed(pending.app.bundleID)
            || (pending.automatic && settings.mode(forBundleID: pending.app.bundleID) != .auto) {
            dismissPrompt()
        }
        if let starting, !validStart(starting) { cancelStarting() }
        if settings.enabled {
            if pollsDetector { detector.start() }
        } else {
            meetings.removeAll()
            declinedStarts.removeAll()
            if pollsDetector { detector.stop() }
        }
    }

    /// Explicit user cancellation of the current prompt ("Cancel start",
    /// "Not now", Escape, or "Keep recording"). Cancelling a START is
    /// remembered as a declined generation so a flickering detector cannot
    /// re-present it; cancelling a STOP ("Keep recording") is not, and never
    /// touches the active recording.
    func cancelPrompt(id: UUID) { cancelPrompt(id: id, userInitiated: true) }

    /// The countdown's own dismissal — an unattended timeout or a long
    /// delivery gap. Identical to a cancel except that it is NOT a user
    /// decline: the generation stays eligible if the detector re-fires it.
    func expirePrompt(id: UUID) { cancelPrompt(id: id, userInitiated: false) }

    private func cancelPrompt(id: UUID, userInitiated: Bool) {
        guard let prompt = pending, prompt.id == id else { return }
        if userInitiated, prompt.kind == .start, let meetingID = prompt.meetingID {
            declinedStarts.insert(DeclinedStart(appID: prompt.app.bundleID, meetingID: meetingID))
        }
        if prompt.kind == .stop {
            announce("Recording will continue.")
        } else {
            announce(prompt.automatic ? "Automatic recording cancelled." : "Recording has not started.")
        }
        dismissPrompt()
    }

    /// Both timer expiry and explicit button clicks go through the current
    /// prompt, not captured booleans from when the window was created.
    func performPrompt(id: UUID, enableAuto: Bool = false) {
        guard var prompt = pending, prompt.id == id else { return }
        guard allowed(prompt.app.bundleID) else { dismissPrompt(); return }
        if enableAuto {
            guard prompt.kind == .start, validStart(prompt), actions.meetingRecordingURL == nil else {
                dismissPrompt(); return
            }
            settings.setMode(.auto, forBundleID: prompt.app.bundleID)
            prompt = Prompt(app: prompt.app, kind: .start, automatic: true,
                            meetingID: prompt.meetingID, recordingURL: nil)
            // Enabling a preference is not consent to capture immediately.
            // Give the newly enabled action its own cancellable grace period.
            present(prompt)
            return
        }
        switch prompt.kind {
        case .start:
            guard validStart(prompt), actions.meetingRecordingURL == nil else { dismissPrompt(); return }
            guard actions.canStartMeetingRecording else {
                // Keep an explicit action available after a busy/preparing
                // interval; do not repeatedly retry capture in the background.
                present(Prompt(app: prompt.app, kind: .start, automatic: false,
                               meetingID: prompt.meetingID, recordingURL: nil, startUnavailable: true))
                return
            }
            dismissPrompt()
            starting = prompt
            let prompt = prompt
            startTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await self.actions.startMeetingRecording { [weak self] in
                    guard let self else { return false }
                    return self.starting?.id == prompt.id && self.validStart(prompt) && !Task.isCancelled
                }
                if self.starting?.id == prompt.id {
                    if let result, self.validStart(prompt), self.actions.meetingRecordingURL == result {
                        if prompt.automatic, let meetingID = prompt.meetingID {
                            self.owner = Ownership(appID: prompt.app.bundleID, meetingID: meetingID, recordingURL: result)
                        }
                        self.announce("Recording started for \(prompt.app.displayName).")
                    }
                    self.starting = nil
                    self.startTask = nil
                }
            }
        case .stop:
            guard validStop(prompt), let url = prompt.recordingURL else { dismissPrompt(); return }
            dismissPrompt()
            let prompt = prompt
            Task { @MainActor [weak self] in
                guard let self, self.validStop(prompt) else { return }
                await self.actions.stopMeetingRecording(expectedURL: url)
                self.owner = nil
                self.announce("Recording stopped.")
            }
        }
    }

    private func cancelStarting() {
        // Cancelling the in-flight start task does two things: the controller
        // bridges the Swift task cancellation to the attempt's
        // `CaptureStartCancellation` synchronously (see `startRecording`), so a
        // capture leg still suspended stops short of opening; and the
        // controller's `isStillValid` predicate returns false at its next
        // checkpoint, covering a bring-up that has already passed its last
        // in-leg check.
        starting = nil
        startTask?.cancel()
        startTask = nil
    }
    private func invalidatePendingActions() {
        dismissPrompt()
        cancelStarting()
    }

    private func present(_ prompt: Prompt) {
        dismissPrompt()
        pending = prompt
        guard presentsPanels else { return }
        let interaction = MeetingPromptInteraction()
        let view = MeetingPromptView(app: prompt.app, kind: prompt.kind,
            autoAct: prompt.automatic, startUnavailable: prompt.startUnavailable, interaction: interaction,
            onPrimary: { [weak self] in self?.performPrompt(id: prompt.id) },
            onDismiss: { [weak self] in self?.cancelPrompt(id: prompt.id) },
            onTimeout: { [weak self] in self?.expirePrompt(id: prompt.id) },
            onSilenceApp: { [weak self] in
                guard let self, self.pending?.id == prompt.id else { return }
                self.settings.setMode(.off, forBundleID: prompt.app.bundleID)
                self.announce("Meeting recording is off for \(prompt.app.displayName).")
                self.dismissPrompt()
            },
            onEnableAuto: prompt.kind == .start && !prompt.automatic ? { [weak self] in
                self?.performPrompt(id: prompt.id, enableAuto: true)
            } : nil,
            onHeightChange: { [weak self] height in
                guard let self, self.pending?.id == prompt.id, let panel = self.window else { return }
                panel.setContentSize(NSSize(width: 360, height: height))
                self.positionTopTrailing(panel)
            })
        let panel = MeetingPromptPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 180),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .participatesInCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: view)
        window = panel
        for notification in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.publisher(for: notification, object: panel)
                .sink { [weak panel, weak interaction] _ in interaction?.keyboardActive = panel?.isKeyWindow == true }
                .store(in: &panelSubscriptions)
        }
        positionTopTrailing(panel)
        panel.orderFrontRegardless()
        if prompt.startUnavailable {
            announce("Recording has not started. Mila is busy; use Start transcribing when ready.")
        } else if prompt.automatic {
            announce("\(prompt.app.displayName): \(prompt.kind == .start ? "starting" : "stopping") recording in ten seconds. Focus the prompt to pause, or cancel.")
        } else {
            let question = prompt.kind == .start ? "Meeting detected. Start transcribing?" : "Meeting ended. Stop recording?"
            announce("\(prompt.app.displayName): \(question) Focus the prompt to pause and respond.")
        }
    }
    private var panelSubscriptions: Set<AnyCancellable> = []
    private func dismissPrompt() {
        pending = nil
        panelSubscriptions.removeAll()
        guard let panel = window else { return }
        window = nil
        panel.orderOut(nil)
        panel.contentView = nil
    }
    private func announce(_ text: String) {
        guard presentsPanels else { return }
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
    private func positionTopTrailing(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - panel.frame.width - 16, y: frame.maxY - 16))
    }
}

private struct MeetingPromptHeight: PreferenceKey {
    static var defaultValue: CGFloat = 180
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct MeetingPromptView: View {
    /// Which prompt this is — start a recording (meeting detected) or stop
    /// one (meeting ended). Drives all the copy, the primary button style,
    /// and the accessibility identifiers so a single view body serves both.
    typealias Kind = MeetingPromptKind

    let app: MeetingDetector.App
    let kind: Kind
    /// When true, the timer auto-triggers `onPrimary` instead of
    /// `onDismiss` — used for per-app auto-start/stop.
    let autoAct: Bool
    let startUnavailable: Bool
    @ObservedObject var interaction: MeetingPromptInteraction
    let onPrimary: () -> Void
    let onDismiss: () -> Void
    /// Countdown expiry for an unattended prompt. Kept separate from
    /// `onDismiss` so the coordinator can tell an explicit user cancellation
    /// (which must suppress the rest of this meeting generation) from the
    /// timer's own dismissal, which must not.
    var onTimeout: (() -> Void)? = nil
    let onSilenceApp: () -> Void
    /// Enable auto-start/stop and present a fresh cancellable countdown.
    var onEnableAuto: (() -> Void)? = nil
    var onHeightChange: (CGFloat) -> Void = { _ in }

    /// How long the prompt stays up if the user doesn't interact.
    private let autoDismissSeconds: Double = 10
    /// Granularity of the progress bar tick. 30 fps is smooth without
    /// being wasteful.
    private let tickInterval: Double = 1.0 / 30.0

    @State private var countdown = MeetingPromptCountdown()
    @State private var hovering = false
    @State private var expanded = false
    @State private var dismissed = false
    /// Monotonic anchor used to track elapsed time accurately even when
    /// the system briefly throttles SwiftUI's timer callbacks.
    @State private var lastTick = ContinuousClock.now

    private let timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Progress bar lives at the TOP of the card now: it reads
            // as "time is running out from here downward" — and crucially
            // it sits INSIDE the rounded corners (the whole VStack gets
            // clipped to the card shape below) so the bar never extends
            // past the card edge.
            progressBar
            content
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)
            if expanded {
                Divider().opacity(0.4)
                expandedActions
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
        }
        .background(cardBackground)
        // Clip everything (including the progress bar) to the card's
        // shape so the bar doesn't bleed past the corners.
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        .frame(width: 360)
        .onHover { hovering = $0 }
        .onReceive(timer) { _ in tick() }
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: MeetingPromptHeight.self, value: proxy.size.height)
        })
        .onPreferenceChange(MeetingPromptHeight.self, perform: onHeightChange)
        .onAppear { lastTick = .now }
        .onDisappear { dismissed = true; countdown.cancel() }
        // Keep identifiers on individual controls; a SwiftUI container
        // identifier propagates to children and masks their identifiers.
    }

    /// Accessibility-identifier prefix, distinct per kind so UI tests can
    /// target the start prompt and the stop prompt independently.
    private var identifierPrefix: String {
        switch kind {
        case .start: return "meetingPrompt"
        case .stop:  return "meetingStopPrompt"
        }
    }

    private var titleText: String {
        switch kind {
        case .start: return "\(app.displayName) meeting detected"
        case .stop:  return "\(app.displayName) meeting ended"
        }
    }

    private var subtitleText: String {
        if isPaused {
            return autoAct ? "Countdown paused — leave the prompt to continue."
                : "Prompt stays open while you interact."
        }
        if startUnavailable { return "Recording has not started. Mila is busy; try Start transcribing when ready." }
        if autoAct {
            let remaining = max(0, Int(ceil(autoDismissSeconds - countdown.elapsed)))
            switch kind {
            case .start: return "Starting recording in \(remaining)…"
            case .stop:  return "Stopping recording in \(remaining)…"
            }
        }
        switch kind {
        case .start: return "Want Mila to transcribe this call?"
        case .stop:  return "Stop recording now?"
        }
    }

    private var primaryButtonText: String {
        switch kind {
        case .start: return "Start transcribing"
        case .stop:  return "Stop recording"
        }
    }

    private var dismissButtonText: String {
        if autoAct { return kind == .start ? "Cancel start" : "Keep recording" }
        switch kind {
        case .start: return "Not now"
        case .stop:  return "Keep recording"
        }
    }

    /// Brighter card fill — `regularMaterial` skews dark on macOS in
    /// dark mode and against bright backgrounds reads as "faded notice
    /// you can ignore." Layering a near-opaque window background tint
    /// on top of `thickMaterial` keeps the vibrant feel while making
    /// the card itself clearly foreground.
    private var cardBackground: some View {
        ZStack {
            Rectangle().fill(.thickMaterial)
            Rectangle().fill(Color(NSColor.windowBackgroundColor).opacity(0.55))
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 12) {
            // App icon — uses Mila's app icon to anchor brand identity.
            // The Mila wordmark + meeting-detection feature is what this
            // prompt represents; showing Zoom's icon could be mistaken
            // for a Zoom notification.
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 36, height: 36)
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(titleText)
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            expanded.toggle()
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("More options")
                    .accessibilityLabel("More meeting recording options")
                    .accessibilityIdentifier("\(identifierPrefix).chevron")
                }

                Text(subtitleText)
                    .accessibilityIdentifier("\(identifierPrefix).countdown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button(action: triggerPrimary) {
                        Text(primaryButtonText)
                            .font(.callout.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("\(identifierPrefix).primary")

                    Button(action: triggerDismiss) {
                        Text(dismissButtonText)
                            .font(.callout)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("\(identifierPrefix).dismiss")
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.top, 4)
            }
        }
    }

    private var expandedActions: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let onEnableAuto, kind == .start, !autoAct {
                Button {
                    guard !dismissed else { return }
                    dismissed = true
                    onEnableAuto()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.circle")
                            .font(.caption)
                        Text("Enable automatic start and stop for \(app.displayName)")
                            .font(.callout)
                    }
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(identifierPrefix).enableAuto")
            }
            Button(action: triggerSilence) {
                HStack(spacing: 6) {
                    Image(systemName: "bell.slash")
                        .font(.caption)
                    Text("Don't show this for \(app.displayName)")
                        .font(.callout)
                }
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("\(identifierPrefix).silence")

            Text("You can re-enable this in Settings → Meetings.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                Rectangle()
                    .fill(isPaused ? Color.secondary : Color.accentColor)
                    .frame(width: geo.size.width * CGFloat(progressFraction))
                    .animation(.linear(duration: tickInterval), value: progressFraction)
            }
        }
        .frame(height: 3)
        // Don't clip the bar to a separate rounded rect — the parent
        // already clips the whole card to its corner radius, which is
        // what keeps the bar from bleeding past the edges.
    }

    private var progressFraction: Double {
        let remaining = max(0, autoDismissSeconds - countdown.elapsed)
        return max(0, min(1, remaining / autoDismissSeconds))
    }

    private var isPaused: Bool { hovering || expanded || interaction.keyboardActive }

    private func tick() {
        guard !dismissed else { return }
        let now = ContinuousClock.now
        let duration = lastTick.duration(to: now).components
        lastTick = now
        let dt = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        switch countdown.advance(by: dt, paused: isPaused, automatic: autoAct) {
        case .waiting: break
        case .primary: triggerPrimary()
        case .dismiss: triggerTimeout()
        }
    }

    private func triggerPrimary() {
        guard !dismissed else { return }
        dismissed = true
        onPrimary()
    }

    /// The timer's own dismissal — distinct from a user clicking the dismiss
    /// button, so the coordinator does not record a declined generation for a
    /// prompt the user never touched.
    private func triggerTimeout() {
        guard !dismissed else { return }
        dismissed = true
        (onTimeout ?? onDismiss)()
    }

    private func triggerDismiss() {
        guard !dismissed else { return }
        dismissed = true
        onDismiss()
    }

    private func triggerSilence() {
        guard !dismissed else { return }
        dismissed = true
        onSilenceApp()
    }
}
