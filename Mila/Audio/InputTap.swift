import AVFoundation
import ObjCExceptionCatcher

/// Installing an input tap without letting `AVAudioEngine` take the app down.
///
/// `installTap(onBus:bufferSize:format:block:)` does not report a bad format
/// through an error: it raises an `NSException`, and an exception unwinding
/// into Swift terminates the process. The format it rejects is one that was
/// correct a moment earlier. Bluetooth headphones re-negotiate when their
/// microphone opens — AirPods drop from 48 kHz to their 24 kHz call profile
/// when a call app already holds them — and the switch can complete between
/// `inputFormat(forBus:)` returning and the tap being installed. In #385 that
/// window was 11 ms, and starting a recording mid-call aborted Mila.
///
/// (macOS 27 adds an `installTapOnBus:…error:block:` variant; it is not
/// available on the 14.0 deployment target, so the exception is caught
/// instead — one path for every supported OS.)
enum InputTap {

    /// `node.installTap(onBus: 0, …)`, with the exception it raises turned
    /// into a thrown error. Nothing is installed when it throws.
    static func install(on node: AVAudioNode,
                        bufferSize: AVAudioFrameCount,
                        format: AVAudioFormat,
                        block: @escaping AVAudioNodeTapBlock) throws {
        try ObjCException.catching {
            node.installTap(onBus: 0, bufferSize: bufferSize, format: format, block: block)
        }
    }

    /// Install with `initial`; if that is refused and the node now reports a
    /// different, usable format, install once more with that one. Returns the
    /// format the tap was installed with — the caller's converter and logs
    /// must follow it, since a 24 kHz tap fed to a 48 kHz converter is
    /// resampled at the wrong ratio.
    ///
    /// One retry, not a loop: the profile switch this exists for settles in
    /// one step, and a format that keeps moving is a device the caller's own
    /// failure path (the start banner, the watchdog's rebuild) handles better
    /// than a spin here. When the format did NOT change, retrying cannot help
    /// and the original error is rethrown.
    static func installFollowingFormatChange(
        initial: AVAudioFormat,
        currentFormat: () -> AVAudioFormat,
        install: (AVAudioFormat) throws -> Void
    ) throws -> AVAudioFormat {
        do {
            try install(initial)
            return initial
        } catch {
            let now = currentFormat()
            guard now.sampleRate > 0, now.channelCount > 0, now != initial else { throw error }
            try install(now)
            return now
        }
    }
}
