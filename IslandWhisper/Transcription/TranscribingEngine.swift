import Foundation

/// Abstraction over `WhisperEngine` so transcription can be unit-tested with
/// a stub instead of depending on whisper.cpp + a 1.5GB model on disk.
///
/// The conformance is `Sendable` so the engine can safely be held by
/// `TranscriptionService` (a `@MainActor` class) and called across actor
/// boundaries without warnings under strict concurrency.
protocol TranscribingEngine: Sendable {
    /// Load the model at `modelURL` if it isn't already loaded. Idempotent.
    func loadIfNeeded(modelURL: URL, displayName: String) async throws

    /// Run synchronous transcription on a buffer of mono 16kHz Float32 samples.
    /// `progress` is invoked with values in `0...1` while the work is running.
    func transcribe(samples: [Float],
                    language: String,
                    progress: (@Sendable (Float) -> Void)?) async throws -> [TranscriptSegment]

    /// Synchronously release any resources (model context, GPU buffers) held
    /// by the engine. Called from the AppDelegate during graceful shutdown so
    /// libc++ doesn't tear them down at static destruction time, which is
    /// what triggered the ggml-metal `ggml_abort` crash on quit.
    func shutdown() async
}
