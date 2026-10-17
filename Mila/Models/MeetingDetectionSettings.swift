import Foundation
import Combine

/// User-facing toggle + per-app silencing for the meeting auto-prompt.
///
/// The prompt asks "Start transcribing?" when a meeting app (Zoom for
/// now — Google Meet / Teams are easy to add later) is detected in a live
/// meeting. Two pieces of state are persisted:
///
///   * `enabled` — global on/off. ON by default; the toggle lives in
///     Settings → Meetings.
///   * `disabledBundleIDs` — apps the user said "stop asking for this"
///     about, via the prompt's overflow chevron. Stored as a comma-
///     separated string in UserDefaults so it survives launches without
///     a custom Codable property list.
///
/// There used to be a 60-minute per-app *snooze* on dismiss — a workaround
/// for the old window-title detector that couldn't tell one meeting from
/// the next. `MeetingDetector` now re-arms reliably when a meeting ends
/// (mic capture stops), so "Not now" simply declines the current meeting
/// and the next one prompts again; no app-wide snooze is needed.
@MainActor
final class MeetingDetectionSettings: ObservableObject {
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled) }
    }
    @Published private(set) var disabledBundleIDs: Set<String> {
        didSet {
            let joined = disabledBundleIDs.sorted().joined(separator: ",")
            defaults.set(joined, forKey: Keys.disabledBundleIDs)
        }
    }
    /// Apps that auto-start/stop recording with a countdown prompt
    /// instead of waiting for user action.
    @Published private(set) var autoStartBundleIDs: Set<String> {
        didSet {
            let joined = autoStartBundleIDs.sorted().joined(separator: ",")
            defaults.set(joined, forKey: Keys.autoStartBundleIDs)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // ON by default — first launch should surface the feature so
        // users discover it. The toggle in Settings flips it.
        if defaults.object(forKey: Keys.enabled) == nil {
            defaults.set(true, forKey: Keys.enabled)
        }
        self.enabled = defaults.bool(forKey: Keys.enabled)
        let raw = defaults.string(forKey: Keys.disabledBundleIDs) ?? ""
        self.disabledBundleIDs = Set(
            raw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        )
        let autoRaw = defaults.string(forKey: Keys.autoStartBundleIDs) ?? ""
        self.autoStartBundleIDs = Set(
            autoRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        )
    }

    func isDisabled(forBundleID bundleID: String) -> Bool {
        disabledBundleIDs.contains(bundleID)
    }

    /// Permanently silence the prompt for `bundleID`. Used by the
    /// "Don't show this for X" affordance inside the prompt overlay.
    func disable(bundleID: String) {
        guard !bundleID.isEmpty else { return }
        var copy = disabledBundleIDs
        copy.insert(bundleID)
        disabledBundleIDs = copy
    }

    /// Undo a silence — reverse of `disable(bundleID:)`. Surfaced from
    /// Settings → Meetings so the user can re-enable a previously-
    /// silenced app without digging into defaults.
    func reenable(bundleID: String) {
        var copy = disabledBundleIDs
        copy.remove(bundleID)
        disabledBundleIDs = copy
    }

    func isAutoStart(forBundleID bundleID: String) -> Bool {
        autoStartBundleIDs.contains(bundleID)
    }

    func setAutoStart(bundleID: String, enabled: Bool) {
        guard !bundleID.isEmpty else { return }
        var copy = autoStartBundleIDs
        if enabled { copy.insert(bundleID) }
        else { copy.remove(bundleID) }
        autoStartBundleIDs = copy
    }

    /// How Mila should treat a supported app when it detects a meeting.
    ///
    /// The three states are stored across the two sets above (`Off` is the
    /// silenced set, `Auto` is the auto-start set, `Ask` is neither) so older
    /// builds keep reading the same defaults. `mode(forBundleID:)` is the
    /// single readable projection of that storage, used by both the Settings
    /// picker and `MeetingPromptCoordinator` — the coordinator must see a
    /// revocation (`Auto` → `Ask`/`Off`) as exactly the same event the user
    /// clicked, not as a pair of set mutations it has to re-derive.
    enum AppMode: String, CaseIterable, Identifiable {
        case ask, auto, off

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .ask: return "Ask"
            case .auto: return "Auto"
            case .off: return "Off"
            }
        }
    }

    func mode(forBundleID bundleID: String) -> AppMode {
        if disabledBundleIDs.contains(bundleID) { return .off }
        if autoStartBundleIDs.contains(bundleID) { return .auto }
        return .ask
    }

    /// Set the whole mode in one call. `Auto` implicitly un-silences the app;
    /// `Off` implicitly revokes auto-start — the states are mutually
    /// exclusive, and going through one setter keeps the two backing sets
    /// from ever disagreeing (an app in both would read as `Off` and silently
    /// ignore a "turn on auto" click).
    func setMode(_ mode: AppMode, forBundleID bundleID: String) {
        switch mode {
        case .ask:
            reenable(bundleID: bundleID)
            setAutoStart(bundleID: bundleID, enabled: false)
        case .auto:
            reenable(bundleID: bundleID)
            setAutoStart(bundleID: bundleID, enabled: true)
        case .off:
            setAutoStart(bundleID: bundleID, enabled: false)
            disable(bundleID: bundleID)
        }
    }

    private enum Keys {
        static let enabled = "meetingDetection.enabled"
        static let disabledBundleIDs = "meetingDetection.disabledBundleIDs"
        static let autoStartBundleIDs = "meetingDetection.autoStartBundleIDs"
    }
}
