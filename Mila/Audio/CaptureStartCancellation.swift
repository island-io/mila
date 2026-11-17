import Foundation
import os

/// A one-way "stop bringing capture up" flag, shared between the main actor
/// (which trips it: `QuickActionsController.abandonStartingRecording`) and the
/// bring-up, which checks it — including from the detached CoreAudio worker in
/// `MicrophoneRecorder.realBringUp`, hence the lock rather than actor state.
///
/// It exists so a sleep / lock that arrives while a start is still in flight
/// (#328) stops capture from ever opening, instead of letting the microphone
/// — and macOS's orange privacy indicator — come on for the controller's
/// post-return cleanup to take down again. The bring-up checks it immediately
/// before the point where capture actually opens (`AVAudioEngine.start()`,
/// `SCStream.startCapture()`) and after each slow step before that.
///
/// Checking is not atomic with opening capture: a cancel that arrives after
/// the last check still sees capture come up, and the controller's existing
/// `abandonStartIfRequested` teardown remains the backstop for it.
final class CaptureStartCancellation: Sendable {
    /// Thrown by the bring-up in place of opening capture.
    struct Cancelled: Error, Equatable {}

    private let flag = OSAllocatedUnfairLock(initialState: false)

    init() {}

    var isCancelled: Bool { flag.withLock { $0 } }

    func cancel() { flag.withLock { $0 = true } }

    func throwIfCancelled() throws {
        if isCancelled { throw Cancelled() }
    }
}
