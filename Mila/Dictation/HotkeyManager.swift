import Foundation
import AppKit
import Carbon.HIToolbox

/// A single user-configurable hotkey binding (key code + modifiers).
///
/// Codable so we can stash bindings in `UserDefaults` and bring them back
/// across launches.
struct HotkeyBinding: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// Human-readable label like `"⌘2"`. Built only from the four common
    /// modifier flags + `kVK_ANSI_*` codes; falls back to the raw key code
    /// for anything we don't have a glyph for.
    var displayName: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += Self.keyGlyph(for: keyCode)
        return s
    }

    static func keyGlyph(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space:  return "Space"
        case kVK_Return: return "↩"
        case kVK_Escape: return "⎋"
        case kVK_Tab:    return "⇥"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            // Try to map letters via the live keyboard layout.
            if let glyph = Self.letterGlyph(for: keyCode) { return glyph }
            return "Key\(keyCode)"
        }
    }

    private static func letterGlyph(for keyCode: UInt32) -> String? {
        guard let layoutData = TISGetInputSourceProperty(
            TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue(),
            kTISPropertyUnicodeKeyLayoutData
        ) else { return nil }

        let cfData = unsafeBitCast(layoutData, to: CFData.self)
        guard let layoutBytes = CFDataGetBytePtr(cfData) else { return nil }
        let keyLayoutPtr = UnsafeRawPointer(layoutBytes)
            .assumingMemoryBound(to: UCKeyboardLayout.self)

        var deadKeyState: UInt32 = 0
        var actualLength = 0
        var unicodeChars = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            keyLayoutPtr,
            UInt16(keyCode),
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            UInt32(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            unicodeChars.count,
            &actualLength,
            &unicodeChars
        )
        guard status == noErr, actualLength > 0 else { return nil }
        return String(utf16CodeUnits: unicodeChars, count: actualLength).uppercased()
    }
}

/// One dictation hotkey: "start dictating in this language". There is one per
/// configured language, so this is a value keyed by language code rather than
/// an enum.
struct HotkeyAction: Hashable, Identifiable {
    let languageCode: String

    init(languageCode: String) {
        self.languageCode = languageCode.lowercased()
    }

    /// Stable id, also the UserDefaults key suffix (`hotkey.dictate.he`).
    var id: String { "dictate.\(languageCode)" }

    var displayLabel: String {
        "\(RecordingLanguage(code: languageCode).displayName) dictation"
    }

    static let dictateEnglish = HotkeyAction(languageCode: "en")
    static let dictateHebrew = HotkeyAction(languageCode: "he")

    /// Default bindings — only the two seed languages have one. A language
    /// the user adds starts unbound: auto-assigning ⌘4, ⌘5… would quietly
    /// collide with other apps' global shortcuts. Chosen because:
    ///   - `⌘⇧Space` is reserved by macOS (input-source switching) and Carbon
    ///     refuses to register it.
    ///   - `⌘1` is taken by the Window menu's "Cycle Through Windows".
    ///   - `⌘2` and `⌘3` are unused at the OS level on a vanilla macOS install.
    static let defaults: [HotkeyAction: HotkeyBinding] = [
        .dictateEnglish: HotkeyBinding(keyCode: UInt32(kVK_ANSI_2),
                                       modifiers: UInt32(cmdKey)),
        .dictateHebrew:  HotkeyBinding(keyCode: UInt32(kVK_ANSI_3),
                                       modifiers: UInt32(cmdKey))
    ]

    /// UserDefaults key suffixes from when this was a two-case enum
    /// (`hotkey.dictateEnglish`). Migrated once by `HotkeySettings`.
    static let legacyStorageNames: [HotkeyAction: String] = [
        .dictateEnglish: "dictateEnglish",
        .dictateHebrew: "dictateHebrew"
    ]
}

/// The registration surface `DictationHotkeyBinder` drives — `HotkeyManager`
/// in the app, a recorder in tests (real Carbon registrations would grab
/// system-wide combos from inside the test host).
@MainActor
protocol HotkeyRegistering: AnyObject {
    var registeredActions: Set<HotkeyAction> { get }
    @discardableResult
    func register(_ action: HotkeyAction, binding: HotkeyBinding,
                  onPressed: @escaping () -> Void) -> Bool
    func unregister(_ action: HotkeyAction)
}

/// Registers global hotkeys via the legacy Carbon API (still supported on
/// macOS 14+ and the only path that's reliable for system-wide hotkeys).
///
/// Each `HotkeyAction` may have at most one active registration. Re-registering
/// with the same action transparently replaces the previous one, so the
/// settings UI can rebind in place without leaking handlers.
@MainActor
final class HotkeyManager: HotkeyRegistering {
    static let shared = HotkeyManager()

    private struct RegisteredHotkey {
        let action: HotkeyAction
        let binding: HotkeyBinding
        /// Carbon `EventHotKeyID.id` this registration was made under.
        let carbonID: UInt32
        let ref: EventHotKeyRef
        var handler: () -> Void
    }

    private var registrations: [HotkeyAction: RegisteredHotkey] = [:]
    /// Registrations parked by `suspendAll()` (capture mode) so
    /// `resumeAll()` can restore them with their handlers intact.
    private var suspended: [HotkeyAction: (binding: HotkeyBinding, handler: () -> Void)] = [:]
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = OSType(0x49575350) // 'IWSP'
    /// Source of Carbon hotkey ids. Only needs uniqueness among LIVE
    /// registrations, and a counter that never repeats guarantees that across
    /// rebinds and suspend/resume without deriving ids from user-supplied
    /// language codes. `canRegister` probes under `UInt32.max`, which this
    /// never reaches.
    private var nextCarbonID: UInt32 = 1

    private init() {
        installEventHandler()
    }

    // MARK: - Registration

    /// Register `action` with the given binding and pressed-handler. If the
    /// binding is already taken globally (e.g. another app or the OS owns it)
    /// the call returns `false` and no registration is recorded.
    @discardableResult
    func register(_ action: HotkeyAction,
                  binding: HotkeyBinding,
                  onPressed: @escaping () -> Void) -> Bool {
        // Already live under this very combo: keep the Carbon registration
        // and take the new handler. `DictationHotkeyBinder` re-applies every
        // hotkey whenever the language list or any binding changes, and
        // tearing each one down and re-registering it for an unrelated edit
        // (a flag, another language's shortcut) would be pure churn.
        if var existing = registrations[action], existing.binding == binding {
            existing.handler = onPressed
            registrations[action] = existing
            return true
        }
        unregister(action)

        let carbonID = nextCarbonID
        nextCarbonID += 1
        let id = EventHotKeyID(signature: signature, id: carbonID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(binding.keyCode,
                                         binding.modifiers,
                                         id,
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)
        guard status == noErr, let validRef = ref else {
            // -9878 = eventHotKeyExistsErr — combo is already taken globally.
            print("Hotkey: RegisterEventHotKey failed for \(action.id) status=\(status)")
            return false
        }
        registrations[action] = RegisteredHotkey(action: action,
                                                 binding: binding,
                                                 carbonID: carbonID,
                                                 ref: validRef,
                                                 handler: onPressed)
        print("Hotkey: registered \(action.id) -> \(binding.displayName)")
        return true
    }

    func unregister(_ action: HotkeyAction) {
        if let existing = registrations.removeValue(forKey: action) {
            UnregisterEventHotKey(existing.ref)
        }
    }

    /// Whether `action` currently holds a live Carbon registration. False
    /// means pressing the bound combo does nothing — e.g. another app owns
    /// it globally and `register` failed. Settings uses this to warn
    /// instead of silently showing a dead binding as active.
    func isRegistered(_ action: HotkeyAction) -> Bool {
        registrations[action] != nil
    }

    var registeredActions: Set<HotkeyAction> { Set(registrations.keys) }

    /// Probe whether `binding` can be registered globally right now,
    /// without keeping the registration: registers a throwaway hotkey and
    /// releases it immediately. Used by Settings to validate a newly
    /// captured combo BEFORE persisting it — the old flow persisted first,
    /// dropped the registration failure on the floor, and (because
    /// `register` unregisters the previous combo before trying the new
    /// one) left the user with NO working hotkey at all.
    func canRegister(_ binding: HotkeyBinding) -> Bool {
        let id = EventHotKeyID(signature: signature, id: UInt32.max)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(binding.keyCode,
                                         binding.modifiers,
                                         id,
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)
        if let ref { UnregisterEventHotKey(ref) }
        return status == noErr
    }

    /// Park every live registration (keeping bindings + handlers) so a
    /// Settings capture field can see raw keyDowns. Carbon consumes
    /// registered combos before the responder chain, so without this,
    /// pressing a currently-bound hotkey while recording a new binding
    /// STARTED DICTATION instead of being captured. Balanced by
    /// `resumeAll()`; nested suspends are no-ops.
    func suspendAll() {
        guard suspended.isEmpty else { return }
        for (action, reg) in registrations {
            suspended[action] = (reg.binding, reg.handler)
            UnregisterEventHotKey(reg.ref)
        }
        registrations.removeAll()
    }

    /// Restore the registrations parked by `suspendAll()`.
    func resumeAll() {
        let toRestore = suspended
        suspended.removeAll()
        for (action, entry) in toRestore {
            register(action, binding: entry.binding, onPressed: entry.handler)
        }
    }

    /// Tear down all registered hotkeys + the shared event handler. Used
    /// during graceful app shutdown so Carbon doesn't try to call back into
    /// a partially-deallocated process.
    func shutdown() {
        for action in Array(registrations.keys) { unregister(action) }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    // MARK: - Carbon plumbing

    private func installEventHandler() {
        let pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                    eventKind: UInt32(kEventHotKeyPressed))
        var specs = [pressed]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(),
                                         { _, eventRef, userData in
            guard let userData, let eventRef else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            var hkID = EventHotKeyID()
            let getStatus = GetEventParameter(eventRef,
                                              EventParamName(kEventParamDirectObject),
                                              EventParamType(typeEventHotKeyID),
                                              nil,
                                              MemoryLayout<EventHotKeyID>.size,
                                              nil,
                                              &hkID)
            guard getStatus == noErr else { return noErr }
            DispatchQueue.main.async {
                manager.dispatch(carbonID: hkID.id)
            }
            return noErr
        }, 1, &specs, selfPtr, &eventHandler)

        if status != noErr {
            print("Hotkey: InstallEventHandler failed status=\(status)")
        }
    }

    private func dispatch(carbonID: UInt32) {
        guard let entry = registrations.values.first(where: { $0.carbonID == carbonID }) else {
            return
        }
        entry.handler()
    }
}
