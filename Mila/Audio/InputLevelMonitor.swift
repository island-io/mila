import Foundation
import AVFoundation
import Combine

/// Lightweight always-on VU meter for the Home screen.
///
/// Opens its own `AVAudioEngine` against the user's preferred input device,
/// installs a level-only tap, and publishes a 0…1 RMS-derived value on
/// `@MainActor`. Unlike `MicrophoneRecorder` this does **not** write samples
/// anywhere — it exists purely so the user can see "yes, this microphone is
/// hearing me" before / between recordings.
///
/// Lifecycle:
///   - `start()` brings up the engine off-main (CoreAudio can stall on
///     wireless mics; we don't want the Home screen to freeze).
///   - `stop()` tears everything down.
///   - When the pinned input UID changes the caller should call
///     `restart()`; switching the device on a running engine is fragile.
@MainActor
final class InputLevelMonitor: ObservableObject {
    @Published private(set) var level: Float = 0
    @Published private(set) var isRunning = false

    /// kAudioDevicePropertyDeviceUID of the input we should monitor, or nil to
    /// follow the system default. Changing this on a running monitor is a
    /// no-op — callers must `stop()` and `start()` for the new device to take
    /// effect.
    var preferredUID: String?

    private var engine: AVAudioEngine?

    func start() async {
        guard !isRunning, engine == nil else { return }
        let preferredUID = self.preferredUID
        let onLevel: @Sendable (Float) -> Void = { [weak self] lvl in
            Task { @MainActor in self?.level = lvl }
        }
        let built: AVAudioEngine? = await Task.detached(priority: .utility) {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            if let device = AudioDeviceManager.preferredInputDevice(preferredUID: preferredUID) {
                try? AudioDeviceManager.setInputDevice(device, on: engine)
            }
            let format = input.inputFormat(forBus: 0)
            guard format.sampleRate > 0 else { return nil }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                onLevel(AudioMeter.level(from: buffer))
            }
            engine.prepare()
            do {
                try engine.start()
                return engine
            } catch {
                input.removeTap(onBus: 0)
                return nil
            }
        }.value
        guard let built else {
            self.level = 0
            return
        }
        self.engine = built
        self.isRunning = true
    }

    func stop() async {
        let toTeardown = engine
        engine = nil
        isRunning = false
        level = 0
        guard let toTeardown else { return }
        await Task.detached(priority: .utility) {
            toTeardown.inputNode.removeTap(onBus: 0)
            toTeardown.stop()
        }.value
    }

    /// Tear down and bring up against whatever `preferredUID` is currently
    /// set to. Used when the user changes the input device on the home
    /// screen — we can't safely swap the device on a live engine.
    func restart() async {
        await stop()
        await start()
    }
}
