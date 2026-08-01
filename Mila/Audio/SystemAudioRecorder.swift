import Foundation
import AVFoundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import Combine
import OSLog
import TranscriptionCore

private let sysLog = Logger(subsystem: "io.island.whisper.IslandWhisper", category: "SystemAudioRecorder")

/// Captures system audio (optionally limited to a single application like Zoom) via ScreenCaptureKit.
///
/// SCK requires at least a video stream to function, so we configure a 2x2 placeholder video
/// stream alongside the audio output. We only consume audio samples.
@MainActor
final class SystemAudioRecorder: NSObject, ObservableObject {
    /// Specific error type so callers can distinguish "user has not granted
    /// Screen & System Audio Recording permission" from generic SCK errors.
    /// The UI uses this to show a button that jumps directly to the right
    /// pane in System Settings.
    enum CaptureError: LocalizedError {
        case permissionDenied
        case noDisplay
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Screen & System Audio Recording permission is required to capture app audio. Open System Settings → Privacy & Security → Screen & System Audio Recording, remove any old Mila entry, then re-add this build."
            case .noDisplay:
                return "No display available to attach the audio stream to."
            case .underlying(let error):
                return error.localizedDescription
            }
        }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var availableApps: [SCRunningApplication] = []
    @Published var selectedApp: SCRunningApplication?
    @Published private(set) var level: Float = 0

    /// Set when SCK kills the stream from its own side mid-capture (TCC
    /// revocation, display disconnect). Cleared on the next successful
    /// `start()`. Lets callers tell "meeting silently lost its app-audio
    /// leg" apart from a normal stop.
    @Published private(set) var lastStreamError: String?

    let audioStream: AsyncStream<AVAudioPCMBuffer>
    private let audioContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation

    private var stream: SCStream?
    private let audioOutput = AudioStreamOutput()

    /// True between `start()` and `stop()` — i.e. "the app still wants system
    /// audio", as opposed to `isRunning` which tracks whether a live SCStream
    /// exists right now. The two diverge exactly when SCK kills the stream
    /// from its side, which is the window where a restart is the right move.
    private var wantsCapture = false

    /// Self-restarts after an SCK-side stream death in the current session.
    /// Bounded so a permanently broken capture (revoked TCC) logs a handful of
    /// attempts instead of spinning for the length of a meeting.
    private var restartAttempts = 0
    private let maxRestartAttempts = 5
    private(set) var restartCount = 0

    /// Serial delivery queue for the audio sample callbacks. `.global()`
    /// is a CONCURRENT queue: two SCK callbacks can run in parallel, and
    /// the per-buffer Task hop the old code used added a second unordered
    /// step — under CPU load, consecutive ~10-20ms chunks could land in
    /// `audioStream` out of capture order (audible garbling in the saved
    /// mix). A private serial queue plus a direct yield (below) preserves
    /// capture order end-to-end.
    private let sampleQueue = DispatchQueue(label: "io.island.mila.system-audio-samples",
                                            qos: .userInitiated)

    override init() {
        var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation!
        self.audioStream = AsyncStream { continuation = $0 }
        self.audioContinuation = continuation
        super.init()
        self.audioOutput.parent = self
        self.audioOutput.continuation = continuation
    }

    func refreshShareableContent() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                                onScreenWindowsOnly: false)
            let unique = Dictionary(grouping: content.applications, by: { $0.bundleIdentifier })
                .compactMap { $0.value.first }
                .sorted { $0.applicationName.lowercased() < $1.applicationName.lowercased() }
            self.availableApps = unique.filter { !$0.applicationName.isEmpty }
        } catch {
            sysLog.error("SCShareableContent failed: \(error.localizedDescription, privacy: .public)")
            self.availableApps = []
        }
    }

    /// Quick read of whether ScreenCaptureKit will let us proceed without
    /// raising the TCC dialog. Returns `false` if permission is missing or
    /// stale (e.g. the on-disk binary's signature changed and macOS is
    /// holding a now-invalid grant for a previous build).
    static func hasScreenRecordingPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false,
                                                                     onScreenWindowsOnly: true)
            return true
        } catch {
            return !Self.isPermissionError(error)
        }
    }

    nonisolated static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        // SCStreamErrorDomain code -3801 = userDeclined
        if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain"
            && nsError.code == -3801 {
            return true
        }
        // TCC denial is sometimes surfaced through the generic SC error domain.
        let desc = nsError.localizedDescription.lowercased()
        return desc.contains("not authorized")
            || desc.contains("not granted")
            || desc.contains("declined")
            || desc.contains("permission")
    }

    func start() async throws {
        guard !isRunning else { return }
        wantsCapture = true
        restartAttempts = 0
        restartCount = 0
        do {
            try await bringUpStream()
        } catch {
            wantsCapture = false
            throw error
        }
    }

    /// The SCStream bring-up proper. Split out of `start()` so a mid-session
    /// restart re-runs exactly the same setup (fresh shareable content, fresh
    /// filter) without resetting the restart budget or the `wantsCapture`
    /// intent.
    private func bringUpStream() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                            onScreenWindowsOnly: false)
        } catch {
            if Self.isPermissionError(error) { throw CaptureError.permissionDenied }
            throw CaptureError.underlying(error)
        }
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter: SCContentFilter
        if let app = selectedApp {
            let windows = content.windows.filter { $0.owningApplication?.processID == app.processID }
            filter = SCContentFilter(display: display,
                                     including: [app],
                                     exceptingWindows: [])
            _ = windows
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
        }

        let config = SCStreamConfiguration()
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 5
        config.showsCursor = false
        config.capturesAudio = true
        config.sampleRate = Int(WhisperAudioFormat.sampleRate)
        config.channelCount = 1
        config.excludesCurrentProcessAudio = true

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(audioOutput,
                                   type: .audio,
                                   sampleHandlerQueue: sampleQueue)
        try stream.addStreamOutput(audioOutput,
                                   type: .screen,
                                   sampleHandlerQueue: .global(qos: .utility))
        // `audioOutput` outlives capture sessions — drop the previous
        // session's resampler state (filter history must not smear the
        // last recording's tail into this one's first buffers). On the
        // sample queue, since that's the only context that touches it;
        // it's idle until startCapture below.
        sampleQueue.sync { audioOutput.resetConverter() }
        try await stream.startCapture()
        self.stream = stream
        self.isRunning = true
        self.lastStreamError = nil
    }

    func stop() async {
        // Clear the intent first so a `didStopWithError` callback racing this
        // teardown can't kick off a restart of a capture the user just ended.
        wantsCapture = false
        // Deliberately NOT gated on `isRunning`: when SCK killed the stream
        // itself (`didStopWithError` flips isRunning to false), the old
        // `guard isRunning` made this a no-op and the dead SCStream stayed
        // retained for the app's lifetime.
        guard let stream else {
            isRunning = false
            level = 0
            return
        }
        if restartCount > 0 {
            sysLog.error("system-audio capture was restarted \(self.restartCount, privacy: .public)x this session after SCK killed the stream")
        }
        do {
            try await stream.stopCapture()
        } catch {
            sysLog.error("stopCapture failed: \(error.localizedDescription, privacy: .public)")
        }
        self.stream = nil
        self.isRunning = false
        self.level = 0
    }

    fileprivate func publishLevel(_ level: Float) {
        self.level = level
    }

    deinit {
        audioContinuation.finish()
    }
}

extension SystemAudioRecorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription
        // Logger, not print: `print` output never reaches OSLog, so when a
        // user's meeting lost its app-audio leg mid-recording the diagnostic
        // bundle had no trace of it at all — the SCStream teardown was only
        // visible through ScreenCaptureKit's own internal log lines, which
        // don't say who asked for it or why.
        sysLog.error("SCStream stopped with error: \(message, privacy: .public)")
        Task { @MainActor in
            // Only act for the CURRENTLY active stream — a stale callback
            // from a previous session's stream arriving after a restart
            // must not clear the new stream or surface an old error.
            guard self.stream === stream else { return }
            // SCK killed the stream from its side (TCC revocation, display
            // config change, ...). Release the dead stream and record the
            // failure — before this, `stream` stayed set (leaked) and the
            // meeting recording silently degraded to mic-only with no
            // signal anywhere.
            self.stream = nil
            self.isRunning = false
            self.level = 0
            self.lastStreamError = message
            await self.restartAfterStreamDeath(error)
        }
    }

    /// Whether an SCK-side stream death should be retried.
    ///
    /// Pure and `nonisolated` so `SystemAudioRestartPolicyTests` can cover the
    /// decisions without ScreenCaptureKit, a Screen Recording grant, or a real
    /// `SCStream` to hand to the delegate.
    enum RestartDecision: Equatable {
        /// `stop()` already ran — the user ended the recording, so a dead
        /// stream is expected rather than something to repair.
        case sessionOver
        /// A revoked or stale grant fails identically every time; retrying
        /// just buries the real reason under repeated failures.
        case permissionDenied
        case budgetExhausted
        case retry
    }

    nonisolated static func restartDecision(wantsCapture: Bool,
                                            attemptsSoFar: Int,
                                            maxAttempts: Int,
                                            error: Error) -> RestartDecision {
        guard wantsCapture else { return .sessionOver }
        if isPermissionError(error) { return .permissionDenied }
        guard attemptsSoFar < maxAttempts else { return .budgetExhausted }
        return .retry
    }

    /// Try to get the app-audio leg back after SCK killed the stream mid-
    /// recording. Losing it silently costs the whole other side of a meeting,
    /// so a bounded retry is well worth a brief gap.
    private func restartAfterStreamDeath(_ error: Error) async {
        // Loop rather than attempt once: `didStopWithError` is the only trigger
        // for this method, and a bring-up that throws never created a stream —
        // so no further callback can ever arrive. A single failed attempt would
        // therefore be terminal and the retry budget would be decoration, even
        // though the common causes (a display being reconfigured, no display
        // available for a moment) clear on their own within a second or two.
        var cause = error
        while true {
            switch Self.restartDecision(wantsCapture: wantsCapture,
                                        attemptsSoFar: restartAttempts,
                                        maxAttempts: maxRestartAttempts,
                                        error: cause) {
            case .sessionOver:
                return
            case .permissionDenied:
                sysLog.error("not restarting system audio: Screen & System Audio Recording permission was denied or revoked mid-capture")
                return
            case .budgetExhausted:
                sysLog.error("giving up on system-audio capture after \(self.maxRestartAttempts, privacy: .public) restart attempts — the rest of this recording is microphone-only")
                return
            case .retry:
                break
            }
            restartAttempts += 1
            let attempt = restartAttempts

            // Back off before attempting, growing with each try, so the budget
            // spans a real transient window instead of being spent inside a
            // single display reconfiguration. `Task.sleep` suspends rather than
            // blocking, so the main actor stays free throughout.
            try? await Task.sleep(nanoseconds: UInt64(Self.restartBackoff(attempt: attempt) * 1_000_000_000))
            guard wantsCapture else { return }

            do {
                try await bringUpStream()
                // Same hazard as the mic side: `bringUpStream` suspends, and
                // `stop()` can run while it does. A stream adopted after the
                // recording ended would keep capturing for the rest of the
                // process, since nothing is left to stop it.
                guard wantsCapture else {
                    sysLog.error("system-audio restart #\(attempt, privacy: .public) finished after the recording ended — releasing the orphaned stream")
                    await stop()
                    return
                }
                restartCount += 1
                sysLog.log("system-audio capture restarted (attempt #\(attempt, privacy: .public)) — app audio is being captured again")
                return
            } catch {
                cause = error
                sysLog.error("system-audio restart attempt #\(attempt, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Delay before restart attempt `attempt` (1-based). Grows linearly so five
    /// attempts cover ~7.5s of a transient outage without a long first wait.
    nonisolated static func restartBackoff(attempt: Int) -> TimeInterval {
        0.5 * Double(max(1, attempt))
    }
}

private final class AudioStreamOutput: NSObject, SCStreamOutput {
    weak var parent: SystemAudioRecorder?

    /// Handed over once at recorder init. Yielding directly here — on the
    /// recorder's serial sample-handler queue — keeps buffers in capture
    /// order end-to-end (`AsyncStream.Continuation.yield` is thread-safe);
    /// only the cosmetic level meter hops to the main actor. The old
    /// per-buffer `Task { @MainActor … yield }` hop gave every chunk its
    /// own unordered task, so delivery order wasn't guaranteed.
    var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    /// Session-scoped stateful converter (resampling keeps filter history
    /// across buffers — see StreamingWhisperConverter). Built lazily from
    /// the first buffer's format and rebuilt if SCK ever changes it; only
    /// touched on the serial sample-handler queue.
    private var converter: StreamingWhisperConverter?

    /// Called (on the sample queue) at the start of each capture session.
    func resetConverter() {
        converter = nil
    }

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio,
              CMSampleBufferIsValid(sampleBuffer),
              let buffer = sampleBuffer.toPCMBuffer() else { return }
        do {
            if converter == nil || converter?.inputFormat != buffer.format {
                converter = StreamingWhisperConverter(inputFormat: buffer.format)
            }
            let converted = try converter?.convert(buffer)
                ?? AudioConvert.toWhisperFormat(buffer)
            continuation?.yield(converted)
            let level = AudioMeter.level(from: converted)
            Task { @MainActor [weak parent] in
                parent?.publishLevel(level)
            }
        } catch {
            print("System audio convert: \(error)")
        }
    }
}

private extension CMSampleBuffer {
    /// Convert a CMSampleBuffer carrying audio (interleaved or planar) into an AVAudioPCMBuffer.
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }

        var asbdMutable = asbd.pointee
        guard let avFormat = AVAudioFormat(streamDescription: &asbdMutable) else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList(mNumberBuffers: 1,
                                              mBuffers: AudioBuffer(mNumberChannels: avFormat.channelCount,
                                                                    mDataByteSize: 0,
                                                                    mData: nil))

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer)

        guard status == noErr else { return nil }

        let dest = buffer.mutableAudioBufferList
        let srcList = UnsafeMutableAudioBufferListPointer(&audioBufferList)
        let dstList = UnsafeMutableAudioBufferListPointer(dest)
        for i in 0..<min(srcList.count, dstList.count) {
            let src = srcList[i]
            var dst = dstList[i]
            dst.mDataByteSize = src.mDataByteSize
            if let s = src.mData, let d = dst.mData {
                memcpy(d, s, Int(src.mDataByteSize))
            }
            dstList[i] = dst
        }
        return buffer
    }
}
