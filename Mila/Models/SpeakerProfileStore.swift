import Foundation
import os

private let profileLog = Logger(
    subsystem: "io.island.whisper.IslandWhisper", category: "SpeakerProfileStore")

/// Persistent voice profile for cross-recording speaker recognition.
/// Stores the speaker's name alongside a centroid embedding (256-dim
/// vector from the bundled wespeaker ResNet34 model, loaded via pyannote —
/// see `SpeakerEmbeddingModel.current`). The centroid is a running mean of
/// all embeddings observed for this speaker — the more recordings, the
/// tighter the distribution.
struct VoiceProfile: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    /// 256-dimensional centroid embedding (running mean).
    var embedding: [Float]
    /// Number of utterances folded into the centroid.
    var sampleCount: Int
    var createdAt: Date
    var lastSeenAt: Date
    /// Which embedding model produced `embedding`. nil on rows written
    /// before the stamp existed; read through `effectiveEmbeddingModel`.
    /// Vectors from different models are incomparable, so every fold
    /// (`updateProfile`, `mergeProfiles`, a `.milashare` import) refuses to
    /// combine two profiles whose stamps differ.
    var embeddingModel: String?
    /// `.milashare` bundles whose copy of this speaker has already been
    /// folded in, so importing the same file twice doesn't double-count.
    /// Lives here, not in a side ledger, so deleting the profile forgets
    /// them too (see `ImportedShareToken`).
    var importedShares: [ImportedShareToken]

    init(id: UUID, name: String, embedding: [Float], sampleCount: Int,
         createdAt: Date, lastSeenAt: Date,
         embeddingModel: String? = nil,
         importedShares: [ImportedShareToken] = []) {
        self.id = id
        self.name = name
        self.embedding = embedding
        self.sampleCount = sampleCount
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.embeddingModel = embeddingModel
        self.importedShares = importedShares
    }

    /// The stamp, with legacy rows resolved to the only model that has ever
    /// shipped. Valid for exactly as long as that stays true — see
    /// `SpeakerEmbeddingModel`.
    var effectiveEmbeddingModel: String {
        embeddingModel ?? SpeakerEmbeddingModel.current.id
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, embedding, sampleCount, createdAt, lastSeenAt, embeddingModel, importedShares
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        embedding = try c.decode([Float].self, forKey: .embedding)
        sampleCount = try c.decode(Int.self, forKey: .sampleCount)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastSeenAt = try c.decode(Date.self, forKey: .lastSeenAt)
        embeddingModel = try c.decodeIfPresent(String.self, forKey: .embeddingModel)
        importedShares = try c.decodeIfPresent([ImportedShareToken].self, forKey: .importedShares) ?? []
    }

    /// The two new keys are written only when they carry something, so a
    /// `speaker-profiles.json` nobody has imported into stays byte-identical
    /// to what earlier builds wrote — and an earlier build reading a newer
    /// file ignores the keys it doesn't know.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(embedding, forKey: .embedding)
        try c.encode(sampleCount, forKey: .sampleCount)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(lastSeenAt, forKey: .lastSeenAt)
        try c.encodeIfPresent(embeddingModel, forKey: .embeddingModel)
        if !importedShares.isEmpty {
            try c.encode(importedShares, forKey: .importedShares)
        }
    }

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

    /// Largest magnitude any embedding component may have. The weighted
    /// fold in `updateProfile` evaluates `component * Float(count)` with a
    /// count of up to `maxSampleCount` (≈ 4.6 × 10¹⁸); `Float` tops out at
    /// ≈ 3.4 × 10³⁸, so a finite — and perfectly decodable — component of
    /// 10³⁰ overflows the product to infinity, the centroid takes it, and
    /// `JSONEncoder` then refuses the whole file: `save()` fails from that
    /// point on. Real embeddings have components in the single digits; the
    /// bound exists only so that nothing reaching the fold — a hand-edited
    /// file, a hostile `.milashare` — can get it there. At 10⁶ the product
    /// stays twelve orders of magnitude short of the overflow.
    static let maxEmbeddingMagnitude: Float = 1_000_000

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
    /// * **a component beyond `maxEmbeddingMagnitude`** — the reachable way
    ///   to the same infinity: finite in the file, decodable, and overflowing
    ///   `Float` the moment the fold multiplies it by a sample count.
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
        if embedding.contains(where: { abs($0) > Self.maxEmbeddingMagnitude }) { return "embedding value out of range" }
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
/// file is never loaded, `profiles` stays empty, no embedding is written,
/// and `seedEntries()` hands the diarizer nothing. A user who never opts in
/// has no voice data stored — the guarantee is "never written", not
/// "written and ignored".
///
/// The one thing that still works while off is deletion, because off is
/// precisely when somebody wants their voice data gone: `deleteAllProfiles`
/// removes the file outright, and `forgetSpeaker(named:)` (Settings → Known
/// speakers' ✕) drops one voice from it. That second path, and
/// `storedVoice(forSpeakerNamed:)` which Known speakers asks before it, are
/// the only off-state reads of the file: decoded exactly as `load()` would,
/// into a local that is gone when the call returns, never into `profiles`,
/// and only on the user's own click. A file they cannot decode is left as
/// it is. Opting out is otherwise non-destructive: profiles stay on disk so
/// re-enabling restores them, and Settings keeps an explicit delete button
/// visible for as long as the file exists.
@MainActor
final class SpeakerProfileStore: ObservableObject {
    /// Profiles held in memory. **Empty whenever the feature is off** — the
    /// file is not loaded until the user opts in, so an opted-out process
    /// holds no voice data at all, not merely unused voice data. (The
    /// off-state single-voice delete decodes the file transiently and keeps
    /// nothing; see the type's doc.)
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

    /// True when `load()` found `speaker-profiles.json` but could not read
    /// or parse it. The file is then the user's unrecovered voice data, not
    /// a stale copy of `profiles`, so the next `save()` moves it aside
    /// rather than writing over it (#329). Cleared once it has been moved,
    /// deleted by the user, or loaded successfully.
    private(set) var loadedFromDamagedFile = false {
        // A change to it changes what Settings must say (#336). `init`
        // refreshes unconditionally on its own, since a load that leaves
        // this false does not fire here.
        didSet { if loadedFromDamagedFile != oldValue { refreshDamagedProfilesNotice() } }
    }

    /// What Settings tells the user about voice profiles that could not be
    /// loaded (#336). Without it the profiles just vanish from recognition
    /// and the only trace is a log line.
    enum DamagedProfilesNotice: Equatable {
        /// `speaker-profiles.json` could not be read or parsed, so none of
        /// its profiles are in use. Still at its own path; the next write
        /// moves it aside.
        case unreadable(URL)
        /// A file that could not be read was kept as this backup.
        case setAside(URL)

        var fileURL: URL {
            switch self {
            case .unreadable(let url), .setAside(let url): return url
            }
        }
    }

    /// Recomputed only by `refreshDamagedProfilesNotice()` — on load, on a
    /// move aside, on opt-out, on delete, on dismiss and when Settings
    /// rechecks — so this is a once-in-a-while publish, safe on an
    /// App-level `@StateObject` (see CLAUDE.md).
    @Published private(set) var damagedProfilesNotice: DamagedProfilesNotice?

    /// The same notice, for the main window (#342) — a user who never opens
    /// Settings → Speakers would otherwise never learn their voices stopped
    /// being recognised. Unlike `damagedProfilesNotice` it is announced
    /// **once per incident**: it is set only for a notice whose
    /// `announcementKey` is not yet in
    /// `VoiceRecognitionSettings.announcedDamagedProfiles`, and the main
    /// window records the key when the banner actually appears
    /// (`noteDamagedProfilesAnnouncementShown`) — not when it is computed,
    /// so a launch whose window never showed it does not use it up. The
    /// unreadable live file and the backup it becomes count as one incident
    /// (`moveDamagedFileAside` carries the key over). Nil while voice
    /// recognition is off, for a backup dismissed in Settings (it derives
    /// from `damagedProfilesNotice`, which already leaves those out), and
    /// once the user closes it or sees the notice in Settings
    /// (`acknowledgeDamagedProfilesAnnouncement`).
    ///
    /// Recomputed only alongside `damagedProfilesNotice`, so it is just as
    /// rare a publish (CLAUDE.md, #280).
    @Published private(set) var damagedProfilesAnnouncement: DamagedProfilesNotice?

    /// Key of the announcement up this session, so a refresh keeps it up
    /// rather than treating it as already announced. Cleared only when the
    /// user takes it down, so switching voice recognition off and on again
    /// brings back a banner they never closed.
    private var shownAnnouncementKey: String?

    /// Incidents taken down this session without being recorded as
    /// announced (`hideDamagedProfilesAnnouncement`). Memory only: without
    /// it the next refresh — Settings rechecks on appear and on every
    /// activation — would put the banner straight back.
    private var hiddenAnnouncementKeys: Set<String> = []

    private static let unreadableKeyPrefix = "unreadable@"
    private let sessionID = UUID().uuidString

    /// What a deletion removed, handed to the observers below.
    enum Deletion: Equatable {
        /// Every profile — `deleteAllProfiles`. Carries no names on purpose:
        /// while the feature is off `profiles` is empty (the file is never
        /// loaded), so the store genuinely does not know what it just
        /// deleted. "All" is the honest answer and the safe one.
        case all
        /// Profiles by name — `deleteProfile`, `forgetSpeaker`, or a
        /// recheck's re-read that no longer holds them.
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
    /// effect immediately and everywhere, exactly as the feature ceasing to
    /// be configured does through
    /// `VoiceRecognitionSettings.addConfiguredObserver`.
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
    ///
    /// In production it is the fixed `Application Support/Mila` root (see the
    /// convenience init), NOT the user's chosen recordings folder — voice
    /// profiles are app state and deliberately do not travel with a relocated
    /// store, exactly like `speaker-names.json` and the voice-memo tombstones.
    /// That is why the load/save/delete failures below keep
    /// `error.localizedDescription` `.public`: the folder Cocoa quotes in the
    /// message can only ever be “Mila”. The profile NAMES are user content and
    /// are already `.private` at the one site that logs one. (Issue #213.)
    init(directory: URL, settings: VoiceRecognitionSettings) {
        self.settings = settings
        self.storeURL = directory.appendingPathComponent("speaker-profiles.json")
        self.hasStoredProfilesOnDisk = storedFilesExist()
        // Only read the file when the user has opted in. Off means off: no
        // embedding reaches memory, so nothing can be seeded or matched
        // even by a caller that forgot its own guard.
        if settings.isEnabled { load() }
        refreshDamagedProfilesNotice()
        // Toggling mid-session has to take effect without a relaunch:
        // opting in loads what was stored, opting out drops it again.
        settings.addEnabledObserver { [weak self] nowEnabled in
            guard let self else { return }
            if nowEnabled {
                self.load()
            } else {
                self.profiles.removeAll()
                // Whatever failed to save is gone from memory too.
                self.hasUnsavedChanges = false
                self.unsavedDeletions.removeAll()
            }
            // The main-window announcement follows the switch (#342).
            self.refreshDamagedProfilesNotice()
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
    ///
    /// `embeddingModel` defaults to the model this build runs; a
    /// `.milashare` import passes the sender's stamp instead, and the merge
    /// below refuses when it differs from the stored one — the model-level
    /// twin of the dimension guard, because two same-width vectors from
    /// different models average into noise rather than into a voice.
    func updateProfile(name: String, embedding: [Float], sampleCount: Int,
                       embeddingModel: String = SpeakerEmbeddingModel.current.id) {
        // The write gate. Callers guard too (so an opted-out user's centroid
        // is never even read out of the diarizer pool), but the refusal that
        // actually matters is here: nothing reaches `save()` while off.
        guard settings.isConfigured else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // The same invariants `VoiceProfile.unusableReason` re-checks on the
        // way back off disk — kept identical on purpose, so the store never
        // accepts something it would later refuse to load, or vice versa. The
        // finiteness and upper-bound clauses matter here too: a NaN reaching
        // the centroid poisons it permanently, an unbounded count makes the
        // addition below trap, and an unbounded component makes the fold's
        // `component * Float(count)` overflow to infinity.
        guard !trimmed.isEmpty,
              !embedding.isEmpty,
              embedding.allSatisfy({ $0.isFinite && abs($0) <= VoiceProfile.maxEmbeddingMagnitude }),
              sampleCount > 0,
              sampleCount <= VoiceProfile.maxSampleCount else { return }

        if let idx = profiles.firstIndex(where: { $0.name == trimmed }) {
            let existing = profiles[idx]
            guard existing.embedding.count == embedding.count else {
                profileLog.log("updateProfile: dimension mismatch (\(existing.embedding.count) vs \(embedding.count)) for \(trimmed, privacy: .private)")
                return
            }
            guard existing.effectiveEmbeddingModel == embeddingModel else {
                profileLog.log("updateProfile: embedding model mismatch (\(existing.effectiveEmbeddingModel, privacy: .public) vs \(embeddingModel, privacy: .public)) for \(trimmed, privacy: .private)")
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
            // A legacy row gets its stamp the first time it is touched.
            if profiles[idx].embeddingModel == nil { profiles[idx].embeddingModel = embeddingModel }
            profileLog.log("updateProfile: merged into \(trimmed, privacy: .private) (now \(storedCount) samples)")
            save()
        } else {
            let profile = VoiceProfile(
                id: UUID(),
                name: trimmed,
                embedding: embedding,
                sampleCount: sampleCount,
                createdAt: Date(),
                lastSeenAt: Date(),
                embeddingModel: embeddingModel
            )
            profiles.append(profile)
            profileLog.log("updateProfile: created \(trimmed, privacy: .private) (\(sampleCount) samples)")
            save()
        }
    }

    /// Reverse a prior `updateProfile` merge: subtract an observation's
    /// contribution from a profile's weighted-average centroid. Called when
    /// a speaker is un-named or renamed, so the old profile no longer
    /// carries this recording's (possibly wrong) embedding.
    ///
    /// If the subtraction would leave the profile with zero or fewer
    /// samples, the profile is deleted entirely. If the resulting centroid
    /// contains non-finite values (numerical drift), the profile is also
    /// deleted as irrecoverable.
    func subtractObservation(name: String, embedding: [Float], sampleCount: Int) {
        guard settings.isConfigured else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !embedding.isEmpty,
              embedding.allSatisfy({ $0.isFinite }),
              sampleCount > 0 else { return }

        guard let idx = profiles.firstIndex(where: { $0.name == trimmed }) else { return }
        let existing = profiles[idx]
        guard existing.embedding.count == embedding.count else {
            profileLog.log("subtractObservation: dimension mismatch (\(existing.embedding.count) vs \(embedding.count)) for \(trimmed, privacy: .private)")
            return
        }

        let remaining = existing.sampleCount - sampleCount
        if remaining <= 0 {
            profileLog.log("subtractObservation: removing \(trimmed, privacy: .private) (samples would drop to \(remaining))")
            deleteProfile(name: trimmed)
            return
        }

        var restored = [Float](repeating: 0, count: embedding.count)
        for i in 0..<restored.count {
            restored[i] = (existing.embedding[i] * Float(existing.sampleCount)
                         - embedding[i] * Float(sampleCount)) / Float(remaining)
        }

        // If subtraction produced non-finite values, the centroid is
        // irrecoverable — delete rather than persist poison.
        guard restored.allSatisfy({ $0.isFinite }) else {
            profileLog.log("subtractObservation: non-finite result for \(trimmed, privacy: .private), deleting profile")
            deleteProfile(name: trimmed)
            return
        }

        profiles[idx].embedding = restored
        profiles[idx].sampleCount = remaining
        profileLog.log("subtractObservation: corrected \(trimmed, privacy: .private) (now \(remaining) samples)")
        save()
    }

    /// What deleting one voice profile achieved. Returned rather than
    /// assumed, so Settings never says a voice is gone when it is not.
    enum ProfileDeletionOutcome: Equatable {
        /// No stored voice profile matched; nothing changed.
        case nothingToDelete
        /// Gone from memory and from `speaker-profiles.json`.
        case deleted
        /// Gone from memory — recognition stops using it at once, and a
        /// recording in flight has been told — but `speaker-profiles.json`
        /// could not be written, so the voice comes back on the next launch
        /// unless a later save succeeds first.
        case deletedForThisSessionOnly
        /// `speaker-profiles.json` could not be read or decoded — the file
        /// `load()` calls damaged — so whether it holds this voice is
        /// unknown and nothing was deleted from it. The file is left exactly
        /// as it is: a damaged file is only ever moved aside, never written
        /// over (#329). A matching profile still in memory was dropped from
        /// there.
        case profileFileUnreadable
        /// Voice recognition is off and the file could not be rewritten;
        /// nothing was deleted.
        case notDeleted
    }

    @discardableResult
    func deleteProfile(id: UUID) -> ProfileDeletionOutcome {
        deleteProfiles { $0.id == id }
    }

    @discardableResult
    func deleteProfile(name: String) -> ProfileDeletionOutcome {
        deleteProfiles { $0.name == name }
    }

    /// The in-memory delete behind `deleteProfile(id:)`,
    /// `deleteProfile(name:)` and, with recognition on, `forgetSpeaker`.
    ///
    /// The removal from `profiles` stands even when the save fails: the
    /// running session must stop matching the voice the user just deleted,
    /// and the deletion observers must still hear about it, or a recording
    /// in flight writes it back at stop. The outcome says the deletion did
    /// not persist (`.deletedForThisSessionOnly`), and `unsavedDeletions`
    /// remembers it, so asking again retries the save. A delete that
    /// matches nothing else writes nothing and notifies nobody, so a no-op
    /// does not disturb an in-flight recording.
    @discardableResult
    private func deleteProfiles(where matches: (VoiceProfile) -> Bool) -> ProfileDeletionOutcome {
        let gone = profiles.filter(matches)
        guard !gone.isEmpty else {
            // Already out of memory from an earlier delete whose save
            // failed: the retry is the save itself. Observers were told the
            // first time.
            guard unsavedDeletions.contains(where: matches) else { return .nothingToDelete }
            return save() ? .deleted : .deletedForThisSessionOnly
        }
        let removed = Set(gone.map(\.name))
        profiles.removeAll(where: matches)
        let saved = save()
        // After the save: a successful one clears the list.
        if !saved { unsavedDeletions.append(contentsOf: gone) }
        // Same reason as `deleteAllProfiles`: a live diarizer seeded with
        // this profile would otherwise keep matching it and write it back at
        // stop.
        notifyDeleted(.named(removed))
        return saved ? .deleted : .deletedForThisSessionOnly
    }

    /// Whether a voice profile is stored under a speaker name, matched the
    /// way `forgetSpeaker(named:)` matches. Known speakers asks before its
    /// ✕ so that removing a plain name stays one click and only deleting a
    /// trained voice asks for confirmation.
    enum StoredVoice: Equatable {
        case notStored
        case stored
        /// `speaker-profiles.json` could not be read or decoded, so there is
        /// no telling — and `forgetSpeaker` could not delete it either.
        case unknown
    }

    /// See `StoredVoice`. While recognition is off this reads the file the
    /// same way the off-state `forgetSpeaker` does — into a local that is
    /// dropped on return, never into `profiles` — and only when the user has
    /// just asked to remove a name.
    func storedVoice(forSpeakerNamed name: String) -> StoredVoice {
        let matches = Self.speakerNameMatcher(name)
        if settings.isEnabled {
            if profiles.contains(where: { matches($0.name) })
                || unsavedDeletions.contains(where: { matches($0.name) }) { return .stored }
            return loadedFromDamagedFile ? .unknown : .notStored
        }
        if loadedFromDamagedFile { return .unknown }
        do {
            guard let stored = try readStoredFile() else { return .notStored }
            return stored.contains(where: { matches($0.name) }) ? .stored : .notStored
        } catch {
            return .unknown
        }
    }

    /// Delete the voice profile behind a name the user removed from Settings
    /// → Known speakers, and say how far that got.
    ///
    /// **Removing the name alone is not enough.** The pick-list
    /// (`SpeakerDirectory`) and the voice profiles are separate files, and
    /// recognition reads only the profiles: a removed name whose profile
    /// survived went on being seeded into every recording and labelling the
    /// matched speaker with the name the user had just thrown away — an
    /// imported "Daniel Solomon (from Daniel)" kept reappearing that way
    /// (#358).
    ///
    /// Matches case-insensitively, the same way `SpeakerDirectory.remove`
    /// does, so the entry and the profile go together even when their
    /// spelling drifted in case.
    ///
    /// Not gated on the feature being on, like `deleteAllProfiles` and for
    /// the same reason. While off the profiles are not in memory, so the
    /// file is decoded exactly as `load()` decodes it, the matching rows are
    /// dropped and the rest written back — or the file deleted, when nothing
    /// is left — without anything reaching `profiles`. Otherwise switching
    /// recognition back on would resurrect the voice.
    ///
    /// A file `load()` could not read is never rewritten here, in either
    /// state: it may hold the user's only copy of every other voice, and a
    /// damaged `speaker-profiles.json` is moved aside, never written over
    /// (#329). The outcome is then `.profileFileUnreadable`, and Settings
    /// says so rather than claiming the voice is gone.
    @discardableResult
    func forgetSpeaker(named name: String) -> ProfileDeletionOutcome {
        let matches = Self.speakerNameMatcher(name)
        guard settings.isEnabled else { return forgetOnDisk(where: matches) }
        guard loadedFromDamagedFile else { return deleteProfiles { matches($0.name) } }
        // A failed re-read leaves `profiles` as it was, so the voice may
        // still be in memory and in use: drop it there and tell the
        // observers. No `save()` — that would move the damaged file aside
        // and leave this voice in the backup while reporting it deleted.
        let removed = Set(profiles.map(\.name).filter(matches))
        if !removed.isEmpty {
            profiles.removeAll { matches($0.name) }
            notifyDeleted(.named(removed))
        }
        profileLog.error("forgetSpeaker: speaker-profiles.json could not be read, so it was left as it is")
        return .profileFileUnreadable
    }

    /// The off-state half of `forgetSpeaker`. Nothing decoded here outlives
    /// the call.
    private func forgetOnDisk(where matches: (String) -> Bool) -> ProfileDeletionOutcome {
        guard !loadedFromDamagedFile else {
            profileLog.error("forgetSpeaker: speaker-profiles.json could not be read, so it was left as it is")
            return .profileFileUnreadable
        }
        let stored: [VoiceProfile]
        do {
            guard let decoded = try readStoredFile() else { return .nothingToDelete }
            stored = decoded
        } catch {
            profileLog.error("forgetSpeaker: speaker-profiles.json could not be read, so it was left as it is: \(error.localizedDescription, privacy: .public)")
            return .profileFileUnreadable
        }
        let removed = Set(stored.map(\.name).filter(matches))
        guard !removed.isEmpty else { return .nothingToDelete }
        let kept = stored.filter { !matches($0.name) }
        do {
            if kept.isEmpty {
                // As `deleteAllProfiles` does: no voices left means no file,
                // not an empty array — so Settings stops reporting stored
                // voice data that is not there.
                try fileManager.removeItem(at: storeURL)
            } else {
                try Self.encodeProfiles(kept).write(to: storeURL, options: .atomic)
            }
        } catch {
            profileLog.error("forgetSpeaker error: \(error.localizedDescription, privacy: .public)")
            return .notDeleted
        }
        lastSeenFileDate = currentFileDate()
        let onDisk = storedFilesExist()
        if onDisk != hasStoredProfilesOnDisk { hasStoredProfilesOnDisk = onDisk }
        notifyDeleted(.named(removed))
        return .deleted
    }

    /// How `forgetSpeaker` and `storedVoice` compare a speaker name with a
    /// profile's: case-insensitively, like `SpeakerDirectory.remove`.
    private static func speakerNameMatcher(_ name: String) -> (String) -> Bool {
        return { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// `speaker-profiles.json` decoded exactly as `load()` decodes it, into a
    /// value the caller drops when done — for the off-state paths, which
    /// must leave nothing in `profiles`. nil when there is no file. Throws
    /// for a file that cannot be read or decoded: one `load()` would call
    /// damaged, which no caller may then rewrite.
    private func readStoredFile() throws -> [VoiceProfile]? {
        guard fileManager.fileExists(atPath: storeURL.path) else { return nil }
        return try Self.decodeProfiles(from: Data(contentsOf: storeURL))
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
        hasUnsavedChanges = false
        unsavedDeletions.removeAll()
        do {
            if fileManager.fileExists(atPath: storeURL.path) {
                try fileManager.removeItem(at: storeURL)
            }
            // A damaged file is gone too: the user asked for exactly that.
            loadedFromDamagedFile = false
        } catch {
            profileLog.log("deleteAll error: \(error.localizedDescription, privacy: .public)")
        }
        // So are the copies `save()` moved aside: they hold voice
        // fingerprints as much as the live file does (#329).
        for copy in damagedCopies() {
            do {
                try fileManager.removeItem(at: copy)
            } catch {
                profileLog.log("deleteAll error: \(error.localizedDescription, privacy: .public)")
            }
        }
        hasStoredProfilesOnDisk = storedFilesExist()
        // The backups are gone, so the names dismissed for them are moot —
        // and must not hide a later backup that happens to reuse one.
        // Keep only names whose file survived a failed removal, so that one
        // does not come back as if never dismissed.
        // Not from a failed listing, which would read as "none survived".
        if let surviving = damagedCopyNames().map(Set.init) {
            settings.setDismissedDamagedBackups(settings.dismissedDamagedBackups.intersection(surviving))
        }
        refreshDamagedProfilesNotice()
        // Unconditional, and after the file is gone: this must fire even
        // when `profiles` was already empty in memory (the feature is off,
        // so the file was never loaded) — that is precisely the case where
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

    // MARK: - Sharing (.milashare)

    /// The stored profiles for a set of speaker names (exact match after
    /// trimming), in name order. What the export sheet offers to include.
    ///
    /// Gated on `isEnabled`, not `isConfigured`, deliberately: this is a
    /// READ of data the user already consented to store, and serialising
    /// floats into a file needs no diarization pipeline. (While off,
    /// `profiles` is empty anyway — the file was never loaded.) Writes on
    /// the import side still go through `updateProfile` and its
    /// `isConfigured` gate; see `.claude/rules/feature-gates.md`.
    func profiles(named names: Set<String>) -> [VoiceProfile] {
        guard settings.isEnabled else { return [] }
        let wanted = Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        return profiles
            .filter { wanted.contains($0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Every `.milashare` import any stored profile remembers. The resolver
    /// marks a matching incoming profile "already imported".
    var importedShareTokens: Set<ImportedShareToken> {
        Set(profiles.flatMap(\.importedShares))
    }

    /// Remember that `token` was folded into the profile called `name`.
    /// Called by `SpeakerProfileImportApplier` right after the
    /// `updateProfile` that did the folding. No-op if the profile is not
    /// there (the fold was refused) or already carries the token.
    ///
    /// Persisted through `save()`'s `isEnabled` gate like the other
    /// housekeeping writes: the fold it records could only have happened
    /// behind `isConfigured`, so no new voice data reaches disk here.
    func recordImport(token: ImportedShareToken, onProfileNamed name: String) {
        guard let idx = profiles.firstIndex(where: { $0.name == name }),
              !profiles[idx].importedShares.contains(token) else { return }
        profiles[idx].importedShares.append(token)
        save()
    }

    // MARK: - Staged writes

    /// Changes made inside `staged(_:)`, waiting for `commit(_:)` or
    /// `discard(_:)`. Opaque on purpose: only a value this store handed out
    /// can end a staging run.
    struct StagedChanges {
        fileprivate let id: UUID
        fileprivate let profilesBefore: [VoiceProfile]
        fileprivate let needsSave: Bool
    }

    /// True while `staged(_:)`'s body runs: `save()` records that a write
    /// is owed instead of writing.
    private var isStaging = false
    /// A `save()` was asked for while staging.
    private var stagedSaveRequested = false
    /// The one `StagedChanges` that may still be committed or discarded.
    /// Cleared by either, and by any ordinary `save()` in between — that
    /// write persisted the staged profiles too, so discarding them in
    /// memory afterwards would only make memory disagree with the file.
    private var openStagedID: UUID?

    /// Run `body` against this store with every write held in memory:
    /// `profiles` changes as usual, but `speaker-profiles.json` is not
    /// touched until the caller hands the result to `commit(_:)` — or ever,
    /// if it hands it to `discard(_:)`.
    ///
    /// `RecordingShareImporter.confirm()` is the caller. It folds a
    /// `.milashare`'s voice profiles in BEFORE the recording row, because
    /// the row's speaker labels come out of that step, but the row's
    /// `recordings.json` write is the import's commit point. Writing the
    /// profiles as they were folded left them on disk — merged, created and
    /// tagged with the bundle's import tokens — for a recording that a crash
    /// or a failed write kept out of the library, and the retry then skipped
    /// every speaker as "already imported" (#319, #329). Staged, nothing
    /// reaches disk until the row has.
    ///
    /// The caller must commit or discard in the same synchronous main-actor
    /// run, with no suspension point in between: no deletion observers fire
    /// for what `discard` takes away, which is only sound because nothing
    /// can have seeded from the staged profiles in the meantime.
    func staged<T>(_ body: () -> T) -> (result: T, changes: StagedChanges) {
        precondition(!isStaging, "staged writes do not nest")
        let before = profiles
        isStaging = true
        stagedSaveRequested = false
        let result = body()
        isStaging = false
        let changes = StagedChanges(id: UUID(), profilesBefore: before, needsSave: stagedSaveRequested)
        stagedSaveRequested = false
        openStagedID = changes.id
        return (result, changes)
    }

    /// Persist what `staged(_:)` held back: one `speaker-profiles.json`
    /// write, through the same `save()` (and its gates) every other change
    /// goes through. Returns whether the staged changes are on disk — true
    /// when there was nothing to write; false when the write was refused
    /// or failed (logged by `save()`), in which case they live in memory
    /// only until the next successful save.
    @discardableResult
    func commit(_ changes: StagedChanges) -> Bool {
        guard openStagedID == changes.id else {
            profileLog.error("commit: these staged changes were already committed, discarded or overtaken")
            return false
        }
        openStagedID = nil
        guard changes.needsSave else { return true }
        return save()
    }

    /// Take back what `staged(_:)` changed. Only memory needs putting back:
    /// the file was never written. A no-op (logged) for changes that are no
    /// longer open, so a stale value cannot revert later edits.
    func discard(_ changes: StagedChanges) {
        guard openStagedID == changes.id else {
            profileLog.error("discard: these staged changes were already committed, discarded or overtaken")
            return
        }
        openStagedID = nil
        profiles = changes.profilesBefore
        profileLog.log("discarded staged voice-profile changes; kept \(changes.profilesBefore.count) profiles")
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
        guard keep.effectiveEmbeddingModel == absorb.effectiveEmbeddingModel else {
            profileLog.log("mergeProfiles: embedding model mismatch (\(keep.effectiveEmbeddingModel, privacy: .public) vs \(absorb.effectiveEmbeddingModel, privacy: .public))")
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
        if profiles[keepIdx].embeddingModel == nil {
            profiles[keepIdx].embeddingModel = absorb.embeddingModel
        }
        // The absorbed profile's import history travels with its samples:
        // a bundle already folded into either side is folded into the result.
        for token in absorb.importedShares where !profiles[keepIdx].importedShares.contains(token) {
            profiles[keepIdx].importedShares.append(token)
        }
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
    /// off `profiles` is empty anyway, since the file was never loaded.
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
    /// Returns whether `profiles` is now on disk; only `commit(_:)` reads it.
    @discardableResult
    private func save() -> Bool {
        guard settings.isEnabled else {
            profileLog.log("save skipped — voice recognition is off")
            return false
        }
        if isStaging {
            // `staged(_:)`: the caller decides later whether this reaches disk.
            stagedSaveRequested = true
            return false
        }
        // An ordinary write persists whatever is staged-but-open as well.
        openStagedID = nil
        // `profiles` does not hold what a damaged file holds, so writing
        // would destroy voice data the user could still repair by hand.
        // Move it out of the way first; if that fails, do not write at all.
        if loadedFromDamagedFile, !moveDamagedFileAside() {
            profileLog.error("save skipped — the damaged speaker-profiles.json could not be moved aside")
            hasUnsavedChanges = true
            return false
        }
        do {
            // Ensure the parent directory exists (first launch on a clean install).
            let dir = storeURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: dir.path) {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let data = try Self.encodeProfiles(profiles)
            try data.write(to: storeURL, options: .atomic)
            lastSeenFileDate = currentFileDate()
            hasUnsavedChanges = false
            unsavedDeletions.removeAll()
            hasStoredProfilesOnDisk = true
            return true
        } catch {
            profileLog.log("save error: \(error.localizedDescription, privacy: .public)")
            hasUnsavedChanges = true
            hasStoredProfilesOnDisk = storedFilesExist()
            return false
        }
    }

    private static let damagedPrefix = "speaker-profiles.damaged-"

    /// Hide the notice for every backup present now; remembered by file
    /// name, so a later damaged file still gets its own notice. Replacing
    /// the whole list also forgets names whose files are gone. The backups
    /// themselves are left alone. An `.unreadable` notice cannot be
    /// dismissed: it clears once the file is moved aside, repaired, or
    /// deleted (see `recheckDamagedProfiles`).
    func dismissDamagedProfilesNotice() {
        guard case .setAside = damagedProfilesNotice else { return }
        settings.setDismissedDamagedBackups(Set(damagedCopies().map(\.lastPathComponent)))
        refreshDamagedProfilesNotice()
    }

    /// Bring the notice up to date with what is on disk now. Settings calls
    /// it when it appears and whenever Mila becomes active again — the
    /// notice's own "Show in Finder" invites the user to delete a backup or
    /// repair the live file there, which nothing here would otherwise see.
    ///
    /// The live file is re-read only when it is not the one this store last
    /// read or wrote (`lastSeenFileDate`), so a still-broken file is not
    /// re-parsed on every focus change, and a repaired one — including a
    /// backup the user fixed and put back over the file `save()` wrote — is
    /// loaded instead of being overwritten by the next save. Never while a
    /// change exists only in memory (`hasUnsavedChanges`: its save failed),
    /// which a re-read would drop. Profiles the re-read removes are
    /// reported to the deletion observers, exactly as a delete from
    /// Settings is, so a recording in flight does not write them back.
    ///
    /// While the feature is off the file is never loaded, so a changed
    /// file just clears the unreadable state; opting in re-detects it.
    func recheckDamagedProfiles() {
        let date = currentFileDate()
        if date == nil {
            // Removed by hand. If it held profiles this store had read or
            // written, memory must follow — otherwise Settings hides
            // "Delete Voice Profiles" while the next save writes the
            // voices straight back.
            if lastSeenFileDate != nil, settings.isEnabled, !hasUnsavedChanges {
                let removed = Set(profiles.map(\.name))
                profiles.removeAll()
                if !removed.isEmpty { notifyDeleted(.named(removed)) }
            }
            lastSeenFileDate = nil
            loadedFromDamagedFile = false
        } else if date != lastSeenFileDate, !hasUnsavedChanges {
            if settings.isEnabled {
                let before = Set(profiles.map(\.name))
                load()
                let removed = before.subtracting(profiles.map(\.name))
                if !removed.isEmpty { notifyDeleted(.named(removed)) }
            } else {
                loadedFromDamagedFile = false
            }
        }
        // Forget dismissals of backups the user removed by hand, so a later
        // backup that reuses a name is still announced.
        // Not from a failed listing, which would forget every dismissal.
        if let present = damagedCopyNames().map(Set.init) {
            let dismissed = settings.dismissedDamagedBackups
            if !dismissed.isSubset(of: present) {
                settings.setDismissedDamagedBackups(dismissed.intersection(present))
            }
        }
        refreshDamagedProfilesNotice()
        let stored = storedFilesExist()
        // Unconditional assignment would publish on every app activation.
        if stored != hasStoredProfilesOnDisk { hasStoredProfilesOnDisk = stored }
    }

    /// A change that `save()` could not write (the damaged file could not
    /// be moved aside, or the write failed). Blocks a recheck's re-read.
    private var hasUnsavedChanges = false

    /// Profiles a single delete removed from memory whose save then failed
    /// (`.deletedForThisSessionOnly`): still on disk, so they come back on
    /// the next launch. Kept so `storedVoice` still reports them — or Known
    /// speakers' ✕ would treat the name as plain and drop it in one click —
    /// and so a retried delete re-attempts the save instead of finding
    /// nothing in memory and writing nothing. Cleared by any successful
    /// save (which persists the removal), a load, deleteAll and opt-out.
    private var unsavedDeletions: [VoiceProfile] = []

    /// Modification date of the live file this store last read or wrote.
    private var lastSeenFileDate: Date?

    private func currentFileDate() -> Date? {
        (try? fileManager.attributesOfItem(atPath: storeURL.path))?[.modificationDate] as? Date
    }

    /// Order of a backup's name: `<prefix><stamp>[-<n>].json`. The stamp is
    /// fixed-width UTC, so it compares as a string; the collision suffix
    /// does not (`-` sorts before `.`, and `-10` before `-2`), so it is
    /// compared as a number, with no suffix meaning 1.
    private static func backupOrder(_ url: URL) -> (String, Int) {
        let core = url.deletingPathExtension().lastPathComponent.dropFirst(damagedPrefix.count)
        let parts = core.split(separator: "-", maxSplits: 1)
        let attempt = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
        return (String(parts.first ?? ""), attempt)
    }

    /// The newest backup the user has not dismissed, unless the live file
    /// itself is unreadable right now — that is the more urgent message.
    private func refreshDamagedProfilesNotice() {
        // One listing serves both the notice and the announcement's pruning.
        let backupNames = damagedCopyNames()
        let notice: DamagedProfilesNotice?
        if loadedFromDamagedFile {
            notice = .unreadable(storeURL)
        } else {
            let dismissed = settings.dismissedDamagedBackups
            let dir = storeURL.deletingLastPathComponent()
            notice = (backupNames ?? [])
                .filter { !dismissed.contains($0) }
                .map { dir.appendingPathComponent($0) }
                .max { Self.backupOrder($0) < Self.backupOrder($1) }
                .map(DamagedProfilesNotice.setAside)
        }
        if damagedProfilesNotice != notice { damagedProfilesNotice = notice }
        refreshDamagedProfilesAnnouncement(presentBackups: backupNames)
    }

    /// The main window's banner is on screen (#342): from now on this
    /// incident counts as announced, so the next launch stays quiet.
    func noteDamagedProfilesAnnouncementShown() {
        guard damagedProfilesAnnouncement != nil, let key = shownAnnouncementKey else { return }
        var announced = settings.announcedDamagedProfiles
        guard !announced.contains(key) else { return }
        // Only the newest unreadable file is worth remembering.
        if key.hasPrefix(Self.unreadableKeyPrefix) {
            announced = announced.filter { !$0.hasPrefix(Self.unreadableKeyPrefix) }
        }
        announced.insert(key)
        // A backup announcement covers every backup present, as Dismiss
        // does: deleting the newest one must not turn an older one the user
        // was never shown separately into fresh news.
        if !key.hasPrefix(Self.unreadableKeyPrefix) {
            announced.formUnion(damagedCopyNames() ?? [])
        }
        settings.setAnnouncedDamagedProfiles(announced)
    }

    /// The user closed the banner or followed it into Settings (#342).
    /// Counts as seen, and takes it down for the rest of the session.
    func acknowledgeDamagedProfilesAnnouncement() {
        noteDamagedProfilesAnnouncementShown()
        hideDamagedProfilesAnnouncement()
    }

    /// Settings → Speakers is showing the same notice, so the main window
    /// need not repeat it this session. Deliberately does NOT count as
    /// announced: the section sits below the fold, and Settings being open
    /// on Speakers does not mean the user scrolled to it.
    func hideDamagedProfilesAnnouncement() {
        if let key = shownAnnouncementKey { hiddenAnnouncementKeys.insert(key) }
        shownAnnouncementKey = nil
        if damagedProfilesAnnouncement != nil { damagedProfilesAnnouncement = nil }
    }

    /// What identifies one incident across launches: a backup by its file
    /// name (unique, never reused while it exists), an unreadable live file
    /// by the modification date it had when it failed to load — so an edit
    /// that leaves it broken is news again, and a relaunch is not.
    private func announcementKey(_ notice: DamagedProfilesNotice) -> String {
        switch notice {
        case .setAside(let backup):
            return backup.lastPathComponent
        case .unreadable:
            // No date (the file could not even be stat'ed): nothing ties two
            // such failures together, so each session is its own incident
            // rather than every one sharing a key that is announced once.
            let stamp = lastSeenFileDate.map { String(Int64(($0.timeIntervalSince1970 * 1000).rounded())) }
                ?? "unknown-\(sessionID)"
            return Self.unreadableKeyPrefix + stamp
        }
    }

    /// See `damagedProfilesAnnouncement`. Also forgets announced backups
    /// whose file is gone, so a later backup that reuses a name is still
    /// announced — but only from a listing that succeeded
    /// (`presentBackups` non-nil): a failed one would otherwise forget
    /// every backup the user has already been told about.
    private func refreshDamagedProfilesAnnouncement(presentBackups: [String]?) {
        let stored = settings.announcedDamagedProfiles
        var next: DamagedProfilesNotice?
        // The same banner staying up under a new key — an unreadable file
        // edited and still broken: the notice value does not change, so the
        // view sees nothing new to record. If the old key was recorded, the
        // user has been shown this one too.
        var recordContinuation = false
        if settings.isEnabled, let notice = damagedProfilesNotice {
            let key = announcementKey(notice)
            if key == shownAnnouncementKey
                || (!stored.contains(key) && !hiddenAnnouncementKeys.contains(key)) {
                if key != shownAnnouncementKey, damagedProfilesAnnouncement == notice,
                   let previous = shownAnnouncementKey, stored.contains(previous) {
                    recordContinuation = true
                }
                next = notice
                shownAnnouncementKey = key
            }
        }
        if let presentBackups {
            let present = Set(presentBackups)
            let kept = stored.filter { $0.hasPrefix(Self.unreadableKeyPrefix) || present.contains($0) }
            if kept != stored { settings.setAnnouncedDamagedProfiles(kept) }
        }
        if damagedProfilesAnnouncement != next { damagedProfilesAnnouncement = next }
        if recordContinuation { noteDamagedProfilesAnnouncementShown() }
    }

    /// The copies `moveDamagedFileAside()` left next to the live file.
    private func damagedCopies() -> [URL] {
        let dir = storeURL.deletingLastPathComponent()
        return (damagedCopyNames() ?? []).map { dir.appendingPathComponent($0) }
    }

    /// Their file names, or nil when the folder could not be listed — which
    /// is not the same as "there are none".
    private func damagedCopyNames() -> [String]? {
        let dir = storeURL.deletingLastPathComponent()
        guard let names = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return nil }
        return names.filter { $0.hasPrefix(Self.damagedPrefix) && $0.hasSuffix(".json") }
    }

    /// Whether any voice data this store owns is on disk: the live file or
    /// a moved-aside damaged copy. Feeds `hasStoredProfilesOnDisk`, so
    /// Settings keeps offering "Delete Voice Profiles" while either exists.
    private func storedFilesExist() -> Bool {
        fileManager.fileExists(atPath: storeURL.path) || !damagedCopies().isEmpty
    }

    /// Rename a `speaker-profiles.json` that `load()` could not parse to
    /// `speaker-profiles.damaged-<UTC timestamp>.json` next to it, so the
    /// next write cannot destroy it. Returns whether the path is now free.
    ///
    /// Moving aside, rather than refusing to write, is deliberate: a
    /// refusal would leave voice recognition unable to persist anything —
    /// a named speaker, an imported voice — until the user repairs a file
    /// they likely do not know is broken, and every write path, not only
    /// a `.milashare` import, would need to carry it. The moved file keeps
    /// every byte for a manual repair, and the log says where it went.
    private func moveDamagedFileAside() -> Bool {
        guard fileManager.fileExists(atPath: storeURL.path) else {
            // Removed by hand since launch: nothing left to protect.
            loadedFromDamagedFile = false
            return true
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: Date())
        let dir = storeURL.deletingLastPathComponent()
        var destination = dir.appendingPathComponent("\(Self.damagedPrefix)\(stamp).json")
        var attempt = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = dir.appendingPathComponent("\(Self.damagedPrefix)\(stamp)-\(attempt).json")
            attempt += 1
        }
        let movedFileDate = currentFileDate()
        do {
            try fileManager.moveItem(at: storeURL, to: destination)
        } catch {
            profileLog.error("could not move the damaged speaker-profiles.json aside: \(error.localizedDescription, privacy: .public)")
            return false
        }
        // The backup is the file the user was already told about, not news
        // (#342): it inherits the unreadable file's announcement. Before the
        // flag flips, since that is what refreshes the notice.
        // Only if it is still the file that was announced: one edited since
        // (and still broken) is a new incident, and its backup is news.
        let unreadableKey = announcementKey(.unreadable(storeURL))
        var announced = settings.announcedDamagedProfiles
        if announced.contains(unreadableKey), movedFileDate == lastSeenFileDate {
            announced.insert(destination.lastPathComponent)
            settings.setAnnouncedDamagedProfiles(announced)
        }
        if movedFileDate == lastSeenFileDate {
            if shownAnnouncementKey == unreadableKey { shownAnnouncementKey = destination.lastPathComponent }
            if hiddenAnnouncementKeys.contains(unreadableKey) {
                hiddenAnnouncementKeys.insert(destination.lastPathComponent)
            }
        }
        loadedFromDamagedFile = false
        profileLog.error("moved a speaker-profiles.json that could not be parsed to \(destination.lastPathComponent, privacy: .public) before writing a new one")
        return true
    }

    /// The one decoder for `speaker-profiles.json`. `load()` and the
    /// off-state `forgetSpeaker` / `storedVoice` share it, so a file one of
    /// them calls damaged the others do too. A more lenient reader (say,
    /// `JSONSerialization`, which takes a row missing a field or a date in
    /// the wrong format) would let a delete rewrite a file `load()` had left
    /// alone for repair.
    private static func decodeProfiles(from data: Data) throws -> [VoiceProfile] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([VoiceProfile].self, from: data)
    }

    /// The one encoder for `speaker-profiles.json`, shared by `save()` and
    /// the off-state `forgetSpeaker`.
    private static func encodeProfiles(_ profiles: [VoiceProfile]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(profiles)
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
        guard fileManager.fileExists(atPath: storeURL.path) else {
            lastSeenFileDate = nil
            loadedFromDamagedFile = false
            return
        }
        do {
            lastSeenFileDate = currentFileDate()
            let decoded = try Self.decodeProfiles(from: Data(contentsOf: storeURL))
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
            hasUnsavedChanges = false
            unsavedDeletions.removeAll()
            loadedFromDamagedFile = false
            profileLog.log("loaded \(accepted.count) of \(decoded.count) voice profiles")
        } catch {
            // Left on disk for the user to repair; `save()` moves it aside
            // before it writes anything in its place.
            loadedFromDamagedFile = true
            profileLog.log("load error: \(error.localizedDescription, privacy: .public)")
        }
    }
}
