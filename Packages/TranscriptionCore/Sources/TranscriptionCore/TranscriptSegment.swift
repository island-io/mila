import Foundation

public struct TranscriptSegment: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var start: Double
    public var end: Double
    public var text: String
    public var speaker: String?

    public init(id: UUID = UUID(), start: Double, end: Double, text: String, speaker: String? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }
}
