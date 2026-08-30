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

    /// Ceiling on `sampleCount`. Not a capacity limit in any meaningful sense
    /// — it is roughly 4.6 × 10¹⁸ utterances — but a guarantee that **any two
    /// valid counts can be added without trapping**, which both
    /// `updateProfile` and `mergeProfiles` do. Those two also clamp their sums
    /// to it, so the store can never produce a value its own validator would
    /// later reject. `Int.max / 2 + Int.max / 2 == Int.max - 1`: exactly one
    /// unit of headroom, which is all that is needed.
    ///
    /// **The clamp applies to the stored count only, never to the divisor of
    /// the weighted mean.** Both folds weight their numerator by the *true*
    /// counts, so dividing by the clamped total would not produce a mean at
    /// all — it would scale the whole centroid by `rawTotal / maxSampleCount`,
    /// up to 2× at the ceiling. Verified: folding two ceiling-count profiles
    /// `[1, 0]` and `[0, 1]` that way yields `[1, 1]` where the mean is
    /// `[0.5, 0.5]`.
    ///
    /// The count therefore **saturates** while the centroid stays exact, and
    /// the two disagree from that point on: a profile that has really seen
    /// `rawTotal` samples reports `maxSampleCount`, so the *next* fold
    /// under-weights it and lets the incoming sample pull the centroid
    /// harder than it should — by at most 2×, since no single valid count
    /// exceeds the ceiling either. That is a deliberate trade. The
    /// alternatives are worse: storing `rawTotal` unclamped re-arms the
    /// overflow trap this ceiling exists to prevent, and refusing the fold
    /// would silently stop a speaker from ever being updated again. It is
    /// also unreachable in practice — at one utterance per second, reaching
    /// the ceiling takes on the order of 10¹¹ years — so the residual
    /// imprecision is bounded, documented and never paid.
    static let maxSampleCount = Int.max / 2

    /// Why this profile cannot be used, or nil when it is sound.
    ///
    /// `speaker-profiles.json` is a plain file in Application Support that
    /// anything can edit, and a syntactically valid one can still hold values
    /// no code path here tolerates. These are exactly the invariants
    /// `SpeakerProfileStore.updateProfile` enforces on the way *in*, so the
    /// same check on the way back out means the store cannot read something
    /// it would have refused to write. Each clause is load-bearing:
    ///
    /// * **`sampleCount <= 0`** — `seedPool` carries the stored count into
    ///   the live pool (`min(count, 3)`, which leaves a negative one
    ///   negative), and the confident-match fold in `LiveSpeakerDiarizer.assign`
    ///   computes `(centroid[i] * Float(n) + embedding[i]) / Float(n + 1)`.
    ///   At `n == -1` that divides by zero. It is `Float` division, not
    ///   `Int`: **nothing traps**. The centroid silently becomes ±inf/NaN,
    ///   every later fold keeps it NaN, and `cosineSimilarity` then returns
    ///   NaN for that entry forever. Worse, `assign` picks its best match
    ///   with `sim > best.sim`, which is *false* for NaN — so a poisoned
    ///   entry ahead of the real ones captures `best`, clears no threshold,
    ///   and every utterance mints a fresh speaker instead of matching. The
    ///   symptom is silent misrecognition, not a crash. The weighted folds in
    ///   `updateProfile` and `mergeProfiles` land on the same `Float(0)`
    ///   divisor when a stored `-1` meets a single new sample, and there the
    ///   NaN is worse still: `JSONEncoder` refuses to encode it, so `save()`
    ///   throws and the store quietly stops persisting anything at all.
    /// * **`sampleCount > maxSampleCount`** — the one variant that *is*
    ///   fatal: `updateProfile` evaluates `existing.sampleCount +
    ///   sampleCount`, and Swift traps on `Int` overflow, so a stored
    ///   `Int.max` crashes the app the moment that speaker is named again.
    /// * **a non-finite component** — the same NaN poisoning, with no fold
    ///   needed to trigger it. Belt and braces rather than a live hole:
    ///   `JSONDecoder` cannot hand one back today, because JSON has no NaN or
    ///   Infinity literal and a number too large for `Float` (`1e39` upwards)
    ///   makes the *whole file* fail to parse. The clause states the
    ///   invariant the arithmetic actually rests on, so it survives a change
    ///   of encoding or of where embeddings come from.
    /// * **an empty name or embedding** — nothing to label with, nothing to
    ///   match against.
    ///
    /// Deliberately *not* checked: the embedding's width. Nothing here
    /// assumes it — `updateProfile`, `mergeProfiles` and `assign` each carry
    /// an explicit dimension-mismatch guard, so a profile written by some
    /// other embedding model is inert rather than dangerous. Pinning it to
    /// 256 here and nowhere else would also make the store refuse to read
    /// back exactly what `updateProfile` accepts, and quietly drop a user's
    /// profiles on any future model change.
    var unusableReason: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "empty name" }
        if embedding.isEmpty { return "empty embedding" }
        if embedding.contains(where: { !$0.isFinite }) { return "non-finite embedding value" }
        if sampleCount <= 0 { return "non-positive sampleCount (\(sampleCount))" }
        if sampleCount > Self.maxSampleCount { return "sampleCount out of range (\(sampleCount))" }
        return nil
    }
}

/// Manages persistent speaker voice profiles for cross-recording
/// recognition, in `speaker-profiles.json` at the Application Support/Mila
/// root. Profiles are created when a user names a speaker that has an
/// embedding available (from the live diarizer pool). Builds on top of the
/// existing `SpeakerDirectory` (which manages the name list) by adding
/// voice embeddings.
///
/// **Entirely gated on `VoiceRecognitionSettings.isConfigured`, which is
/// off by default.** With the feature off this object is inert: the JSON
/// file is never parsed, `profiles` stays empty, no embedding is written,
/// and `seedEntries()` hands the diarizer nothing. A user who never opts in
/// has no voice data stored — the guarantee is "never written", not
/// "written and ignored".
///
/// The one thing that still works while off is deletion
/// (`deleteAllProfiles`), because off is precisely when somebody wants
/// their voice data gone. Opting out is otherwise non-destructive: profiles
/// stay on disk so re-enabling restores them, and Settings keeps an
/// explicit delete button visible for as long as the file exists.
@MainActor
final class SpeakerProfileStore: ObservableObject {
    /// Profiles held in memory. **Empty whenever the feature is off** — the
    /// file is not even parsed until the user opts in, so an opted-out
    /// process holds no voice data at all, not merely unused voice data.
    @Published private(set) var profiles: [VoiceProfile] = []

    /// True when `speaker-profiles.json` exists on disk, whether or not it
    /// has been parsed. Lets Settings tell an opted-out user that voice
    /// profiles from an earlier opt-in are still stored, and offer to
    /// delete them, without reading a single embedding back into memory.
    @Published private(set) var hasStoredProfilesOnDisk: Bool = false

    /// The opt-in gate. Every persist / seed / match path below is guarded
    /// on `settings.isConfigured` (enabled **and** the diarization pipeline
    /// able to produce embeddings), never on `settings.isEnabled` alone.
    let settings: VoiceRecognitionSettings

    private let fileManager = FileManager.default
    private let storeURL: URL

    /// What a deletion removed, handed to the observers below.
    enum Deletion: Equatable {
        /// Every profile — `deleteAllProfiles`. Carries no names on purpose:
        /// while the feature is off `profiles` is empty (the file is never
        /// parsed), so the store genuinely does not know what it just
        /// deleted. "All" is the honest answer and the safe one.
        case all
        /// One profile, by name.
        case named(Set<String>)
    }

    private var deletionObservers: [(Deletion) -> Void] = []

    /// Register a handler for profile deletions, called synchronously after
    /// the profiles are gone.
    ///
    /// **This is what stops a recording that is already in flight from
    /// putting a deleted profile back.** Deleting is a privacy action, but
    /// it only reaches this object and the file: `LiveSpeakerDiarizer`'s pool
    /// was seeded with those centroids at record-start and keeps its own
    /// copy, so without this the rest of the recording goes on matching
    /// against the erased voice, and `RecognisedSpeakerAssigner.finish`
    /// writes it straight back at stop — under a new id, with this
    /// recording's centroid, which is the same person's fingerprint to
    /// within rounding. `MilaApp` wires this to
    /// `LiveSpeakerDiarizer.forgetSeededProfiles`, so the deletion takes
    /// effect immediately and everywhere, exactly as opting out does through
    /// `VoiceRecognitionSettings.addEnabledObserver`.
    ///
    /// A list rather than one slot, for the same reason `addEnabledObserver`
    /// is: a second registrant must not silently unhook the first.
    func addDeletionObserver(_ observer: @escaping (Deletion) -> Void) {
        deletionObservers.append(observer)
    }

    private func notifyDeleted(_ deletion: Deletion) {
        for observer in deletionObservers { observer(deletion) }
    }

    /// `directory` is the folder that holds `speaker-profiles.json`.
    /// Injectable so tests can point at a temp directory.
    init(directory: URL, settings: VoiceRecognitionSettings) {
        self.settings = settings
        self.storeURL = directory.appendingPathComponent("speaker-profiles.json")
        self.hasStoredProfilesOnDisk = fileManager.fileExists(atPath: storeURL.path)
        // Only read the file when the user has opted in. Off means off: no
        // embedding reaches memory, so nothing can be seeded or matched
        // even by a caller that forgot its own guard.
        if settings.isEnabled { load() }
        // Toggling mid-session has to take effect without a relaunch:
        // opting in loads what was stored, opting out drops it again.
        settings.addEnabledObserver { [weak self] nowEnabled in
            guard let self else { return }
            if nowEnabled {
                self.load()
            } else {
                self.profiles.removeAll()
            }
        }
    }

    /// Production init: the same Application Support/Mila root
    /// `RecordingStore` and `SpeakerDirectory` resolve.
    convenience init(settings: VoiceRecognitionSettings) {
        // Mirror SpeakerDirectory: UI tests must never read or write the
        // user's real voice profiles.
        if CommandLine.arguments.contains("--ui-test-clean-store") {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("Mila-UITest-VoiceProfiles-\(UUID())", isDirectory: true)
            self.init(directory: tmp, settings: settings)
            return
        }
        // Non-throwing lookup + temp-dir fallback, matching SpeakerDirectory:
        // a missing Application Support directory must not crash the app at
        // launch (the previous `try!` here would have).
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.init(directory: appSupport.appendingPathComponent("Mila", isDirectory: true),
                  settings: settings)
    }

    deinit {}

    // MARK: - CRUD

    /// Upsert a speaker profile by name. If a profile with the same name
    /// exists, merge the new embedding into its centroid via weighted
    /// average. Otherwise create a new profile.
    func updateProfile(name: String, embedding: [Float], sampleCount: Int) {
        // The write gate. Callers guard too (so an opted-out user's centroid
        // is never even read out of the diarizer pool), but the refusal that
        // actually matters is here: nothing reaches `save()` while off.
        guard settings.isConfigured else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // The same invariants `VoiceProfile.unusableReason` re-checks on the
        // way back off disk — kept identical on purpose, so the store never
        // accepts something it would later refuse to load, or vice versa. The
        // finiteness and upper-bound clauses matter here too: a NaN reaching
        // the centroid poisons it permanently, and an unbounded count makes
        // the addition below trap.
        guard !trimmed.isEmpty,
              !embedding.isEmpty,
              embedding.allSatisfy({ $0.isFinite }),
              sampleCount > 0,
              sampleCount <= VoiceProfile.maxSampleCount else { return }

        if let idx = profiles.firstIndex(where: { $0.name == trimmed }) {
            let existing = profiles[idx]
            guard existing.embedding.count == embedding.count else {
                profileLog.log("updateProfile: dimension mismatch (\(existing.embedding.count) vs \(embedding.count)) for \(trimmed, privacy: .private)")
                return
            }
            // Safe to add: both operands are at most `maxSampleCount` — the
            // incoming one by the guard above, the stored one because every
            // route into `profiles` (this method, or `load`'s validation)
            // enforces it. Swift traps on `Int` overflow, and a decoded
            // `Int.max` here would otherwise crash the app outright.
            let rawTotal = existing.sampleCount + sampleCount
            // Clamped so what is written back is always something `load` will
            // accept. **Only the stored count is clamped** — the fold below
            // divides by `rawTotal`, because its numerator is weighted by the
            // true counts and a clamped divisor would scale the centroid
            // instead of averaging it. See `VoiceProfile.maxSampleCount`.
            let storedCount = min(rawTotal, VoiceProfile.maxSampleCount)
            var merged = [Float](repeating: 0, count: embedding.count)
            for i in 0..<merged.count {
                merged[i] = (existing.embedding[i] * Float(existing.sampleCount)
                           + embedding[i] * Float(sampleCount)) / Float(rawTotal)
            }
            profiles[idx].embedding = merged
            profiles[idx].sampleCount = storedCount
            profiles[idx].lastSeenAt = Date()
            profileLog.log("updateProfile: merged into \(trimmed, privacy: .private) (now \(storedCount) samples)")
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
        let removed = Set(profiles.filter { $0.id == id }.map(\.name))
        profiles.removeAll { $0.id == id }
        save()
        // Same reason as `deleteAllProfiles`: a live diarizer seeded with
        // this profile would otherwise keep matching it and write it back at
        // stop. Skipped when nothing matched the id, so a no-op delete does
        // not disturb an in-flight recording.
        if !removed.isEmpty { notifyDeleted(.named(removed)) }
    }

    func deleteProfile(name: String) {
        let removed = Set(profiles.filter { $0.name == name }.map(\.name))
        profiles.removeAll { $0.name == name }
        save()
        if !removed.isEmpty { notifyDeleted(.named(removed)) }
    }

    /// Remove every stored voice profile — the "Delete voice profiles"
    /// button in Settings.
    ///
    /// Deliberately **not** gated: deletion has to work when the feature is
    /// off, because off is exactly when a user wants their voice data gone.
    /// It deletes the file rather than writing an empty array over it, so
    /// after opting out and deleting there is no `speaker-profiles.json`
    /// left behind at all.
    ///
    /// **Deleting in memory and on disk is not the whole job.** A recording
    /// in flight was seeded from these profiles at record-start and holds
    /// its own copy of every centroid in `LiveSpeakerDiarizer`'s pool, so
    /// until the observers below are told, the deletion is only two thirds
    /// done: the rest of the recording keeps matching the erased voice, and
    /// `RecognisedSpeakerAssigner` writes the profile back at stop — the
    /// file the user deleted reappears, holding a fingerprint that matches
    /// the deleted one to better than 0.999 cosine. That is CWE-459, and the
    /// notification is what completes the cleanup.
    func deleteAllProfiles() {
        profiles.removeAll()
        do {
            if fileManager.fileExists(atPath: storeURL.path) {
                try fileManager.removeItem(at: storeURL)
            }
        } catch {
            profileLog.log("deleteAll error: \(error.localizedDescription, privacy: .public)")
        }
        hasStoredProfilesOnDisk = fileManager.fileExists(atPath: storeURL.path)
        // Unconditional, and after the file is gone: this must fire even
        // when `profiles` was already empty in memory (the feature is off,
        // so the file was never parsed) — that is precisely the case where
        // the store cannot name what it deleted but a seeded pool may still
        // be holding it.
        notifyDeleted(.all)
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
        // Reject if the target name is already taken by another profile.
        guard !profiles.contains(where: { $0.name == trimmed }) else {
            profileLog.log("renameProfile: target name already exists: \(trimmed, privacy: .private)")
            return
        }
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
        guard keep.embedding.count == absorb.embedding.count else {
            profileLog.log("mergeProfiles: dimension mismatch (\(keep.embedding.count) vs \(absorb.embedding.count))")
            return nil
        }
        let dim = keep.embedding.count
        guard dim > 0 else { return nil }
        // Bounded and clamped exactly as in `updateProfile`, and for the same
        // reasons: the sum cannot trap because both stored counts are at most
        // `maxSampleCount`, and only the *stored* count is clamped — the fold
        // divides by the true `rawTotal` so it stays a weighted mean.
        let rawTotal = keep.sampleCount + absorb.sampleCount
        let storedCount = min(rawTotal, VoiceProfile.maxSampleCount)
        var merged = [Float](repeating: 0, count: dim)
        for i in 0..<dim {
            merged[i] = (keep.embedding[i] * Float(keep.sampleCount)
                       + absorb.embedding[i] * Float(absorb.sampleCount)) / Float(rawTotal)
        }
        profiles[keepIdx].embedding = merged
        profiles[keepIdx].sampleCount = storedCount
        profiles[keepIdx].lastSeenAt = max(keep.lastSeenAt, absorb.lastSeenAt)
        profiles.removeAll { $0.id == absorb.id }
        profileLog.log("mergeProfiles: merged \(absorbName, privacy: .private) into \(keepName, privacy: .private)")
        save()
        return profiles.first { $0.id == keep.id }
    }

    /// Match an embedding against all stored profiles. Returns the best
    /// match above the threshold, or nil.
    func match(embedding: [Float], threshold: Double = 0.55) -> VoiceProfile? {
        guard settings.isConfigured else { return nil }
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
    ///
    /// The seed gate. Returns nothing while the feature is off — and while
    /// off `profiles` is empty anyway, since the file was never parsed.
    func seedEntries() -> [(id: String, name: String, centroid: [Float], sampleCount: Int)] {
        guard settings.isConfigured else { return [] }
        return profiles.map { p in
            (id: p.name, name: p.name, centroid: p.embedding, sampleCount: p.sampleCount)
        }
    }

    // MARK: - Persistence

    /// Writes `profiles` to disk.
    ///
    /// **Refuses while the feature is off**, and that refusal does double
    /// duty. It is the last line of the "nothing is written unless the user
    /// opted in" guarantee, and it stops the opposite failure too: while off
    /// `profiles` is empty, so a stray `save()` would overwrite a
    /// previously-stored file with `[]` and destroy voice profiles the user
    /// is entitled to get back by re-enabling.
    ///
    /// This one guard reads `isEnabled` rather than `isConfigured` on
    /// purpose. `isConfigured` gates everything that *creates* voice data
    /// (`updateProfile`) or *uses* it (`seedEntries`, `match`), so no new
    /// embedding can reach here without it; what's left is the user's own
    /// housekeeping — a rename or a single delete from Settings — and that
    /// must still persist when the diarization pipeline happens to be
    /// unverified, or their edit would silently revert on relaunch.
    private func save() {
        guard settings.isEnabled else {
            profileLog.log("save skipped — voice recognition is off")
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            // Ensure the parent directory exists (first launch on a clean install).
            let dir = storeURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: dir.path) {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let data = try encoder.encode(profiles)
            try data.write(to: storeURL, options: .atomic)
            hasStoredProfilesOnDisk = true
        } catch {
            profileLog.log("save error: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Parses `speaker-profiles.json` into memory. Called from `init` only
    /// when the user has already opted in, and from the opt-in transition —
    /// the guard is belt and braces so a future caller can't read voice data
    /// back in behind an opted-out user's back.
    ///
    /// Decoding is only half the job: a file that parses can still describe a
    /// profile no arithmetic here survives, so each decoded entry is checked
    /// against `VoiceProfile.unusableReason` before it is installed.
    ///
    /// **An unusable entry is dropped individually and logged**, rather than
    /// the whole file being rejected. One hand-edited or truncated profile
    /// must not cost the user every other voice they have trained, and the
    /// entry is unusable by definition — there is nothing to salvage, and
    /// leaving it in memory is what does the damage. The drop is in-memory;
    /// the file is not rewritten here, so the bad entry survives on disk
    /// until the next legitimate `save()` and can still be repaired by hand
    /// until then.
    ///
    /// Per-entry granularity is only available for *semantic* invalidity.
    /// Malformed JSON, or a number too large for its Swift type, fails inside
    /// `decode` before any entry exists, so those stay all-or-nothing — the
    /// catch below leaves `profiles` as it was and logs.
    private func load() {
        guard settings.isEnabled else { return }
        guard fileManager.fileExists(atPath: storeURL.path) else { return }
        do {
            let data = try Data(contentsOf: storeURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([VoiceProfile].self, from: data)
            var accepted: [VoiceProfile] = []
            accepted.reserveCapacity(decoded.count)
            for profile in decoded {
                if let reason = profile.unusableReason {
                    profileLog.log("load: dropped \(profile.name, privacy: .private) — \(reason, privacy: .public)")
                    continue
                }
                accepted.append(profile)
            }
            profiles = accepted
            profileLog.log("loaded \(accepted.count) of \(decoded.count) voice profiles")
        } catch {
            profileLog.log("load error: \(error.localizedDescription, privacy: .public)")
        }
    }
}
