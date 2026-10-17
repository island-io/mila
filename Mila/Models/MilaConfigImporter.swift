import Foundation
import Combine
import os

/// Loads a `.milaconfig`, previews the changes it would make, and — once the
/// user confirms — applies the present fields onto the app's live settings
/// objects. Absent fields are left untouched (see `MilaConfig`).
///
/// Only settings that make sense to carry between machines are handled here:
/// the remote transcription server, the recording language, and the feature
/// toggles. Deliberately excluded — because they don't transfer meaningfully:
///   - the selected audio input device UID (machine-specific hardware),
///   - the recordings-directory security-scoped bookmark (path + per-machine
///     sandbox grant), and
///   - per-key hotkey bindings.
///
/// Constructed once in `MilaApp.init()` and injected via `.environmentObject`;
/// the file-open handler in `MilaAppDelegate` calls `handleOpen(_:)`.
@MainActor
final class MilaConfigImporter: ObservableObject {

    /// One human-readable "this will change" line for the confirmation sheet.
    struct PlannedChange: Identifiable, Equatable {
        let id = UUID()
        /// e.g. "Transcription server".
        let label: String
        /// The value the setting will be set to (secrets are masked).
        let value: String
    }

    /// A parsed config staged for the user to confirm. `Identifiable` so it can
    /// drive a `.sheet(item:)`.
    struct PendingImport: Identifiable {
        let id = UUID()
        let config: MilaConfig
        let changes: [PlannedChange]
        /// Labels of settings the file sets but a configuration profile
        /// locks — listed in the sheet as "managed by your organization" and
        /// left alone by `apply`. Managed settings outrank a `.milaconfig`.
        var managedSkipped: [String] = []
        /// The file name it came from, shown in the sheet.
        let sourceName: String
    }

    /// Non-nil while a confirmation sheet should be shown.
    @Published var pending: PendingImport?
    /// Non-nil to surface a load/parse error to the user.
    @Published var errorMessage: String?

    private let remote: RemoteTranscriptionSettings
    private let language: RecordingLanguageSettings
    private let liveAI: LiveAISettings
    private let diarization: DiarizationSettings
    private let meetingDetection: MeetingDetectionSettings
    /// The configuration profile's locked fields — the same snapshot
    /// `MilaApp` hands the settings objects. Managed fields outrank a
    /// `.milaconfig`: they are left out of the diff and the apply.
    private let managed: ManagedSettings
    private let log = Logger(subsystem: "io.island.whisper.IslandWhisper", category: "MilaConfig")

    init(remote: RemoteTranscriptionSettings,
         language: RecordingLanguageSettings,
         liveAI: LiveAISettings,
         diarization: DiarizationSettings,
         meetingDetection: MeetingDetectionSettings,
         managed: ManagedSettings = .empty) {
        self.remote = remote
        self.language = language
        self.liveAI = liveAI
        self.diarization = diarization
        self.meetingDetection = meetingDetection
        self.managed = managed
    }

    // MARK: - Open / confirm / cancel

    /// Entry point from the file-open handler. Loads and stages the config for
    /// confirmation; parse failures surface via `errorMessage`.
    func handleOpen(_ url: URL) {
        // The file may live outside the app's sandbox-granted locations (e.g. a
        // download the user double-clicked). Take a security scope if one is
        // offered — harmless when it isn't.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let config = try MilaConfig.load(from: url)
            pending = PendingImport(config: config,
                                    changes: plannedChanges(for: config),
                                    managedSkipped: managedSkipped(for: config),
                                    sourceName: url.lastPathComponent)
            // The FILENAME is user-chosen — a `.milaconfig` handed round a
            // team is commonly named for the org or the server it configures
            // ("acme-asr.milaconfig"), which is the same "names an employer or
            // a customer" exposure as the storage folder. The change count is
            // the diagnostic and stays public. (Issue #213.)
            log.log("""
                staged \(url.lastPathComponent, privacy: .private) for import \
                (\(self.pending?.changes.count ?? 0, privacy: .public) change(s))
                """)
        } catch {
            // `errorMessage` is the sheet the user is looking at — it keeps
            // the full text, including the quoted filename. The LOG does not:
            // the success line above redacts `url.lastPathComponent` for a
            // reason, and `String(describing:)` on a
            // `MilaConfig.LoadError.unreadable` published exactly that name
            // (plus its containing folder) right back, because the case wraps
            // `Data(contentsOf:).localizedDescription`. Same success-redacted
            // / failure-public asymmetry Bugbot found in `WAVHeaderRepair`.
            // The failure KIND stays public; the message goes `.private` so it
            // is still there for anyone who enables private-data logging.
            // (Issue #213, CWE-532.)
            errorMessage = (error as? MilaConfig.LoadError)?.errorDescription
                ?? error.localizedDescription
            log.error("""
                failed to load config: \
                \(MilaConfig.LoadError.logMessage(for: error), privacy: .public) \
                (\(String(describing: error), privacy: .private))
                """)
        }
    }

    /// Apply the staged config and clear the pending state.
    func confirm() {
        guard let pending else { return }
        apply(pending.config)
        self.pending = nil
    }

    /// Dismiss the staged config without applying it.
    func cancel() { pending = nil }

    // MARK: - Diff (for the confirmation sheet)

    /// The human-readable changes a config would make against the *current*
    /// settings, skipping fields that already match — so the sheet lists only
    /// genuine changes. A present-but-equal field is a no-op, and so is a
    /// field a configuration profile manages (see `managedSkipped(for:)`).
    func plannedChanges(for config: MilaConfig) -> [PlannedChange] {
        var out: [PlannedChange] = []
        let config = unmanagedFields(of: config)

        if let r = config.remoteTranscription {
            if let enabled = r.enabled {
                let target: TranscriptionBackend = enabled ? .remote : .local
                if target != remote.backend {
                    out.append(.init(label: ManagedField.backend.label, value: target.displayName))
                }
            }
            if let endpoint = r.endpoint, endpoint != remote.endpoint {
                out.append(.init(label: ManagedField.endpoint.label, value: endpoint))
            }
            if let model = r.model, model != remote.model {
                out.append(.init(label: ManagedField.model.label, value: model))
            }
            if let englishModel = r.englishModel, englishModel != remote.englishModel {
                out.append(.init(label: ManagedField.englishModel.label,
                                 value: englishModel.isEmpty ? "Same as Model" : englishModel))
            }
            if let apiKey = r.apiKey, apiKey != remote.apiKey {
                out.append(.init(label: ManagedField.apiKey.label, value: Self.mask(apiKey)))
            }
        }
        if let langCode = config.recordingLanguage {
            let target = RecordingLanguage.fromCode(langCode)
            if target != language.current {
                out.append(.init(label: ManagedField.recordingLanguage.label, value: target.displayName))
            }
        }
        if let live = config.liveAI {
            if let enabled = live.enabled, enabled != liveAI.enabled {
                out.append(.init(label: ManagedField.liveAIEnabled.label, value: enabled ? "On" : "Off"))
            }
            if let model = live.model, model != liveAI.model {
                out.append(.init(label: ManagedField.liveAIModel.label, value: model))
            }
        }
        if let d = config.diarization, let enabled = d.enabled, enabled != diarization.isEnabled {
            out.append(.init(label: ManagedField.diarizationEnabled.label, value: enabled ? "On" : "Off"))
        }
        if let m = config.meetingDetection, let enabled = m.enabled, enabled != meetingDetection.enabled {
            out.append(.init(label: ManagedField.meetingDetectionEnabled.label, value: enabled ? "On" : "Off"))
        }
        return out
    }

    // MARK: - Managed settings (configuration profile)

    /// Labels of the settings `config` sets that a configuration profile
    /// manages. Those are not applied — managed outranks `.milaconfig` — and
    /// the sheet says so rather than letting them vanish silently. Listed
    /// whether or not the value differs: the user should learn that the file's
    /// value for that setting is not one they control.
    func managedSkipped(for config: MilaConfig) -> [String] {
        lockedFields(in: config).map(\.label)
    }

    /// `config` with every field a configuration profile manages removed, so
    /// the diff and the apply both act only on what the user may change. Both
    /// this and `managedSkipped(for:)` come from `lockedFields(in:)`, so the
    /// sheet and the outcome can't disagree.
    func unmanagedFields(of config: MilaConfig) -> MilaConfig {
        var out = config
        for field in lockedFields(in: config) { field.remove(from: &out) }
        return out
    }

    /// The fields `config` sets that `managed` locks, in `ManagedField` order.
    private func lockedFields(in config: MilaConfig) -> [ManagedField] {
        ManagedField.allCases.filter { managed.isManaged($0) && $0.isPresent(in: config) }
    }

    // MARK: - Apply

    /// Override every present field; leave absent fields untouched. Fields a
    /// configuration profile manages are dropped first — the settings objects
    /// would refuse them anyway, but skipping them here keeps a managed API
    /// key's slot from ever seeing the file's value.
    func apply(_ config: MilaConfig) {
        let config = unmanagedFields(of: config)
        if let r = config.remoteTranscription {
            // Set endpoint/model/key BEFORE flipping the backend. Switching to
            // `.remote` triggers `RemoteTranscriptionSettings`' lazy Keychain
            // read; setting the key first means that read sees a non-empty
            // in-memory value and won't overwrite the key we're applying with a
            // stale stored one.
            if let endpoint = r.endpoint { remote.endpoint = endpoint }
            if let model = r.model { remote.model = model }
            if let englishModel = r.englishModel { remote.englishModel = englishModel }
            if let apiKey = r.apiKey { remote.apiKey = apiKey }
            if let enabled = r.enabled { remote.backend = enabled ? .remote : .local }
        }
        if let langCode = config.recordingLanguage {
            language.current = RecordingLanguage.fromCode(langCode)
        }
        if let live = config.liveAI {
            if let enabled = live.enabled { liveAI.enabled = enabled }
            if let model = live.model { liveAI.model = model }
        }
        if let d = config.diarization, let enabled = d.enabled {
            diarization.isEnabled = enabled
        }
        if let m = config.meetingDetection, let enabled = m.enabled {
            meetingDetection.enabled = enabled
        }
        log.log("applied configuration")
    }

    /// Mask a secret for display: keep the last 4 chars, dot out the rest.
    static func mask(_ secret: String) -> String {
        let visible = 4
        guard secret.count > visible else { return String(repeating: "•", count: 8) }
        return String(repeating: "•", count: 8) + secret.suffix(visible)
    }
}
