import Foundation

/// Persistent voice profile for cross-recording speaker recognition.
/// Stores the speaker's name alongside a centroid embedding (256-dim
/// vector from wespeaker ECAPA-TDNN via pyannote). The centroid is a
/// running mean of all embeddings observed for this speaker — the more
/// recordings, the tighter the distribution.
struct SpeakerProfile: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    /// 256-dimensional centroid embedding (running mean).
    var embedding: [Float]
    /// Number of utterances folded into the centroid.
    var sampleCount: Int
    var createdAt: Date
    var lastSeenAt: Date

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: SpeakerProfile, rhs: SpeakerProfile) -> Bool { lhs.id == rhs.id }
}

/// Manages persistent speaker voice profiles for cross-recording
/// recognition. Profiles are created when a user names a speaker
/// that has an embedding in the live diarizer pool.
@MainActor
final class SpeakerProfileStore: ObservableObject {
    @Published private(set) var profiles: [SpeakerProfile] = []

    /// Tracks which speakers are currently having their voice profiles
    /// updated (re-diarizing recordings to extract embeddings). Keyed
    /// by speaker name so the UI can show progress per-speaker and
    /// survive navigation away and back.
    @Published var updatingProfiles: [String: ProfileUpdateState] = [:]

    struct ProfileUpdateState {
        var progress: Double = 0
        var status: String?
        var isRunning: Bool = true
    }

    private let fileManager = FileManager.default
    private var storeURL: URL {
        // Non-throwing resolution with a temp-dir fallback so a missing
        // Application Support directory can't crash the app at launch —
        // matches SpeakerDirectory's pattern (island-io/mila#88 review).
        let appSupport = fileManager.urls(for: .applicationSupportDirectory,
                                          in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return appSupport
            .appendingPathComponent("Mila", isDirectory: true)
            .appendingPathComponent("speaker-profiles.json")
    }

    init() {
        load()
    }

    // MARK: - CRUD

    /// Upsert a speaker profile by name. If a profile with the same name
    /// exists, merge the new embedding into its centroid via weighted
    /// average. Otherwise create a new profile.
    func updateProfile(name: String, embedding: [Float], sampleCount: Int) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !embedding.isEmpty else { return }

        if let idx = profiles.firstIndex(where: { $0.name == trimmed }) {
            // Weighted merge of centroids.
            let existing = profiles[idx]
            let totalCount = existing.sampleCount + sampleCount
            var merged = [Float](repeating: 0, count: embedding.count)
            for i in 0..<merged.count {
                merged[i] = (existing.embedding[i] * Float(existing.sampleCount)
                           + embedding[i] * Float(sampleCount)) / Float(totalCount)
            }
            profiles[idx].embedding = merged
            profiles[idx].sampleCount = totalCount
            profiles[idx].lastSeenAt = Date()
            save()
        } else {
            let profile = SpeakerProfile(
                id: UUID(),
                name: trimmed,
                embedding: embedding,
                sampleCount: sampleCount,
                createdAt: Date(),
                lastSeenAt: Date()
            )
            profiles.append(profile)
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

    /// Check if a profile with the given name exists.
    func profileExists(name: String) -> Bool {
        profiles.contains { $0.name == name }
    }

    /// Find the profile for a given name.
    func profile(named: String) -> SpeakerProfile? {
        profiles.first { $0.name == named }
    }

    /// Rename a profile, propagating across all stored profiles.
    func renameProfile(from oldName: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != oldName else { return }
        if let idx = profiles.firstIndex(where: { $0.name == oldName }) {
            profiles[idx].name = trimmed
            save()
        }
    }

    /// Merge two profiles: keep the `keep` profile, absorb the `absorb`
    /// profile's centroid via weighted average, then delete `absorb`.
    /// Returns the merged profile.
    @discardableResult
    func mergeProfiles(keep keepName: String, absorb absorbName: String) -> SpeakerProfile? {
        guard let keepIdx = profiles.firstIndex(where: { $0.name == keepName }),
              let absorbIdx = profiles.firstIndex(where: { $0.name == absorbName }),
              keepIdx != absorbIdx else { return nil }

        let keep = profiles[keepIdx]
        let absorb = profiles[absorbIdx]
        let totalCount = keep.sampleCount + absorb.sampleCount
        let dim = min(keep.embedding.count, absorb.embedding.count)
        var merged = [Float](repeating: 0, count: dim)
        for i in 0..<dim {
            merged[i] = (keep.embedding[i] * Float(keep.sampleCount)
                       + absorb.embedding[i] * Float(absorb.sampleCount)) / Float(totalCount)
        }
        profiles[keepIdx].embedding = merged
        profiles[keepIdx].sampleCount = totalCount
        profiles[keepIdx].lastSeenAt = max(keep.lastSeenAt, absorb.lastSeenAt)

        // Remove absorb (index may have shifted if keepIdx < absorbIdx).
        profiles.removeAll { $0.id == absorb.id }
        save()
        return profiles.first { $0.id == keep.id }
    }

    /// Match an embedding against all stored profiles. Returns the best
    /// match above the threshold, or nil.
    func match(embedding: [Float], threshold: Double = 0.55) -> SpeakerProfile? {
        var best: (profile: SpeakerProfile, sim: Double)?
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
        profiles.map { p in
            (id: p.name, name: p.name, centroid: p.embedding, sampleCount: p.sampleCount)
        }
    }

    // MARK: - Voice Profile Update (with re-diarization)

    /// Re-extract embeddings from all recordings for a speaker, then
    /// build/update the voice profile. Runs diarization on recordings
    /// that lack embeddings. Progress is tracked in `updatingProfiles`
    /// so the UI survives navigation.
    func updateVoiceProfile(
        speakerName: String,
        store: RecordingStore,
        pythonPath: String
    ) {
        guard updatingProfiles[speakerName]?.isRunning != true else { return }
        updatingProfiles[speakerName] = ProfileUpdateState()

        Task { @MainActor in
            let recs = store.recordings(forSpeaker: speakerName)
            var collectedEmbeddings: [([Float], Int)] = []
            var recsNeedingExtraction: [Recording] = []

            for rec in recs {
                var hasEmbedding = false
                for (rawID, name) in rec.speakerNames where name == speakerName {
                    if let emb = rec.speakerEmbeddings[rawID], !emb.isEmpty {
                        collectedEmbeddings.append((emb, 1))
                        hasEmbedding = true
                    }
                }
                if !hasEmbedding {
                    recsNeedingExtraction.append(rec)
                }
            }

            let total = recsNeedingExtraction.count
            if total == 0, collectedEmbeddings.isEmpty {
                updatingProfiles[speakerName] = ProfileUpdateState(
                    progress: 1, status: "No voice data could be extracted.", isRunning: false)
                return
            }

            for (i, rec) in recsNeedingExtraction.enumerated() {
                updatingProfiles[speakerName]?.progress = Double(i) / Double(max(total, 1))
                let wavURL = store.audioURL(for: rec)
                guard FileManager.default.fileExists(atPath: wavURL.path) else {
                    // Audio file gone (moved/deleted) — skip this recording.
                    continue
                }
                do {
                    let embeddings = try await SpeakerDiarizer.extractEmbeddings(
                        wavURL: wavURL, pythonPath: pythonPath)
                    if var current = store.recordings.first(where: { $0.id == rec.id }) {
                        current.speakerEmbeddings.merge(embeddings) { _, new in new }
                        store.update(current)
                        for (rawID, name) in current.speakerNames where name == speakerName {
                            if let emb = current.speakerEmbeddings[rawID], !emb.isEmpty {
                                collectedEmbeddings.append((emb, 1))
                            }
                        }
                    }
                } catch {
                    // Best-effort per recording: an extraction failure here
                    // just means this recording contributes no voice sample.
                }
            }
            updatingProfiles[speakerName]?.progress = 1.0

            if collectedEmbeddings.isEmpty {
                updatingProfiles[speakerName] = ProfileUpdateState(
                    progress: 1, status: "No voice data could be extracted.", isRunning: false)
                return
            }

            let dim = collectedEmbeddings[0].0.count
            var centroid = [Float](repeating: 0, count: dim)
            var totalCount = 0
            for (emb, count) in collectedEmbeddings {
                guard emb.count == dim else { continue }
                for i in 0..<dim { centroid[i] += emb[i] * Float(count) }
                totalCount += count
            }
            if totalCount > 0 {
                for i in 0..<dim { centroid[i] /= Float(totalCount) }
            }

            deleteProfile(name: speakerName)
            updateProfile(name: speakerName, embedding: centroid, sampleCount: totalCount)
            let msg = "Updated from \(collectedEmbeddings.count) recording\(collectedEmbeddings.count == 1 ? "" : "s")"
            updatingProfiles[speakerName] = ProfileUpdateState(
                progress: 1, status: msg, isRunning: false)
        }
    }

    // MARK: - Persistence

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let url = storeURL
            // Ensure the Application Support/Mila directory exists — the
            // non-throwing storeURL no longer creates it eagerly.
            try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            let data = try encoder.encode(profiles)
            try data.write(to: url, options: .atomic)
        } catch {
            print("SpeakerProfileStore save error: \(error)")
        }
    }

    private func load() {
        guard fileManager.fileExists(atPath: storeURL.path) else { return }
        do {
            let data = try Data(contentsOf: storeURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            profiles = try decoder.decode([SpeakerProfile].self, from: data)
        } catch {
            print("SpeakerProfileStore load error: \(error)")
        }
    }
}
