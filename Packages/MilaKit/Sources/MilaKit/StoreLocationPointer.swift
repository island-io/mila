import Foundation

/// Cross-process contract telling external tools (mila-mcp) where the
/// recording store currently lives. The app's relocated-recordings feature
/// stores the user's choice as a security-scoped bookmark in UserDefaults,
/// which a separate process can't resolve — so RecordingStore mirrors the
/// resolved paths into this small JSON file at the DEFAULT app-support root
/// on every launch and relocation.
public struct StoreLocationPointer: Codable, Equatable {
    public var version: Int
    /// Directory holding the audio files + sidecars (`.txt`/`.srt`/…).
    public var recordingsDirectory: String
    /// Full path of `recordings.json`.
    public var storeFile: String
    public var updatedAt: Date

    public init(version: Int = 1, recordingsDirectory: String, storeFile: String, updatedAt: Date) {
        self.version = version
        self.recordingsDirectory = recordingsDirectory
        self.storeFile = storeFile
        self.updatedAt = updatedAt
    }

    public static let fileName = "store-location.json"

    /// The default Mila app-support root (`~/Library/Application Support/Mila`).
    public static func defaultRoot() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Mila", isDirectory: true)
    }

    public static func read(from root: URL = defaultRoot()) -> StoreLocationPointer? {
        let url = root.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(StoreLocationPointer.self, from: data)
    }

    public func write(to root: URL = defaultRoot()) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appendingPathComponent(Self.fileName), options: .atomic)
    }
}
