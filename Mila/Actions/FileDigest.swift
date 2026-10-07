import CryptoKit
import Foundation

/// Streaming SHA-256 of a file, for the `.milashare` audio integrity check.
/// Reads in 1 MiB chunks so a multi-hour `.wav` never lands in memory whole.
enum FileDigest {
    static func sha256Hex(of url: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
