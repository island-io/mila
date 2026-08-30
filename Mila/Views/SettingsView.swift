import SwiftUI
import AppKit
import Carbon.HIToolbox

/// One destination in Settings.
///
/// Still called `SettingsTab` even though Settings is no longer a `TabView`
/// (#177 replaced the strip with a sidebar). The name is deliberately kept:
/// it is the key of the deep-link contract (`SettingsNavigation.pendingTab`),
/// its raw values are pinned by `AISettingsKeyCompatibilityTests`, and the
/// per-destination views are all still named `…SettingsTab`. Renaming the type
/// would churn all three for no behavioural gain.
///
/// `allCases` order IS the sidebar order, top to bottom. Adding a case adds a
/// row; it costs vertical space in a scrollable list, so — unlike the old tab
/// strip — there is no width budget to re-measure.
enum SettingsTab: Int, Hashable, CaseIterable, Identifiable {
    /// `aiProvider` + `aiFeatures` replace the former separate `llm` and
    /// `liveAI` tabs. The split is by *how often you touch it*: the provider
    /// is technical and set once (often via a `.milaconfig` import), while the
    /// feature switches are what people come back for. Keeping them on one
    /// screen forced every feature below the fold behind a disclosure arrow.
    case general, audio, models, aiProvider, aiFeatures, speakers, meetings, voiceMemos, storage

    var id: Int { rawValue }

    /// Sidebar row label, and the Settings window title while selected.
    var title: String {
        switch self {
        case .general: return "General"
        case .audio: return "Audio"
        case .models: return "Models"
        case .aiProvider: return "AI Provider"
        case .aiFeatures: return "AI Features"
        case .speakers: return "Speakers"
        case .meetings: return "Meetings"
        case .voiceMemos: return "Voice Memos"
        case .storage: return "Storage"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .audio: return "mic"
        case .models: return "cube.box"
        case .aiProvider: return "sparkles"
        case .aiFeatures: return "wand.and.stars"
        case .speakers: return "person.2"
        case .meetings: return "video.fill"
        case .voiceMemos: return "waveform"
        case .storage: return "externaldrive"
        }
    }

    /// Stable per-row accessibility identifier, so GUI tests can select a
    /// destination without matching on the (localisable) visible label.
    /// `MilaUITests` hardcodes these strings — the UI-test target cannot
    /// import the app's types — and `AISettingsKeyCompatibilityTests` pins
    /// them.
    var accessibilityID: String {
        switch self {
        case .general: return "settings.section.general"
        case .audio: return "settings.section.audio"
        case .models: return "settings.section.models"
        case .aiProvider: return "settings.section.aiProvider"
        case .aiFeatures: return "settings.section.aiFeatures"
        case .speakers: return "settings.section.speakers"
        case .meetings: return "settings.section.meetings"
        case .voiceMemos: return "settings.section.voiceMemos"
        case .storage: return "settings.section.storage"
        }
    }

    /// True when the destination's own root view is already a `ScrollView`.
    ///
    /// Load-bearing, not cosmetic. The detail column must never report a
    /// height larger than the window proposes it — that overflow is exactly
    /// what made the first attempt at this change render an empty window (see
    /// `SettingsView`). A `ScrollView` is the structural guarantee: it
    /// accepts whatever height it is offered and scrolls the rest. Sections
    /// that don't bring their own get wrapped in one by
    /// `SettingsView.detailPane`; double-wrapping the ones that do would nest
    /// two vertical scrollers, which fight each other.
    var providesOwnScrollView: Bool {
        switch self {
        case .models, .aiProvider, .aiFeatures, .meetings, .storage:
            return true
        case .general, .audio, .speakers, .voiceMemos:
            return false
        }
    }
}

@Observable
final class SettingsNavigation {
    @MainActor static let shared = SettingsNavigation()

    /// Set this to jump Settings to a destination. Consumed (reset to nil) by
    /// `SettingsView` as soon as it applies. Cross-references inside Settings
    /// use it to become real navigation instead of prose — see
    /// `AIFeaturesSettingsTab.notConfiguredBanner`.
    var pendingTab: SettingsTab?
}

/// Standard `Settings` scene. Opened via `Cmd+,` from the menu bar, and via
/// `SettingsLink` in the sidebar footer.
///
/// ## Why a sidebar and not a tab strip (#177)
///
/// This used to be a `TabView`, and the window width was load-bearing because
/// of it: AppKit's `NSTabView` collapses whatever does not fit the strip into
/// a `>>` overflow menu, which reads as a stray "expand button" and makes the
/// collapsed tabs look disabled. That was reported as #131 and worked around
/// in #137 by pinning the window to 700×560 (740 pt of strip room) to hold
/// the measured 599 pt run of nine tab items. #144 then concluded the
/// obvious: nine fits, "with no room for a tenth". Both remaining moves —
/// widen again, or merge tabs — were spent, so new settings were being parked
/// inside the Storage section for want of a slot.
///
/// A sidebar list removes the ceiling instead of raising it: destinations cost
/// vertical space, which scrolls, rather than horizontal strip width, which
/// does not. There is no `NSTabView` in the tree, so #131's `>>` chevron
/// cannot come back at any destination count, and the window no longer needs
/// a hardcoded size — it is resizable, which also settles #177's "a dense tab
/// can't be given more room".
///
/// Settings stays its own `Settings` scene rather than becoming a page inside
/// the main window (which is what #177 literally proposed): that keeps
/// `Cmd+,`, `SettingsLink` and the App-menu item working with no code at all,
/// keeps the macOS-native idiom, and — being a real window — can be placed
/// side by side with the main window, which an in-app page that takes over
/// the content area cannot. It also keeps the documented convention that
/// app-wide settings objects are injected into both scenes (`CLAUDE.md`) true
/// as written.
///
/// ## Why the layout is hand-rolled and not a `NavigationSplitView`
///
/// The first attempt at this change (#194, commit `60218f1`) used
/// `NavigationSplitView` and shipped a completely empty window: no sidebar
/// rows, no controls. It was reverted in `6b64e8b`.
///
/// The cause, from the accessibility tree of the running app: inside the
/// 900×472 Settings window, the split view laid out at
/// `{{62, -2671}, {900, 6115}}` — 6115 pt tall, vertically centred, so it
/// began 2671 pt *above* the window. Every sidebar row landed at y ≈ -2600
/// and `updates.autoCheck.toggle` at y = 3314, i.e. thousands of points
/// outside the visible content area. Nothing was missing; everything was
/// off-screen. The window title still tracked the section, which is why the
/// window read as "chrome but no content".
///
/// What let that happen: the old `.frame(width: 700, height: 560)` was a
/// *rigid* frame, and it had been the only thing pinning the content to the
/// window. #194 replaced it with `.frame(minWidth:idealWidth:minHeight:
/// idealHeight:)` — no `max` in either axis. A flexible frame reports
/// `clamp(childSize, min, max)`, so with no upper bound it adopted the split
/// view's content-driven 6115 pt instead of the 472 pt the window offered.
///
/// So the rule this layout follows: **every child of the window-sized frame
/// must be bounded** — it may never report a size larger than it is
/// proposed. A `ScrollView` satisfies that by construction (it takes the
/// height offered and scrolls the overflow), and so does a fixed-width
/// column. That is the whole reason `SettingsTab.providesOwnScrollView`
/// exists and the reason this is a plain `HStack` of two bounded columns
/// rather than an AppKit-bridged split container whose sizing behaviour is
/// not ours to reason about. It is also the same failure mode
/// `DetailLayoutUITests` was originally written for, one window over.
struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general

    /// Sidebar column width. Fixed rather than draggable: nine short labels
    /// need no user-tunable column, and a fixed column is one fewer thing
    /// that can be dragged into an unusable state.
    private static let sidebarWidth: CGFloat = 188

    /// The old `TabView` was wrapped in `.padding(20)`, so every
    /// destination's content is written assuming a 20 pt outer inset. Keep
    /// it, so the per-destination layouts are untouched by this change.
    private static let detailInset: CGFloat = 20

    /// Narrowest the destination *content* may get. Every destination lays
    /// out flexibly (`maxWidth:`); the widest rigid run in any of them is a
    /// 110 pt label beside a 160 pt hotkey field, so 560 has real slack. It
    /// exists to stop the window being dragged into nonsense, and it is what
    /// `minWindowWidth` is derived from.
    private static let minDetailWidth: CGFloat = 560

    /// The old window was 740 pt wide with 700 pt of content. Keep 700 pt of
    /// content at the ideal size so first launch is not a downgrade.
    private static let idealDetailWidth: CGFloat = 700

    static let minWindowWidth = sidebarWidth + minDetailWidth + 2 * detailInset
    static let idealWindowWidth = sidebarWidth + idealDetailWidth + 2 * detailInset

    /// The old window was 600 pt tall (560 pt of content). Never offer less
    /// vertical room than the fixed window did; growing past it is the point.
    private static let minWindowHeight: CGFloat = 600
    private static let idealWindowHeight: CGFloat = 700

    var body: some View {
        HStack(spacing: 0) {
            sectionList
            Divider()
            detailPane
        }
        // Bounded in both axes, unlike #194's frame. `maxWidth`/`maxHeight`
        // of `.infinity` make this greedy — it fills the window instead of
        // sizing to its content — and `windowResizability(.contentSize)` on
        // the `Settings` scene in `MilaApp` maps min/max onto the window's
        // own resize limits.
        .frame(minWidth: Self.minWindowWidth,
               idealWidth: Self.idealWindowWidth,
               maxWidth: .infinity,
               minHeight: Self.minWindowHeight,
               idealHeight: Self.idealWindowHeight,
               maxHeight: .infinity)
        .background(
            SettingsWindowTitle(title: selectedTab.title)
                .frame(width: 0, height: 0)
        )
        .onChange(of: SettingsNavigation.shared.pendingTab, initial: true) { _, newTab in
            if let tab = newTab {
                selectedTab = tab
                SettingsNavigation.shared.pendingTab = nil
            }
        }
    }

    // MARK: Sidebar

    private var sectionList: some View {
        List(SettingsTab.allCases, selection: sidebarSelection) { tab in
            Label(tab.title, systemImage: tab.systemImage)
                .accessibilityIdentifier(tab.accessibilityID)
                .tag(tab)
        }
        .listStyle(.sidebar)
        // A `List` is bounded by construction — it takes the height it is
        // offered and scrolls the rest — so a tenth, twentieth or fiftieth
        // destination changes nothing about the window's geometry.
        .frame(width: Self.sidebarWidth)
        .frame(maxHeight: .infinity)
    }

    /// `List`'s selection binding is `Optional` — Escape, or a click on empty
    /// sidebar space, clears it, which would blank the detail pane.
    /// Swallowing the nil keeps a destination always selected.
    private var sidebarSelection: Binding<SettingsTab?> {
        Binding(
            get: { selectedTab },
            set: { if let new = $0 { selectedTab = new } }
        )
    }

    // MARK: Detail

    private var detailPane: some View {
        Group {
            if selectedTab.providesOwnScrollView {
                destination
                    .padding(Self.detailInset)
            } else {
                ScrollView(.vertical) {
                    destination
                        .padding(Self.detailInset)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // A fresh identity per destination. Two things hang off it: the
        // scroll offset resets per section (a leftover offset from a long
        // section reads as a mis-rendered short one), and SwiftUI is
        // guaranteed to tear the previous destination down — so
        // `AudioSettingsTab`'s `.onDisappear` really does stop the VU meter
        // when you leave Audio, and its `.task` really does restart it when
        // you come back. The old `TabView` gave that teardown for free.
        .id(selectedTab)
    }

    @ViewBuilder
    private var destination: some View {
        switch selectedTab {
        case .general: GeneralSettingsTab()
        case .audio: AudioSettingsTab()
        case .models: ModelsSettingsTab()
        case .aiProvider: AIProviderSettingsTab()
        case .aiFeatures: AIFeaturesSettingsTab()
        case .speakers: DiarizationSettingsTab()
        case .meetings: MeetingsSettingsTab()
        case .voiceMemos: VoiceMemosSettingsTab()
        case .storage: StorageSettingsTab()
        }
    }
}

/// Puts the selected destination's name in the Settings window's title bar.
///
/// The old `TabView` got this for free: AppKit titles an `NSTabView`-backed
/// Settings window after the selected tab item. With the strip gone nothing
/// sets it, and `.navigationTitle` needs a navigation container to hang off —
/// there isn't one here — so set it on the hosting `NSWindow` directly. This
/// is the only window this view is ever installed in, so there is no risk of
/// retitling someone else's.
private struct SettingsWindowTitle: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let title = self.title
        // `nsView.window` is nil while the view is still being installed, so
        // the very first update would drop the title. Defer a runloop turn.
        DispatchQueue.main.async {
            nsView.window?.title = title
        }
    }
}

// MARK: - Audio

private struct AudioSettingsTab: View {
    @EnvironmentObject private var settings: AudioInputSettings
    @EnvironmentObject private var monitor: InputLevelMonitor
    @EnvironmentObject private var actions: QuickActionsController
    @State private var devices: [AudioDeviceManager.Device] = []

    /// Sentinel UID that means "follow the system default input". Picker's
    /// SwiftUI tag has to be `String`, so we can't use Optional<String> as a
    /// tag value directly here without all the rawValue plumbing.
    private static let autoTag = "__auto__"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Input source")
                .font(.title3.weight(.semibold))
            Text("Choose which microphone Mila reads from. Leave on Automatic to follow whatever macOS uses as its system default. Pin to a specific device if your default is a virtual mic (Krisp, BlackHole, Zoom Audio, etc.) and you'd rather record from the raw hardware.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Input", selection: binding) {
                Text("Automatic (system default)")
                    .tag(Self.autoTag)
                ForEach(devices, id: \.uid) { device in
                    Text(label(for: device))
                        .tag(device.uid)
                }
                if let pinned = settings.preferredUID,
                   devices.first(where: { $0.uid == pinned }) == nil {
                    Text("Saved device (unplugged) — \(pinned)")
                        .tag(pinned)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 360)
            // Audio's per-section probe for `DetailLayoutUITests`: a control
            // that is present unconditionally, so "this destination rendered"
            // is checkable without depending on device state.
            .accessibilityIdentifier("audio.input.picker")

            Button("Refresh device list") { refresh() }
                .buttonStyle(.borderless)

            Divider().padding(.vertical, 4)

            // Live VU meter for the currently-selected input. Lets users
            // confirm the chosen device is actually hearing them before
            // they record — the most common "why is my transcript empty"
            // failure mode comes from picking the wrong (or muted) input.
            // Paused during active recording so we don't fight the real
            // MicrophoneRecorder for the device.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .foregroundStyle(.tint)
                    Text("Input level")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text(meterStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        // Lets a GUI test see that the VU meter's lifecycle
                        // still runs when Settings switches destinations
                        // (`.task` / `.onDisappear` now fire on selection
                        // change rather than tab change — see
                        // `SettingsView.detailPane`). Deliberately not
                        // asserted to read "Live" in CI: the hosted runners
                        // have no input device.
                        .accessibilityIdentifier("audio.meter.status")
                }
                LevelMeterView(level: monitor.level,
                               isLive: monitor.isRunning && !actions.isRecording)
                    .frame(maxWidth: 360)
            }

            Divider().padding(.vertical, 4)

            // Adaptive digital gain. Default ON — most users with a built-in
            // MacBook mic have their system input volume well below
            // unity, which puts speech below the live VAD cutoff (0.012)
            // and starves the live transcript pane. The gain controller
            // boosts low-volume capture to a target observed RMS uniformly
            // across the saved WAV and the live feed.
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Automatic mic gain adjustment",
                       isOn: $settings.adaptiveGainEnabled)
                    .toggleStyle(.switch)
                Text("Boosts low-volume microphone input automatically when speech is captured. Disable if you prefer manual control of input levels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: refresh)
        .task {
            // Bring up (or refresh) the monitor when the user opens this tab.
            // Settings is a separate window so we can't rely on Home's
            // lifecycle — each window manages its own start/stop.
            await refreshMonitor()
        }
        .onDisappear {
            Task { await monitor.stop() }
        }
        .onChange(of: settings.preferredUID) { _, newValue in
            monitor.preferredUID = newValue
            Task { await monitor.restart() }
        }
        .onChange(of: actions.isRecording) { _, _ in
            Task { await refreshMonitor() }
        }
    }

    private func refreshMonitor() async {
        if actions.isRecording {
            await monitor.stop()
        } else {
            await monitor.start()
        }
    }

    private var meterStatusText: String {
        if actions.isRecording {
            return "Paused — recording in progress"
        }
        return monitor.isRunning ? "Live" : "Starting…"
    }

    private var binding: Binding<String> {
        Binding(
            get: { settings.preferredUID ?? Self.autoTag },
            set: { settings.preferredUID = ($0 == Self.autoTag) ? nil : $0 }
        )
    }

    private func label(for device: AudioDeviceManager.Device) -> String {
        var parts: [String] = [device.name]
        if device.isBuiltIn { parts.append("built-in") }
        if device.isVirtual { parts.append("virtual") }
        return parts.joined(separator: " — ")
    }

    private func refresh() {
        devices = AudioDeviceManager.inputDevices()
    }
}

// MARK: - Hotkeys

/// Settings → General. Dictation hotkeys plus the small Updates group (auto
/// update check + nested beta opt-in). The Updates group used to be its own
/// tab; it was folded in here because a single toggle and a version string
/// didn't justify a tenth tab — and the tab strip had already overflowed into
/// AppKit's ">>" overflow chevron at that width, which is what made the
/// Updates tab look "disabled" (see PR discussion).
///
/// The strip is gone as of #177, so the width half of that argument no longer
/// applies. The other half — a single toggle and a version string don't
/// deserve their own destination — still does, which is why this stays folded
/// in.
private struct GeneralSettingsTab: View {
    @EnvironmentObject private var hotkeys: HotkeySettings

    /// The action whose hotkey the user is currently re-recording. Nil when
    /// no row is in capture mode.
    @State private var recordingAction: HotkeyAction?
    @State private var lastError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dictation hotkeys")
                .font(.title3.weight(.semibold))
            Text("Press the hotkey anywhere in macOS to start dictating. Press it again to stop, transcribe, and paste at the cursor. Click a binding to record a new one; press Esc to cancel.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                ForEach(HotkeyAction.allCases) { action in
                    HotkeyRow(action: action,
                              isRecording: recordingAction == action,
                              // Live-registration warning: register() can fail
                              // (another app owns the combo globally) and the
                              // binding then LOOKS active while doing nothing.
                              // Suppressed mid-capture — suspendAll() has
                              // deliberately parked everything then.
                              showsInactiveWarning: recordingAction == nil
                                  && !HotkeyManager.shared.isRegistered(action),
                              onStartRecording: {
                                  recordingAction = action
                                  // Park our own registrations so the pressed
                                  // combo reaches the capture field's keyDown —
                                  // Carbon otherwise consumes a currently-bound
                                  // combo and STARTS DICTATION mid-capture.
                                  HotkeyManager.shared.suspendAll()
                              },
                              onCaptured: { applyCapture($0, for: action) },
                              onCancel: {
                                  recordingAction = nil
                                  HotkeyManager.shared.resumeAll()
                              },
                              onReset: { resetToDefault(action) })
                }
            }

            if let lastError {
                Text(lastError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Divider().padding(.vertical, 4)

            UpdatesSettingsSection()

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear {
            // Window closed mid-capture: don't leave the app's hotkeys
            // parked forever.
            if recordingAction != nil {
                recordingAction = nil
                HotkeyManager.shared.resumeAll()
            }
        }
    }

    private func applyCapture(_ binding: HotkeyBinding, for action: HotkeyAction) {
        recordingAction = nil
        HotkeyManager.shared.resumeAll()

        // Reject empty / modifier-only combos: Carbon will accept them but
        // Apple shortcut conventions require at least one of ⌘ ⌃ ⌥.
        let needsModifier = UInt32(cmdKey | controlKey | optionKey)
        guard binding.modifiers & needsModifier != 0 else {
            lastError = "Please include at least one modifier (⌘, ⌃, or ⌥)."
            return
        }

        // Reject collisions with the *other* action so the user doesn't
        // shoot themselves in the foot.
        for other in HotkeyAction.allCases where other != action {
            let existing = hotkeys.binding(for: other)
            if existing == binding {
                lastError = "\(binding.displayName) is already used for \(other.displayLabel)."
                return
            }
        }

        // Re-capturing the combo the action already has: nothing to do
        // (and the registrability probe below would false-positive against
        // our own live registration).
        guard binding != hotkeys.binding(for: action) else {
            lastError = nil
            return
        }

        // Validate registrability BEFORE persisting. The old flow persisted
        // first and dropped the registration failure on the floor: Settings
        // showed the new combo as active while no hotkey was registered at
        // all (the previous combo had already been unregistered) — dictation
        // went silently dead until a reset.
        guard HotkeyManager.shared.canRegister(binding) else {
            lastError = "\(binding.displayName) is already taken by another app or macOS — choose a different combo."
            return
        }

        lastError = nil
        hotkeys.setBinding(binding, for: action)
    }

    private func resetToDefault(_ action: HotkeyAction) {
        hotkeys.resetToDefault(action)
        lastError = nil
    }
}

/// The Updates group inside Settings → General: Sparkle's own
/// "automatically check" preference, with the beta-channel opt-in nested
/// underneath it, plus the running version.
///
/// The auto-check checkbox is bound straight through to the ONE
/// `SPUUpdater` the app owns (via the injected `UpdaterViewModel`) — Sparkle
/// persists that value itself, so we deliberately keep no parallel user
/// default for it. The beta checkbox writes
/// `UpdaterViewModel.betaChannelDefaultsKey`, which the updater delegate reads
/// both in `allowedChannels(for:)` (channel filtering) and in
/// `updater(_:shouldProceedWithUpdate:updateCheck:)` (the defensive
/// pre-release guard).
private struct UpdatesSettingsSection: View {
    @EnvironmentObject private var updater: UpdaterViewModel
    @AppStorage(UpdaterViewModel.betaChannelDefaultsKey) private var betaChannel = false

    private var versionString: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Updates")
                .font(.title3.weight(.semibold))

            Toggle("Automatically check for updates", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.setAutomaticallyChecksForUpdates($0) }
            ))
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("updates.autoCheck.toggle")

            // Nested under the auto-check box: the beta opt-in. Deliberately
            // NOT disabled when auto-check is off — a user with automatic
            // checks disabled can still opt into betas and fetch one by hand
            // with "Check for Updates…".
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Receive beta versions of Mila", isOn: $betaChannel)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("updates.beta.toggle")
                Text("Receive pre-release builds with the newest features before they ship to everyone. Betas can be less stable. Turn this off to stay on stable releases — you'll move back to stable the next time a stable version ships.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 20)

            Text("You're on version \(versionString). After changing these, choose “Check for Updates…” from the Mila menu to check right away.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HotkeyRow: View {
    @EnvironmentObject private var hotkeys: HotkeySettings

    let action: HotkeyAction
    let isRecording: Bool
    let showsInactiveWarning: Bool
    let onStartRecording: () -> Void
    let onCaptured: (HotkeyBinding) -> Void
    let onCancel: () -> Void
    let onReset: () -> Void

    var body: some View {
        HStack {
            Text(action.displayLabel)
                .font(.body)
                .frame(width: 160, alignment: .leading)

            if showsInactiveWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("This combo couldn't be registered — another app or macOS owns it globally. Pick a different one or hit Reset.")
                    .accessibilityIdentifier("hotkeys.\(action.rawValue).inactive")
            }

            Spacer()

            HotkeyCaptureField(currentDisplay: hotkeys.binding(for: action).displayName,
                               isRecording: isRecording,
                               onStartRecording: onStartRecording,
                               onCaptured: onCaptured,
                               onCancel: onCancel)
                .frame(width: 160)

            Button("Reset") { onReset() }
                .buttonStyle(.borderless)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A click-to-record hotkey field. When activated it becomes first responder
/// and captures the next non-modifier keyDown event into a `HotkeyBinding`.
/// Hosted via `NSViewRepresentable` because SwiftUI's focus / key event APIs
/// don't expose the raw virtual key code we need to register through Carbon.
private struct HotkeyCaptureField: NSViewRepresentable {
    let currentDisplay: String
    let isRecording: Bool
    let onStartRecording: () -> Void
    let onCaptured: (HotkeyBinding) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> HotkeyCaptureNSView {
        let view = HotkeyCaptureNSView()
        view.onStartRecording = onStartRecording
        view.onCaptured = onCaptured
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: HotkeyCaptureNSView, context: Context) {
        nsView.label = isRecording ? "Press a hotkey…" : currentDisplay
        nsView.recording = isRecording
        nsView.onStartRecording = onStartRecording
        nsView.onCaptured = onCaptured
        nsView.onCancel = onCancel
        if isRecording {
            nsView.window?.makeFirstResponder(nsView)
        } else if nsView.window?.firstResponder === nsView {
            nsView.window?.makeFirstResponder(nil)
        }
    }
}

final class HotkeyCaptureNSView: NSView {
    var label: String = "" { didSet { needsDisplay = true } }
    var recording: Bool = false { didSet { needsDisplay = true } }
    var onStartRecording: (() -> Void)?
    var onCaptured: ((HotkeyBinding) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard !recording else { return }
        onStartRecording?()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }

        // Esc cancels the capture without saving.
        if event.keyCode == kVK_Escape {
            onCancel?()
            return
        }

        // Carbon expects its own modifier flags, not NSEvent's. Translate.
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.command)  { modifiers |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.shift)    { modifiers |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.option)   { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control)  { modifiers |= UInt32(controlKey) }

        let binding = HotkeyBinding(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        onCaptured?(binding)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        if recording {
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            NSColor.controlAccentColor.setStroke()
        } else {
            NSColor.controlBackgroundColor.setFill()
            NSColor.separatorColor.setStroke()
        }
        path.lineWidth = 1
        path.fill()
        path.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: recording ? NSColor.controlAccentColor : NSColor.labelColor
        ]
        let string = NSAttributedString(string: label, attributes: attrs)
        let size = string.size()
        let origin = NSPoint(x: rect.midX - size.width / 2,
                             y: rect.midY - size.height / 2)
        string.draw(at: origin)
    }
}

// MARK: - Models

private struct ModelsSettingsTab: View {
    @EnvironmentObject private var manager: ModelManager
    @EnvironmentObject private var transcription: TranscriptionService
    @EnvironmentObject private var remote: RemoteTranscriptionSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Transcription backend")
                    .font(.title3.weight(.semibold))
                Text("Mila transcribes on-device by default — audio never leaves your Mac. Switch to a remote API to offload transcription to OpenAI's Whisper API or any self-hosted OpenAI-compatible server.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Backend", selection: $remote.backend) {
                    ForEach(TranscriptionBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // Models' per-section probe for `DetailLayoutUITests` — the
                // one control on this destination that is present whichever
                // backend is selected.
                .accessibilityIdentifier("models.backend.picker")

                switch remote.backend {
                case .local:
                    localModelsSection
                case .remote:
                    RemoteBackendSection(remote: remote)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var localModelsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Whisper models")
                .font(.headline)
            Text("English dictation uses the OpenAI turbo model; Hebrew uses ivrit.ai. Both download automatically on first launch (~1.6 GB each). The optional ivrit.ai large model is higher accuracy but ~2× slower.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                ForEach(WhisperModel.all) { model in
                    ModelRow(model: model)
                }
            }

            // Failed downloads used to only leave an os_log line — the
            // progress bar vanished with zero explanation of whether the
            // model installed or why it didn't. One row per failed model:
            // the defaults auto-download concurrently on first launch, so
            // two reports can be live at once.
            ForEach(manager.lastDownloadErrors.keys.sorted(), id: \.self) { name in
                if let error = manager.lastDownloadErrors[name] {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Dismiss") { manager.lastDownloadErrors[name] = nil }
                            .buttonStyle(.borderless)
                    }
                    .accessibilityIdentifier("models.download.error.\(name)")
                }
            }
        }
    }
}

/// Endpoint / model / API-key configuration for the remote transcription
/// backend, plus a connectivity test and the mandatory "audio leaves your
/// device" warning.
///
/// The **Model** row is a picker over `RemoteModelPreset.all`, not free text.
/// It used to be a `TextField` whose only guidance was a `whisper-1`
/// placeholder, which invited model ids that fail with an opaque HTTP 400 —
/// and, before PR #189, that was *most* of OpenAI's transcription line-up
/// (issue #178). Free text still exists, behind **Advanced**, for a
/// self-hosted id no catalogue could enumerate.
private struct RemoteBackendSection: View {
    @ObservedObject var remote: RemoteTranscriptionSettings

    private static let setupGuideURL = URL(string: "https://github.com/island-io/mila/blob/main/docs/REMOTE_TRANSCRIPTION_SERVER.md")!

    /// Picker tag for "a model id Mila has no entry for". A `nil` selection
    /// can't be a `Picker` tag, so `Custom…` gets its own sentinel.
    private static let customTag = "__mila.remote.model.custom__"

    /// Opens itself when the configured model isn't one of the presets — a
    /// custom id (typed, or arriving via a `.milaconfig` import) must not be
    /// invisible just because it doesn't fit the picker.
    @State private var showAdvanced: Bool

    @MainActor
    init(remote: RemoteTranscriptionSettings) {
        self.remote = remote
        _showAdvanced = State(initialValue: remote.selectedPreset == nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            privacyWarning

            VStack(alignment: .leading, spacing: 8) {
                fieldRow(label: "Endpoint") {
                    TextField(RemoteTranscriptionSettings.defaultEndpoint, text: $remote.endpoint)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
                Text("Base URL of an OpenAI-compatible API. Mila appends `/audio/transcriptions`. Picking a model below fills this in; edit it to point at your own server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                modelPickerRow

                fieldRow(label: "API key") {
                    SecureField("Stored in your Keychain", text: $remote.apiKey)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Sent as a Bearer token and stored encrypted in the macOS Keychain — never written to disk in plaintext. Leave blank for self-hosted servers that don't require auth.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            advancedDisclosure

            HStack(spacing: 10) {
                Button {
                    Task { await remote.testConnection() }
                } label: {
                    if case .testing = remote.testStatus {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Test connection")
                    }
                }
                .disabled(remote.endpointURL == nil || remote.testStatus == .testing)

                testStatusLabel
                Spacer()
            }

            Divider()

            Link(destination: Self.setupGuideURL) {
                Label("How to host ivrit.ai (or any model) behind this API", systemImage: "book")
                    .font(.callout)
            }
        }
    }

    // MARK: - Model

    /// The picker, plus one caption describing the selection and — when the
    /// model can't return timings — the warning that says so *before* the user
    /// records an hour-long meeting with it.
    @ViewBuilder
    private var modelPickerRow: some View {
        fieldRow(label: "Model") {
            Picker("Model", selection: modelSelection) {
                ForEach(RemoteModelPreset.Group.allCases, id: \.self) { group in
                    Section(group.displayName) {
                        ForEach(RemoteModelPreset.presets(in: group)) { preset in
                            Text(preset.displayName).tag(preset.id)
                        }
                    }
                }
                Text("Custom…").tag(Self.customTag)
            }
            .labelsHidden()
            .accessibilityIdentifier("remote.model.picker")
        }

        if let preset = remote.selectedPreset {
            Text(preset.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Custom model id — set it under **Advanced** below. Mila can't vouch for a model it doesn't know; use **Test connection** to confirm the server accepts it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Asked of the engine, not of the preset. `forModel(_:)` sends ANY
        // `gpt-*` id as `json`, preset or not, so a hand-typed
        // `gpt-4o-transcribe-something` loses timestamps just as surely as a
        // listed one -- and gating the warning on a preset match is exactly
        // how it would lose them silently.
        if RemoteWhisperEngine.ResponseFormat.forModel(remote.model).timestamps.isUntimed {
            noTimestampsWarning
        }
    }

    /// Bridges the picker's `String` tag to the settings' model id.
    ///
    /// Reads as `customTag` whenever the configured id isn't a preset, so a
    /// hand-typed model shows as *Custom…* rather than snapping the display to
    /// some unrelated row. Selecting `Custom…` deliberately leaves `model`
    /// alone — it opens the free-text field rather than clearing the value the
    /// user is about to edit.
    private var modelSelection: Binding<String> {
        Binding(
            get: { remote.selectedPreset?.id ?? Self.customTag },
            set: { tag in
                guard let preset = RemoteModelPreset.matching(tag) else {
                    showAdvanced = true
                    return
                }
                remote.apply(preset)
            }
        )
    }

    /// Losing per-segment timings is not a cosmetic downgrade — it costs SRT
    /// timings *and* speaker labels, because local diarization has nothing to
    /// align its speaker turns to. Say so at the point of choice; silently
    /// degrading transcripts is what this picker exists to stop.
    private var noTimestampsWarning: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
            Text("No timestamps. This model can only return plain text, so the recording arrives as one segment: SRT export has no timings and speaker labels can't be aligned. Fine for dictation, poor for meetings.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityIdentifier("remote.model.noTimestamps")
    }

    // MARK: - Advanced

    /// The raw ids. Free text is still fully supported — a self-hosted server
    /// can serve any model id — it just stops being the first thing the user
    /// sees, the same treatment #144 gave "technical, set once" configuration.
    private var advancedDisclosure: some View {
        DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 8) {
                fieldRow(label: "Model id") {
                    TextField(RemoteTranscriptionSettings.defaultModel, text: $remote.model)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("remote.model.custom")
                }
                Text("Any model id your server accepts. Mila derives the response format from the id — `gpt-*` ids are sent without timestamps, anything else as a Whisper-style request (`verbose_json`).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                fieldRow(label: "English model") {
                    TextField("Same as above", text: $remote.englishModel)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("remote.model.english")
                }
                Text("Optional. Set this when the model above only handles one language — an ivrit.ai server, for example, returns Hebrew words for English speech. English recordings then use this model instead. Leave blank for multilingual endpoints like OpenAI.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        }
        .font(.callout)
        // `showAdvanced` is @State, so its initial value is used once and never
        // recomputed. If `model` changes to a custom id while this section is on
        // screen -- a `.milaconfig` import is the realistic way -- the picker
        // flips to "Custom..." while the Model id field stays collapsed, leaving
        // the value visible nowhere and un-editable. Open the disclosure when
        // the configured id stops being one of the presets.
        .onChange(of: remote.model) { _, _ in
            if remote.selectedPreset == nil { showAdvanced = true }
        }
    }

    private var privacyWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Audio leaves your device. When the remote backend is active, every recording is uploaded to the endpoint below for transcription. Use a server you trust.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var testStatusLabel: some View {
        switch remote.testStatus {
        case .idle, .testing:
            EmptyView()
        case .ok(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
                .lineLimit(2)
                .textSelection(.enabled)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .lineLimit(2)
        }
    }

    private func fieldRow<Content: View>(label: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label).frame(width: 80, alignment: .leading)
            content()
        }
        .font(.callout)
    }
}

private struct ModelRow: View {
    @EnvironmentObject private var manager: ModelManager
    let model: WhisperModel

    /// Confirmation gate before deleting an installed model — these are
    /// multi-GB downloads, so an accidental click shouldn't cost the user
    /// a re-download.
    @State private var confirmingDelete = false
    @State private var deleteError: String?

    var body: some View {
        let progress = manager.downloads[model.name]
        let installed = manager.isInstalled(model)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(.body)
                Text(byteCountString(model.sizeBytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let progress {
                ProgressView(value: progress).frame(width: 80)
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if installed {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.iconOnly)
                Button("Delete", role: .destructive) {
                    confirmingDelete = true
                }
                .buttonStyle(.borderless)
            } else {
                Button("Download") { manager.download(model) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .confirmationDialog("Delete \(model.displayName)?",
                            isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                do {
                    try manager.delete(model)
                } catch {
                    deleteError = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Using this model again will require re-downloading it (\(byteCountString(model.sizeBytes))).")
        }
        .alert(
            "Couldn't delete model",
            isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            ),
            actions: { Button("OK") { deleteError = nil } },
            message: { Text(deleteError ?? "") }
        )
    }

    private func byteCountString(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        f.allowedUnits = [.useGB, .useMB]
        return f.string(fromByteCount: bytes)
    }
}

// MARK: - AI

/// Longest line the AI tabs let help text run before it wraps.
///
/// The Settings window is a fixed width, but capping the measure keeps
/// captions at a readable ~90 characters instead of stretching edge to edge,
/// and it keeps holding if the window ever grows.
private let aiCaptionWidth: CGFloat = 520

/// Label column for the AI Provider field rows. Deliberately the same width
/// the Models tab uses for the remote transcription backend
/// (`RemoteBackendSection.fieldRow`), so Mila's two "point this at a backend"
/// screens read as the same kind of screen rather than two dialects.
private let aiLabelWidth: CGFloat = 80

/// Gap between the label column and the control column. Captions are indented
/// by `aiLabelWidth + aiLabelGap` so help text lines up under the control it
/// describes instead of starting a second left edge under the label.
private let aiLabelGap: CGFloat = 8

extension View {
    /// `.help(_:)` that no-ops when there is no extra detail to show.
    ///
    /// The AI tabs push every second and third sentence of explanation into a
    /// tooltip; rows with nothing extra to say pass `nil` rather than an empty
    /// string, which would still arm a hover target.
    @ViewBuilder
    fileprivate func aiHelp(_ text: String?) -> some View {
        if let text, !text.isEmpty { self.help(text) } else { self }
    }
}

/// One short line of help under a field, indented to the control column.
private struct AICaption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        // `LocalizedStringKey`, not `String`, so inline markdown — `code`
        // spans, **bold** — renders instead of showing literal backticks.
        Text(LocalizedStringKey(text))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: aiCaptionWidth, alignment: .leading)
            .padding(.leading, aiLabelWidth + aiLabelGap)
    }
}

/// A settings row whose whole label area expands/collapses the row, with an
/// optional switch on the right that works *without* expanding anything.
///
/// The switch is a **sibling** of the tap target, never a child of it:
///
/// ```swift
/// HStack {
///     Button { isExpanded.toggle() } label: {
///         HStack { chevron; title + caption; Spacer(minLength: 0) }
///             .contentShape(Rectangle())      // the whole strip is clickable
///     }
///     .buttonStyle(.plain)
///
///     Toggle("", isOn: isOn)                  // laid out outside the Button
/// }
/// ```
///
/// `Spacer(minLength: 0)` inside the button label is what makes "click
/// anywhere on the row" work — the button stretches across the free space
/// instead of hugging its text — and `.contentShape(Rectangle())` makes that
/// empty space hit-testable. Because the `Toggle` is a later child of the
/// enclosing `HStack`, a click on the switch is never inside the button's
/// shape, so flipping the switch cannot also expand the row. Wrapping the
/// whole `HStack` in `.contentShape(Rectangle()).onTapGesture { … }` instead —
/// the obvious first attempt — leaves every switch click ambiguous.
private struct AIFeatureRow<Content: View>: View {
    let title: String
    /// Exactly one short line. Anything longer belongs in `help`.
    let caption: String
    /// The detail that used to be inline prose, as a tooltip.
    var help: String?
    /// `nil` for rows that aren't a feature you switch on (the Test panel).
    var isOn: Binding<Bool>?
    var toggleDisabled = false
    var toggleIdentifier: String?
    /// Carried over from the single-tab design (`ai.section.*`) so existing
    /// automation keeps resolving these rows.
    let identifier: String
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 10)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(caption)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: aiCaptionWidth, alignment: .leading)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // `.help` sets the accessibility hint as well as the tooltip,
                // so it goes on FIRST and the explicit expand/collapse hint
                // below wins for VoiceOver.
                .aiHelp(help)
                .accessibilityIdentifier(identifier)
                .accessibilityLabel(Text(title))
                .accessibilityHint(Text(isExpanded ? "Collapse" : "Expand"))

                if let isOn {
                    Toggle("", isOn: isOn)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(toggleDisabled)
                        .accessibilityLabel(Text(title))
                        .accessibilityIdentifier(toggleIdentifier ?? "\(identifier).toggle")
                }
            }
            .padding(.vertical, 4)

            if isExpanded {
                content
                    .padding(.leading, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
            }
        }
    }
}

/// A prompt editor with a "Reset to default" affordance. Used by three of the
/// four feature rows and by Live AI.
///
/// "Reset to default" and the Examples list next to it each replace a
/// hand-written prompt in one click, and used to do it irrecoverably — `⌘Z` did
/// nothing anywhere in Settings (#176). The editor is now `UndoableTextEditor`,
/// which gives this field a real per-editor undo stack that covers typing *and*
/// those overwrites, however they reach the binding. `⌘Z` is what users try
/// first; the "Undo" link is here because a recovery path you can see beats one
/// that depends on where first responder happens to be.
private struct AIPromptEditor: View {
    let title: String
    @Binding var text: String
    let defaultText: String
    var minHeight: CGFloat = 90
    /// One line, under the editor.
    var caption: String?
    var isEnabled = true

    /// Survives the re-renders that recreate the editor struct, so the undo
    /// history outlives a keystroke.
    @StateObject private var undo = PromptUndoBridge()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if undo.canUndo {
                    Button("Undo") { undo.undo() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .disabled(!isEnabled)
                        .help("Put back the previous prompt (\u{2318}Z).")
                        .accessibilityIdentifier("ai.prompt.undo")
                }
                Button("Reset to default") { text = defaultText }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(!isEnabled)
            }
            UndoableTextEditor(text: $text, undo: undo, isEnabled: isEnabled)
                .frame(minHeight: minHeight, maxHeight: minHeight + 60)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
            if let caption {
                Text(LocalizedStringKey(caption))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: aiCaptionWidth, alignment: .leading)
            }
        }
    }
}

// MARK: - AI Provider

/// Settings → AI Provider. The technical, set-once half of Mila's AI config:
/// which tool to talk to, how to reach it, how long to wait for it, and a test
/// panel to prove it works. Most users touch this once — or never, because a
/// `.milaconfig` import filled it in for them.
///
/// Everything a user *revisits* lives on **AI Features** instead. This screen
/// deliberately mirrors Settings → Models (`ModelsSettingsTab` /
/// `RemoteBackendSection`): the same label column, the same "control, then one
/// line of help underneath" rhythm, the same privacy-warning treatment.
///
/// Purely presentational. Every `UserDefaults` key (`llm.*`, `liveAI.*`) and
/// the `llm.openai.apiKey` Keychain item are unchanged, so an upgrading user
/// keeps their provider, prompts and toggles exactly as they were.
private struct AIProviderSettingsTab: View {
    @EnvironmentObject private var settings: LLMSettings
    @State private var showTest = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                toolRow
                AICaption("Used by every AI feature. Only transcript text is sent, never audio.")

                if settings.tool != .none {
                    Divider()
                    if settings.isOpenAICompatible { endpointFields } else { cliFields }
                    timeoutRow
                    Divider()
                    testRow
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    // MARK: Field chrome

    /// `label — control` line. Same geometry as the Models tab's field rows.
    private func fieldRow<Content: View>(_ label: String,
                                         help: String? = nil,
                                         @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: aiLabelGap) {
            Text(label).frame(width: aiLabelWidth, alignment: .leading)
            content()
        }
        .font(.callout)
        .aiHelp(help)
    }

    // MARK: Tool

    private var toolRow: some View {
        // A pop-up menu, not a full-width segmented control: five options of
        // very uneven length stretched across the pane gave "Off" a segment
        // the size of a button.
        fieldRow("Tool",
                 help: "Claude, Cursor and Gemini shell out to a CLI on this Mac, using the login you already set up. OpenAI Compatible calls any /chat/completions endpoint over HTTP, including a local Ollama.") {
            Picker("Tool", selection: $settings.tool) {
                ForEach(LLMTool.allCases) { tool in
                    Text(tool.displayName).tag(tool)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityIdentifier("ai.provider.tool")
            Spacer(minLength: 0)
        }
    }

    // MARK: CLI tools

    private var cliFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldRow("Executable",
                     help: "Only needed when Mila can't find the CLI itself — it already searches $PATH, Homebrew, ~/.local/bin, your configured npm prefix and the node version managers (nvm, Volta, asdf).") {
                TextField("(use $PATH)", text: $settings.executablePath)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("ai.provider.executablePath")
            }
            AICaption("Leave blank to look the binary up on $PATH.")

            fieldRow("Extra args",
                     help: "Appended to every run — name suggestion, auto-summary, the Send action and the test below. Shell-style quoting is supported; for most CLIs a flag here overrides an earlier one.") {
                TextField("(none) e.g. --model claude-sonnet-4-6", text: $settings.extraArgs)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .accessibilityIdentifier("ai.provider.extraArgs")
            }
            AICaption("Added to every run. Live AI keeps its own model.")
        }
    }

    // MARK: OpenAI-compatible endpoint

    private var endpointFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldRow("Provider",
                     help: "Presets fill in the base URL and a sensible default model. Pick Custom to type your own.") {
                Picker("Provider", selection: $settings.openAIProvider) {
                    ForEach(OpenAIProvider.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                // Without this the menu picker draws its own "Provider"
                // label beside the label column's, showing the word twice.
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier("ai.provider.preset")
                .onChange(of: settings.openAIProvider) { oldPreset, newPreset in
                    // Pass the PREVIOUS provider explicitly: the Picker
                    // binding has already set `openAIProvider` to
                    // `newPreset` by the time `.onChange` fires, so
                    // `applyPreset` cannot derive the old value itself
                    // (issue celarent7/mila#2).
                    settings.applyPreset(newPreset, previous: oldPreset)
                }
                Spacer(minLength: 0)
            }

            fieldRow("Base URL") {
                TextField("https://api.openai.com/v1", text: $settings.openAIBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("ai.provider.baseURL")
            }
            AICaption("Mila appends `/chat/completions`. A trailing slash is ignored.")

            fieldRow("Model") {
                TextField("gpt-4o-mini", text: $settings.openAIModelName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("ai.provider.model")
            }

            fieldRow("API key") {
                SecureField("Required for most providers", text: $settings.openAIAPIKey)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("ai.provider.apiKey")
            }
            AICaption("Stored in your Keychain. Blank only for a local server without auth.")

            if !OpenAILocality.isLocal(baseURL: settings.openAIBaseURL) {
                remoteEndpointWarning
            }
        }
    }

    private var remoteEndpointWarning: some View {
        Label {
            Text("Remote endpoint — transcript text leaves your Mac.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .frame(maxWidth: aiCaptionWidth, alignment: .leading)
        .padding(.leading, aiLabelWidth + aiLabelGap)
        .help("This base URL is not localhost, loopback or .local, so transcript text is sent off your machine for processing. Choose a provider you trust.")
    }

    // MARK: Timeout

    /// Whole seconds, clamped to the stepper's range. The row used to be a
    /// bare `Stepper` with no text field, which made getting from 300 to 900
    /// an exercise in clicking.
    private var timeoutSeconds: Binding<Int> {
        Binding(
            get: { Int(settings.cliTimeout) },
            set: { settings.cliTimeout = TimeInterval(min(max($0, 30), 900)) }
        )
    }

    private var timeoutHelp: String {
        settings.isOpenAICompatible
            ? "How long Mila waits for the endpoint to respond before giving up. Applies to title generation, auto-summary and the Send action."
            : "How long Mila waits for the CLI before giving up. Applies to title generation, auto-summary and the Send action. Raise it if your prompt uses agentic tools — a calendar lookup, say — that need extra time to finish."
    }

    private var timeoutRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldRow(settings.timeoutLabel, help: timeoutHelp) {
                TextField("300", value: timeoutSeconds, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 60)
                    .accessibilityIdentifier("ai.provider.timeout")
                Stepper("", value: timeoutSeconds, in: 30...900, step: 30)
                    .labelsHidden()
                Text("seconds")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Reset") { settings.cliTimeout = LLMSettings.defaultTimeout }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(Int(settings.cliTimeout) == Int(LLMSettings.defaultTimeout))
            }
            AICaption("30–900 s. Covers titles, summaries and the Send action.")
        }
    }

    // MARK: Test

    private var testRow: some View {
        AIFeatureRow(title: "Test this provider",
                     caption: "See exactly what Mila sends and what comes back.",
                     help: "Runs the configured prompt against a sample transcript using your real settings, and shows the literal command or request body so you can reproduce it in a terminal.",
                     isOn: nil,
                     identifier: "ai.section.test",
                     isExpanded: $showTest) {
            testPanel
        }
    }

    private var testPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Labelled above rather than inline, to match the "Sample
            // transcript" block below it — `.labelsHidden()` alone left a
            // bare segmented control with nothing saying what it selects.
            VStack(alignment: .leading, spacing: 4) {
                Text("Prompt to test")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("Prompt to test", selection: $settings.testPromptKind) {
                    ForEach(LLMSettings.TestPromptKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Sample transcript")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $settings.testTranscript)
                    .font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 80, maxHeight: 130)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
            }

            HStack(spacing: 10) {
                Button {
                    Task { await settings.runTest() }
                } label: {
                    if settings.isTesting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Running…")
                        }
                    } else {
                        Text("Run test")
                    }
                }
                .disabled(settings.tool == .none || settings.isTesting)
                .accessibilityIdentifier("ai.provider.runTest")
                Spacer()
            }

            if let result = settings.lastTestResult {
                LLMTestResultView(result: result)
            }
        }
    }
}

// MARK: - AI Features

/// Settings → AI Features. What the AI does for you, one row per feature.
///
/// Each row carries a title, a single line of description and a real switch,
/// so the state of all four features is legible — and changeable — without
/// opening anything. Clicking anywhere else on the row expands that feature's
/// prompt editor and its own options. See `AIFeatureRow` for why the switch
/// and the expand target cannot be the same view.
private struct AIFeaturesSettingsTab: View {
    @EnvironmentObject private var settings: LLMSettings
    @EnvironmentObject private var liveAI: LiveAISettings

    // Nothing starts expanded: the point of this screen is that you can read
    // and flip every feature without expanding a thing.
    @State private var showSummary = false
    @State private var showName = false
    @State private var showAction = false
    @State private var showLiveAI = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !settings.isConfigured { notConfiguredBanner }

                outputLanguageRow
                Divider()

                AIFeatureRow(title: "Automatic summary",
                             caption: "Summarize every recording when it finishes.",
                             help: "Mila runs a one-shot LLM pass after each recording and stores the result as that recording's AI Overview. Turning this off keeps the summaries you already have; any recording that has one can be refreshed from its right-click \u{201C}Regenerate summary\u{201D} action.",
                             isOn: $settings.summaryEnabled,
                             toggleIdentifier: "llm.summary.enabled.toggle",
                             identifier: "ai.section.summary",
                             isExpanded: $showSummary) {
                    AIPromptEditor(title: "Summary prompt",
                                   text: $liveAI.summaryPrompt,
                                   defaultText: LiveAISettings.defaultSummaryPrompt,
                                   caption: "Sent with the full transcript. `{{LANGUAGE}}` becomes the output language above.",
                                   isEnabled: settings.summaryEnabled)
                }
                Divider()

                AIFeatureRow(title: "Recording names",
                             caption: "Suggest a title from the transcript.",
                             help: "Adds a Suggest button to the rename sheet. The prompt below is sent together with the transcript when you click it.",
                             isOn: $settings.nameGenerationEnabled,
                             toggleIdentifier: "llm.name.enabled.toggle",
                             identifier: "ai.section.name",
                             isExpanded: $showName) {
                    VStack(alignment: .leading, spacing: 8) {
                        AIPromptEditor(title: "Name prompt",
                                       text: $settings.namePrompt,
                                       defaultText: LLMSettings.defaultNamePrompt,
                                       minHeight: 70,
                                       isEnabled: settings.nameGenerationEnabled)
                        ExamplesView(title: "Examples", items: LLMSettings.nameExamples) {
                            settings.namePrompt = $0
                        }
                    }
                }
                Divider()

                AIFeatureRow(title: "Send-to-LLM action",
                             caption: "Run your own prompt against a transcript.",
                             help: "Adds a Run-action button to the rename sheet. The prompt below is sent together with the transcript when you click it.",
                             isOn: $settings.postActionEnabled,
                             toggleIdentifier: "llm.action.enabled.toggle",
                             identifier: "ai.section.action",
                             isExpanded: $showAction) {
                    VStack(alignment: .leading, spacing: 8) {
                        AIPromptEditor(title: "Action prompt",
                                       text: $settings.postActionPrompt,
                                       defaultText: LLMSettings.defaultActionPrompt,
                                       minHeight: 70,
                                       isEnabled: settings.postActionEnabled)
                        ExamplesView(title: "Examples", items: LLMSettings.actionExamples) {
                            settings.postActionPrompt = $0
                        }
                        transcriptByPathToggle
                    }
                }
                Divider()

                AIFeatureRow(title: "Live AI mode",
                             caption: liveAICaption,
                             help: "During a recording Mila streams the transcript to your provider every few seconds and surfaces action items in real time. The home screen swaps to a split-pane recording view as soon as you press Record.",
                             isOn: $liveAI.enabled,
                             // Both gates grey the switch out rather than
                             // hiding it, so the user can still see the
                             // feature exists. The persisted value keeps
                             // round-tripping either way.
                             toggleDisabled: !liveAI.isLiveAIAvailable
                                 || settings.liveAIDisabledByRemoteOpenAI,
                             toggleIdentifier: "liveAI.enabled.toggle",
                             identifier: "ai.section.liveAI",
                             isExpanded: $showLiveAI) {
                    LiveAISection(settings: liveAI,
                                  disabledByRemoteEndpoint: settings.liveAIDisabledByRemoteOpenAI)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    /// Transcript delivery for the Send-to-LLM action (issue #179): paste the
    /// transcript into the prompt, or name the recording's files and let the CLI
    /// read them.
    ///
    /// Lives inside the action row rather than next to the provider picker
    /// because it governs that one feature — title generation and the automatic
    /// summary stay inlined on purpose (see
    /// `LLMSettings.actionTranscriptByPath`).
    ///
    /// Greyed rather than hidden for a provider that can't read files, matching
    /// how the Live AI row treats its own gates: a control that vanishes reads
    /// as "this app can't do that", and the caption says which gate is closed.
    private var transcriptByPathToggle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Send the transcript as a file path",
                   isOn: $settings.actionTranscriptByPath)
                .font(.callout)
                .toggleStyle(.switch)
                .disabled(!settings.postActionEnabled || !settings.tool.readsLocalFiles)
                .accessibilityIdentifier("llm.action.transcriptByPath.toggle")
            Text(transcriptByPathCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: aiCaptionWidth, alignment: .leading)
        }
        .help("Instead of pasting the transcript into the prompt, Mila names the "
              + "recording's subtitle (.srt), transcript (.txt) and audio files and "
              + "asks the tool to read them. The .srt keeps the timestamps the pasted "
              + "text drops, and the tool can re-read or seek within the file instead "
              + "of getting one pass over a blob. Needs a tool that reads local files.")
    }

    /// Say which gate is closed rather than leaving a dead switch unexplained —
    /// same principle as `liveAICaption`.
    private var transcriptByPathCaption: String {
        if !settings.tool.readsLocalFiles {
            return "Needs a local CLI — the OpenAI-compatible endpoint can't read your files."
        }
        return "Point the tool at the recording's .srt / .txt / audio instead of pasting the text. Keeps timestamps."
    }

    /// Live AI has two independent gates on top of the user's own switch, and
    /// a switch that reads "on" while the feature is inert is exactly the
    /// legibility problem this redesign is fixing. Say which gate is closed.
    ///
    /// Hardware comes first: its override lives one click away in the expanded
    /// body, whereas the remote-endpoint gate is only cleared by changing the
    /// provider on the other tab.
    private var liveAICaption: String {
        if !liveAI.isLiveAIAvailable {
            return "Not available on this Mac — expand for the override."
        }
        if settings.liveAIDisabledByRemoteOpenAI {
            return "Off while the provider is a remote endpoint."
        }
        return "Show action items while the recording runs."
    }

    /// Shown once, at the top, instead of repeating "no provider" inside every
    /// feature that needs one.
    private var notConfiguredBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("No AI provider yet.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                // A button, not prose: with the sidebar (#177) a
                // cross-reference inside Settings can actually navigate, so
                // it does. This is also the only producer of
                // `SettingsNavigation.pendingTab` inside Settings, which
                // until now had consumers but no caller.
                Button("Set one up in AI Provider") {
                    SettingsNavigation.shared.pendingTab = .aiProvider
                }
                .buttonStyle(.link)
                .font(.caption)
                .accessibilityIdentifier("ai.features.notConfigured.link")
            }
            .frame(maxWidth: aiCaptionWidth, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityIdentifier("ai.features.notConfigured")
    }

    /// Output language governs *generated content*, not the connection, so it
    /// sits with the features rather than with the endpoint. It is one knob
    /// shared by two of them: it fills the `{{LANGUAGE}}` slot in BOTH the
    /// post-recording summary prompt and the Live AI tick prompt
    /// (`RecordingSummarizer` and `LiveAISession` read the same
    /// `LiveAISettings.outputLanguage`). The persisted key
    /// (`liveAI.outputLanguage`) is unchanged.
    private var outputLanguageRow: some View {
        // Wider than `aiLabelWidth`: this label has no field rows to line up
        // with on this tab, and "Output language" would truncate at 80.
        let labelWidth: CGFloat = 110
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: aiLabelGap) {
                Text("Output language")
                    .frame(width: labelWidth, alignment: .leading)
                Picker("Output language", selection: $liveAI.outputLanguage) {
                    ForEach(LiveAISettings.OutputLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)
                .accessibilityIdentifier("ai.features.outputLanguage")
                Spacer(minLength: 0)
            }
            .font(.callout)
            Text("Language the AI writes in, for every feature below. Auto follows what was spoken.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: aiCaptionWidth, alignment: .leading)
                .padding(.leading, labelWidth + aiLabelGap)
        }
    }
}

/// The expanded body of the "Live AI mode" row on Settings → AI Features: the
/// per-tick system prompt editor (with reset-to-default) and an Advanced
/// disclosure holding the Live-AI-only model override plus the cost /
/// segmentation dials most users never touch.
///
/// The master switch is NOT here — it lives in the row header
/// (`AIFeatureRow`), so Live AI can be turned on or off without expanding
/// anything. Provider setup isn't here either: Live AI uses whatever is
/// configured on Settings → AI Provider. The one thing it keeps for itself is
/// `LiveAISettings.model`, because the live loop pins its own (cheaper) model
/// per tick rather than inheriting the CLI default.
private struct LiveAISection: View {
    @ObservedObject var settings: LiveAISettings
    /// `LLMSettings.liveAIDisabledByRemoteOpenAI`, passed as a plain `Bool`
    /// rather than the whole settings object so this view doesn't re-render on
    /// every unrelated provider edit.
    let disabledByRemoteEndpoint: Bool
    @State private var showAdvanced: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !settings.isLiveAIAvailable {
                hardwareDisabledNotice
            }
            if disabledByRemoteEndpoint {
                remoteEndpointDisabledNotice
            }
            promptEditor
            advancedDisclosure
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Live AI is gated to local endpoints (`liveAIDisabledByRemoteOpenAI`),
    /// and `LiveAISession` enforces that silently — so without this the switch
    /// could be on, the recording could run, and no action items would ever
    /// appear with nothing on screen explaining why.
    private var remoteEndpointDisabledNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            Text("Won't run on a remote endpoint. Use a CLI tool or a local one.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: aiCaptionWidth, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 6))
        .help("Every Live AI tick re-sends the whole transcript. A hosted OpenAI-compatible endpoint bills that in full each time with no prompt-cache discount, so Mila restricts the live loop to CLI tools and local endpoints (localhost, loopback, .local).")
        .accessibilityIdentifier("liveAI.remoteEndpointDisabled")
    }

    /// Banner shown when this Mac is below the hardware bar for Live
    /// AI (currently: any MacBook Air). The row's switch stays visible but
    /// is greyed out — the persisted preference still round-trips,
    /// so taking the user's settings back to a fast Mac restores the
    /// previous state without surprises.
    private var hardwareDisabledNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Text("Gated off on Air-class chips. Recordings still transcribe.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: aiCaptionWidth, alignment: .leading)
                    .help("Live AI was too slow on Air-class chips when this gate was added. With Apple Neural Engine encoder offload it may now keep up — hence the override below. Recordings transcribe in the background either way.")
            }
            Toggle("Try Live AI anyway", isOn: $settings.forceLiveAIOnLowEndHardware)
                .font(.callout)
                .toggleStyle(.switch)
                .accessibilityIdentifier("liveAI.forceOnLowEndHardware.toggle")
                .help("Overrides the hardware gate. Apple Neural Engine encoder offload may have closed the gap. If transcription lags behind, turn this off and use background mode instead.")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private var promptEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            AIPromptEditor(title: "System prompt",
                           text: $settings.prompt,
                           defaultText: LiveAISettings.defaultPrompt,
                           minHeight: 140,
                           caption: "Ask for a strict JSON array — free-form prose is ignored.")
            // This prompt is a permanent template, so anything meeting-
            // specific pasted here silently applies to every LATER
            // recording — which produced blended "previous meeting + this
            // meeting" summaries and action items lifted from a stale
            // agenda. Point users at the per-meeting Context box instead.
            Text("Reused for every recording. One meeting's agenda goes in **Context**.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: aiCaptionWidth, alignment: .leading)
                .help("Anything meeting-specific pasted here silently applies to every LATER recording, which produced blended \u{201C}previous meeting + this meeting\u{201D} summaries. The Context box in the recording pane is cleared when that recording stops — put per-meeting notes there instead.")
        }
    }

    /// The dials most users never touch. Same text discipline as the rest of
    /// the AI tabs: one line of caption per control, the paragraph that used
    /// to sit under it moved into the control's tooltip.
    private var advancedDisclosure: some View {
        DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextField(LiveAISettings.defaultModel, text: $settings.model)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("liveAI.model")
                    advancedCaption("Live loop only. Blank lets your CLI pick.")
                }
                .help("Passed to the CLI as `--model` for the live loop only, so the cheap per-tick model doesn't have to be your default. Leave blank to let the CLI choose.")

                advancedToggle("Auto-segment by silence (beta)",
                               isOn: $settings.useVAD,
                               caption: "Transcribe per utterance instead of on a timer.",
                               help: "Detects natural pauses (≥400 ms of silence) and runs whisper once per utterance rather than on a fixed timer: lower latency and cleaner word boundaries. Force-cuts at 25s for monologue speakers.")

                advancedToggle("Filter non-speech (neural VAD)",
                               isOn: $settings.useNeuralVAD,
                               caption: "Skip segments with no speech. Needs auto-segment.",
                               help: "Runs a lightweight neural voice detector on each segment and drops the ones with no actual speech, so whisper stops inventing filler text over background noise. Recommended on.",
                               disabled: !settings.useVAD)

                advancedToggle("Background mode (hide live pane)",
                               isOn: $settings.backgroundMode,
                               caption: "Stay on Home while recording.",
                               help: "Transcription, speaker labels and the Live AI summary still run in the background and are saved when you stop. Useful on lower-power Macs, where rendering the live pane competes with whisper for CPU.")

                advancedSlider("Update every",
                               value: $settings.chunkSeconds,
                               range: 15...60,
                               step: 5,
                               readout: "\(Int(settings.chunkSeconds))s",
                               caption: "Used only when auto-segment is off.",
                               help: "How often Mila re-transcribes and re-prompts when auto-segment is off. 30s is the default — it matches the whisper window, so words don't get cut mid-utterance.",
                               disabled: settings.useVAD)

                advancedSlider("AI update interval",
                               value: $settings.llmMinIntervalSeconds,
                               range: 5...60,
                               step: 5,
                               readout: "\(Int(settings.llmMinIntervalSeconds))s",
                               caption: "Longer means fewer API calls.",
                               help: "Minimum time between AI summary updates: the transcript is sent to the LLM at most once per interval, so longer values use less CPU and fewer API calls on long recordings. The final update when you stop always runs regardless.")

                advancedSlider("Speaker similarity",
                               value: $settings.speakerSimilarityThreshold,
                               range: 0.5...0.95,
                               step: 0.01,
                               readout: String(format: "%.2f", settings.speakerSimilarityThreshold),
                               caption: "Higher merges fewer similar voices.",
                               help: "How confident the live diarizer must be before it treats two segments as the same speaker. Higher values make it more conservative about merging similar voices.")
            }
            .padding(.top, 6)
        }
    }

    private func advancedCaption(_ text: String) -> some View {
        Text(LocalizedStringKey(text))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: aiCaptionWidth, alignment: .leading)
    }

    private func advancedToggle(_ title: String,
                                isOn: Binding<Bool>,
                                caption: String,
                                help: String,
                                disabled: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: isOn)
                .font(.callout)
                .toggleStyle(.switch)
                .disabled(disabled)
            advancedCaption(caption)
        }
        .help(help)
    }

    private func advancedSlider(_ title: String,
                                value: Binding<Double>,
                                range: ClosedRange<Double>,
                                step: Double,
                                readout: String,
                                caption: String,
                                help: String,
                                disabled: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(readout)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
                .disabled(disabled)
            advancedCaption(caption)
        }
        .help(help)
    }
}

/// Renders the outcome of a Settings → AI Provider test run: the exact command
/// Copy button), a status line, and the captured stdout/stderr. Designed so a
/// user who can't get their CLI working can read or copy everything they need
/// to self-diagnose.
private struct LLMTestResultView: View {
    let result: LLMTestResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusLine

            if !result.command.isEmpty {
                labeledBlock("Command", text: result.command, copyable: true)
            }
            // OpenAI HTTP path: show the JSON body that was POSTed, for
            // copy-paste debugging. Empty for the CLI path.
            if !result.requestBody.isEmpty {
                labeledBlock("Request body", text: result.requestBody, copyable: true)
            }
            if let error = result.setupError {
                labeledBlock("Problem", text: error, copyable: false)
            }
            if result.didLaunch {
                let outputLabel = isHTTP ? "Response" : "Output (stdout)"
                let diagLabel = isHTTP ? "Error" : "Diagnostics (stderr)"
                if !result.stdout.isEmpty {
                    labeledBlock(outputLabel, text: result.stdout, copyable: true)
                }
                if !trimmed(result.stderr).isEmpty {
                    labeledBlock(diagLabel, text: result.stderr, copyable: true)
                }
                if result.stdout.isEmpty && trimmed(result.stderr).isEmpty {
                    Text(isHTTP ? "The endpoint returned no content."
                                : "The CLI produced no output.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    /// True for the OpenAI HTTP diagnostic path (which populates `url`),
    /// false for the CLI path. Picks Response/Error vs stdout/stderr labels.
    private var isHTTP: Bool { !result.url.isEmpty }

    private var statusLine: some View {
        HStack(spacing: 8) {
            icon
            Text(statusText)
                .font(.callout.weight(.medium))
            Spacer()
            if result.durationSeconds > 0 {
                Text(String(format: "%.1fs", result.durationSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if result.succeeded {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private var statusText: String {
        if result.succeeded { return "Success" }
        if result.timedOut {
            return isHTTP ? "Timed out — the endpoint didn't respond in time"
                          : "Timed out — the CLI didn't respond in time"
        }
        if let error = result.setupError, !result.didLaunch { return error }
        if let code = result.exitCode { return "CLI exited with status \(code)" }
        if let status = result.httpStatus { return "HTTP \(status)" }
        return "Failed"
    }

    private func labeledBlock(_ label: String, text: String, copyable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if copyable {
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(text, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy to clipboard")
                }
            }
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 160)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Compact "click an example to fill the prompt field above" helper.
private struct ExamplesView: View {
    let title: String
    let items: [String]
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(items, id: \.self) { item in
                Button {
                    onPick(item)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "arrow.up.left")
                            .font(.caption)
                            .foregroundStyle(.tint)
                        Text(item)
                            .font(.callout)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
        }
    }
}

// MARK: - Speakers

/// Slim Speakers tab. Surface area is: enable/disable checkbox, a single
/// health-status pill, and a "Run health check" button. When the bundled
/// PythonRuntime is shipping but torch hasn't been runtime-downloaded yet,
/// a bootstrap progress card takes priority over the health pill.
private struct DiarizationSettingsTab: View {
    @EnvironmentObject private var diarization: DiarizationSettings

    var body: some View {
        // Indirect through a content view so we can attach an ObservedObject
        // to the bootstrap instance — @EnvironmentObject isn't visible in
        // init() so we can't bind the ObservedObject there.
        DiarizationSettingsTabContent(
            diarization: diarization,
            bootstrap: diarization.bootstrap
        )
    }
}

private struct DiarizationSettingsTabContent: View {
    @ObservedObject var diarization: DiarizationSettings
    @ObservedObject var bootstrap: DiarizationBootstrap

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Speaker diarization")
                .font(.title3.weight(.semibold))

            Text("Identify who's speaking in your recordings. Required components install automatically on first enable; the check below confirms the local pipeline is ready.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Enable speaker diarization", isOn: $diarization.isEnabled)
                .accessibilityIdentifier("speakers.enable.toggle")

            if showingBootstrapCard {
                bootstrapCard
                    .accessibilityIdentifier("speakers.bootstrap.card")
            } else {
                healthCard
                    .accessibilityIdentifier("speakers.health.card")
            }

            if let error = diarization.healthCheckResult?.error,
               diarization.healthCheckResult?.ok == false,
               !showingBootstrapCard {
                ScrollView {
                    Text(error)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
                .padding(8)
                .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }

            // Stable accessibility probe for XCUITest — reads "ok" iff
            // the health-check result is ok. Zero-size, not visible to
            // humans. Lets the automated GUI test wait deterministically
            // for "Speakers self-heals to green" without scraping labels.
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityIdentifier("speakers.health.ok.probe")
                .accessibilityLabel(diarization.healthCheckResult?.ok == true ? "ok" : "not_ok")

            Divider()

            KnownSpeakersSection()

            Divider()

            VoiceRecognitionSection(diarization: diarization)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Show the bootstrap progress card whenever a bundled runtime exists
    /// AND it's still in flight or has failed. Once ready (or if no
    /// bundle is present at all), we go back to the regular health pill.
    private var showingBootstrapCard: Bool {
        guard diarization.hasBundledRuntime else { return false }
        switch bootstrap.stage {
        case .ready, .notStarted:
            return false
        default:
            return true
        }
    }

    private var bootstrapCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                bootstrapIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(bootstrapTitle)
                        .font(.callout.weight(.medium))
                    Text(bootstrapSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if case .downloadingTorch(let progress) = bootstrap.stage {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }
            if case .failed = bootstrap.stage {
                Button("Retry") {
                    Task { await bootstrap.bootstrapIfNeeded() }
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var healthCard: some View {
        HStack(spacing: 10) {
            healthIcon
            Text(healthLabel)
                .font(.callout)
            Spacer()
            Button {
                Task { await diarization.runHealthCheck() }
            } label: {
                if diarization.isHealthChecking {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Run health check")
                }
            }
            .disabled(diarization.isHealthChecking)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var bootstrapIcon: some View {
        switch bootstrap.stage {
        case .downloadingTorch, .installingTorch, .signing, .checking:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        default:
            Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
        }
    }

    private var bootstrapTitle: String {
        switch bootstrap.stage {
        case .notStarted:          return "Preparing speaker detection…"
        case .checking:            return "Checking…"
        case .downloadingTorch:    return "Downloading torch runtime"
        case .installingTorch:     return "Installing torch"
        case .signing:             return "Finalizing install"
        case .ready:               return "Ready"
        case .failed(let msg):     return "Setup failed: \(msg)"
        }
    }

    private var bootstrapSubtitle: String {
        switch bootstrap.stage {
        case .downloadingTorch(let p):
            return "\(Int(p * 100))% — torch is one-time, ~60 MB"
        case .installingTorch, .signing:
            return "Almost done — installing into the speaker runtime"
        case .failed:
            return "Retry to try the download again"
        default:
            return "First-time setup runs once; subsequent launches skip it"
        }
    }

    @ViewBuilder
    private var healthIcon: some View {
        if diarization.isHealthChecking {
            ProgressView().controlSize(.small)
        } else if let result = diarization.healthCheckResult {
            if result.ok {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        } else {
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
    }

    private var healthLabel: String {
        if diarization.isHealthChecking { return "Checking…" }
        guard let result = diarization.healthCheckResult else { return "Not checked yet" }
        if result.ok { return "Speaker detection is working" }
        // Library validation refused torch's dylibs — reinstalling the
        // Python packages can't fix that (the health check deliberately
        // skips auto-repair for this code); the app binary itself needs
        // its release entitlements. Point the user at the actual fix.
        if result.code == "codesign_blocked" {
            return "Speaker detection blocked by macOS code signing — reinstall Mila from the official download"
        }
        return "Speaker detection unavailable"
    }
}

/// "Known Speakers" — manage the persistent name list behind the
/// transcript's speaker-rename popover. Names added here (or via the
/// popover) are offered in every future recording's rename list.
private struct KnownSpeakersSection: View {
    @EnvironmentObject private var directory: SpeakerDirectory
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Known speakers")
                .font(.callout.weight(.semibold))
            Text("Names you can assign to speakers by clicking their label in a transcript. Removing a name here doesn't change recordings it's already assigned to.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !directory.names.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(directory.names, id: \.self) { name in
                            HStack {
                                Text(name)
                                Spacer()
                                Button {
                                    directory.remove(name)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help("Remove \"\(name)\" from the list")
                                .accessibilityIdentifier("speakers.known.remove.\(name)")
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("speakers.known.row.\(name)")
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 120)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 8) {
                TextField("Add a name…", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addName)
                    .accessibilityIdentifier("speakers.known.addField")
                Button("Add", action: addName)
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("speakers.known.addButton")
            }
        }
    }

    private func addName() {
        if directory.add(newName) != nil {
            newName = ""
        }
    }
}

/// Settings → Speakers → voice recognition: the opt-in switch for
/// cross-recording recognition, plus the delete path for whatever it has
/// already stored. Sits below the known-speakers list.
///
/// The off-state footprint is deliberately one toggle and one caption — the
/// shape `ObsidianSettingsSection.enableCard` uses, in the flat,
/// divider-separated style the rest of this tab uses rather than a card —
/// with one addition that only appears when it has to. While profiles from
/// an earlier opt-in are still on disk, the delete button stays visible
/// *even with the feature off*: opting out stops all reading and writing but
/// does not destroy the user's work, so deleting is a separate, explicit
/// decision, and it would be dishonest for the opt-out to be the only hint
/// that voice data is still at rest.
///
/// The caption is the full disclosure in both states rather than a teaser
/// that expands once you've already switched it on. What gets stored, where
/// it goes, and the fact that it never leaves the Mac are things you need
/// *before* deciding, not after.
private struct VoiceRecognitionSection: View {
    /// The diarization settings this tab is already showing. Voice
    /// recognition rides on the diarizer's embedding pool, so the section
    /// observes it to explain why an enabled toggle might not be doing
    /// anything yet.
    @ObservedObject var diarization: DiarizationSettings
    @EnvironmentObject private var settings: VoiceRecognitionSettings
    @EnvironmentObject private var profileStore: SpeakerProfileStore
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Voice recognition")
                .font(.callout.weight(.semibold))

            Toggle("Recognise returning speakers by voice", isOn: $settings.isEnabled)
                .accessibilityIdentifier("speakers.voiceRecognition.toggle")

            Text("Naming a speaker also saves a voice fingerprint for them: 256 numbers describing how the voice sounds, written to speaker-profiles.json in Mila's Application Support folder. The audio is not part of it and a fingerprint can't be played back — but it is enough to pick the same person out of a later recording, which is the point of it. Nothing is uploaded: the fingerprints stay on this Mac and are left out of diagnostic reports. They describe everyone whose name you fill in, not only you, so turn this on only where that is yours to decide.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // An enabled toggle does nothing until the diarizer can hand it
            // embeddings, so say so rather than letting it look broken.
            if settings.isEnabled, !diarization.isConfigured {
                Text("Waiting on speaker diarization above — until that reports Ready there are no voices to learn from, and nothing is stored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("speakers.voiceRecognition.waiting")
            }

            if profileStore.hasStoredProfilesOnDisk {
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    Text(storedProfilesLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button("Delete Voice Profiles", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                    .font(.caption)
                    .accessibilityIdentifier("speakers.voiceRecognition.delete")
                }
                .alert("Delete stored voice profiles?", isPresented: $showDeleteConfirmation) {
                    Button("Delete", role: .destructive) {
                        profileStore.deleteAllProfiles()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This deletes speaker-profiles.json and every voice fingerprint in it. Speaker names already on your recordings are untouched, but nobody will be recognised in new ones. This can't be undone.")
                }
            }
        }
    }

    /// While the feature is off the profiles file is deliberately never
    /// parsed, so there is no count to show — only the fact that it exists.
    private var storedProfilesLabel: String {
        guard settings.isEnabled else {
            return "Voice profiles from an earlier session are still stored on this Mac. Turning the switch back on picks up where you left off; they are only removed if you remove them."
        }
        let n = profileStore.profiles.count
        return n == 1 ? "1 voice profile stored." : "\(n) voice profiles stored."
    }
}

// MARK: - Meetings

/// Settings → Meetings. Toggles the floating "Zoom meeting detected" prompt
/// and surfaces the per-app silence list so a user who clicked
/// "Don't show this for Zoom" inside the prompt can undo that without
/// hunting through UserDefaults.
private struct MeetingsSettingsTab: View {
    @EnvironmentObject private var settings: MeetingDetectionSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Toggle(isOn: $settings.enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Prompt when a meeting starts or ends")
                            .font(.body)
                        Text("Mila shows a small prompt in the top-right when it sees you join a meeting in a supported app — and, while it's recording, when that meeting ends, it offers to stop.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.regular)
                // Meetings' per-section probe for `DetailLayoutUITests`.
                .accessibilityIdentifier("meetings.enable.toggle")

                Divider()

                supportedAppsBlock
                silencedAppsBlock

                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Meetings")
                .font(.title3.weight(.semibold))
            Text("Auto-prompt when Mila notices you're in a call so you don't have to remember to start recording.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var supportedAppsBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Supported apps")
                .font(.callout.weight(.semibold))
            ForEach(MeetingDetector.supportedApps, id: \.bundleID) { app in
                HStack {
                    Image(systemName: "video.fill")
                        .foregroundStyle(.tint)
                    Text(app.displayName)
                    Spacer()
                    if settings.isDisabled(forBundleID: app.bundleID) {
                        Text("Silenced")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if !settings.enabled {
                        Text("Off")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("On")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var silencedAppsBlock: some View {
        let silenced = MeetingDetector.supportedApps.filter {
            settings.isDisabled(forBundleID: $0.bundleID)
        }
        if !silenced.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Silenced from inside the prompt")
                    .font(.callout.weight(.semibold))
                Text("You clicked \"Don't show this for X\" on one of these. Re-enable the prompt for them here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(silenced, id: \.bundleID) { app in
                    HStack {
                        Text(app.displayName)
                        Spacer()
                        Button("Re-enable") {
                            settings.reenable(bundleID: app.bundleID)
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}
