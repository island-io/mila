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

    /// Bumped by every `start()` and `stop()`. The off-main bring-up can
    /// take seconds on a wireless mic, and `engine`/`isRunning` are only
    /// assigned AFTER it completes — so a `stop()` (view closed) or a
    /// second `start()` (device changed) landing inside that window used
    /// to be lost: the late-completing engine was adopted anyway and ran
    /// forever, holding the mic open with no view left to stop it. Each
    /// bring-up records the generation it started under and abandons its
    /// engine if anything bumped it since.
    private var generation = 0

    func start() async {
        guard !isRunning, engine == nil else { return }
        // Supersede any in-flight bring-up: if two starts race, the later
        // one wins and the earlier tears its engine down on arrival.
        generation += 1
        let myGeneration = generation
        let preferredUID = self.preferredUID
        let onLevel: @Sendable (Float) -> Void = { [weak self] lvl in
            Task { @MainActor [weak self] in
                // Generation gate: a superseded engine keeps tapping until
                // its teardown lands — its queued updates must not repaint
                // the meter after stop() zeroed it.
                guard let self, self.generation == myGeneration else { return }
                self.level = lvl
            }
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
            if generation == myGeneration { self.level = 0 }
            return
        }
        guard generation == myGeneration, engine == nil else {
            // A stop() or newer start() took over while we were coming up
            // — nobody owns this engine, so tear it down instead of
            // adopting it.
            await Self.teardown(built)
            return
        }
        self.engine = built
        self.isRunning = true
    }

    func stop() async {
        generation += 1
        let toTeardown = engine
        engine = nil
        isRunning = false
        level = 0
        guard let toTeardown else { return }
        await Self.teardown(toTeardown)
    }

    private static func teardown(_ engine: AVAudioEngine) async {
        await Task.detached(priority: .utility) {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
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
