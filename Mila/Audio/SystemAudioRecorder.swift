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

    /// The CURRENT session's buffers. Every `start()` installs a brand-new
    /// stream, so read this after `start()` returns — the same contract as
    /// `MicrophoneRecorder.audioStream`.
    ///
    /// It used to be a single `let` built in `init` and shared by every
    /// recording for the life of the process. `RecordingSession.stop()`
    /// cancels the task iterating it, and cancelling an `AsyncStream`'s
    /// consumer TERMINATES the stream: from then on every `yield` returns
    /// `.terminated` and every new `for await` ends at once. So only the
    /// first app-audio or meeting recording after launch captured app audio;
    /// each later one ran with a perfectly healthy SCStream whose buffers went
    /// nowhere — an app-audio recording saved 0 samples ("too quiet to be real
    /// speech"), and a meeting silently lost the other side of the call.
    private(set) var audioStream: AsyncStream<AVAudioPCMBuffer>
    private var audioContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation

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

    /// Test seam: when set, replaces the ScreenCaptureKit bring-up so tests
    /// can drive a session's stream lifecycle without a Screen Recording
    /// grant or a display. Used for mid-session restarts too. Buffers are
    /// then pushed in with `deliverForTesting(_:)`.
    var bringUpOverride: (@MainActor () async throws -> Void)?

    /// Bumped by every `start()` and `stop()`. A restart loop captures the
    /// value it began with and abandons itself as soon as it no longer
    /// matches, because `wantsCapture` alone cannot tell "my session still
    /// wants capture" from "a *later* session does". Without this, a
    /// stop → start inside a restart's backoff window (or inside its bring-up)
    /// would let the stale loop hand `stream` a replacement it built for the
    /// previous recording — leaking the new session's live stream, which then
    /// keeps capturing for the rest of the process while both streams feed the
    /// same continuation. Same epoch guard `LiveTranscriber` uses.
    private var captureEpoch = 0

    /// Does the session that started this work still own the recorder?
    private func stillOwns(epoch: Int) -> Bool {
        wantsCapture && captureEpoch == epoch
    }

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

    /// Finish the previous session's stream and install a fresh one — on the
    /// sample queue, the only context the SCK callback reads `continuation`
    /// from. Per SESSION, not per bring-up: a mid-session restart must keep
    /// feeding the stream `RecordingSession` is already iterating.
    private func installFreshStream() {
        audioContinuation.finish()
        var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation!
        audioStream = AsyncStream { continuation = $0 }
        audioContinuation = continuation
        let fresh: AsyncStream<AVAudioPCMBuffer>.Continuation = continuation
        sampleQueue.sync { audioOutput.continuation = fresh }
    }

    /// Test seam: push a buffer through the same convert-and-yield path an
    /// SCK audio callback takes, on the same serial queue.
    func deliverForTesting(_ buffer: AVAudioPCMBuffer) {
        sampleQueue.sync { audioOutput.deliver(buffer) }
    }

    /// Test seam: push a raw SCK-shaped sample buffer through the same
    /// copy-validate-deliver path the stream callback takes.
    func deliverSampleForTesting(_ sample: CMSampleBuffer) {
        sampleQueue.sync { audioOutput.handleAudioSample(sample) }
    }

    /// Packets dropped as malformed since the last `stop()` (which reports
    /// and resets the tally).
    var rejectedPacketCount: Int {
        sampleQueue.sync { audioOutput.rejectedPackets }
    }

    /// Log how many packets this session dropped, and reset the tally. Called
    /// once the stream has stopped delivering (or was already gone).
    private func reportRejectedPackets() {
        let rejected = sampleQueue.sync { audioOutput.takeRejectedPacketCount() }
        if rejected > 0 {
            sysLog.error("dropped \(rejected, privacy: .public) malformed system-audio packet(s) this session — the first drop's reason was logged when it happened")
        }
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

    /// `cancellation` — see `MicrophoneRecorder.start(cancellation:)`: once
    /// tripped, the bring-up throws `CaptureStartCancellation.Cancelled`
    /// instead of starting the stream (#328).
    func start(cancellation: CaptureStartCancellation? = nil) async throws {
        guard !isRunning else { return }
        try cancellation?.throwIfCancelled()
        captureEpoch += 1
        let epoch = captureEpoch
        wantsCapture = true
        restartAttempts = 0
        restartCount = 0
        installFreshStream()
        do {
            try await bringUpStream(epoch: epoch, cancellation: cancellation)
        } catch {
            wantsCapture = false
            throw error
        }
    }

    /// The SCStream bring-up proper. Split out of `start()` so a mid-session
    /// restart re-runs exactly the same setup (fresh shareable content, fresh
    /// filter) without resetting the restart budget or the `wantsCapture`
    /// intent.
    ///
    /// Returns whether the new stream was actually adopted: this suspends
    /// twice (shareable content, `startCapture`), and a `stop()` — or a whole
    /// stop/start cycle — can land in between, in which case the stream is
    /// released here rather than installed on top of a newer session's.
    @discardableResult
    private func bringUpStream(epoch: Int,
                               cancellation: CaptureStartCancellation? = nil) async throws -> Bool {
        if let override = bringUpOverride {
            sampleQueue.sync { audioOutput.resetConverter() }
            try await override()
            try cancellation?.throwIfCancelled()
            guard epoch == captureEpoch else { return false }
            self.isRunning = true
            self.lastStreamError = nil
            return true
        }
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
        // Last point a start abandoned during the shareable-content wait can
        // stop without capture opening (#328). The stream was never started;
        // detach the long-lived `audioOutput` from it and let it go.
        if cancellation?.isCancelled == true {
            try? stream.removeStreamOutput(audioOutput, type: .audio)
            try? stream.removeStreamOutput(audioOutput, type: .screen)
            sysLog.log("system-audio bring-up cancelled before startCapture — capture never opened")
            throw CaptureStartCancellation.Cancelled()
        }
        try await stream.startCapture()
        // Adopt only if this is still the session that asked. Assigning
        // `self.stream` unconditionally would drop a newer session's stream on
        // the floor without stopping it — it would keep capturing screen and
        // audio for the rest of the process, and both streams would push
        // samples into the same continuation.
        guard epoch == captureEpoch else {
            sysLog.error("system-audio bring-up finished after its session ended (epoch \(epoch, privacy: .public) ≠ \(self.captureEpoch, privacy: .public)) — releasing the stream instead of adopting it")
            try? await stream.stopCapture()
            return false
        }
        self.stream = stream
        self.isRunning = true
        self.lastStreamError = nil
        return true
    }

    func stop() async {
        // Clear the intent first so a `didStopWithError` callback racing this
        // teardown can't kick off a restart of a capture the user just ended,
        // and bump the epoch so any restart already in flight abandons itself
        // even if a new recording sets `wantsCapture` back to true meanwhile.
        wantsCapture = false
        captureEpoch += 1
        // End this session's stream so its consumer's `for await` returns on
        // its own. The next `start()` builds a new one either way.
        audioContinuation.finish()
        // Deliberately NOT gated on `isRunning`: when SCK killed the stream
        // itself (`didStopWithError` flips isRunning to false), the old
        // `guard isRunning` made this a no-op and the dead SCStream stayed
        // retained for the app's lifetime.
        guard let stream else {
            // No SCStream: SCK killed it, or this is the `bringUpOverride`
            // test path, which never builds one.
            reportRejectedPackets()
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
        reportRejectedPackets()
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
        let epoch = captureEpoch
        var cause = error
        while true {
            switch Self.restartDecision(wantsCapture: stillOwns(epoch: epoch),
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
            guard stillOwns(epoch: epoch) else { return }

            do {
                // `bringUpStream` re-checks the epoch at the moment it would
                // adopt, and releases the stream itself if the session moved
                // on — so a stale loop can never replace a live stream.
                guard try await bringUpStream(epoch: epoch) else { return }
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

    /// Packets `SystemAudioPCM` refused since the last `takeRejectedPacketCount()`.
    /// Only touched on the serial sample queue. Per-buffer hot path, so the
    /// first rejection is logged with its reason and the rest are only
    /// counted; `SystemAudioRecorder.stop()` reports the total — the same
    /// first-one-then-a-count shape as the mic tap's conversion failures.
    private(set) var rejectedPackets = 0

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio else { return }
        handleAudioSample(sampleBuffer)
    }

    /// Copy one SCK audio packet into owned storage and deliver it, or count
    /// and (the first time) log why it was dropped. Validity is checked once,
    /// inside `SystemAudioPCM.copy`. Only called on the serial sample queue.
    func handleAudioSample(_ sampleBuffer: CMSampleBuffer) {
        switch SystemAudioPCM.copy(from: sampleBuffer) {
        case .success(let buffer):
            deliver(buffer)
        case .failure(let rejection):
            rejectedPackets += 1
            if rejectedPackets == 1 {
                sysLog.error("dropping system-audio packet: \(rejection.description, privacy: .public) — further drops this session are counted, not logged")
            }
        }
    }

    /// Return the drop count and start a fresh tally, so the next session
    /// logs its own first rejection. Sample queue only.
    func takeRejectedPacketCount() -> Int {
        defer { rejectedPackets = 0 }
        return rejectedPackets
    }

    /// Convert to whisper format and yield. Only called on the recorder's
    /// serial sample queue.
    func deliver(_ buffer: AVAudioPCMBuffer) {
        do {
            if converter == nil || converter?.inputFormat != buffer.format {
                converter = StreamingWhisperConverter(inputFormat: buffer.format)
            }
            let converted = try converter?.convert(buffer)
                ?? AudioConvert.toWhisperFormat(buffer)
            // Metered before the yield only so the producer is done with the
            // buffer once it is handed off. Not a safety requirement: every
            // reader on both sides (`AudioMeter.level`, `AudioConvert.samples`)
            // goes through the read-only `audioBufferList`, so a concurrent
            // read by the consumer would not race a write here.
            let level = AudioMeter.level(from: converted)
            continuation?.yield(converted)
            Task { @MainActor [weak parent] in
                parent?.publishLevel(level)
            }
        } catch {
            print("System audio convert: \(error)")
        }
    }
}

/// Copy ScreenCaptureKit PCM into owned storage before asynchronous delivery.
/// Core Media handles planar/interleaved lists and checks the source extent;
/// never trust a source byte count as the capacity of a destination buffer.
enum SystemAudioPCM {
    /// Why a packet was dropped. The stream output logs the first one per
    /// session and the total at stop, so a recording that loses its app-audio
    /// leg packet by packet says why instead of going quiet.
    enum Rejection: Error, Equatable, CustomStringConvertible {
        case invalid
        case dataNotReady
        case missingFormatDescription
        case notLinearPCM(formatID: AudioFormatID)
        case noFrames
        case unsupportedSampleRate(Double)
        case tooManyFrames(Int, limit: Int)
        case unsupportedFormat
        case allocationFailed(frames: Int)
        case copyFailed(OSStatus)

        var description: String {
            switch self {
            case .invalid:
                return "sample buffer is not valid"
            case .dataNotReady:
                return "sample buffer data is not ready"
            case .missingFormatDescription:
                return "no audio stream description"
            case .notLinearPCM(let formatID):
                return "not linear PCM (format ID \(formatID))"
            case .noFrames:
                return "packet has no frames"
            case .unsupportedSampleRate(let rate):
                return "unusable sample rate \(rate)"
            case .tooManyFrames(let frames, let limit):
                return "packet claims \(frames) frames, over the \(limit)-frame cap"
            case .unsupportedFormat:
                return "AVAudioFormat rejected the stream description"
            case .allocationFailed(let frames):
                return "could not allocate a \(frames)-frame buffer"
            case .copyFailed(let status):
                return "CMSampleBufferCopyPCMDataIntoAudioBufferList failed (OSStatus \(status))"
            }
        }
    }

    /// Longest packet accepted, in seconds of audio at the packet's own
    /// sample rate. SCK delivers ~10–20 ms at a time; the cap exists so a
    /// corrupt frame count can't size a huge allocation on the sample queue
    /// before the copy gets a chance to fail.
    static let maxPacketSeconds: Double = 2

    /// Frame cap for a packet at `sampleRate`, or nil for a rate no real
    /// stream has (non-finite, non-positive, or above 1 MHz). Every value it
    /// returns is far below `Int32.max`, which is what makes the narrowing
    /// conversions in `copy(from:)` safe.
    static func maxFrames(sampleRate: Double) -> Int? {
        guard sampleRate.isFinite, sampleRate > 0, sampleRate <= 1_000_000 else { return nil }
        return max(1, Int(sampleRate * maxPacketSeconds))
    }

    static func buffer(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        try? copy(from: sample).get()
    }

    static func copy(from sample: CMSampleBuffer) -> Result<AVAudioPCMBuffer, Rejection> {
        guard CMSampleBufferIsValid(sample) else { return .failure(.invalid) }
        guard CMSampleBufferDataIsReady(sample) else { return .failure(.dataNotReady) }
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            return .failure(.missingFormatDescription)
        }
        var streamDescription = asbd.pointee
        guard streamDescription.mFormatID == kAudioFormatLinearPCM else {
            return .failure(.notLinearPCM(formatID: streamDescription.mFormatID))
        }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0 else { return .failure(.noFrames) }
        guard let limit = maxFrames(sampleRate: streamDescription.mSampleRate) else {
            return .failure(.unsupportedSampleRate(streamDescription.mSampleRate))
        }
        // Checked BEFORE allocating: the destination is sized from this count.
        guard frames <= limit else { return .failure(.tooManyFrames(frames, limit: limit)) }
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            return .failure(.unsupportedFormat)
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)) else {
            return .failure(.allocationFailed(frames: frames))
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else { return .failure(.copyFailed(status)) }
        return .success(buffer)
    }
}
