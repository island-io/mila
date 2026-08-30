import SwiftUI
import AppKit
import Combine
import OSLog
import Sparkle
import TranscriptionCore

/// Wraps Sparkle's `SPUStandardUpdaterController` so SwiftUI menu items can
/// observe `canCheckForUpdates` and disable themselves while a check is
/// already in flight. Created once at app launch — Sparkle starts its
/// scheduled background poll immediately (interval comes from
/// `SUScheduledCheckInterval` in Info.plist).
///
/// It ALSO drives the custom pre-update "What's New" popup. When Sparkle's
/// scheduled background poll finds a newer valid version, we intercept it
/// via the gentle-reminder delegate hooks: `availableUpdate` is published so
/// `ContentView` can present `WhatsNewPopup` instead of Sparkle's stock
/// "update available" window. "Update Now" calls back into Sparkle's normal
/// install flow; "Later" dismisses. A USER-initiated "Check for Updates…"
/// (from the app menu) always uses Sparkle's standard UI — we only swap in
/// the custom popup for the silent scheduled discovery, which is where the
/// enticement matters.
///
/// Content for the popup comes from the appcast item's release notes
/// (`SUAppcastItem.itemDescription`): the installed app can't carry a
/// not-yet-released version's local notes, so "populate every new version"
/// means writing per-release highlights into each appcast `<description>`.
@MainActor
final class UpdaterViewModel: NSObject, ObservableObject,
                              SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    /// Implicitly-unwrapped because Sparkle wires its delegates at
    /// controller-construction time and holds them weakly, so the controller
    /// can only be built AFTER `super.init()` makes `self` available as the
    /// delegate. It's always non-nil by the end of `init`.
    private(set) var controller: SPUStandardUpdaterController!
    @Published var canCheckForUpdates = false

    /// Mirrors Sparkle's own `automaticallyChecksForUpdates` (persisted by
    /// Sparkle in the host bundle's defaults — we deliberately do NOT keep a
    /// second user default for it, per `SPUUpdater.h`). Kept in sync via KVO so
    /// the Settings toggle reflects changes Sparkle makes itself (e.g. the
    /// second-launch permission prompt). Write through
    /// `setAutomaticallyChecksForUpdates(_:)`.
    @Published var automaticallyChecksForUpdates = true

    /// UserDefaults key for the "Enable beta version" opt-in. Read live by
    /// `allowedChannels(for:)` and by the pre-release guard in
    /// `updater(_:shouldProceedWithUpdate:updateCheck:)`; written by the toggle
    /// in Settings → General ▸ Updates.
    static let betaChannelDefaultsKey = "updates.betaChannel"

    /// The update we want the custom popup to show. Non-nil iff a scheduled
    /// poll found a newer version we haven't already shown the user.
    /// `ContentView` binds a `.sheet(item:)` to this.
    @Published var availableUpdate: WhatsNewUpdate?

    /// True while a user-initiated check is in flight. During this window we
    /// let Sparkle's STANDARD UI handle everything (the menu command is an
    /// explicit ask — no enticement needed) instead of swapping in the popup.
    private var userInitiatedCheckInFlight = false

    private let gate: WhatsNewGate

    /// `defaults` is injectable so tests can isolate the "last seen version"
    /// persistence. In the app it's `.standard`.
    init(defaults: UserDefaults = .standard) {
        self.gate = WhatsNewGate(defaults: defaults)
        super.init()
        // Sparkle wires its delegates at controller-construction time (they
        // can't be reassigned afterward) and holds them weakly, so the
        // controller can only be built now that `self` exists to act as the
        // delegate. Starting the updater here kicks off the scheduled poll
        // (interval from `SUScheduledCheckInterval` in Info.plist).
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$automaticallyChecksForUpdates)

        // UI-test seam: force the "What's New" popup to appear with fixture
        // release-notes content, without needing a live appcast / a newer
        // published version. Exercised by
        // `WhatsNewPopupUITests.test_whats_new_popup_shows_highlights_and_update_button`.
        if CommandLine.arguments.contains("--ui-test-show-whats-new") {
            self.availableUpdate = WhatsNewUpdate(
                displayVersion: "9.9.9",
                releaseNotesHTML: """
                <h2>What's New</h2>
                <ul>
                  <li>Live AI meeting summaries are now faster and more accurate</li>
                  <li>Speaker labels stay stable across long recordings</li>
                  <li>New diagnostic report export for easier bug reports</li>
                </ul>
                """
            )
        }
    }

    /// Write-through for the "Automatically check for updates" toggle. Sparkle
    /// persists the value itself; the KVO mirror above pushes it back into
    /// `automaticallyChecksForUpdates` so the UI stays consistent.
    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    /// User picked "Check for Updates…" from the menu. Flag it so the
    /// gentle-reminder delegate lets Sparkle's standard UI run, then check.
    func checkForUpdates() {
        userInitiatedCheckInFlight = true
        controller.checkForUpdates(nil)
    }

    /// "Update Now" from the custom popup. Re-enter Sparkle's flow: it has
    /// the found update cached, so this brings up the standard install/confirm
    /// path immediately. We mark this as user-initiated so we don't recurse
    /// into the custom popup again.
    func proceedWithUpdate() {
        markSeenAndClear()
        userInitiatedCheckInFlight = true
        controller.checkForUpdates(nil)
    }

    /// "Later" / ESC on the popup. Remember this version as seen so the next
    /// scheduled poll doesn't immediately re-pop it, and drop the model.
    func dismissUpdate() {
        markSeenAndClear()
    }

    private func markSeenAndClear() {
        if let version = availableUpdate?.displayVersion {
            gate.markSeen(version: version)
        }
        availableUpdate = nil
    }

    // MARK: - SPUUpdaterDelegate

    /// Which appcast channels this app is willing to update to. Sparkle always
    /// includes the default (stable) channel; returning `["beta"]` additionally
    /// opts the user into items tagged `<sparkle:channel>beta</sparkle:channel>`.
    /// So stable users never see beta releases, while users who enable the beta
    /// toggle get betas AND stable. Read live from defaults so flipping the
    /// toggle takes effect on the next check — no relaunch needed.
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.bool(forKey: Self.betaChannelDefaultsKey) ? ["beta"] : []
    }

    /// Pure version classifier: does this marketing version string denote a
    /// pre-release? Matches the `-beta` / `-alpha` / `-rc` suffix conventions
    /// this project actually tags with (`1.9.2-beta.1`), case-insensitively.
    /// A plain `1.9.2` — or an empty/unknown string, which must never be
    /// treated as a beta — is not a pre-release.
    ///
    /// The marker has to be a *complete* token, guarded on both sides, because
    /// anything we can't positively classify must fail open:
    /// - a leading `-`, so a build named `Alpharetta` (`1.0.0 Alpharetta`) or a
    ///   `-superbeta` suffix isn't misread;
    /// - and nothing but a non-letter after it, so an unknown label like
    ///   `1.0.0-betamax` or `1.0.0-alphabet` is treated as unclassifiable
    ///   (allowed) rather than silently refused. A digit still counts as a
    ///   terminator so the common `1.9.2-beta1` spelling keeps matching,
    ///   alongside `-beta`, `-beta.1` and `-beta-1`.
    ///
    /// Kept `static`, `nonisolated` and side-effect-free so it's callable from
    /// Sparkle's nonisolated delegate callbacks and unit-testable without
    /// constructing an updater (see `UpdaterPrereleaseGuardTests`).
    nonisolated static func isPrerelease(_ shortVersionString: String) -> Bool {
        let v = shortVersionString.lowercased()
        return ["-beta", "-alpha", "-rc"].contains { marker in
            var searchStart = v.startIndex
            while let hit = v.range(of: marker, range: searchStart..<v.endIndex) {
                // A complete token: end-of-string, or followed by something
                // that isn't a letter (`.`, `-`, `+`, a digit, whitespace…).
                if hit.upperBound == v.endIndex || !v[hit.upperBound].isLetter {
                    return true
                }
                searchStart = hit.upperBound
            }
            return false
        }
    }

    /// Defensive, client-side beta gate — the last line of defence in front of
    /// `allowedChannels(for:)`.
    ///
    /// Channel filtering is only as good as the appcast: an item tagged
    /// `<sparkle:channel>beta</sparkle:channel>` is hidden from users who
    /// haven't opted in, but an item that is a beta and *forgot* the tag lands
    /// in the DEFAULT channel and is therefore offered to everyone. That is
    /// exactly what happened when `1.9.2-beta.1` was published without the
    /// channel element: every stable user was offered a beta regardless of the
    /// opt-in. The feed and the publishing pipeline were fixed separately —
    /// this hook makes the client refuse such an item anyway, so a single
    /// mis-tagged release can't push betas at people again.
    ///
    /// `shouldProceedWithUpdate` is the right hook: per `SPUUpdaterDelegate.h`,
    /// throwing here means "the user is not shown this updateItem nor is the
    /// update downloaded or installed" — it gates *offering* the update, unlike
    /// `didFindValidUpdate` (informational, too late) or the user-driver hooks
    /// (which only choose which UI presents an update that's already been
    /// accepted). It runs for both scheduled and user-initiated checks.
    nonisolated func updater(
        _ updater: SPUUpdater,
        shouldProceedWithUpdate updateItem: SUAppcastItem,
        updateCheck: SPUUpdateCheck
    ) throws {
        guard !UserDefaults.standard.bool(forKey: Self.betaChannelDefaultsKey) else { return }
        // Check both: `displayVersionString` is the marketing version users see
        // (`1.9.2-beta.1`), but a feed may only carry `sparkle:version`.
        let candidates = [updateItem.displayVersionString, updateItem.versionString]
        guard candidates.contains(where: { Self.isPrerelease($0) }) else { return }

        os.Logger(subsystem: "io.island.whisper.IslandWhisper", category: "MilaApp")
            .error("""
            Refusing update \(updateItem.displayVersionString, privacy: .public) \
            (\(updateItem.versionString, privacy: .public)): it is a pre-release \
            and this user has not opted into the beta channel. The appcast item \
            is probably missing <sparkle:channel>beta</sparkle:channel>.
            """)
        throw NSError(
            domain: "io.island.mila.updates",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey:
                "\(updateItem.displayVersionString) is a pre-release build. "
                + "Enable “Receive beta versions” in Settings ▸ General to install betas."]
        )
    }

    /// Sparkle found a newer valid version. Capture its release notes for the
    /// custom popup. This fires for both scheduled and user-initiated checks;
    /// `standardUserDriverShouldHandleShowingScheduledUpdate` decides which UI
    /// actually shows.
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        let notes = item.itemDescription
        Task { @MainActor in
            // A user-initiated "Check for Updates…" (menu command, or
            // "Update Now" from the popup) is owned end-to-end by Sparkle's
            // STANDARD driver — it puts up its own "update available" window.
            // If we ALSO recorded the custom popup here, BOTH would appear.
            // Bail in that case so exactly one UI shows. The silent scheduled
            // background poll leaves this flag false, so the custom popup
            // still owns that path.
            guard !self.userInitiatedCheckInFlight else { return }
            guard self.gate.shouldShow(availableVersion: version) else { return }
            self.availableUpdate = WhatsNewUpdate(
                displayVersion: version,
                releaseNotesHTML: notes
            )
        }
    }

    // MARK: - SPUStandardUserDriverDelegate

    /// Opt into gentle reminders so Sparkle asks us (below) whether to handle
    /// scheduled-update UI itself.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Return `false` for a SCHEDULED (background-poll) discovery so the
    /// delegate (our custom `WhatsNewPopup`) owns presentation instead of
    /// Sparkle's stock window.
    ///
    /// This method is NOT called for user-initiated checks — per
    /// `SPUStandardUserDriverDelegate.h`, "the standard user driver always
    /// handles those." So we must NOT branch on `immediateFocus`: it merely
    /// reflects whether the app was launched recently / the system is idle
    /// (a common path), NOT whether the check was user-initiated. Branching
    /// on it was why Sparkle's stock window ALSO popped on the launch poll.
    ///
    /// We only return `false` when the gate says we'd actually show a popup
    /// for this version. If the gate would suppress the popup (e.g. the user
    /// already dismissed this version), let Sparkle's standard UI handle it so
    /// a scheduled discovery never ends up with no UI at all.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        let version = update.displayVersionString
        return MainActor.assumeIsolated {
            !self.gate.shouldShow(availableVersion: version)
        }
    }

    /// Called when an update CHECK CYCLE finishes — update scheduled, no
    /// update found, dismissed/skipped, or aborted (per `SPUUpdaterDelegate.h`).
    /// Reset the user-initiated flag here so the NEXT scheduled poll is treated
    /// as scheduled again. We use this terminal callback rather than
    /// `standardUserDriverWillHandleShowingUpdate` (which fires BEFORE the
    /// update window appears and not at all for "no update found", which would
    /// leave the flag stuck `true` after a user check that finds nothing).
    nonisolated func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        Task { @MainActor in
            self.userInitiatedCheckInFlight = false
        }
    }
}

extension Notification.Name {
    /// Posted from `ContentView` whenever NavigationSplitView's column
    /// visibility flips (the user toggled the sidebar). The
    /// `MilaAppDelegate` listens so it can re-run the
    /// "freeze sidebar to withinWindow blending" chrome hack on the
    /// freshly-added NSVisualEffectViews — without that, opening the
    /// sidebar shows a frame of the default behindWindow material
    /// (which looks like a flicker).
    static let milaSidebarVisibilityDidChange = Notification.Name("milaSidebarVisibilityDidChange")
}

@main
struct MilaApp: App {
    @NSApplicationDelegateAdaptor(MilaAppDelegate.self) private var appDelegate

    @StateObject private var store: RecordingStore
    @StateObject private var storageSettings: RecordingStorageSettings
    @StateObject private var modelManager: ModelManager
    @StateObject private var transcription: TranscriptionService
    @StateObject private var dictation: DictationController
    @StateObject private var actions: QuickActionsController
    @StateObject private var session: RecordingSession
    @StateObject private var hotkeySettings: HotkeySettings
    @StateObject private var languageSettings: RecordingLanguageSettings
    @StateObject private var audioInputSettings: AudioInputSettings
    @StateObject private var inputLevelMonitor: InputLevelMonitor
    @StateObject private var llmSettings: LLMSettings
    @StateObject private var postRecording: PostRecordingCoordinator
    @StateObject private var diarizationSettings: DiarizationSettings
    @StateObject private var remoteTranscriptionSettings: RemoteTranscriptionSettings
    @StateObject private var meetingDetectionSettings: MeetingDetectionSettings
    @StateObject private var meetingDetector: MeetingDetector
    @StateObject private var meetingPrompt: MeetingPromptCoordinator
    @StateObject private var liveAISettings: LiveAISettings
    @StateObject private var liveTranscriber: LiveTranscriber
    @StateObject private var liveSpeakerDiarizer: LiveSpeakerDiarizer
    @StateObject private var liveAISession: LiveAISession
    /// Generates a one-shot LLM summary for every finished recording
    /// whenever the user's LLM CLI is configured (Live AI mode no
    /// longer gates this). Held as a `@StateObject` so it survives
    /// SwiftUI redraws and so its in-flight task table survives
    /// alongside everything else.
    @StateObject private var recordingSummarizer: RecordingSummarizer
    /// Obsidian vault destination + its exporter. The exporter is held as a
    /// StateObject purely so it stays alive — the completion hooks capture it
    /// weakly.
    @StateObject private var obsidianVaultSettings: ObsidianVaultSettings
    @StateObject private var mcpAccessSettings: MCPAccessSettings
    @StateObject private var obsidianExporter: ObsidianExporter
    @StateObject private var voiceMemosSettings: VoiceMemosSettings
    @StateObject private var voiceMemosImporter: VoiceMemosImporter
    /// Persistent, app-wide list of speaker names — the pick-list behind
    /// the transcript's speaker rename popover.
    @StateObject private var speakerDirectory: SpeakerDirectory
    /// Applies double-clicked `.milaconfig` files (with a confirmation sheet).
    @StateObject private var configImporter: MilaConfigImporter
    /// Mirrors the live transcript to `live/current.json` for external
    /// tools (mila-mcp). Not observed by any view; held as a StateObject
    /// purely so it survives SwiftUI re-inits like the other singletons.
    @StateObject private var liveSidecarWriter: LiveTranscriptSidecarWriter
    @StateObject private var updater = UpdaterViewModel()
    /// Opt-in switch for cross-recording voice recognition (off by default).
    @StateObject private var voiceRecognitionSettings: VoiceRecognitionSettings
    /// Persisted voice fingerprints behind that feature. Inert — nothing
    /// read, nothing written — until the setting above is turned on.
    @StateObject private var speakerProfileStore: SpeakerProfileStore

    init() {
        // RecordingStore's no-arg init handles the legacy migration and
        // opens at the default Application Support location. The
        // storage-settings instance owns the security-scoped bookmark
        // resolution; we apply any user override by calling
        // `relocateRecordings(to:)` once both are constructed.
        let store = RecordingStore()
        let storage = RecordingStorageSettings()
        if let custom = storage.customDirectory {
            store.relocateRecordings(to: custom)
        }
        let mgr = ModelManager(modelsDirectory: store.modelsDirectory)
        // Diarization is OFF by default. The live diarizer runs a
        // continuous pyannote (torch) subprocess that embeds every
        // utterance during recording — a heavy, separate-process CPU draw
        // that competes with the app and was a major contributor to the
        // "high CPU on long recordings" reports. Speaker labels are worth
        // it for some users, so it stays one toggle away in Settings ▸
        // Diarization (enabling it triggers the one-time torch download);
        // we just don't pay that cost for everyone by default. Users who
        // previously toggled it either way have an explicit value
        // persisted, which shadows this default. Passed as a ctor argument
        // rather than registered on `UserDefaults.standard` because the
        // unit-test process loads MilaApp as TEST_HOST — a global
        // registration would leak into tests and fire DiarizationSettings'
        // launch-time checkDeps subprocess, starving the cooperative
        // thread pool that timing-sensitive tests depend on.
        //
        // One-time force-off migration: flipping the default only helps
        // users with no persisted value. To stop the pyannote subprocess
        // CPU draw for EVERYONE on upgrade — including those who had
        // explicitly enabled it — turn it off exactly once, guarded by a
        // versioned flag. Anyone who re-enables it in Settings afterward
        // keeps their choice (the flag stops the migration re-running).
        let diarForceOffKey = "diarization.forcedOffMigration.v1"
        if UserDefaults.standard.object(forKey: diarForceOffKey) == nil {
            UserDefaults.standard.set(false, forKey: "diarization.enabled")
            UserDefaults.standard.set(true, forKey: diarForceOffKey)
        }
        let diarSettings = DiarizationSettings(defaultEnabledIfUnset: false)
        // Remote transcription backend (opt-in, off by default). Constructed
        // here so the same instance backs both the Settings UI and the
        // transcription router.
        let remoteSettings = RemoteTranscriptionSettings()
        let svc = TranscriptionService(store: store,
                                       modelManager: mgr,
                                       diarizationSettings: diarSettings,
                                       remoteSettings: remoteSettings)
        let session = RecordingSession()
        let langSettings = RecordingLanguageSettings()
        let audioSettings = AudioInputSettings()
        let inputMonitor = InputLevelMonitor()
        inputMonitor.preferredUID = audioSettings.preferredUID
        let llm = LLMSettings()
        let coordinator = PostRecordingCoordinator(store: store, transcription: svc, llm: llm)
        let actions = QuickActionsController(session: session,
                                             store: store,
                                             transcription: svc,
                                             languageSettings: langSettings,
                                             postRecording: coordinator)
        let hotkeys = HotkeySettings()
        // UI-test bypass for the hardware gate: hosted macos-26 runners
        // sometimes report as MacBook Air via `hw.model`, which trips
        // the Live AI gate and stops the live-transcript fixture/RTL
        // routes from rendering. When the UI-test flags are set, force
        // a non-Air capability so `isLiveAIAvailable` returns true for
        // every downstream check (ContentView routing,
        // wireLiveAIPipeline, etc.) — the production hardware gate is
        // untouched in real launches. Centralising the bypass here is
        // simpler and less error-prone than sprinkling
        // `CommandLine.arguments` checks at every gate.
        let uiTestForcesLiveAI =
            CommandLine.arguments.contains("--ui-test-rtl-live-hebrew")
            || CommandLine.arguments.contains(where: { $0.hasPrefix("--ui-test-inject-fixture-wav=") })
        let liveAICapabilities: SystemCapabilities = uiTestForcesLiveAI
            ? SystemCapabilities(
                modelIdentifier: SystemCapabilities.live.modelIdentifier,
                marketingName: "MacBook Pro",
                isMacBookAir: false,
                physicalRamGB: SystemCapabilities.live.physicalRamGB,
                performanceCoreCount: SystemCapabilities.live.performanceCoreCount
            )
            : .live
        let liveAI = LiveAISettings(capabilities: liveAICapabilities)
        let liveTrans = LiveTranscriber(transcription: svc)
        // Dictation gets its OWN LiveTranscriber instance so triggering
        // a dictation overlay while a meeting recording is in flight
        // (or vice versa) doesn't clobber the other's buffer / tick
        // task. They share the underlying TranscriptionService — the
        // engine itself serialises whisper calls per-actor — but the
        // streaming state stays independent.
        let dictationTrans = LiveTranscriber(transcription: svc)
        // UI-test seed for the Hebrew RTL alignment regression test
        // (see `DetailLayoutUITests.test_hebrew_live_segments_hug_right_edge_with_sidebar_open`).
        // We do this AFTER constructing the live transcriber rather
        // than inside its init so the seed doesn't depend on whatever
        // order Swift evaluates the @MainActor isolation of init vs
        // CommandLine population — putting it here makes it deterministic.
        os.Logger(subsystem: "io.island.whisper.IslandWhisper", category: "MilaApp")
            .log("MilaApp.init args=\(CommandLine.arguments.joined(separator: " "), privacy: .public)")
        // UI-test launch args that override persisted settings so the
        // workflow can pick the recording language without depending on
        // whatever the host's UserDefaults happens to have.
        if CommandLine.arguments.contains("--ui-test-recording-lang-en") {
            langSettings.current = .english
        } else if CommandLine.arguments.contains("--ui-test-recording-lang-he") {
            langSettings.current = .hebrew
        }
        // Force the "All Transcriptions" sidebar section EXPANDED when seeding
        // a recording for UI tests. `sidebar.allTranscriptions.expanded` is
        // @AppStorage-backed and is NOT reset by `--ui-test-clean-store` (that
        // only swaps the recordings store), so its value leaks across runs and
        // the seeded recording's inline row was present or absent
        // nondeterministically. Pinning it true makes
        // `sidebar.recording.Seed Recording` deterministically reachable, which
        // removes the select-vs-expand flake in
        // `DetailLayoutUITests.test_recording_detail_renders_within_window_bounds`.
        if CommandLine.arguments.contains("--ui-test-seed-recording") {
            UserDefaults.standard.set(true, forKey: "sidebar.allTranscriptions.expanded")
        }
        // CI E2E: point LLMSettings at a Claude CLI installed on the
        // runner. With ANTHROPIC_API_KEY set in the env, the CLI
        // authenticates non-interactively and Live AI's session loop
        // runs for real instead of being silently skipped because
        // `isConfigured == false`.
        if let arg = CommandLine.arguments.first(where: {
            $0.hasPrefix("--ui-test-llm-claude=")
        }) {
            let path = String(arg.dropFirst("--ui-test-llm-claude=".count))
            llm.tool = .claude
            llm.executablePath = path
        }
        // CI E2E: swap whichever language-best model the catalog would
        // normally pick out for a small `ggml-tiny.bin` so cold-load +
        // transcribe stays under ~10s instead of 60-200s.
        if let arg = CommandLine.arguments.first(where: {
            $0.hasPrefix("--ui-test-tiny-model-path=")
        }) {
            let path = String(arg.dropFirst("--ui-test-tiny-model-path=".count))
            mgr.setTestModelOverride(URL(fileURLWithPath: path))
        }
        if CommandLine.arguments.contains("--ui-test-rtl-live-hebrew") {
            liveTrans.seedForTesting([
                LiveSegment(id: UUID(), startSeconds: 0, endSeconds: 2,
                            text: "שלום לכולם וברוכים הבאים לפגישה",
                            speaker: nil, stable: true),
                LiveSegment(id: UUID(), startSeconds: 2, endSeconds: 5,
                            text: "היום נסקור את התוכנית לרבעון הבא",
                            speaker: nil, stable: true),
                LiveSegment(id: UUID(), startSeconds: 5, endSeconds: 8,
                            text: "ונחלק את העבודה בין החברים",
                            speaker: nil, stable: true)
            ])
            os.Logger(subsystem: "io.island.whisper.IslandWhisper", category: "MilaApp")
                .log("seeded \(liveTrans.segments.count, privacy: .public) Hebrew segments for UI test")
        }
        let liveDiar = LiveSpeakerDiarizer()
        let liveSession = LiveAISession(llmSettings: llm, liveAISettings: liveAI)
        let summarizer = RecordingSummarizer(store: store,
                                             llmSettings: llm,
                                             liveAISettings: liveAI)
        // Obsidian vault destination. When enabled, a completed recording is
        // written into the vault as a Markdown note (summary + action items,
        // transcript fallback) once its summary is ready, then optionally
        // committed + pushed to git. Off by default.
        let obsidianSettings = ObsidianVaultSettings()
        // Opt-in gate for the bundled mila-mcp helper. Constructing it
        // mirrors the persisted flag back out to `mcp-access.json`, so the
        // helper's view of consent re-converges on every launch.
        //
        // The readiness half is bound to the store: consent alone isn't
        // enough, because a `store-location.json` write that failed after a
        // relocation would leave the helper reading the OLD store and
        // answering from it. `storeIsDiscoverable` is a closure, not a
        // snapshot, so it is re-consulted on every mirror — the store is
        // already constructed above, and the launch-time relocation on line
        // ~379 has already run, so the first mirror sees the real verdict.
        //
        // `store` is captured STRONGLY on purpose. A weak capture that went
        // nil would fall back to the `?? true` default and quietly re-open
        // the gate — a fail-open in the one place that must not have one.
        // There is no cycle: the store's callback below holds `mcpAccess`
        // weakly, and both objects are `@StateObject`-lived anyway.
        let mcpAccess = MCPAccessSettings(storeIsDiscoverable: {
            store.storeLocationIsDiscoverable
        })
        // A mid-session relocation can flip discoverability either way, and
        // the helper's gate must follow immediately rather than at the next
        // launch. The store only calls this when the verdict actually
        // changes, so a normal relocation doesn't rewrite the gate file.
        store.onStoreLocationDiscoverabilityChanged = { [weak mcpAccess] in
            mcpAccess?.refreshMirror()
        }
        let obsidian = ObsidianExporter(settings: obsidianSettings)
        // Write the note once the summary state is final. Gated on `pending`
        // so a launch-time backfill sweep never re-files the back-catalogue.
        summarizer.onSummaryFinished = { [weak obsidian] rec in
            guard let obsidian, obsidian.isPending(rec.id) else { return }
            obsidian.export(rec)
            obsidian.clearPending(rec.id)
        }
        // Wire the post-transcription summary hook. Fires for every
        // recording that the queue successfully completes — the
        // summarizer's own `shouldSummarize` gate skips work if a
        // live summary already landed, if the LLM CLI isn't
        // configured, or if the transcript came up empty.
        //
        // When `wasRetranscription` is true the recording had an old
        // summary referring to the previous transcript; we force-
        // regenerate so the user doesn't end up with a stale summary
        // that disagrees with what the segments now say.
        // Live-transcript sidecar for external tools (mila-mcp). Anchored
        // to the store's original root so tests / UI-test temp stores stay
        // isolated from the user's real app-support directory.
        //
        // Constructed HERE, above `onTranscriptionCompleted`, because that hook
        // captures it to publish the deferred batch handoff. It only needs
        // `store`; the `actions` wiring stays further down with the rest.
        let sidecarWriter = LiveTranscriptSidecarWriter(root: store.originalRootDirectory)
        sidecarWriter.cleanupAtLaunch()
        svc.onTranscriptionCompleted = { [weak summarizer, weak llm, weak obsidianSettings, weak obsidian, weak sidecarWriter] rec, wasRetranscription in
            // A recording whose live transcript wasn't final closed its live
            // sidecar WITHOUT a handoff id, because at Stop the batch worker
            // hadn't produced the transcript yet. It just did — so publish the
            // handoff now, completing what `finish(…, transcriptIsFinal:
            // false)` deferred. A no-op unless this is that exact recording
            // and its snapshot is still the one on disk; see `attachHandoff`.
            sidecarWriter?.attachHandoff(forRecording: rec.id)
            // Obsidian export is driven off the summarizer's completion hook.
            // Mark this fresh completion pending so the hook knows to write it
            // (backfilled recordings are never marked, hence never re-filed).
            let obsidianOn = (obsidianSettings?.enabled == true) && (obsidianSettings?.vaultURL != nil)
            if wasRetranscription {
                // `regenerate` bypasses the "already has a summary" gate by
                // design (it's also the manual on-demand path), so it does
                // NOT consult `summaryEnabled` itself. Guard the AUTOMATIC
                // re-transcription trigger here so a transcript-only user
                // doesn't get a summary regenerated behind their back.
                guard llm?.summaryEnabled ?? true else {
                    // No summary will be regenerated — export immediately with
                    // the transcript fallback (no summarizer hook to wait for).
                    if obsidianOn { obsidian?.export(rec) }
                    return
                }
                if obsidianOn { obsidian?.markPending(rec.id) }
                summarizer?.regenerate(rec)
            } else {
                if obsidianOn { obsidian?.markPending(rec.id) }
                summarizer?.summarizeIfNeeded(rec)
            }
        }
        // Cross-recording voice recognition. Opt-in and off by default:
        // `voiceSettings.isConfigured` is the single gate, and it means
        // "the user turned it on AND diarization can actually produce
        // embeddings" — see `.claude/rules/feature-gates.md`. Readiness is
        // injected as a closure so the settings object can read the
        // diarization gate without being able to mutate it.
        let voiceSettings = VoiceRecognitionSettings()
        voiceSettings.diarizationReady = { [weak diarSettings] in
            diarSettings?.isConfigured ?? false
        }
        _voiceRecognitionSettings = StateObject(wrappedValue: voiceSettings)
        let profileStoreRef = SpeakerProfileStore(settings: voiceSettings)
        _speakerProfileStore = StateObject(wrappedValue: profileStoreRef)
        let voiceSnapshots = ObservedVoiceSnapshots()
        voiceSnapshots.clearOnOptOut(of: voiceSettings)
        // …and the third holder of copied voice data: the live pool. The two
        // lines above unload the profiles (`SpeakerProfileStore`'s own
        // observer) and drop the snapshots, but `seedPool` handed the
        // diarizer its own copy of every centroid at record-start, so an
        // opt-out mid-recording otherwise leaves `assign` matching against
        // stored voices for the rest of it. The write gates stop the result
        // being persisted; they do not stop it being *read*, and the user
        // still watches their transcript auto-fill with names from a feature
        // they just switched off.
        //
        // Exactly the deletion path's problem, so it gets the deletion
        // path's remedy — see `addDeletionObserver` below. Opt-out is the
        // broader of the two, so it forgets every seeded entry rather than
        // named ones.
        voiceSettings.addEnabledObserver { [weak liveDiar] nowEnabled in
            guard !nowEnabled else { return }
            liveDiar?.forgetSeededProfiles()
        }
        // Auto-naming + the per-recording snapshot, driven by the finalize
        // drain rather than by observing `isRecording`. The drain hands over
        // the id of the recording that actually finished, and calls
        // synchronously inside the window where the diarizer pool still
        // belongs to it — see `RecognisedSpeakerAssigner`.
        let assigner = RecognisedSpeakerAssigner(store: store,
                                                diarizer: liveDiar,
                                                snapshots: voiceSnapshots,
                                                settings: voiceSettings,
                                                profileStillStored: { name in
                                                    profileStoreRef.profileExists(name: name)
                                                })
        // Deleting voice profiles has to reach the recording that is already
        // running, not just memory and the file. The pool was seeded from
        // these profiles at record-start and keeps its own copy of every
        // centroid, so without this the rest of the recording goes on
        // matching the erased voice and `assigner.finish` writes it back at
        // stop — the deleted file reappears, holding the same person's
        // fingerprint. Same immediacy as the opt-out path above.
        profileStoreRef.addDeletionObserver { [weak liveDiar] deletion in
            switch deletion {
            case .all: liveDiar?.forgetSeededProfiles()
            case .named(let names): liveDiar?.forgetSeededProfiles(named: names)
            }
        }
        actions.onRecordingFinalized = { [assigner] recordingID in
            assigner.finish(recording: recordingID)
        }
        // Save a voice profile when a speaker is named — if the live
        // diarizer observed that speaker *in that recording*, persist it.
        // The store refuses writes while the feature is off; the guard here
        // means an opted-out user's voice isn't so much as looked up.
        //
        // Resolved through the per-recording snapshot keyed on
        // `recordingID`, never against the live pool. `SPEAKER_00` restarts from zero on every
        // `reset()`, so a live-pool lookup silently returned the *current*
        // recording's speaker for a name applied to an older one — writing a
        // stranger's voice into the named profile. A recording with no
        // snapshot resolves to nil and persists nothing, which is the honest
        // answer: its pool is gone.
        //
        // The snapshot holds what was observed in that recording, not the
        // pool's matching centroid — for a seeded speaker the latter carries
        // weight already stored on disk, and folding it back counts it twice.
        // This is the only place voice profiles are written, so a recognised
        // speaker merges exactly once per recording.
        let voiceLog = os.Logger(subsystem: "io.island.whisper.IslandWhisper", category: "VoiceProfile")
        store.onSpeakerNamed = { [weak store, weak diarSettings] recordingID, rawID, name in
            guard voiceSettings.isConfigured else { return }
            if let observed = voiceSnapshots.observation(forSpeaker: rawID,
                                                         in: recordingID) {
                // Snapshot exists (live or batch) — save immediately.
                profileStoreRef.updateProfile(
                    name: name,
                    embedding: observed.observedCentroid,
                    sampleCount: observed.observedCount
                )
            } else if let store {
                // No snapshot (old recording, never re-transcribed).
                // Extract the embedding on demand (~0.5s) from the
                // speaker's longest segment in this recording.
                guard let rec = store.recordings.first(where: { $0.id == recordingID }) else { return }
                var best: (start: Double, end: Double)?
                for seg in rec.segments where seg.speaker == rawID {
                    let dur = seg.end - seg.start
                    if best == nil || dur > (best!.end - best!.start) {
                        best = (seg.start, seg.end)
                    }
                }
                guard let segment = best else { return }
                let pythonPath = diarSettings?.pythonPath ?? "/usr/bin/python3"
                let capturedName = name
                let capturedRecID = recordingID
                let capturedRawID = rawID
                Task.detached(priority: .utility) {
                    let wavURL = await store.audioURL(for: rec)
                    guard FileManager.default.fileExists(atPath: wavURL.path) else { return }
                    do {
                        let embeddings = try await SpeakerDiarizer.embedSpeakers(
                            wavURL: wavURL, pythonPath: pythonPath,
                            speakerSegments: [capturedRawID: segment])
                        guard let emb = embeddings[capturedRawID] else { return }
                        voiceLog.log("on-demand voice profile saved for \(capturedRawID, privacy: .public)")
                        await MainActor.run {
                            voiceSnapshots.record(
                                [(id: capturedRawID, observedCentroid: emb.map { Float($0) },
                                  observedCount: 1, profileName: nil)],
                                for: capturedRecID)
                            profileStoreRef.updateProfile(
                                name: capturedName,
                                embedding: emb.map { Float($0) },
                                sampleCount: 1)
                        }
                    } catch {
                        voiceLog.log("on-demand embedding failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }

        // Batch voice matching: after any transcription completes, embed
        // each speaker's longest segment and match against stored voice
        // profiles. Uses embedSpeakers (embedding model only, ~0.5s)
        // instead of extractEmbeddings (full pyannote pipeline, 30-60min).
        let existingCallback = svc.onTranscriptionCompleted
        svc.onTranscriptionCompleted = { [weak store, weak diarSettings] rec, wasRetranscription in
            existingCallback?(rec, wasRetranscription)
            guard voiceSettings.isConfigured,
                  !profileStoreRef.profiles.isEmpty,
                  rec.speakerNames.isEmpty,
                  rec.segments.contains(where: { $0.speaker != nil }),
                  let store else { return }
            // Build a map of each speaker's longest segment.
            var longest: [String: (start: Double, end: Double)] = [:]
            for seg in rec.segments {
                guard let sp = seg.speaker else { continue }
                let dur = seg.end - seg.start
                if let existing = longest[sp] {
                    if dur > (existing.end - existing.start) {
                        longest[sp] = (seg.start, seg.end)
                    }
                } else {
                    longest[sp] = (seg.start, seg.end)
                }
            }
            guard !longest.isEmpty else { return }
            let pythonPath = diarSettings?.pythonPath ?? "/usr/bin/python3"
            Task.detached(priority: .utility) {
                let wavURL = await store.audioURL(for: rec)
                guard FileManager.default.fileExists(atPath: wavURL.path) else { return }
                let embeddings = (try? await SpeakerDiarizer.embedSpeakers(
                    wavURL: wavURL, pythonPath: pythonPath,
                    speakerSegments: longest)) ?? [:]
                guard !embeddings.isEmpty else { return }
                await MainActor.run {
                    // Store embeddings as snapshots so naming a speaker
                    // later (via onSpeakerNamed) can save the voice
                    // profile even for batch-transcribed recordings.
                    let entries = embeddings.map { (rawID, emb) in
                        (id: rawID,
                         observedCentroid: emb.map { Float($0) },
                         observedCount: 1,
                         profileName: nil as String?)
                    }
                    voiceSnapshots.record(entries, for: rec.id)

                    for (rawID, emb) in embeddings {
                        if let profile = profileStoreRef.match(embedding: emb) {
                            store.setSpeakerName(
                                profile.name, forSpeaker: rawID,
                                recordingID: rec.id)
                        }
                    }
                }
            }
        }

        // Auto-drop accidental short+empty captures (issue #61). A recording
        // that finishes transcription with no text AND under the user's
        // minimum-duration threshold (Settings ▸ Storage, default 5s, 0 = keep
        // all) is a hotkey misfire / silence clip — permanently drop it so it
        // never spams the list. Reads the live threshold each time so a
        // Settings change takes effect on the next recording without relaunch.
        svc.shouldAutoDropShortEmpty = { [weak storage] duration, transcript in
            storage?.shouldAutoDrop(duration: duration, transcript: transcript) ?? false
        }
        // Late-bind the live-AI dependencies onto `actions` so it can
        // attach summary/items to the saved Recording and skip the
        // rename sheet when Live AI was running.
        actions.llmSettings = llm
        actions.liveAISettings = liveAI
        actions.liveAISession = liveSession
        actions.liveTranscriber = liveTrans
        actions.liveDiarizer = liveDiar
        actions.summarizer = summarizer
        actions.storageSettings = storage
        actions.obsidianSettings = obsidianSettings
        actions.obsidianExporter = obsidian
        actions.liveSidecarWriter = sidecarWriter
        let meetingSettings = MeetingDetectionSettings()
        let detector = MeetingDetector()
        let promptCoordinator = MeetingPromptCoordinator(
            detector: detector,
            settings: meetingSettings,
            actions: actions
        )
        // Applies `.milaconfig` files. Given the settings objects it's allowed
        // to mutate; the open event is routed in from `MilaAppDelegate`.
        let configImporter = MilaConfigImporter(
            remote: remoteSettings,
            language: langSettings,
            liveAI: liveAI,
            diarization: diarSettings,
            meetingDetection: meetingSettings
        )
        _store = StateObject(wrappedValue: store)
        _storageSettings = StateObject(wrappedValue: storage)
        _modelManager = StateObject(wrappedValue: mgr)
        _transcription = StateObject(wrappedValue: svc)
        _diarizationSettings = StateObject(wrappedValue: diarSettings)
        _remoteTranscriptionSettings = StateObject(wrappedValue: remoteSettings)
        _session = StateObject(wrappedValue: session)
        _actions = StateObject(wrappedValue: actions)
        _hotkeySettings = StateObject(wrappedValue: hotkeys)
        _languageSettings = StateObject(wrappedValue: langSettings)
        _audioInputSettings = StateObject(wrappedValue: audioSettings)
        _inputLevelMonitor = StateObject(wrappedValue: inputMonitor)
        _llmSettings = StateObject(wrappedValue: llm)
        _postRecording = StateObject(wrappedValue: coordinator)
        _meetingDetectionSettings = StateObject(wrappedValue: meetingSettings)
        _meetingDetector = StateObject(wrappedValue: detector)
        _meetingPrompt = StateObject(wrappedValue: promptCoordinator)
        _liveAISettings = StateObject(wrappedValue: liveAI)
        _liveTranscriber = StateObject(wrappedValue: liveTrans)
        _liveSpeakerDiarizer = StateObject(wrappedValue: liveDiar)
        _liveAISession = StateObject(wrappedValue: liveSession)
        _recordingSummarizer = StateObject(wrappedValue: summarizer)
        _obsidianVaultSettings = StateObject(wrappedValue: obsidianSettings)
        _mcpAccessSettings = StateObject(wrappedValue: mcpAccess)
        _obsidianExporter = StateObject(wrappedValue: obsidian)
        // Voice Memos (iPhone) folder integration. Settings are opt-in and
        // default-off; the importer wires up its FSEvents watcher + initial
        // backfill from its `start()` launch task (below), so constructing
        // it here is cheap (no DB / filesystem work in init).
        let vmSettings = VoiceMemosSettings()
        let vmImporter = VoiceMemosImporter(store: store,
                                            transcription: svc,
                                            settings: vmSettings,
                                            languageSettings: langSettings)
        _voiceMemosSettings = StateObject(wrappedValue: vmSettings)
        _voiceMemosImporter = StateObject(wrappedValue: vmImporter)
        _speakerDirectory = StateObject(wrappedValue: SpeakerDirectory())
        _configImporter = StateObject(wrappedValue: configImporter)
        _liveSidecarWriter = StateObject(wrappedValue: sidecarWriter)
        let dictationController = DictationController(store: store,
                                                      transcription: svc,
                                                      hotkeySettings: hotkeys,
                                                      liveTranscriber: dictationTrans)
        dictationController.storageSettings = storage
        _dictation = StateObject(wrappedValue: dictationController)
    }

    var body: some Scene {
        WindowGroup("Mila") {
            ContentView()
                .environmentObject(store)
                .environmentObject(storageSettings)
                .environmentObject(modelManager)
                .environmentObject(transcription)
                .environmentObject(dictation)
                .environmentObject(actions)
                .environmentObject(session)
                .environmentObject(hotkeySettings)
                .environmentObject(languageSettings)
                .environmentObject(audioInputSettings)
                .environmentObject(inputLevelMonitor)
                .environmentObject(llmSettings)
                .environmentObject(postRecording)
                .environmentObject(diarizationSettings)
                .environmentObject(remoteTranscriptionSettings)
                .environmentObject(liveAISettings)
                .environmentObject(liveTranscriber)
                .environmentObject(liveSpeakerDiarizer)
                .environmentObject(liveAISession)
                .environmentObject(updater)
                .frame(minWidth: 1000, minHeight: 640)
                .task { ensureDefaultModelsInstalled() }
                .task { prewarmDefaultModel() }
                .task { await diarizationSettings.runHealthCheck() }
                .task { await diarizationSettings.runStartupCheckDepsIfNeeded() }
                .task { await diarizationSettings.startAutoBootstrapIfNeeded() }
                .onAppear { wireDelegate() }
                .task { maybeRelocateBundle() }
                .task { await enqueueRecoveredRecordings() }
                .task { startMeetingDetectionIfNeeded() }
                .task { await simulateMeetingEndedIfRequested() }
                .task { await wireLiveAIPipeline() }
                .task { await injectFixtureWavIfRequested() }
                .task { await runFinalizeRegressionIfRequested() }
                .task { recordingSummarizer.backfillIfNeeded() }
                .task { voiceMemosImporter.start() }
                .environmentObject(recordingSummarizer)
                .environmentObject(meetingDetectionSettings)
                .environmentObject(voiceMemosSettings)
                .environmentObject(voiceMemosImporter)
                .environmentObject(speakerDirectory)
                .environmentObject(voiceRecognitionSettings)
                .environmentObject(speakerProfileStore)
                .environmentObject(configImporter)
                .sheet(item: Binding(
                    get: { configImporter.pending },
                    set: { if $0 == nil { configImporter.cancel() } }
                )) { pending in
                    MilaConfigConfirmationView(
                        pending: pending,
                        onApply: { configImporter.confirm() },
                        onCancel: { configImporter.cancel() }
                    )
                }
                .alert(
                    "Couldn't import configuration",
                    isPresented: Binding(
                        get: { configImporter.errorMessage != nil },
                        set: { if !$0 { configImporter.errorMessage = nil } }
                    )
                ) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text(configImporter.errorMessage ?? "")
                }
                .environmentObject(obsidianVaultSettings)
                .environmentObject(mcpAccessSettings)
                .environmentObject(obsidianExporter)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Voice Memo") {
                    Task { await actions.toggleVoiceMemo() }
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("Open Audio File…") {
                    Task { await actions.openFiles() }
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("Dictation") {
                Button("English Dictation (\(hotkeySettings.binding(for: .dictateEnglish).displayName))") {
                    Task { await dictation.toggle(action: .dictateEnglish) }
                }
                Button("Hebrew Dictation (\(hotkeySettings.binding(for: .dictateHebrew).displayName))") {
                    Task { await dictation.toggle(action: .dictateHebrew) }
                }
            }
            // Surface the diagnostic-report action under Help so a user
            // with a bug to report can hand off a zip without us asking
            // for ad-hoc Console.app exports or screenshots.
            CommandGroup(after: .help) {
                Button("Save Diagnostic Report…") {
                    Task { await saveDiagnosticReport() }
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(storageSettings)
                .environmentObject(modelManager)
                .environmentObject(hotkeySettings)
                .environmentObject(transcription)
                .environmentObject(audioInputSettings)
                .environmentObject(inputLevelMonitor)
                .environmentObject(actions)
                .environmentObject(llmSettings)
                .environmentObject(diarizationSettings)
                .environmentObject(remoteTranscriptionSettings)
                .environmentObject(meetingDetectionSettings)
                .environmentObject(liveAISettings)
                .environmentObject(voiceMemosSettings)
                .environmentObject(voiceMemosImporter)
                .environmentObject(speakerDirectory)
                .environmentObject(voiceRecognitionSettings)
                .environmentObject(speakerProfileStore)
                .environmentObject(configImporter)
                // Settings ▸ General shows the Sparkle-backed
                // "Automatically check for updates" toggle, so the Settings
                // scene needs the same single updater instance the main window
                // and the menu command use — never a second one.
                .environmentObject(updater)
                .environmentObject(obsidianVaultSettings)
                .environmentObject(mcpAccessSettings)
                .environmentObject(obsidianExporter)
        }
        // Settings used to be pinned to 700×560 by a rigid `.frame` inside
        // `SettingsView`; since #177 it is a resizable sidebar window whose
        // content declares min/ideal/max instead. `.contentSize` is what
        // turns those declarations into the window's own resize limits —
        // without it the window would not honour the minimum and could be
        // dragged narrower than the destinations can lay out in.
        .windowResizability(.contentSize)
    }

    /// Build a diagnostic zip and let the user pick where to save it.
    /// Errors surface through the standard transcription.lastError alert
    /// — there's already plumbing for showing a one-shot error toast,
    /// no need to invent a new error-presentation path for this menu
    /// item.
    private func saveDiagnosticReport() async {
        do {
            _ = try await DiagnosticReporter.saveReportInteractively(
                store: store,
                diarization: diarizationSettings
            )
        } catch {
            transcription.lastError = "Could not build diagnostic report: \(error.localizedDescription)"
        }
    }

    /// One-time per launch: if the bundle is installed at the legacy
    /// IslandWhisper.app path, offer the user a rename-and-relaunch.
    /// See `BundleRelocator` for the why + safety constraints (only
    /// runs against /Applications or ~/Applications, never overwrites
    /// an existing Mila.app at the destination, persists a skip flag
    /// if the user declines).
    private static var didCheckBundleRename = false
    private func maybeRelocateBundle() {
        guard !Self.didCheckBundleRename else { return }
        Self.didCheckBundleRename = true
        BundleRelocator.relocateIfNeeded()
    }

    private func wireDelegate() {
        appDelegate.transcription = transcription
        appDelegate.session = session
        appDelegate.dictation = dictation
        appDelegate.modelManager = modelManager
        appDelegate.actions = actions
        // Route `.milaconfig` opens through the importer, and drain any that
        // arrived during a cold launch (before this wiring ran).
        appDelegate.configImporter = configImporter
        appDelegate.flushBufferedConfigOpens()
        appDelegate.startScreenLockObserversIfNeeded()
    }

    /// Start the meeting-detection background poll + bind it to the
    /// user's enabled toggle. Called once from the main `WindowGroup`
    /// `.task` so the work is tied to the app's lifetime rather than
    /// to any single view.
    private func startMeetingDetectionIfNeeded() {
        meetingPrompt.start()
        meetingPrompt.bindEnabledChanges()
    }

    /// CI/UI-test seam for the end-of-meeting STOP prompt. With
    /// `--ui-test-simulate-meeting-ended` present we start a fake
    /// recording (no AVAudioEngine / no real Zoom) and then fire the
    /// detector's `meetingEnded` subject for Zoom, exercising the exact
    /// production path: `MeetingPromptCoordinator.handleMeetingEnd` →
    /// `showStopPanel`. The UI test then asserts the stop prompt
    /// (`meetingStopPrompt.*`) appears. Mirrors the
    /// `--ui-test-inject-fixture-wav=` injection style used elsewhere.
    @MainActor
    private func simulateMeetingEndedIfRequested() async {
        guard CommandLine.arguments.contains("--ui-test-simulate-meeting-ended") else { return }
        // Let `startMeetingDetectionIfNeeded` mount the coordinator's
        // `meetingEnded` subscription before we fire the event.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mila-fake-recording-\(UUID().uuidString).wav")
        await actions.startFakeRecordingForTesting(outputURL: outputURL)
        // Give the fake recording a moment to flip `actions.isRecording`.
        try? await Task.sleep(nanoseconds: 300_000_000)
        if let zoom = MeetingDetector.supportedApps.first {
            os.Logger(subsystem: "io.island.whisper.IslandWhisper", category: "MilaApp")
                .log("simulate-meeting-ended: firing meetingEnded for \(zoom.displayName, privacy: .public)")
            meetingDetector.meetingEnded.send(zoom)
        }
    }

    /// Wire the Live AI pipeline. Observes `RecordingSession.state` and
    /// starts/stops the live transcriber, diarizer, and LLM session
    /// when a recording is in flight + the feature is enabled +
    /// LLM is configured.
    ///
    /// CI E2E injection seam. If `--ui-test-inject-fixture-wav=PATH`
    /// is present, kicks off a fake recording (no AVAudioEngine) and
    /// pumps the WAV's samples through `session.onLiveSamples` at the
    /// real-time 16kHz rate. The rest of the pipeline (VAD →
    /// transcriber → diarizer → LiveAISession) runs exactly as in
    /// production because they all observe `session.state` / get
    /// wired by `wireLiveAIPipeline`'s `.recording` branch.
    ///
    /// Avoids depending on a real microphone or BlackHole (which
    /// doesn't reliably route audio on macos-26 CI runners).
    ///
    /// The injected samples are run through `AdaptiveGainController`
    /// before being handed to `onLiveSamples` so the E2E exercises the
    /// same gain stage that `MicrophoneRecorder` applies on a real
    /// mic. Without this the AGC e2e would be meaningless (the WAV
    /// would reach the live VAD un-boosted regardless of the toggle).
    /// `--ui-test-disable-agc` lets the test inject the raw, un-boosted
    /// signal to verify AGC is what's bridging the gap.
    @MainActor
    private func injectFixtureWavIfRequested() async {
        // The finalize-regression seam reuses `--ui-test-inject-fixture-wav=`
        // but drives its own start/pump/stop cycle through
        // `QuickActionsController`; if both ran they'd both flip
        // `session.state` and fight over the fake recording. Defer entirely
        // to `runFinalizeRegressionIfRequested` when that flag is present.
        guard !CommandLine.arguments.contains("--ui-test-finalize-regression") else { return }
        guard let arg = CommandLine.arguments.first(where: {
            $0.hasPrefix("--ui-test-inject-fixture-wav=")
        }) else { return }
        let wavPath = String(arg.dropFirst("--ui-test-inject-fixture-wav=".count))
        guard FileManager.default.fileExists(atPath: wavPath) else {
            os.Logger(subsystem: "io.island.whisper.IslandWhisper", category: "MilaApp")
                .log("inject-fixture: WAV missing at \(wavPath, privacy: .public)")
            return
        }
        let agcEnabled = !CommandLine.arguments.contains("--ui-test-disable-agc")
        // Hand wireLiveAIPipeline a moment to mount its $state observer
        // BEFORE we flip session.state — otherwise we'd transition to
        // .recording before there's a listener to react.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let sessionRef = session
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mila-fake-recording-\(UUID().uuidString).wav")
        // Start through QuickActionsController, NOT session directly. Routing
        // via `startFakeRecordingForTesting` sets `activeJob = .recording` so
        // `actions.isRecording` flips true — which is what
        // `ContentView.shouldShowLiveAIRecordingView` keys off to swap Home
        // for `LiveAIRecordingView`. Calling `session.startFakeForTesting`
        // alone only moves `session.state` to `.recording` (enough to wire the
        // live transcriber via `wireLiveAIPipeline`), but leaves `activeJob ==
        // .none`, so the app stays on Home and the `liveTranscript.*` a11y
        // elements never mount — the throughput/AGC E2Es then time out waiting
        // for a `liveTranscript.segment` that exists only in the (background)
        // pipeline, never in the view tree.
        await actions.startFakeRecordingForTesting(outputURL: outputURL)
        // Wait for wireLiveAIPipeline to install onLiveSamples (it
        // does so once the .recording case fires). Poll up to ~3s.
        for _ in 0..<60 {
            if sessionRef.onLiveSamples != nil { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        os.Logger(subsystem: "io.island.whisper.IslandWhisper", category: "MilaApp")
            .log("inject-fixture: pumping \(wavPath, privacy: .public) agc=\(agcEnabled ? "on" : "off", privacy: .public)")
        await Self.pumpFixtureWAV(path: wavPath, to: sessionRef, agcEnabled: agcEnabled)
    }

    /// CI E2E seam for the "record while the previous recording finalizes"
    /// regression (PR `fix/record-while-finalizing`). Distinct from
    /// `injectFixtureWavIfRequested` — that one pumps a single recording
    /// forever for the throughput/AGC tests; this one is TEST-DRIVEN: the UI
    /// test taps the real Record button to start / stop each recording, and
    /// this seam supplies the audio so a recording produces real live
    /// segments without a mic. It lets the UI test assert that:
    ///
    ///   1. Stop #1 frees the Record button quickly (Phase A is bounded and
    ///      `isFinalizingRecording` clears the moment the live pipeline is
    ///      drained — it is NOT held across the heavy Phase B tail). In the
    ///      buggy pre-PR code the flag was held by a blanket `defer` across
    ///      the whole finalize, so a second Start was blocked until the tail
    ///      finished.
    ///   2. Recording #2 can start and finalize while #1's heavy tail
    ///      (rediarize / SRT / summarize / transcode, or batch enqueue) is
    ///      still settling in the background, and BOTH recordings end up in
    ///      the store with their live transcripts intact (neither clobbers
    ///      the other — the id-keyed `finalizeTasks` ownership model).
    ///
    /// Triggered by `--ui-test-finalize-regression`. The button tap is
    /// routed to `QuickActionsController.startFakeRecordingForTesting`
    /// (which skips AVAudioEngine) by the `toggleRecord` interception. This
    /// task just watches `session.$state`: each time a recording starts it
    /// kicks a ONE-SHOT finite fixture pump so the live transcriber produces
    /// real segments. (The post-record rename sheet is suppressed under the
    /// same flag in `PostRecordingCoordinator.present`, so Home and the
    /// Record button stay reachable for the next tap without any dismiss
    /// dance here.)
    ///
    /// Reuses the same `--ui-test-inject-fixture-wav=` /
    /// `--ui-test-tiny-model-path=` launch args as the throughput test so
    /// the workflow wiring is shared.
    @MainActor
    private func runFinalizeRegressionIfRequested() async {
        guard CommandLine.arguments.contains("--ui-test-finalize-regression") else { return }
        guard let arg = CommandLine.arguments.first(where: {
            $0.hasPrefix("--ui-test-inject-fixture-wav=")
        }) else { return }
        let wavPath = String(arg.dropFirst("--ui-test-inject-fixture-wav=".count))
        guard FileManager.default.fileExists(atPath: wavPath) else {
            os.Logger(subsystem: "io.island.whisper.IslandWhisper", category: "MilaApp")
                .log("finalize-regression: WAV missing at \(wavPath, privacy: .public)")
            return
        }
        let sessionRef = session
        var pumpTask: Task<Void, Never>?
        // Watch for the test tapping Record (→ .recording) and Stop
        // (→ .stopping → .idle). On each fresh .recording, pump the fixture
        // once so the live transcriber produces real segments.
        for await state in sessionRef.$state.values {
            switch state {
            case .recording:
                guard pumpTask == nil else { break }
                os.Logger(subsystem: "io.island.whisper.IslandWhisper", category: "MilaApp")
                    .log("finalize-regression: .recording — arming one-shot fixture pump")
                pumpTask = Task { @MainActor in
                    // Wait for wireLiveAIPipeline to install onLiveSamples
                    // on the .recording transition before pumping (≤ ~3s).
                    for _ in 0..<60 {
                        if sessionRef.onLiveSamples != nil { break }
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                    await Self.pumpFixtureWAVOnce(path: wavPath, to: sessionRef, agcEnabled: true)
                }
            case .paused, .stopping:
                break
            case .idle:
                pumpTask?.cancel()
                pumpTask = nil
            }
        }
    }

    /// Like `pumpFixtureWAV` but pumps the fixture exactly ONCE and returns
    /// (no infinite loop). Used by the finalize-regression seam, which needs
    /// each recording to have a finite tail it can stop on. The fixture is
    /// only ~5-10s so a recording's worth of segments lands quickly even on
    /// CI's slow first whisper cold-load.
    private static func pumpFixtureWAVOnce(path: String,
                                           to session: RecordingSession,
                                           agcEnabled: Bool) async {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let (samples, sampleRate) = Self.decodeWAV(data: data) else {
            os.Logger(subsystem: "io.island.whisper.IslandWhisper", category: "MilaApp")
                .log("finalize-regression: failed to decode WAV at \(path, privacy: .public)")
            return
        }
        let agc = AdaptiveGainController(sampleRate: sampleRate, enabled: agcEnabled)
        let chunkSamples = Int(sampleRate * 0.02)  // 20ms
        let startedAt = Date()
        var pumped = 0
        var pausedFor: TimeInterval = 0
        var offset = 0
        while offset < samples.count {
            if Task.isCancelled { return }
            pausedFor += await Self.waitWhilePaused(session)
            if Task.isCancelled { return }
            let end = min(offset + chunkSamples, samples.count)
            var chunk = Array(samples[offset..<end])
            if agcEnabled {
                chunk = agc.process(chunk)
            }
            session.onLiveSamples?(ArraySlice(chunk))
            offset = end
            pumped += chunk.count
            let elapsedTarget = Double(pumped) / sampleRate
            let elapsedReal = Date().timeIntervalSince(startedAt) - pausedFor
            if elapsedTarget > elapsedReal {
                let napNs = UInt64((elapsedTarget - elapsedReal) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: napNs)
            }
        }
    }

    /// Hold an injection pump while the session is paused, and report how
    /// long the hold lasted.
    ///
    /// The pumps feed `session.onLiveSamples` directly, which sits
    /// DOWNSTREAM of `RecordingSession`'s paused capture gate — so without
    /// this they'd keep pushing fixture audio into the live transcriber
    /// across a pause, and any UI test of pause/resume would be asserting
    /// against behaviour production doesn't have. Returning the paused
    /// duration lets the caller shift its real-time pacing baseline; without
    /// that it would think it had fallen behind and dump the whole paused
    /// span in one un-paced burst on resume.
    private static func waitWhilePaused(_ session: RecordingSession) async -> TimeInterval {
        guard session.state == .paused else { return 0 }
        let began = Date()
        while session.state == .paused, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return Date().timeIntervalSince(began)
    }

    /// Read a 16kHz mono WAV from disk and feed it to
    /// `session.onLiveSamples` in 20ms chunks paced at real-time.
    /// Supports the two WAV variants the fixture generator emits:
    /// 16-bit PCM (afconvert / our concat path) and 32-bit float
    /// (RecordingSession's own output format).
    ///
    /// When `agcEnabled` is true, every chunk passes through a fresh
    /// `AdaptiveGainController` first — mirrors the path a real mic
    /// takes through `MicrophoneRecorder`, which is what makes the
    /// AGC-recovery E2E meaningful for a deliberately quiet fixture.
    private static func pumpFixtureWAV(path: String,
                                       to session: RecordingSession,
                                       agcEnabled: Bool) async {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        // Locate the "data" chunk — afconvert emits a standard
        // RIFF/WAVE so the data chunk starts at byte 44 in practice,
        // but parsing it lets us tolerate fmt chunks of different
        // sizes (e.g. with an `fact` chunk for float WAVs).
        guard let (samples, sampleRate) = Self.decodeWAV(data: data) else {
            os.Logger(subsystem: "io.island.whisper.IslandWhisper", category: "MilaApp")
                .log("inject-fixture: failed to decode WAV at \(path, privacy: .public)")
            return
        }
        // Match MicrophoneRecorder: one controller for the lifetime of
        // the (fake) recording, so attack/release smoothing accumulates
        // across chunks. `enabled=false` makes it a bit-for-bit
        // passthrough — exactly what the negative AGC test wants.
        let agc = AdaptiveGainController(sampleRate: sampleRate, enabled: agcEnabled)
        let chunkSamples = Int(sampleRate * 0.02)  // 20ms
        let startedAt = Date()
        var pumped = 0
        var pausedFor: TimeInterval = 0
        // Loop the fixture indefinitely — the test runs for ~2 min but
        // our generated fixture is only ~70s. Without looping, segments
        // plateau halfway through the test and the "no 30s stall"
        // assertion would trip on what's actually just "audio ran out".
        // Real conversations don't stop after 70s either.
        while !Task.isCancelled {
            var offset = 0
            while offset < samples.count {
                if Task.isCancelled { return }
                // Mirror the production capture gate — see `waitWhilePaused`.
                pausedFor += await Self.waitWhilePaused(session)
                if Task.isCancelled { return }
                let end = min(offset + chunkSamples, samples.count)
                // Copy out the chunk so we can mutate it in place
                // through AGC without touching the source array.
                var chunk = Array(samples[offset..<end])
                if agcEnabled {
                    chunk = agc.process(chunk)
                }
                session.onLiveSamples?(ArraySlice(chunk))
                offset = end
                pumped += chunk.count
                // Pace ourselves: stay one chunk's worth ahead of wall
                // clock so VAD / whisper run at real-time speed. The paused
                // span doesn't count as wall clock we've fallen behind.
                let elapsedTarget = Double(pumped) / sampleRate
                let elapsedReal = Date().timeIntervalSince(startedAt) - pausedFor
                if elapsedTarget > elapsedReal {
                    let napNs = UInt64((elapsedTarget - elapsedReal) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: napNs)
                }
            }
            os.Logger(subsystem: "io.island.whisper.IslandWhisper", category: "MilaApp")
                .log("inject-fixture: looping, pumped=\(pumped, privacy: .public) samples so far gain=\(agc.currentGain, privacy: .public)")
        }
    }

    /// Minimal RIFF/WAVE decoder. Returns mono Float32 samples in
    /// [-1, 1] + the sample rate, or nil on parse failure. Handles
    /// both 16-bit PCM and 32-bit float; collapses stereo to mono.
    private static func decodeWAV(data: Data) -> (samples: [Float], sampleRate: Double)? {
        guard data.count > 44 else { return nil }
        guard data.prefix(4) == Data("RIFF".utf8),
              data[8..<12] == Data("WAVE".utf8) else { return nil }
        var idx = 12
        var fmtTag: UInt16 = 0
        var channels: UInt16 = 1
        var sampleRate: UInt32 = 16_000
        var bitsPerSample: UInt16 = 16
        var dataStart = -1
        var dataLen = 0
        while idx + 8 <= data.count {
            let id = String(data: data[idx..<idx+4], encoding: .ascii) ?? ""
            let size = Int(data[idx+4..<idx+8].withUnsafeBytes { $0.load(as: UInt32.self).littleEndian })
            let payloadStart = idx + 8
            switch id {
            case "fmt ":
                fmtTag = data[payloadStart..<payloadStart+2].withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
                channels = data[payloadStart+2..<payloadStart+4].withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
                sampleRate = data[payloadStart+4..<payloadStart+8].withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
                bitsPerSample = data[payloadStart+14..<payloadStart+16].withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
            case "data":
                dataStart = payloadStart
                dataLen = size
            default:
                break
            }
            idx = payloadStart + size
            if dataStart >= 0 { break }
        }
        guard dataStart >= 0, dataStart + dataLen <= data.count else { return nil }
        let payload = data[dataStart..<dataStart+dataLen]
        var samples: [Float] = []
        if fmtTag == 1 && bitsPerSample == 16 {
            // 16-bit PCM
            let count = dataLen / 2
            samples.reserveCapacity(count / Int(channels))
            payload.withUnsafeBytes { raw in
                let i16 = raw.bindMemory(to: Int16.self)
                if channels == 1 {
                    for i in 0..<count {
                        samples.append(Float(i16[i]) / 32768.0)
                    }
                } else {
                    let frames = count / Int(channels)
                    for f in 0..<frames {
                        var sum: Float = 0
                        for c in 0..<Int(channels) {
                            sum += Float(i16[f * Int(channels) + c]) / 32768.0
                        }
                        samples.append(sum / Float(channels))
                    }
                }
            }
        } else if fmtTag == 3 && bitsPerSample == 32 {
            // 32-bit float
            let count = dataLen / 4
            samples.reserveCapacity(count / Int(channels))
            payload.withUnsafeBytes { raw in
                let f32 = raw.bindMemory(to: Float.self)
                if channels == 1 {
                    for i in 0..<count {
                        samples.append(f32[i])
                    }
                } else {
                    let frames = count / Int(channels)
                    for f in 0..<frames {
                        var sum: Float = 0
                        for c in 0..<Int(channels) {
                            sum += f32[f * Int(channels) + c]
                        }
                        samples.append(sum / Float(channels))
                    }
                }
            }
        } else {
            return nil
        }
        return (samples, Double(sampleRate))
    }

    /// MilaApp is a struct so we can't `[weak self]` here — but every
    /// dependency is a `@StateObject` (reference type), which is what
    /// the closures actually need. Captured directly by reference.
    @MainActor
    private func wireLiveAIPipeline() async {
        let transcriber = liveTranscriber
        let diarizer = liveSpeakerDiarizer
        let aiSession = liveAISession
        let aiSettings = liveAISettings
        let llmSettingsRef = llmSettings
        let diarSettings = diarizationSettings
        let langSettings = languageSettings
        let sessionRef = session
        // `actions` captured weakly so the .idle handler can read
        // its `isFinalizingRecording` flag to decide whether the
        // drain belongs here (sleep/lock/quit path) or to
        // `stopRecording` (Stop-button path).
        let actionsRef: QuickActionsController? = actions
        let sidecarWriter = liveSidecarWriter

        var feedTask: Task<Void, Never>?
        var aiEnabledCancellable: AnyCancellable?

        // Neural-VAD gate, loaded lazily once and reused across
        // recordings (this loop is long-lived). The bundled Silero
        // model is ~0.9 MB; load it the first time a recording opts in
        // and cache the result. `loadAttempted` keeps a failed load
        // (missing/corrupt model) from retrying every recording — on
        // failure we simply run without the gate (today's behaviour).
        var sileroVAD: SileroVAD?
        var sileroVADLoadAttempted = false

        // Hardware gate: re-checked PER-RECORDING (not at function
        // level) so the user can toggle `forceLiveAIOnLowEndHardware`
        // mid-session and have the next recording pick up the change.
        // The old function-level early-return meant flipping the
        // override required an app relaunch (flagged by Cursor on
        // baeeb8c: "wireLiveAIPipeline runs once at launch and returns
        // immediately when isLiveAIAvailable is false. Toggling
        // forceLiveAIOnLowEndHardware updates isLiveAIAvailable but
        // never starts the session observer").
        //
        // The state observer below runs forever now; the `.recording`
        // branch is where we gate on `aiSettings.isLiveAIAvailable`.

        // Epoch of the capture this observer has already wired. `nil` until
        // the first recording.
        var wiredCaptureEpoch: Int?
        for await state in sessionRef.$state.values {
            switch state {
            case .recording:
                // `.recording` is published twice per recording that gets
                // paused: once at start, once on resume. Only the first is a
                // new recording — re-running the setup below on a resume
                // would call `transcriber.start()`, which resets `segments` /
                // `fullText` and wipes the entire transcript the user has
                // been reading.
                //
                // Keyed on the session's capture epoch rather than on the
                // previously-observed state, because the `.paused` in between
                // is not guaranteed to be delivered: `@Published` drops values
                // published while its `.values` consumer has no outstanding
                // demand, so a fast pause→resume can arrive here as a bare
                // second `.recording`. The epoch only moves on a real
                // `start()`, so it cannot be fooled that way.
                if wiredCaptureEpoch == sessionRef.captureEpoch { break }
                wiredCaptureEpoch = sessionRef.captureEpoch
                guard aiSettings.isLiveAIAvailable else {
                    // Hardware below the Live AI bar AND no override
                    // flipped. Recording still runs via RecordingSession;
                    // QuickActionsController enqueues a post-record
                    // transcribe on stop. We just skip the live
                    // pipeline setup.
                    //
                    // BUT: clear the transcriber's `segments` /
                    // `useVAD` first. Without this, a stale live
                    // transcript from a previous recording (when the
                    // user had the override toggle on) would still be
                    // sitting in memory; `stopRecording` would
                    // snapshot it onto the new recording and could
                    // mark it `.completed` without ever running batch
                    // transcription. Cursor flagged on 62e1c3b.
                    _ = transcriber.stop()
                    sessionRef.onLiveSamples = nil
                    // Also clear LiveAISession so its rolling `summary`
                    // and `actionItems` from a previous override-enabled
                    // recording don't leak onto this gated capture.
                    // `stopRecording` reads aiSession.summary /
                    // actionItems unconditionally; without this reset,
                    // a previous Live AI session's output would attach
                    // to a recording that never ran the LLM loop.
                    // Cursor flagged on c95d2bb.
                    aiSession.cancel()
                    // Still surface the recording to external pollers
                    // (mila-mcp): they get an honest "recording, but no
                    // live text on this hardware" status instead of
                    // silence.
                    sidecarWriter.begin(title: nil, source: nil, liveAvailable: false)
                    os.Logger(subsystem: "io.island.whisper.IslandWhisper", category: "MilaApp")
                        .log("wireLiveAIPipeline: .recording skipped — hardware below Live AI bar (model=\(aiSettings.capabilities.marketingName, privacy: .public))")
                    continue
                }
                // Open the live-transcript sidecar for this recording so
                // external tools (mila-mcp) can follow the meeting; the
                // feed loop below streams content into it.
                sidecarWriter.begin(title: nil, source: nil, liveAvailable: true)
                // Live transcription runs on every recording — it's how
                // the recording UI shows the live transcript pane even
                // when AI mode is off. Apply the user's tick-interval
                // setting before start() so the running loop picks it
                // up (default 5s, settable in Settings → AI Features).
                transcriber.chunkSeconds = aiSettings.chunkSeconds
                transcriber.useVAD = aiSettings.useVAD
                // Attach the neural-VAD speech gate (drops noise-only
                // utterances before whisper). Only meaningful on the VAD
                // path; the fixed-timer path has no per-utterance gate.
                if aiSettings.useNeuralVAD && aiSettings.useVAD {
                    if !sileroVADLoadAttempted {
                        sileroVADLoadAttempted = true
                        if let vadPath = Bundle.main.path(forResource: "ggml-silero-v5.1.2", ofType: "bin") {
                            sileroVAD = try? SileroVAD(modelPath: vadPath)
                        }
                        if sileroVAD == nil {
                            os.Logger(subsystem: "io.island.whisper.IslandWhisper", category: "MilaApp")
                                .error("Neural VAD enabled but Silero model failed to load — running without the gate")
                        }
                    }
                    transcriber.speechGate = sileroVAD
                } else {
                    transcriber.speechGate = nil
                }
                // Wire each VAD-bounded utterance into the speaker
                // diarizer. Without this, diarizer.process is never
                // called, intervals stays empty, and segments never
                // get a speaker label.
                transcriber.onUtteranceCaptured = { [weak diarizer] samples, start, end in
                    // Use `submit` (chained, trackable) rather than a
                    // detached task — at end-of-recording we need to
                    // `awaitPending()` so the final utterance's
                    // speaker label is attached before the transcript
                    // is saved.
                    diarizer?.submit(samples: samples, startSeconds: start, endSeconds: end)
                }
                transcriber.start(language: langSettings.current.rawValue)
                print("wireLiveAIPipeline: .recording — installing onLiveSamples → liveTranscriber.ingest")
                sessionRef.onLiveSamples = { [weak transcriber] samples in
                    // The callback is invoked synchronously from
                    // RecordingSession.write (already @MainActor), so we
                    // can ingest directly without spawning a Task —
                    // hopping through a detached Task here was dropping
                    // the ArraySlice on some Swift-concurrency edge.
                    transcriber?.ingest(samples)
                }
                // NOTE: the Live AI session is reset deterministically at
                // record-start in QuickActionsController (`liveAISession?.start()`),
                // NOT here. Driving the reset off this async `.recording`
                // observer risked the transition being coalesced under load,
                // leaving the previous recording's session live so its first
                // tick `--resume`d the prior meeting → cross-recording bleed.
                // By the time this runs, the session has already been freshly
                // started for this recording.
                diarizer.reset()
                // Seed the embedding pool with known voices only when the
                // user opted in. `seedEntries()` refuses on its own too, and
                // while off it has nothing to hand over regardless (the
                // profiles file is never parsed) — three independent reasons
                // an opted-out recording starts from a blank pool.
                if voiceRecognitionSettings.isConfigured {
                    diarizer.seedPool(with: speakerProfileStore.seedEntries())
                }
                diarizer.similarityThreshold = aiSettings.speakerSimilarityThreshold
                // Detach the diarizer start so a quick stop-after-start
                // doesn't block the state observer on pyannote cold-init.
                // The session token (claimed synchronously HERE) lets a
                // stop() that lands before/while the detached body runs
                // supersede it — otherwise a fast start→stop recording
                // booted the ~1 GB daemon after the recording ended and
                // left it idling.
                let diarSession = diarizer.beginSession()
                Task.detached(priority: .userInitiated) { [diarizer, diarSettings] in
                    await diarizer.start(diarization: diarSettings, session: diarSession)
                }
                // Watch for off→on transitions on the Live AI toggle.
                // The feed loop only kicks when new segments land, so
                // a user who toggles Live AI on mid-recording would
                // otherwise wait up to one chunk before the LLM sees
                // anything. Mirror the feed-loop's gate here so an
                // immediate feed runs the moment the toggle flips.
                aiEnabledCancellable?.cancel()
                aiEnabledCancellable = aiSettings.$enabled
                    .dropFirst()
                    .filter { $0 }
                    .sink { [weak transcriber, weak aiSession] _ in
                        guard llmSettingsRef.isConfigured else { return }
                        if let text = transcriber?.formattedTranscript, !text.isEmpty {
                            // User just flipped Live AI on — bypass the
                            // min-interval floor for instant feedback.
                            aiSession?.feed(transcript: text, immediate: true)
                        }
                    }

                feedTask?.cancel()
                feedTask = Task { @MainActor [weak transcriber, weak diarizer, weak aiSession, weak sidecarWriter, aiSettings, llmSettingsRef] in
                    var lastFed = ""
                    guard let transcriber else { return }
                    for await _ in transcriber.$segments.values {
                        if Task.isCancelled { break }
                        // Recompute each tick — Live AI is whatever
                        // the toggle currently says. Recording started
                        // with it off + flipped on → ticks fire from
                        // now on. Recording started with it on +
                        // flipped off → ticks stop; the LLM session
                        // preserves whatever it has produced so far.
                        let aiActive = aiSettings.enabled && llmSettingsRef.isConfigured
                            && !llmSettingsRef.liveAIDisabledByRemoteOpenAI
                        // Speaker labels are a transcription feature,
                        // not an LLM feature — apply them whenever the
                        // diarizer has produced intervals, regardless
                        // of whether the user has the LLM CLI
                        // configured.
                        if let diarizer {
                            transcriber.applySpeakerLabels(diarizer.intervals)
                        }
                        // Mirror the tick to the on-disk live sidecar
                        // (throttled + deduped inside the writer).
                        let liveSegments = transcriber.segments.map {
                            TranscriptSegment(start: $0.startSeconds, end: $0.endSeconds,
                                              text: $0.text, speaker: $0.speaker)
                        }
                        sidecarWriter?.update(segments: liveSegments,
                                              speakerNames: transcriber.speakerNames)
                        if aiActive {
                            let text = transcriber.formattedTranscript
                            if text != lastFed, !text.isEmpty {
                                lastFed = text
                                aiSession?.feed(transcript: text)
                            }
                        }
                    }
                }
            case .paused:
                // A pause suspends capture but keeps the whole live
                // pipeline intact — RecordingSession simply drops incoming
                // audio while paused, so the transcriber / diarizer / feed
                // loop just see a gap and pick back up on resume. No
                // teardown (that only happens on `.idle`).
                break
            case .stopping:
                // Don't tear down yet — RecordingSession.stop() still
                // flushes the buffered system-audio tail during
                // `.stopping`, calling write() (and onLiveSamples) one or
                // two more times. We need `onLiveSamples` and the
                // transcriber to remain live so the last chunk lands in the
                // live pane and produces a final Live AI update. Cleanup
                // happens when state lands at `.idle`.
                break
            case .idle:
                feedTask?.cancel()
                feedTask = nil
                aiEnabledCancellable?.cancel()
                aiEnabledCancellable = nil
                // Coordination with QuickActionsController.stopRecording:
                // when the user hits the Stop button, stopRecording
                // sets `isFinalizingRecording = true` and runs an
                // inline drain (transcribeNow + LLM feed +
                // diarizer.awaitPending + applySpeakerLabels) so it
                // can snapshot final state, write the saved
                // Recording, and only THEN tear down the live
                // pipelines. If we ran the drain here too, the two
                // paths would race — `transcriber.stop()` could fire
                // before stopRecording reads `liveTranscriber?.
                // segments`, wiping the snapshot to empty.
                //
                // So: when stopRecording owns the lifecycle, this
                // handler does only session-level cleanup (clear
                // onLiveSamples). When stopRecording is NOT the
                // trigger — sleep / lock-screen / app-quit /
                // cancelAll — we run the full drain here so the
                // tail doesn't get lost.
                let stopRecordingOwnsFinalize = actionsRef?.isFinalizingRecording == true
                if !stopRecordingOwnsFinalize {
                    // Force one last whisper pass on whatever's in
                    // the buffer so the tail of the meeting (up to
                    // ~chunkSeconds since the previous tick) makes
                    // it into the live pane and the saved Live AI
                    // snapshot.
                    await transcriber.transcribeNow()
                    // Same idea for the LLM: if new segments just
                    // landed and Live AI is on, push one final feed.
                    if aiSettings.enabled && llmSettingsRef.isConfigured {
                        let text = transcriber.formattedTranscript
                        if !text.isEmpty {
                            // Final teardown flush — bypass the floor so
                            // the saved snapshot covers up to stop.
                            aiSession.feed(transcript: text, immediate: true)
                        }
                    }
                    _ = transcriber.stop()
                    // Drain the diarizer's chained background work
                    // BEFORE killing the daemon. The daemon stays
                    // alive until every queued embed has landed; if
                    // we stop()'d first, pending continuations would
                    // resume with `error: "stopped"` and the final
                    // utterance would lose its speaker label.
                    await diarizer.awaitPending()
                    diarizer.stop()
                    // This branch owns the whole teardown, so kill the Live
                    // AI session with the rest of it: otherwise a tick
                    // deferred by the min-interval floor can still wake and
                    // spawn a `claude` child while the app is tearing down
                    // AVAudioEngine (CodeRabbit on #113). Safe to clear
                    // `summary` / `actionItems` here — the only path that
                    // reaches this branch today is `cancelAll()` at app
                    // termination, which by design does NOT flush a WAV or
                    // assemble a Recording (the orphan WAV is recovered on
                    // next launch instead), so there is no snapshot to
                    // protect. Sleep and screen-lock both route through
                    // `stopRecording`, which owns finalize and cancels the
                    // session itself once its snapshot is stored.
                    aiSession.cancel()
                    // Close the live sidecar with no handoff id — this
                    // teardown path (sleep/lock/quit/cancelAll) has no
                    // saved Recording yet; the Stop-button path closes
                    // it from stopRecording with the real id instead.
                    sidecarWriter.finish(recordingID: nil)
                }
                // Note: no aiSession.cancel() out here, outside the branch
                // above — this handler fires during `session.stop()`,
                // BEFORE QuickActionsController has read .summary /
                // .actionItems for the saved Recording, and `cancel()`
                // clears both. When `stopRecording` owns finalize it
                // cancels the session itself, after its snapshot is
                // safely in the store; it's the only path that knows
                // when that is.
                sessionRef.onLiveSamples = nil
            }
        }
    }

    /// Recovery decision for one recording left over from a previous
    /// session, factored out of `enqueueRecoveredRecordings` so the launch
    /// sweep is unit-testable without the App/SwiftUI lifecycle.
    enum RecoveryAction: Equatable {
        case reenqueue    // hand back to the transcription worker
        case markFailed   // audio is gone — stop the row from retrying
        case leaveAlone   // terminal / already settled
    }

    /// `.running` (died mid-transcription) and `.pending` (queued but never
    /// started) are both mid-flight leftovers the fresh worker won't resume
    /// on its own: re-enqueue when the `.wav` survives, else `.failed`.
    /// `.completed` / `.failed` are terminal and left untouched.
    static func recoveryAction(status: TranscriptionStatus, wavExists: Bool) -> RecoveryAction {
        switch status {
        case .running, .pending:
            return wavExists ? .reenqueue : .markFailed
        case .completed, .failed:
            return .leaveAlone
        }
    }

    /// Crash-recovery sweep + stale-status cleanup. Two things happen
    /// here at launch:
    ///   1. Any recording left mid-flight from a previous session is
    ///      re-enqueued — both `.running` (the app died while whisper was
    ///      mid-transcription OR the stop-time live-drain in
    ///      `QuickActionsController` was still in flight) and `.pending`
    ///      (queued but never started before the app quit). The worker on
    ///      this fresh process boots with an empty queue and won't touch
    ///      either unless we hand it back, so a `.pending` row would
    ///      otherwise sit in the Queue forever showing "Queued" and a
    ///      `.running` row would never advance. `.running` is first reset to
    ///      `.pending`; both are re-enqueued provided the `.wav` is still on
    ///      disk. If the WAV is gone we fall back to `.failed` so the row
    ///      doesn't loop forever trying to read a missing file.
    ///   2. Orphan .wav files re-attached by RecordingStore as
    ///      `.pending` are enqueued for transcription so the user
    ///      gets a usable transcript on the next launch without
    ///      having to do anything.
    /// The silent-/short-audio rejection inside TranscriptionService
    /// no longer pops a modal alert; the recording is just marked
    /// `.failed` in the list so empty orphans don't nag the user at
    /// launch.
    private func enqueueRecoveredRecordings() async {
        // 1. Resurrect stale mid-flight recordings. The current process
        //    hasn't started its worker loop yet, so anything still flagged
        //    `.running` (died mid-transcription) or `.pending` (queued but
        //    never started) is a leftover the new worker won't resume on its
        //    own. `enqueue` is idempotent, so a row also re-attached as a
        //    recovered orphan in step 2 is still enqueued at most once.
        let fm = FileManager.default
        // Collect the status changes and re-enqueues, then persist once at the
        // end. `store.update(_:)` rewrites the whole recordings file per call,
        // so a large synced library (dozens of stale `.pending` rows) would
        // otherwise fire a burst of synchronous full-file writes on launch.
        var statusChanged: [Recording] = []
        var toEnqueue: [Recording] = []
        for recording in store.recordings
        where recording.status == .running || recording.status == .pending {
            let wavURL = store.audioURL(for: recording)
            var fixed = recording
            switch Self.recoveryAction(status: recording.status,
                                       wavExists: fm.fileExists(atPath: wavURL.path)) {
            case .reenqueue:
                // Audio still on disk: re-queue for a fresh batch run rather
                // than stranding the row at `.failed` (no self-serve recovery
                // path). `.running` is reset to `.pending`; an already
                // `.pending` row is re-enqueued as-is.
                // A crash skips AVAudioFile.close(), so the WAV header still
                // advertises 0 audio frames — the transcription reader would
                // see an empty file. Rewrite the size fields from the physical
                // length first so the recovered run actually gets the audio.
                // Off the main actor: the repair is blocking file I/O, and in
                // an iCloud-backed recordings folder opening a dataless `.wav`
                // can stall for seconds. Awaited here, so the file is repaired
                // before this row reaches `toEnqueue` (and the `enqueue` pass
                // below).
                await WAVHeaderRepair.repairInBackground(at: wavURL)
                if fixed.status != .pending {
                    fixed.status = .pending
                    statusChanged.append(fixed)
                }
                print("MilaApp: re-enqueuing stale \(recording.status.rawValue) recording \(recording.audioFileName)")
                toEnqueue.append(fixed)
            case .markFailed:
                fixed.status = .failed
                statusChanged.append(fixed)
                print("MilaApp: reset stale \(recording.status.rawValue) recording \(recording.audioFileName) to .failed (WAV missing)")
            case .leaveAlone:
                break  // unreachable given the `where` filter above
            }
        }
        store.updateAll(statusChanged)          // single persist for the whole sweep
        // Recovered rows are re-runs of transcriptions that were already
        // in flight before the app quit — never a fresh capture. Mark them
        // as re-transcriptions so the issue-#61 auto-drop gate can't delete
        // one (e.g. a mid-retranscribe of an empty-transcript recording that
        // crashed) just because the recovered rerun comes back short + empty.
        toEnqueue.forEach { transcription.enqueue($0, isRetranscription: true) }

        // 2. Auto-enqueue recovered orphans.
        let ids = store.consumePendingRecoveryIDs()
        guard !ids.isEmpty else { return }
        for id in ids {
            guard let recording = store.recordings.first(where: { $0.id == id }) else { continue }
            // Orphan WAVs from a crash have an unfinalized header (see the
            // reenqueue branch above) — repair it, off the main actor, before
            // the batch run reads it. Awaited so this recording is only
            // enqueued once its own repair has finished.
            await WAVHeaderRepair.repairInBackground(at: store.audioURL(for: recording))
            print("MilaApp: re-enqueuing recovered recording \(recording.audioFileName)")
            transcription.enqueue(recording)
        }
    }

    /// Kick the engine's `loadIfNeeded` on the user's default model
    /// once at launch. The first time whisper.cpp loads a model with
    /// a sibling `-encoder.mlmodelc` on a given device, CoreML
    /// compiles the mlmodelc for that hardware — ~13s peg on M-series
    /// the very first time, then fully cached. Doing this at launch
    /// (rather than on the user's first Record press) means the
    /// preparation banner shows BEFORE the user reaches for the
    /// button, and any too-eager Record press during the window finds
    /// the model already loaded.
    private func prewarmDefaultModel() {
        // Skip prewarm under UI tests. No UI test relies on a launch-time
        // warm — the transcription E2E tests pass `--ui-test-tiny-model-path=`
        // and load on demand — so warming the (potentially multi-GB) default
        // model here just burns CPU/IO on every UI-test launch and creates a
        // whisper/Metal context that XCTest never frees (it exits via
        // `exit()`, bypassing `gracefulShutdown()`), which is what prints the
        // ggml-metal teardown backtrace at process exit.
        guard !isRunningUITests else { return }
        // No local weights to warm when the remote backend is selected.
        guard !remoteTranscriptionSettings.isActive else { return }
        transcription.prewarm(language: languageSettings.current.rawValue)
    }

    /// True when the process was launched by an XCUITest run. Keyed off the
    /// `--uitests` / `--ui-test-*` launch arguments the UI test targets pass.
    private var isRunningUITests: Bool {
        CommandLine.arguments.contains { $0 == "--uitests" || $0.hasPrefix("--ui-test") }
    }

    /// Pre-download the two default models on first launch:
    ///   - ivrit.ai large-v3 (Hebrew dictation, ~3 GB)
    ///   - OpenAI turbo (English dictation, ~1.6 GB)
    /// We start them in parallel — `ModelManager` queues them through the
    /// same `URLSession` so they don't actually saturate the network, and
    /// the in-app banner shows whichever is currently selected.
    private func ensureDefaultModelsInstalled() {
        // Skip the multi-GB local model downloads + CoreML prep entirely for
        // users who've opted into the remote backend — they don't need any
        // local weights. (The Models tab still offers manual downloads, and
        // switching back to local re-triggers this on next launch.)
        guard !remoteTranscriptionSettings.isActive else { return }
        modelManager.setSelected(WhisperModel.ivritLarge)
        for model in [WhisperModel.ivritLarge, WhisperModel.openaiTurbo] {
            if !modelManager.isInstalled(model) && modelManager.downloads[model.name] == nil {
                modelManager.download(model)
            }
        }
        // Pick up any sibling `-encoder.mlmodelc` that's missing for an
        // already-installed `.bin`. New users get the CoreML zip via the
        // post-`.bin`-install hook in ModelManager; this catches the
        // upgrade case (existing 1.7 users who already have the .bin on
        // disk from a previous run).
        modelManager.ensureCoreMLInstalled()
    }
}

/// Owns the graceful shutdown sequence.
///
/// The on-disk crash reports (IvritWhisper-2026-05-08-*.ips) all show the
/// same backtrace: `[NSApp terminate:]` -> `exit()` -> `__cxa_finalize_ranges`
/// -> `~vector<unique_ptr<ggml_metal_device>>` -> `ggml_metal_rsets_free`
/// -> `ggml_abort` (because the rsets-init dispatch block hadn't completed
/// yet). The fix is to release the `whisper_full` context and tear down the
/// recording / dictation / network stacks while we're still in a normal
/// runtime state, BEFORE letting `terminate:` call `exit()`.
@MainActor
final class MilaAppDelegate: NSObject, NSApplicationDelegate {
    weak var transcription: TranscriptionService?
    weak var session: RecordingSession?
    weak var dictation: DictationController?
    weak var modelManager: ModelManager?
    weak var actions: QuickActionsController?
    weak var configImporter: MilaConfigImporter?

    private var didShutDown = false
    private var screenLockObserversInstalled = false
    /// `.milaconfig` URLs delivered by a cold launch (double-click while Mila
    /// was not running) before `wireDelegate()` connected the importer. Drained
    /// by `flushBufferedConfigOpens()`.
    private var bufferedConfigURLs: [URL] = []

    /// macOS calls this when the user double-clicks / drops a file the app
    /// declares it opens (`CFBundleDocumentTypes` in Info.plist). We only claim
    /// `.milaconfig`; anything else is ignored.
    func application(_ application: NSApplication, open urls: [URL]) {
        let configURLs = urls.filter {
            $0.pathExtension.lowercased() == MilaConfig.fileExtension
        }
        guard !configURLs.isEmpty else { return }
        Task { @MainActor in
            if let importer = self.configImporter {
                configURLs.forEach { importer.handleOpen($0) }
            } else {
                // Cold launch: hold until the importer is wired in.
                self.bufferedConfigURLs.append(contentsOf: configURLs)
            }
        }
    }

    /// Deliver any config opens that arrived before the importer was wired.
    @MainActor
    func flushBufferedConfigOpens() {
        guard let importer = configImporter, !bufferedConfigURLs.isEmpty else { return }
        let urls = bufferedConfigURLs
        bufferedConfigURLs.removeAll()
        urls.forEach { importer.handleOpen($0) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if didShutDown { return .terminateNow }
        didShutDown = true
        Task { @MainActor [weak self] in
            await self?.gracefulShutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Backstop: if `applicationShouldTerminate` was bypassed (e.g. a force
        // quit through the dock), we still get a chance to free the metal
        // context here. A second call is a no-op via `didShutDown`.
        if !didShutDown {
            didShutDown = true
            Task { @MainActor [weak self] in await self?.gracefulShutdown() }
        }
    }

    /// Subscribe to the events that affect a live recording:
    ///   1. `willSleepNotification` — system about to sleep (lid close on
    ///      battery, sleep menu, low-battery). We have ~1–2 s to flush
    ///      the WAV and tag the recording so the wake-up alert can show
    ///      duration + "stopped because the Mac slept".
    ///   2. `didWakeNotification` — system woke. Surfaces the alert.
    ///   3. `com.apple.screenIsLocked` (distributed center) — explicit
    ///      Lock Screen / hot corner. Stops the recording for privacy
    ///      (no in-flight buffering past a deliberately-secured screen)
    ///      but does NOT fire the sleep alert: this is a user action,
    ///      not an interruption.
    ///
    /// We deliberately stopped observing `screensDidSleepNotification`:
    /// it fires for the display sleep timer too, and now that we hold an
    /// IOPMAssertion while recording, the user expects the recording to
    /// keep running when they walk away from the keyboard.
    ///
    /// `SleepGuard` also holds a `PreventUserIdleDisplaySleep` assertion
    /// while recording, which suppresses the idle screensaver/auto-lock.
    /// So `com.apple.screenIsLocked` now only fires for the *deliberate*
    /// locks above — the automatic "lock after X minutes" that used to
    /// cut meeting captures short no longer reaches this observer.
    ///
    /// We stop recording rather than discard it: the user's working
    /// assumption is "the conversation is over, I want the bit I captured
    /// saved + transcribed", not "throw it away". Dictation IS discarded
    /// because there is no recipient app to paste into once the screen is
    /// locked.
    ///
    /// Idempotent — `wireDelegate()` fires every time SwiftUI re-runs
    /// `.onAppear`, and we MUST NOT register two observers for the same
    /// event.
    func startScreenLockObserversIfNeeded() {
        guard !screenLockObserversInstalled else { return }
        screenLockObserversInstalled = true

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self,
            selector: #selector(handleWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspace.addObserver(
            self,
            selector: #selector(handleDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        // Screen-lock from Control Center / hot corner posts here. macOS
        // does NOT publish this via NSWorkspace — it's only on the
        // distributed center, under a string name. Without this observer,
        // recordings would only stop on lid close, not on "Lock Screen".
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleScreenLock(_:)),
            name: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil
        )

        // Kill the inconsistent toolbar separator (a thin hairline that
        // appears under the toolbar in the detail pane but not in the
        // sidebar, looks broken). NavigationSplitView re-applies the
        // toolbar configuration on every layout pass, so a single set
        // via NSViewRepresentable doesn't stick — we have to reapply
        // whenever a window becomes key.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(stripToolbarSeparator(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        // Apply once now in case the main window is already key by the
        // time observers are installed.
        for window in NSApp.windows {
            applyChrome(to: window)
        }

        // Re-apply on every sidebar visibility flip so the freshly-
        // added NSVisualEffectView in the reopened sidebar gets its
        // blending mode pinned to .withinWindow before the user sees
        // the default .behindWindow material flash through.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSidebarVisibilityChange(_:)),
            name: .milaSidebarVisibilityDidChange,
            object: nil
        )
    }

    @objc private func handleSidebarVisibilityChange(_ notification: Notification) {
        // SwiftUI hasn't necessarily finished re-creating the AppKit
        // hierarchy by the time the visibility flip fires — defer to
        // the next runloop spin so our walk catches the new view.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for window in NSApp.windows {
                self.applyChrome(to: window)
            }
        }
    }

    @objc private func stripToolbarSeparator(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        applyChrome(to: window)
    }

    /// Whether `applyChrome` must leave a window alone.
    ///
    /// Pure and `static` so the decision is unit-testable without an
    /// `NSWindow` — see `WindowChromeExemptionTests`. The two exemptions
    /// are deliberately different shapes, because identifiers turn out
    /// to be a usable discriminator for only one of them:
    ///
    /// - **Settings** is matched on its identifier, lowercased. SwiftUI
    ///   names that window `com_apple_SwiftUI_Settings_window` — capital
    ///   `S`. The original guard tested `id.contains("settings")`, which
    ///   is case-sensitive and therefore never matched, so the early
    ///   return never fired and this whole method ran on the Settings
    ///   window on every `didBecomeKeyNotification` (#207). Lowercasing
    ///   once and comparing is what actually honours the intent.
    ///
    /// - **Panels** are matched on their *class*, not their identifier,
    ///   and this replaces the old `id.contains("alert")` arm rather
    ///   than merely case-correcting it. That arm could never have
    ///   worked: an `NSAlert`'s window is an `_NSAlertPanel` whose
    ///   identifier is an opaque AppKit nib id — `_NS:87` when probed on
    ///   macOS 26 — containing no recognisable substring in any case,
    ///   and not something to depend on across OS versions. A bare
    ///   `NSPanel` and an `NSOpenPanel` report no identifier at all, so
    ///   `if let id = window.identifier` fell through for them too and
    ///   they were also being restyled. Alerts, open/save panels, and
    ///   the dictation overlay are all `NSPanel`s, and none of them
    ///   wants a toolbar-separator tweak; the main window is a plain
    ///   `NSWindow`, so it is unaffected.
    /// `nonisolated` because it is pure — it touches no delegate state and
    /// needs no main-actor context, which is also what lets the unit tests
    /// call it synchronously.
    nonisolated static func isChromeExempt(identifier: String?, isPanel: Bool) -> Bool {
        if isPanel { return true }
        guard let identifier else { return false }
        return identifier.lowercased().contains("settings")
    }

    /// Apply Mila's window chrome tweaks to a single NSWindow. Strips
    /// the hairline separator that renders below the toolbar in the
    /// detail pane but stops at the sidebar splitter — looks like a
    /// broken half-divider.
    ///
    /// Both `titlebarSeparatorStyle` (the modern, macOS 11+ property)
    /// and the deprecated `NSToolbar.showsBaselineSeparator` are zeroed
    /// out because they govern different layers — depending on the
    /// macOS version + SwiftUI version, either or both can produce the
    /// line. Setting both is harmless and covers everything.
    private func applyChrome(to window: NSWindow) {
        if Self.isChromeExempt(identifier: window.identifier?.rawValue,
                               isPanel: window is NSPanel) {
            return
        }
        // Belt and suspenders: queue the property change behind any
        // SwiftUI layout passes that might be re-applying the default
        // separator style.
        DispatchQueue.main.async {
            window.titlebarSeparatorStyle = .none
            window.toolbar?.showsBaselineSeparator = false
            // (Tried `setAutorecalculatesContentBorderThickness` here
            // too — it only works on the deprecated "textured" window
            // style and throws NSInvalidArgumentException on regular
            // windows. Don't add it back.)

            // Freeze the sidebar's vibrant material so it stops
            // shifting color when the user drags the window across
            // other apps. Cross-app color sampling is what
            // NSVisualEffectView with `.behindWindow` blending mode
            // does — switching the sidebar's effect views to
            // `.withinWindow` makes them sample only Mila's own
            // content, which is uniform, so the card stays a stable
            // gray. The card's shape (rounded corners, floating
            // inset) is untouched.
            if let contentView = window.contentView {
                self.freezeSidebarMaterials(in: contentView)
            }
        }
    }

    /// Locate the NSSplitView under `view` and switch every
    /// NSVisualEffectView in its sidebar pane to `.withinWindow`
    /// blending. Restricting the walk to the sidebar pane (the first
    /// arranged subview of the split view) is what makes this safe to
    /// run repeatedly — we don't touch the detail pane's chrome.
    private func freezeSidebarMaterials(in view: NSView) {
        if let split = view as? NSSplitView,
           let sidebar = split.arrangedSubviews.first {
            applyWithinWindowBlending(to: sidebar)
            return
        }
        for sub in view.subviews {
            freezeSidebarMaterials(in: sub)
        }
    }

    private func applyWithinWindowBlending(to view: NSView) {
        if let effect = view as? NSVisualEffectView {
            // `.withinWindow` blends with content layered behind this
            // view inside the same window, not whatever's behind the
            // window itself. The visual on top of the material — text,
            // icons, selection highlights — is unaffected.
            effect.blendingMode = .withinWindow
        }
        for sub in view.subviews {
            applyWithinWindowBlending(to: sub)
        }
    }

    /// System is about to sleep (lid close on battery, low battery, sleep
    /// menu). We race the system sleep timer to flush the WAV — the
    /// `stopBecauseOfSleep` path stashes the metadata so the wake-up
    /// alert can show duration + "stopped by sleep".
    @objc private func handleWillSleep(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let actions = self.actions, actions.isRecording {
                print("Sleep guard: stopping recording before system sleeps")
                await actions.stopBecauseOfSleep()
            }
            if let dictation = self.dictation, case .recording = dictation.state {
                print("Sleep guard: cancelling dictation before system sleeps")
                await dictation.cancelInFlight()
            }
        }
    }

    /// System woke. Nudge the controller so its `sleepInterruption`
    /// publish-flag re-triggers any SwiftUI subscribers that were
    /// suspended over the sleep window.
    @objc private func handleDidWake(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.actions?.notifyDidWake()
        }
    }

    @objc private func handleScreenLock(_ notification: Notification) {
        Task { @MainActor [weak self] in await self?.pauseForScreenLock(reason: "screen locked") }
    }

    /// Stop whatever the user was doing because they're no longer at the
    /// machine. Active recording finalizes and goes to transcription as if
    /// the user had hit Stop. Active dictation is dropped (a synthesized
    /// ⌘V into a locked screen is at best useless, at worst leaks the
    /// transcript onto the lock-screen password field).
    ///
    /// This only runs for *deliberate* locks: while recording, `SleepGuard`
    /// holds a display-sleep assertion that prevents the idle auto-lock from
    /// firing, so reaching here means the user explicitly locked the screen.
    private func pauseForScreenLock(reason: String) async {
        guard let actions else { return }
        if actions.isRecording {
            print("Screen-lock guard: stopping active recording (\(reason))")
            await actions.stopRecording()
        }
        if let dictation, case .recording = dictation.state {
            print("Screen-lock guard: cancelling active dictation (\(reason))")
            await dictation.cancelInFlight()
        }
    }

    private func gracefulShutdown() async {
        // Stop any active recording / dictation cleanly so AVAudioEngine and
        // SCStream release the user's mic / screen-recording grant.
        await session?.cancelAll()
        await dictation?.cancelInFlight()
        // Tear down the URLSession <-> ModelManager retain cycle and cancel
        // in-flight downloads.
        modelManager?.shutdown()
        // Free whisper.cpp context (and via it, the ggml-metal devices) BEFORE
        // libc++ static destructors run. See class doc for the why.
        await transcription?.shutdown()
        // Yield so pending dispatch blocks queued by ggml-metal
        // (rsets-init, etc.) have a chance to drain before libc++
        // static destructors run. 50ms was enough for the
        // chunk-based path; with VAD's higher transcribe frequency
        // we observed SIGABRT in ggml_metal_rsets_free at exit on
        // macOS 26 — bumping to 500ms gives the init blocks more
        // breathing room. Cost: quit takes ~half a second longer.
        try? await Task.sleep(nanoseconds: 500_000_000)
        HotkeyManager.shared.shutdown()
    }
}
