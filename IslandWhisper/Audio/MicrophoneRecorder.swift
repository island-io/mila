import Foundation
import AVFoundation
import Combine

/// Pulls samples from the user's preferred input device using `AVAudioEngine`.
/// Emits whisper-format buffers (16kHz mono Float32) on `audioStream`.
///
/// **Important:** every `start()` call builds a brand-new `AVAudioEngine` and
/// a brand-new `AsyncStream`. Reusing a single engine across stop/start cycles
/// is a documented macOS quirk that makes the input node go silent after the
/// first session — the user-visible symptom was "first Voice Memo records
/// fine, every subsequent one captures ~60ms of noise and Whisper hallucinates
/// the same Hebrew test phrase for all of them".
@MainActor
final class MicrophoneRecorder: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var level: Float = 0

    /// Current stream — replaced on every `start()` so leftover buffered
    /// samples from a previous recording can never leak into the next one.
    private(set) var audioStream: AsyncStream<AVAudioPCMBuffer>
    private var audioContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    private var engine: AVAudioEngine?

    init() {
        var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation!
        self.audioStream = AsyncStream { continuation = $0 }
        self.audioContinuation = continuation
    }

    func requestAccess() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }

    func start() throws {
        guard !isRunning else { return }

        // Tear down anything that may still be alive from a previous session
        // (defensive — `stop()` should have done this, but a partially-started
        // session that threw mid-way could leak engine/tap state).
        if let existing = engine {
            existing.inputNode.removeTap(onBus: 0)
            existing.stop()
            engine = nil
        }
        audioContinuation.finish()

        var newContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation!
        self.audioStream = AsyncStream { newContinuation = $0 }
        self.audioContinuation = newContinuation

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode

        if let device = AudioDeviceManager.preferredInputDevice() {
            do {
                try AudioDeviceManager.setInputDevice(device, on: engine)
                print("Mic: using \(device.name) [\(device.manufacturer)]")
            } catch {
                print("Mic: could not switch to \(device.name): \(error)")
            }
        }

        let nativeFormat = input.inputFormat(forBus: 0)
        guard nativeFormat.sampleRate > 0 else {
            throw NSError(domain: "MicrophoneRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No input device available."])
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let level = AudioMeter.level(from: buffer)
            Task { @MainActor in self.level = level }

            do {
                let converted = try AudioConvert.toWhisperFormat(buffer)
                self.audioContinuation.yield(converted)
            } catch {
                print("Mic conversion error: \(error)")
            }
        }

        engine.prepare()
        try engine.start()
        isRunning = true
        print(String(format: "Mic: started (%.0fHz, %d ch)",
                     nativeFormat.sampleRate, Int(nativeFormat.channelCount)))
    }

    func stop() {
        guard isRunning else { return }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        audioContinuation.finish()
        isRunning = false
        level = 0
    }

    deinit {
        audioContinuation.finish()
    }
}
