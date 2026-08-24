import Foundation
import os

private let profileLog = Logger(
    subsystem: "io.island.whisper.IslandWhisper", category: "SpeakerProfileStore")

/// Persistent voice profile for cross-recording speaker recognition.
/// Stores the speaker's name alongside a centroid embedding (256-dim
/// vector from wespeaker ECAPA-TDNN via pyannote). The centroid is a
/// running mean of all embeddings observed for this speaker — the more
/// recordings, the tighter the distribution.
struct VoiceProfile: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    /// 256-dimensional centroid embedding (running mean).
    var embedding: [Float]
    /// Number of utterances folded into the centroid.
    var sampleCount: Int
    var createdAt: Date
    var lastSeenAt: Date

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: VoiceProfile, rhs: VoiceProfile) -> Bool { lhs.id == rhs.id }
}

/// Manages persistent speaker voice profiles for cross-recording
/// recognition. Profiles are created when a user names a speaker
/// that has an embedding available (from the live diarizer pool or
/// batch extraction). Builds on top of the existing SpeakerDirectory
/// (which manages the name list) by adding voice embeddings.
@MainActor
final class SpeakerProfileStore: ObservableObject {
    @Published private(set) var profiles: [VoiceProfile] = []

    /// Master opt-in for voice recognition. When off, no voice profiles
    /// are created or matched — speaker naming still works (via
    /// SpeakerDirectory) but without cross-recording auto-identification.
    /// Off by default: the user must consciously opt in to storing voice
    /// biometric data.
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "voiceRecognition.enabled") }
    }

    private let fileManager = FileManager.default
    private let storeURL: URL

    init() {
        self.enabled = UserDefaults.standard.bool(forKey: "voiceRecognition.enabled")
        let appSupport = try! fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        self.storeURL = appSupport
            .appendingPathComponent("Mila", isDirectory: true)
            .appendingPathComponent("speaker-profiles.json")
        load()
    }

    /// Injectable init for tests.
    init(directory: URL) {
        self.enabled = true
        self.storeURL = directory.appendingPathComponent("speaker-profiles.json")
        load()
    }

    deinit {}

    // MARK: - CRUD

    /// Upsert a speaker profile by name. If a profile with the same name
    /// exists, merge the new embedding into its centroid via weighted
    /// average. Otherwise create a new profile.
    func updateProfile(name: String, embedding: [Float], sampleCount: Int) {
        guard enabled else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !embedding.isEmpty else { return }

        if let idx = profiles.firstIndex(where: { $0.name == trimmed }) {
            let existing = profiles[idx]
            guard existing.embedding.count == embedding.count else {
                profileLog.log("updateProfile: dimension mismatch (\(existing.embedding.count) vs \(embedding.count)) for \(trimmed, privacy: .private)")
                return
            }
            let totalCount = existing.sampleCount + sampleCount
            var merged = [Float](repeating: 0, count: embedding.count)
            for i in 0..<merged.count {
                merged[i] = (existing.embedding[i] * Float(existing.sampleCount)
                           + embedding[i] * Float(sampleCount)) / Float(totalCount)
            }
            profiles[idx].embedding = merged
            profiles[idx].sampleCount = totalCount
            profiles[idx].lastSeenAt = Date()
            profileLog.log("updateProfile: merged into \(trimmed, privacy: .private) (now \(totalCount) samples)")
            save()
        } else {
            let profile = VoiceProfile(
                id: UUID(),
                name: trimmed,
                embedding: embedding,
                sampleCount: sampleCount,
                createdAt: Date(),
                lastSeenAt: Date()
            )
            profiles.append(profile)
            profileLog.log("updateProfile: created \(trimmed, privacy: .private) (\(sampleCount) samples)")
            save()
        }
    }

    func deleteProfile(id: UUID) {
        profiles.removeAll { $0.id == id }
        save()
    }

    func deleteProfile(name: String) {
        profiles.removeAll { $0.name == name }
        save()
    }

    /// Remove all stored voice profiles. Used by the "Wipe All Voice
    /// Data" button in Settings.
    func deleteAllProfiles() {
        profiles.removeAll()
        save()
    }

    func profileExists(name: String) -> Bool {
        profiles.contains { $0.name == name }
    }

    func profile(named: String) -> VoiceProfile? {
        profiles.first { $0.name == named }
    }

    /// Rename a profile.
    func renameProfile(from oldName: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != oldName else { return }
        if let idx = profiles.firstIndex(where: { $0.name == oldName }) {
            profiles[idx].name = trimmed
            save()
        }
    }

    /// Merge two profiles: weighted-average centroids, delete absorbed.
    @discardableResult
    func mergeProfiles(keep keepName: String, absorb absorbName: String) -> VoiceProfile? {
        guard let keepIdx = profiles.firstIndex(where: { $0.name == keepName }),
              let absorbIdx = profiles.firstIndex(where: { $0.name == absorbName }),
              keepIdx != absorbIdx else { return nil }

        let keep = profiles[keepIdx]
        let absorb = profiles[absorbIdx]
        let dim = min(keep.embedding.count, absorb.embedding.count)
        guard dim > 0 else { return nil }
        let totalCount = keep.sampleCount + absorb.sampleCount
        var merged = [Float](repeating: 0, count: dim)
        for i in 0..<dim {
            merged[i] = (keep.embedding[i] * Float(keep.sampleCount)
                       + absorb.embedding[i] * Float(absorb.sampleCount)) / Float(totalCount)
        }
        profiles[keepIdx].embedding = merged
        profiles[keepIdx].sampleCount = totalCount
        profiles[keepIdx].lastSeenAt = max(keep.lastSeenAt, absorb.lastSeenAt)
        profiles.removeAll { $0.id == absorb.id }
        profileLog.log("mergeProfiles: merged \(absorbName, privacy: .private) into \(keepName, privacy: .private)")
        save()
        return profiles.first { $0.id == keep.id }
    }

    /// Match an embedding against all stored profiles. Returns the best
    /// match above the threshold, or nil.
    func match(embedding: [Float], threshold: Double = 0.55) -> VoiceProfile? {
        guard enabled else { return nil }
        var best: (profile: VoiceProfile, sim: Double)?
        for profile in profiles {
            let sim = cosineSimilarity(embedding, profile.embedding)
            if sim >= threshold, best == nil || sim > best!.sim {
                best = (profile, sim)
            }
        }
        return best?.profile
    }

    /// Entries suitable for seeding the live diarizer pool.
    func seedEntries() -> [(id: String, name: String, centroid: [Float], sampleCount: Int)] {
        guard enabled else { return [] }
        return profiles.map { p in
            (id: p.name, name: p.name, centroid: p.embedding, sampleCount: p.sampleCount)
        }
    }

    // MARK: - Persistence

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(profiles)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            profileLog.log("save error: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func load() {
        guard fileManager.fileExists(atPath: storeURL.path) else { return }
        do {
            let data = try Data(contentsOf: storeURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            profiles = try decoder.decode([VoiceProfile].self, from: data)
            profileLog.log("loaded \(self.profiles.count) voice profiles")
        } catch {
            profileLog.log("load error: \(error.localizedDescription, privacy: .public)")
        }
    }
}
