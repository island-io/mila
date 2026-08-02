import Foundation

/// App-wide directory of speaker names the user has assigned across
/// recordings — the pick-list behind the speaker rename popover. Most
/// people recur across meetings, so the list persists to
/// `speaker-names.json` at the Application Support/Mila root. Like the
/// voice-memo tombstones (and unlike `folders.json`), it deliberately
/// does NOT travel with a relocated recordings folder: it's app state,
/// not per-folder content.
///
/// Per-recording assignments live in `Recording.speakerNames` as plain
/// string copies — removing a name here never touches recordings it was
/// already assigned to.
@MainActor
final class SpeakerDirectory: ObservableObject {

    @Published private(set) var names: [String] = []

    private let fileURL: URL

    /// `directory` is the folder that holds `speaker-names.json`.
    /// Injectable so tests can point at a temp directory.
    init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("speaker-names.json")
        load()
    }

    /// Production init: same Application Support/Mila root the
    /// RecordingStore resolves.
    convenience init() {
        // Mirror RecordingStore: UI tests must never read or write the
        // user's real directory.
        if CommandLine.arguments.contains("--ui-test-clean-store") {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("Mila-UITest-Speakers-\(UUID())", isDirectory: true)
            self.init(directory: tmp)
            return
        }
        // Non-throwing lookup + temp-dir fallback: a missing Application
        // Support directory shouldn't crash the app at launch — worst case
        // the directory just doesn't persist across reboots.
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.init(directory: appSupport.appendingPathComponent("Mila", isDirectory: true))
    }

    /// Add a name to the directory. Trims whitespace, rejects empty input,
    /// and dedupes case-insensitively — adding "daniel" when "Daniel"
    /// exists returns the existing canonical spelling instead of a
    /// duplicate. Returns the canonical name that's now in the list, or
    /// nil when the input was blank.
    @discardableResult
    func add(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let existing = names.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return existing
        }
        names.append(trimmed)
        names.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        persist()
        return trimmed
    }

    func remove(_ name: String) {
        let before = names.count
        names.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        if names.count != before { persist() }
    }

    /// Names matching a type-to-filter query (case-insensitive contains).
    /// An empty/whitespace query returns the full list.
    func matches(for query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return names }
        return names.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return }
        names = decoded.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(names)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("SpeakerDirectory persist error: \(error)")
        }
    }
}
