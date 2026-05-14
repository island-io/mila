import Foundation

public protocol TranscribingEngine: Sendable {
    func loadIfNeeded(modelURL: URL, displayName: String) async throws
    func transcribe(samples: [Float],
                    language: String,
                    progress: (@Sendable (Float) -> Void)?,
                    isCancelled: (@Sendable () -> Bool)?) async throws -> [TranscriptSegment]
    func shutdown() async
}
