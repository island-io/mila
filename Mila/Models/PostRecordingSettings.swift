import Foundation

/// Controls whether recordings use live transcription or batch-only mode.
///
/// When `batchOnly` is ON:
///   * Audio is captured normally but the live pipeline (LiveTranscriber,
///     LiveSpeakerDiarizer, LiveAI) is not started.
///   * On stop, the recording saves immediately without the rename sheet,
///     auto-titled from the meeting app name or the date.
///   * Transcription, diarization, and summary run in the background via
///     the existing batch queue.
///
/// Default is OFF — preserving the current live transcription behavior.
@MainActor
final class PostRecordingSettings: ObservableObject {
    @Published var batchOnly: Bool {
        didSet { defaults.set(batchOnly, forKey: Keys.batchOnly) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.batchOnly = defaults.bool(forKey: Keys.batchOnly)
    }

    deinit {}

    private enum Keys {
        static let batchOnly = "postRecording.batchOnly"
    }
}
