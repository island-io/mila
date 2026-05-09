import Foundation
import Combine

/// Persists recordings + their metadata under Application Support/IslandWhisper.
///
/// The pre-rename location was `Application Support/IvritWhisper`; we
/// transparently migrate that on first launch so users don't lose their
/// already-downloaded models (~1.6 GB) or recordings.
@MainActor
final class RecordingStore: ObservableObject {
    @Published private(set) var recordings: [Recording] = []

    private let fileManager = FileManager.default
    private let storeURL: URL
    let recordingsDirectory: URL
    let modelsDirectory: URL

    convenience init() {
        let appSupport = try! FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil,
                                                      create: true)
        let newRoot = appSupport.appendingPathComponent("IslandWhisper", isDirectory: true)
        let oldRoot = appSupport.appendingPathComponent("IvritWhisper", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: newRoot.path),
           fm.fileExists(atPath: oldRoot.path) {
            do {
                try fm.moveItem(at: oldRoot, to: newRoot)
                print("RecordingStore: migrated \(oldRoot.path) -> \(newRoot.path)")
            } catch {
                print("RecordingStore: migration from IvritWhisper failed (\(error)) — falling back to fresh dir")
            }
        }
        self.init(rootDirectory: newRoot)
    }

    init(rootDirectory: URL) {
        self.recordingsDirectory = rootDirectory.appendingPathComponent("Recordings", isDirectory: true)
        self.modelsDirectory = rootDirectory.appendingPathComponent("Models", isDirectory: true)
        self.storeURL = rootDirectory.appendingPathComponent("recordings.json")

        try? fileManager.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        load()
    }

    func audioURL(for recording: Recording) -> URL {
        recordingsDirectory.appendingPathComponent(recording.audioFileName)
    }

    func freshAudioURL(suggestedName: String? = nil) -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let suffix = String(UUID().uuidString.prefix(6))
        let base = (suggestedName?.isEmpty == false ? suggestedName! : "Recording")
            + " " + stamp + "-" + suffix
        return recordingsDirectory.appendingPathComponent(base + ".wav")
    }

    func add(_ recording: Recording) {
        recordings.insert(recording, at: 0)
        persist()
    }

    func update(_ recording: Recording) {
        guard let idx = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        recordings[idx] = recording
        persist()
    }

    /// Move to "Recently Deleted". The audio file stays on disk until permanent delete.
    func softDelete(_ recording: Recording) {
        guard let idx = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        recordings[idx].deletedAt = Date()
        persist()
    }

    /// Restore from "Recently Deleted".
    func restore(_ recording: Recording) {
        guard let idx = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        recordings[idx].deletedAt = nil
        persist()
    }

    /// Remove the metadata + audio file from disk.
    func permanentlyDelete(_ recording: Recording) {
        recordings.removeAll { $0.id == recording.id }
        let url = audioURL(for: recording)
        try? fileManager.removeItem(at: url)
        persist()
    }

    /// Backwards-compatible delete: soft-delete first, permanent if already trashed.
    func delete(_ recording: Recording) {
        if recording.isTrashed {
            permanentlyDelete(recording)
        } else {
            softDelete(recording)
        }
    }

    func recordings(in category: HistoryCategory) -> [Recording] {
        switch category {
        case .recentlyDeleted:
            return recordings.filter { $0.isTrashed }
                .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
        case .meetings:
            return recordings.filter { !$0.isTrashed && $0.source == .meeting }
        case .dictations:
            return recordings.filter { !$0.isTrashed && $0.source == .microphone && $0.title.hasPrefix("Dictation") }
        case .transcriptions:
            return recordings.filter { !$0.isTrashed }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([Recording].self, from: data) {
            self.recordings = decoded.sorted { $0.createdAt > $1.createdAt }
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(recordings)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            print("RecordingStore persist error: \(error)")
        }
    }
}
