import Foundation
import AppKit
import Combine
import AVFoundation

/// Press the bound hotkey to start a dictation in that language. Press the same
/// hotkey again to stop, transcribe, and paste at the cursor.
///
/// English and Hebrew each have their own global hotkey (configurable in the
/// Settings UI; defaults `⌘2` and `⌘3`). Pressing the *other* language's
/// hotkey while one is in flight is ignored — the user has to stop the active
/// one first to avoid mid-sentence language flips that produce garbage
/// transcripts.
@MainActor
final class DictationController: ObservableObject {
    enum State: Equatable { case idle, recording(HotkeyAction), transcribing(HotkeyAction) }

    @Published private(set) var state: State = .idle
    @Published private(set) var level: Float = 0
    /// The language of the *most recent* dictation, exposed so the toolbar
    /// button can label itself ("Dictate · EN" / "Dictate · HE"). Defaults
    /// to Hebrew on a fresh install to preserve the pre-rename UX.
    @Published private(set) var lastLanguage: String = "he"

    private let recorder = MicrophoneRecorder()
    private var samples: [Float] = []
    private var streamTask: Task<Void, Never>?

    private let store: RecordingStore
    private let transcription: TranscriptionService
    private let hotkeySettings: HotkeySettings
    private var bindingsObserver: AnyCancellable?

    init(store: RecordingStore,
         transcription: TranscriptionService,
         hotkeySettings: HotkeySettings) {
        self.store = store
        self.transcription = transcription
        self.hotkeySettings = hotkeySettings
        registerHotkeys()
        bindingsObserver = hotkeySettings.$bindings
            .dropFirst()
            .sink { [weak self] _ in self?.registerHotkeys() }
    }

    // MARK: - Hotkey wiring

    private func registerHotkeys() {
        for action in HotkeyAction.allCases {
            let binding = hotkeySettings.binding(for: action)
            HotkeyManager.shared.register(action, binding: binding) { [weak self] in
                Task { await self?.toggle(action: action) }
            }
        }
    }

    // MARK: - Public API

    /// Toggle dictation for `action`. If a different action's dictation is
    /// already in flight, this call is ignored (we don't want to interleave
    /// languages).
    func toggle(action: HotkeyAction) async {
        switch state {
        case .idle:
            await start(action: action)
        case .recording(let active) where active == action:
            await stopAndTranscribe(action: action)
        case .recording, .transcribing:
            NSSound.beep()
        }
    }

    /// Stop any in-flight dictation immediately. Used by the AppDelegate
    /// during graceful shutdown.
    func cancelInFlight() async {
        guard case .recording = state else { return }
        recorder.stop()
        streamTask?.cancel(); streamTask = nil
        samples.removeAll(keepingCapacity: true)
        DictationOverlayWindow.shared.hide()
        state = .idle
        level = 0
    }

    // MARK: - Recording

    private func start(action: HotkeyAction) async {
        guard await recorder.requestAccess() else {
            NSSound.beep()
            return
        }
        samples.removeAll(keepingCapacity: true)
        do {
            try recorder.start()
        } catch {
            NSSound.beep()
            return
        }
        state = .recording(action)
        lastLanguage = action.languageCode
        DictationOverlayWindow.shared.show()
        streamTask = Task { [weak self] in
            guard let self else { return }
            for await buffer in self.recorder.audioStream {
                let chunk = AudioConvert.samples(from: buffer)
                let lvl = AudioMeter.level(from: buffer)
                await MainActor.run {
                    self.samples.append(contentsOf: chunk)
                    self.level = lvl
                    DictationOverlayWindow.shared.updateLevel(lvl)
                }
            }
        }
    }

    private func stopAndTranscribe(action: HotkeyAction) async {
        recorder.stop()
        streamTask?.cancel(); streamTask = nil
        state = .transcribing(action)
        DictationOverlayWindow.shared.setBusy(true)

        let captured = samples
        samples.removeAll(keepingCapacity: true)
        let text = await transcription.transcribeOnce(samples: captured,
                                                      language: action.languageCode)

        DictationOverlayWindow.shared.hide()
        state = .idle
        level = 0

        if !text.isEmpty {
            paste(text)
        } else {
            NSSound.beep()
        }

        await persistDictation(samples: captured, text: text, action: action)
    }

    // MARK: - Persistence

    /// Save the dictation as a Recording so it shows up under History → Dictations.
    private func persistDictation(samples: [Float],
                                  text: String,
                                  action: HotkeyAction) async {
        guard !samples.isEmpty else { return }
        let url = store.freshAudioURL(suggestedName: "Dictation")
        do {
            let format = WhisperAudioFormat.pcmFloat32
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            if let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: AVAudioFrameCount(samples.count)) {
                buffer.frameLength = AVAudioFrameCount(samples.count)
                if let channel = buffer.floatChannelData?[0] {
                    samples.withUnsafeBufferPointer { src in
                        channel.update(from: src.baseAddress!, count: samples.count)
                    }
                }
                try file.write(from: buffer)
            }
        } catch {
            print("Dictation save error: \(error)")
            return
        }
        let title = "Dictation · \(Self.titleFormatter.string(from: Date()))"
        let recording = Recording(
            title: title,
            duration: Double(samples.count) / WhisperAudioFormat.sampleRate,
            source: .microphone,
            audioFileName: url.lastPathComponent,
            status: text.isEmpty ? .failed : .completed,
            language: action.languageCode,
            segments: text.isEmpty ? [] : [.init(start: 0, end: 0, text: text)],
            fullText: text
        )
        store.add(recording)
    }

    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // MARK: - Paste

    private func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let priorContents = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let src = CGEventSource(stateID: .hidSystemState)
        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: true)
        let vDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
        let vUp = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: false)
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand
        cmdDown?.post(tap: .cghidEventTap)
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let prior = priorContents {
                pasteboard.clearContents()
                pasteboard.setString(prior, forType: .string)
            }
        }
    }
}
