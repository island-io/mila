import Foundation
import AVFoundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import Combine

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
                return "Screen & System Audio Recording permission is required to capture app audio. Open System Settings → Privacy & Security → Screen & System Audio Recording, remove any old IslandWhisper entry, then re-add this build."
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

    let audioStream: AsyncStream<AVAudioPCMBuffer>
    private let audioContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation

    private var stream: SCStream?
    private let audioOutput = AudioStreamOutput()

    override init() {
        var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation!
        self.audioStream = AsyncStream { continuation = $0 }
        self.audioContinuation = continuation
        super.init()
        self.audioOutput.parent = self
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
            print("SCShareableContent error: \(error)")
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

    static func isPermissionError(_ error: Error) -> Bool {
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
                                   sampleHandlerQueue: .global(qos: .userInitiated))
        try stream.addStreamOutput(audioOutput,
                                   type: .screen,
                                   sampleHandlerQueue: .global(qos: .utility))
        try await stream.startCapture()
        self.stream = stream
        self.isRunning = true
    }

    func stop() async {
        guard isRunning, let stream else { return }
        do { try await stream.stopCapture() } catch { print("stopCapture: \(error)") }
        self.stream = nil
        self.isRunning = false
        self.level = 0
    }

    fileprivate func handle(buffer: AVAudioPCMBuffer) {
        let level = AudioMeter.level(from: buffer)
        Task { @MainActor in self.level = level }
        audioContinuation.yield(buffer)
    }

    deinit {
        audioContinuation.finish()
    }
}

extension SystemAudioRecorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("SCStream stopped with error: \(error)")
        Task { @MainActor in
            self.isRunning = false
            self.level = 0
        }
    }
}

private final class AudioStreamOutput: NSObject, SCStreamOutput {
    weak var parent: SystemAudioRecorder?

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio,
              CMSampleBufferIsValid(sampleBuffer),
              let buffer = sampleBuffer.toPCMBuffer() else { return }
        do {
            let converted = try AudioConvert.toWhisperFormat(buffer)
            Task { @MainActor [weak parent] in
                parent?.handle(buffer: converted)
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
