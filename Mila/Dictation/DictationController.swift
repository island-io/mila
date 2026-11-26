import Foundation
import AppKit
import Combine
import AVFoundation
import OSLog
import TranscriptionCore

private let dictationLog = Logger(subsystem: "io.island.whisper.IslandWhisper",
                                  category: "DictationController")

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
    /// True while `start(action:)` is between its entry and setting
    /// `state = .recording` — the two awaits in that window (mic permission,
    /// engine bring-up) are where a hotkey double-press could re-enter.
    private var isStarting = false
    /// True from the moment `stopAndTranscribe` begins until the state has
    /// moved on to `.transcribing`. The state stays `.recording` while the
    /// recorder tears down, as it always has, and without this flag `toggle`
    /// would route a double-tap in that wait into a second stop. (A sleep or
    /// screen-lock `cancelInFlight` in the same wait still runs, but it does
    /// not stop the stop's own transcription and paste; that predates #434.)
    private var isStopping = false

    /// This dictation's claim on the local Whisper model (#434). Batch-only
    /// mode releases an idle model (#393), so without it every dictation
    /// loaded the model only once the user had finished speaking. Taken once
    /// mic access is granted, so the load overlaps with the mic coming up and
    /// the user speaking; handed to this property once capture is running,
    /// and ended exactly once — by the stop that takes it out of here (after
    /// its final transcription), or on cancel. A start that fails ends its
    /// own hold before it returns. Nil in live
    /// mode and on the remote backend (see
    /// `TranscriptionService.beginLocalModelHold`).
    private var modelHold: TranscriptionService.LocalModelHold?

    /// Live transcriber used to surface partial transcripts in the
    /// dictation overlay AND to remove the post-release transcription
    /// wait. We rely on it being the *same instance* across dictations
    /// (it's reset at the start of every press via `start(language:)`).
    private let liveTranscriber: LiveTranscriber

    /// Observation of `liveTranscriber.segments` so the overlay can show
    /// the latest tentative text without the controller having to
    /// manually push every update.
    private var liveTextObserver: AnyCancellable?

    /// The app that was frontmost when this dictation started. Captured at
    /// `start(action:)` time and re-activated at `paste(_:)` time so the
    /// synthesized ⌘V always lands in the user's intended app — never in
    /// Mila itself, even if focus shifted to us during recording
    /// (e.g. the user clicked back into the Mila window mid-take).
    private var targetApp: NSRunningApplication?

    private let store: RecordingStore
    private let transcription: TranscriptionService
    private let hotkeySettings: HotkeySettings
    private var bindingsObserver: AnyCancellable?
    /// Late-bound by MilaApp. Enforces the storage cap for dictation too,
    /// so a full library blocks new clips consistently with Settings copy.
    var storageSettings: RecordingStorageSettings?

    init(store: RecordingStore,
         transcription: TranscriptionService,
         hotkeySettings: HotkeySettings,
         liveTranscriber: LiveTranscriber) {
        self.store = store
        self.transcription = transcription
        self.hotkeySettings = hotkeySettings
        self.liveTranscriber = liveTranscriber
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
        switch Self.outcome(ofPress: action, state: state, isStopping: isStopping) {
        case .start:
            await start(action: action)
        case .stop:
            await stopAndTranscribe(action: action)
        case .ignore:
            NSSound.beep()
        }
    }

    enum PressOutcome: Equatable { case start, stop, ignore }

    /// What a press of `action`'s hotkey does. Kept pure so the routing can
    /// be tested without a microphone.
    ///
    /// Only the language being recorded can stop it, and only once: a second
    /// press while that stop is still tearing the recorder down is ignored,
    /// like a press during `.transcribing`. Routing it to a second stop ran
    /// a second final pass over empty audio, which beeped and set `.idle`
    /// while the first pass was still running — so a later press could start
    /// a new dictation that the first stop then knocked back to `.idle`.
    static func outcome(ofPress action: HotkeyAction,
                        state: State,
                        isStopping: Bool) -> PressOutcome {
        switch state {
        case .idle:
            return .start
        case .recording(let active) where active == action && !isStopping:
            return .stop
        case .recording, .transcribing:
            return .ignore
        }
    }

    /// Stop any in-flight dictation immediately. Used by the AppDelegate
    /// during graceful shutdown.
    func cancelInFlight() async {
        guard case .recording = state else { return }
        await recorder.stop()
        streamTask?.cancel(); streamTask = nil
        liveTextObserver?.cancel(); liveTextObserver = nil
        _ = liveTranscriber.stop()
        samples.removeAll(keepingCapacity: true)
        targetApp = nil
        // Nothing will be transcribed: let batch-only mode release the model.
        endModelHold()
        DictationOverlayWindow.shared.hide()
        state = .idle
        level = 0
    }

    /// End this dictation's model hold, if it has one. Safe to call more than
    /// once: the property is cleared first, and the service ignores a hold
    /// that already ended.
    private func endModelHold() {
        guard let hold = modelHold else { return }
        modelHold = nil
        transcription.endLocalModelHold(hold)
    }

    // MARK: - Recording

    private func start(action: HotkeyAction) async {
        // Re-entrancy guard: `state` only becomes .recording AFTER the two
        // awaits below (mic permission + engine bring-up), so a nervous
        // double-tap of the hotkey inside that window saw .idle twice and
        // ran two overlapping starts — the second streamTask overwrote the
        // first without cancelling it and the recorder was restarted
        // mid-flight. Set synchronously, so the second entry bails.
        guard !isStarting else {
            NSSound.beep()
            return
        }
        isStarting = true
        defer { isStarting = false }

        // Storage cap: a full library blocks new dictation clips too
        // (consistent with Settings copy). A beep is the right-sized signal
        // for the hotkey flow — rare edge, and the user can free space.
        if let storageSettings, store.currentUsageBytes() >= storageSettings.limitBytes {
            NSSound.beep()
            return
        }
        // Snapshot the user's frontmost app FIRST, before we touch any UI or
        // the audio engine. Even though our overlay is a non-activating
        // panel, the user might click into Mila mid-take, and we
        // need to know where to put the result regardless.
        let myPID = ProcessInfo.processInfo.processIdentifier
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != myPID {
            targetApp = frontmost
        } else {
            targetApp = nil
        }

        // Trigger the AX permission prompt on first dictation if we're not
        // trusted yet. This pops the system dialog + adds us to the
        // Accessibility list. macOS requires a relaunch after the user
        // toggles us on for trust to actually apply, so the first dictation
        // after install will still hit the missing-permission fallback path.
        if !AccessibilityPermission.isTrusted() {
            AccessibilityPermission.requestPromptIfNeeded()
        }

        guard await recorder.requestAccess() else {
            NSSound.beep()
            return
        }

        // Start loading the model the final pass will use now, so the load
        // overlaps with the mic coming up and the user speaking instead of
        // following the second press (#434). After the permission check, not
        // before it: on a first dictation the system prompt can stay up for a
        // long time, and a denial would throw the whole load away. Once access
        // is granted that check returns at once, so nothing is lost here.
        // This call owns the hold until capture is running; every return
        // before that point ends it, so a failed start cannot strand it.
        let hold = transcription.beginLocalModelHold(language: action.languageCode)
        var holdHandedOff = false
        defer {
            if !holdHandedOff, let hold { transcription.endLocalModelHold(hold) }
        }

        samples.removeAll(keepingCapacity: true)
        do {
            try await recorder.start()
        } catch {
            NSSound.beep()
            return
        }
        // At most one hold per controller. Every end path clears the previous
        // dictation's before going idle, so this only guards against a future
        // path that forgets to — ending the old one rather than leaking it.
        endModelHold()
        modelHold = hold
        holdHandedOff = true
        state = .recording(action)
        lastLanguage = action.languageCode
        DictationOverlayWindow.shared.show()
        DictationOverlayWindow.shared.setLanguage(action.languageCode)

        // Start the live transcriber so the overlay shows partial text
        // and the user doesn't wait for a one-shot pass on release.
        liveTranscriber.start(language: action.languageCode)
        liveTextObserver = liveTranscriber.$segments
            .receive(on: DispatchQueue.main)
            .sink { segments in
                let text = segments
                    .map(\.text)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                DictationOverlayWindow.shared.updateLiveText(text)
            }

        streamTask = Task { [weak self] in
            guard let self else { return }
            for await buffer in self.recorder.audioStream {
                let chunk = AudioConvert.samples(from: buffer)
                let lvl = AudioMeter.level(from: buffer)
                await MainActor.run {
                    self.samples.append(contentsOf: chunk)
                    self.level = lvl
                    DictationOverlayWindow.shared.updateLevel(lvl)
                    self.liveTranscriber.ingest(chunk[0..<chunk.count])
                }
            }
        }
    }

    private func stopAndTranscribe(action: HotkeyAction) async {
        // Mark the stop and take this dictation's model hold BEFORE the first
        // await. The state reads `.recording` until `recorder.stop()` returns,
        // and `isStopping` is what turns a double-tap in that window away
        // instead of running a second stop. The hold moves into a local so
        // this stop ends exactly the hold it took, whatever `modelHold`
        // carries by the time it does.
        isStopping = true
        let hold = modelHold
        modelHold = nil
        await recorder.stop()
        streamTask?.cancel(); streamTask = nil
        state = .transcribing(action)
        isStopping = false
        DictationOverlayWindow.shared.setBusy(true)

        let captured = samples
        samples.removeAll(keepingCapacity: true)
        liveTextObserver?.cancel()
        liveTextObserver = nil
        _ = liveTranscriber.stop()

        // ALWAYS do a final one-shot pass over the full captured audio.
        // We tried using `LiveTranscriber.formattedTranscript` as the
        // authoritative paste text, but that's a snapshot of the
        // sliding-window state — it only contains the last ~20 seconds
        // of audio because earlier windows aged out. A 60-second
        // dictation pasted as the last ~20 seconds. The live transcriber
        // stays around purely for the overlay's "watch your words
        // appear" UX; the FINAL text comes from one whisper pass over
        // every sample we captured.
        //
        // `audioCtx: 0` opts out of WhisperEngine's live-VAD-tuned
        // audio_ctx truncation. Dictation clips are hotkey-bounded
        // (sub-second to a few seconds) and we don't have a labelled
        // fixture set for that distribution — the CI e2e sweep on
        // ggml-tiny showed short-clip WER regressions under truncation
        // (en_numbers_and_dates 5.17s, 0.29 → 0.36). Use whisper's
        // default 1500-token (= 30s) context to preserve baseline
        // quality for dictation.
        let text = await transcription.transcribeOnce(samples: captured,
                                                      language: action.languageCode,
                                                      audioCtx: 0)
        // The final pass has run, so this dictation no longer needs the
        // model: batch-only mode releases it once nothing else is using it.
        if let hold { transcription.endLocalModelHold(hold) }

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
            // `url` is `store.freshAudioURL(...)` — inside the recordings
            // directory, which is the folder the user chose in Settings →
            // Storage. Cocoa quotes the file AND its containing folder in
            // `localizedDescription` ("…in the folder “Acme Corp Client X”"),
            // so the message leaks that choice even though the filename
            // itself is the fixed "Dictation" stem. Domain + code stay public:
            // "no permission" (NSCocoaErrorDomain 513) versus a full disk
            // versus a missing directory is the entire diagnostic, and neither
            // names a path. (Issue #213, CWE-532.)
            let ns = error as NSError
            dictationLog.error("""
                dictation save failed \
                [\(ns.domain, privacy: .public) \(ns.code, privacy: .public)]: \
                \(error.localizedDescription, privacy: .private)
                """)
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
        let priorContents = Self.snapshotPasteboard(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Without Accessibility trust, CGEvent.post is silently dropped by
        // macOS — the user would see "I dictated, nothing happened" with no
        // explanation. Surface a one-shot alert and leave the text on the
        // clipboard so they can paste manually with ⌘V.
        guard AccessibilityPermission.isTrusted() else {
            AccessibilityPermission.notifyMissing()
            // Do NOT restore the prior clipboard contents — the transcript
            // is the user's only path to the dictated text right now.
            targetApp = nil
            return
        }

        // Re-activate the user's intended app so the synthesized ⌘V lands
        // there instead of in Mila itself. If the captured target
        // is gone (quit during recording) we fall through and the paste
        // hits whatever app is currently frontmost — best effort.
        let captured = targetApp
        targetApp = nil
        if let target = captured, !target.isTerminated, !target.isActive {
            target.activate()
        }

        // Give the OS ~120ms to actually move focus to the target app
        // before posting the keystrokes; otherwise the synthesized events
        // can race the activation and land in the previously-frontmost
        // window instead.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120)) {
            Self.postCommandV()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if !priorContents.isEmpty {
                    Self.restorePasteboard(pasteboard, from: priorContents)
                }
            }
        }
    }

    // MARK: - Pasteboard snapshot/restore

    /// Full-fidelity pasteboard snapshot: every item with every type it
    /// carries. The old `string(forType: .string)`-only snapshot destroyed
    /// any non-text clipboard content — copy a screenshot, dictate a
    /// caption, and the screenshot was gone forever (the restore step was
    /// skipped entirely because the string snapshot came back nil).
    ///
    /// Static + pasteboard-parameterized so tests can exercise the round
    /// trip against a private named pasteboard instead of the user's real
    /// clipboard.
    static func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                // Lazily-promised types can resolve to nil; skip those
                // rather than fail the whole snapshot.
                if let data = item.data(forType: type) {
                    entry[type] = data
                }
            }
            return entry
        }
    }

    static func restorePasteboard(_ pasteboard: NSPasteboard,
                                  from snapshot: [[NSPasteboard.PasteboardType: Data]]) {
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = snapshot.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }

    /// Synthesize a Cmd+V at the HID event-tap level. Requires the process
    /// to be Accessibility-trusted; the caller is responsible for that
    /// check (see `AccessibilityPermission.isTrusted()`).
    private static func postCommandV() {
        let src = CGEventSource(stateID: .hidSystemState)
        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: true)
        let vDown   = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
        let vUp     = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        let cmdUp   = CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: false)
        // Some apps inspect the event flags rather than the global modifier
        // state. Setting the Command flag on every event in the sequence is
        // the most defensive thing we can do.
        cmdDown?.flags = .maskCommand
        vDown?.flags   = .maskCommand
        vUp?.flags     = .maskCommand
        cmdUp?.flags   = .maskCommand
        cmdDown?.post(tap: .cghidEventTap)
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)
    }
}
