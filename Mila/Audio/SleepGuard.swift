import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps

/// Thin wrapper around macOS power-management APIs. Two responsibilities:
///
///  1. Hold a pair of `IOPMAssertion`s while a recording is in flight so the
///     Mac doesn't cut the capture short when the user steps away:
///       • `PreventUserIdleSystemSleep` keeps the *system* awake.
///       • `PreventUserIdleDisplaySleep` keeps the *display* awake — which is
///         what actually stops the automatic screen lock. Without it, macOS
///         sleeps the display after the user's idle timer, posts
///         `com.apple.screenIsLocked`, and our lock observer
///         (`MilaApp.handleScreenLock`) finalizes the recording — the exact
///         bug where a meeting capture dies a few minutes after the user
///         leaves the keyboard. Suppressing idle display sleep also suppresses
///         the idle screensaver/auto-lock, so that observer now only fires for
///         *deliberate* locks (Control Center, hot corner, ⌘⌃Q), where
///         stopping the recording is the intended privacy behavior.
///     Both assertions are released the moment the recording stops or the app
///     quits — leaving one pinned would block sleep / keep the screen lit
///     indefinitely.
///
///  2. Tell callers whether the Mac is currently running on AC. macOS will
///     forcibly sleep on lid close when on battery regardless of any
///     assertion an app holds, so the UI uses this signal to warn the user
///     that closing the lid will still cut the recording short.
///
/// Not @MainActor: the assertion APIs are thread-safe and we want to be able
/// to release the assertions from teardown paths (app termination) without
/// hopping back to the main actor.
final class SleepGuard {
    private var systemAssertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var displayAssertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var held = false

    /// Take the assertions if we don't already hold them. Idempotent —
    /// repeated calls while held are no-ops, so callers can call this at the
    /// start of every recording without tracking state themselves.
    func preventIdleSleep(reason: String) {
        guard !held else { return }
        // Take both independently: the display assertion is the one that
        // prevents the automatic lock, so we still want it even if the
        // system-sleep assertion somehow fails (and vice versa).
        let systemResult = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &systemAssertionID
        )
        if systemResult != kIOReturnSuccess {
            print("SleepGuard: failed to take system-sleep assertion (\(systemResult))")
            systemAssertionID = IOPMAssertionID(0)
        }
        let displayResult = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &displayAssertionID
        )
        if displayResult != kIOReturnSuccess {
            // The display assertion is the load-bearing one for this feature:
            // without it the idle auto-lock can still fire and end the
            // recording. macOS won't let us force a denied assertion, so make
            // the degradation LOUD rather than silent — the system-sleep
            // assertion above (if it succeeded) still keeps the Mac awake.
            print("SleepGuard: WARNING — display-sleep assertion denied (\(displayResult)); idle auto-lock prevention is UNAVAILABLE for this recording")
            displayAssertionID = IOPMAssertionID(0)
        }
        // `held` means "we hold at least one assertion that must be released
        // later" — true if EITHER succeeded, so `allowIdleSleep`/`deinit`
        // can't leak the one we did get. It does NOT claim both are held; a
        // denied display assertion is surfaced by the warning above.
        held = systemResult == kIOReturnSuccess || displayResult == kIOReturnSuccess
    }

    /// Release both assertions. Safe to call when not held.
    func allowIdleSleep() {
        guard held else { return }
        releaseAssertions()
        held = false
    }

    /// Release whichever assertions we actually hold, zeroing their IDs so a
    /// second call (deinit after `allowIdleSleep`) can't double-release.
    private func releaseAssertions() {
        if systemAssertionID != IOPMAssertionID(0) {
            IOPMAssertionRelease(systemAssertionID)
            systemAssertionID = IOPMAssertionID(0)
        }
        if displayAssertionID != IOPMAssertionID(0) {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = IOPMAssertionID(0)
        }
    }

    deinit {
        if held {
            releaseAssertions()
        }
    }

    /// True when the Mac is plugged in (AC power), false on battery. Returns
    /// true on desktops (Mac mini / Studio / Pro) and any machine where the
    /// power source can't be determined — we'd rather not nag desktop users
    /// with a battery-only warning.
    static func isOnACPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return true
        }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            // `Power Source State` is "AC Power", "Battery Power", or
            // "Off Line". We only treat explicit battery as off-AC.
            if let state = info[kIOPSPowerSourceStateKey] as? String,
               state == kIOPSBatteryPowerValue {
                return false
            }
        }
        return true
    }
}
