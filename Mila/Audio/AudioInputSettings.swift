import Foundation
import Combine

/// User's choice of input device for new recordings. When `preferredUID` is
/// nil we let `AudioDeviceManager.preferredInputDevice()` pick automatically
/// (current system default, falling back to built-in). When set, we pin to
/// that exact device — useful for users who keep a virtual mic (e.g. Krisp)
/// as their system default but want Mila to read straight from the
/// hardware mic.
@MainActor
final class AudioInputSettings: ObservableObject {
    /// kAudioDevicePropertyDeviceUID of the user's pinned input, or nil for
    /// "follow the system default".
    @Published var preferredUID: String? {
        didSet {
            guard preferredUID != oldValue else { return }
            if let preferredUID {
                defaults.set(preferredUID, forKey: Self.preferredUIDKey)
            } else {
                defaults.removeObject(forKey: Self.preferredUIDKey)
            }
        }
    }

    /// When true (default), `MicrophoneRecorder` runs every captured frame
    /// through `AdaptiveGainController` so low-volume mic input is boosted
    /// to a target observed RMS before reaching the live VAD + saved WAV.
    /// Disable for users who prefer to manage their input levels manually.
    @Published var adaptiveGainEnabled: Bool {
        didSet {
            guard adaptiveGainEnabled != oldValue else { return }
            defaults.set(adaptiveGainEnabled, forKey: Self.adaptiveGainEnabledKey)
        }
    }

    private let defaults: UserDefaults
    private static let preferredUIDKey = "audio.input.preferredUID"
    static let adaptiveGainEnabledKey = "audioInput.adaptiveGainEnabled"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.preferredUID = defaults.string(forKey: Self.preferredUIDKey)
        // Adaptive gain is on by default for new installs — most users
        // benefit immediately and the controller is bypassed (gain == 1)
        // when input is already loud. `object(forKey:)` distinguishes
        // "unset" from "explicitly false" so an older install upgrading
        // doesn't accidentally re-enable a setting the user turned off.
        if defaults.object(forKey: Self.adaptiveGainEnabledKey) == nil {
            self.adaptiveGainEnabled = true
        } else {
            self.adaptiveGainEnabled = defaults.bool(forKey: Self.adaptiveGainEnabledKey)
        }
    }
}
