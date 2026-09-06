import Foundation
import os

private let snapshotLog = Logger(
    subsystem: "io.island.whisper.IslandWhisper", category: "ObservedVoiceSnapshots")

/// Per-recording snapshots of what `LiveSpeakerDiarizer` observed, so that
/// naming a speaker persists **that recording's** voice and never a later
/// recording's.
///
/// Speaker ids (`SPEAKER_00`, `SPEAKER_01`, …) are positional and restart
/// from zero after every `LiveSpeakerDiarizer.reset()` — once per recording.
/// The persistence hook used to resolve a name against the *live* pool by raw
/// id, which is only correct while the recording being named happens to be
/// the one the pool belongs to. Name a speaker in an earlier recording after
/// a later one has started — an entirely ordinary thing to do from the
/// sidebar — and `SPEAKER_00` resolved to whoever was `SPEAKER_00` in the
/// *newer* recording, writing a different person's voice into the named
/// profile. Nothing surfaced the mistake: the profile was silently poisoned
/// with a stranger's embedding.
///
/// Keying the lookup by recording id makes that confusion impossible. A
/// recording with no snapshot resolves to `nil` and persists nothing, which
/// is the honest answer: its pool is gone, so there is no embedding to learn
/// from.
///
/// Only ever populated from behind the `VoiceRecognitionSettings.isConfigured`
/// gate, and it drops everything on opt-out — an opted-out user has no voice
/// data held here either.
@MainActor
final class ObservedVoiceSnapshots {

    /// What one speaker contributed in one recording. Mirrors the
    /// `observedCentroid` / `observedCount` pair from
    /// `LiveSpeakerDiarizer.SpeakerProfile` — the delta for this recording
    /// alone, never the matching centroid.
    struct Observation: Equatable {
        let observedCentroid: [Float]
        let observedCount: Int
        let profileName: String?
    }

    /// How many recordings' snapshots to keep. Raised from 8 to 20 so
    /// un-naming a speaker (to correct a false recognition) can still find
    /// the snapshot and subtract it from the voice profile. Memory cost is
    /// negligible (~1 KB per speaker per recording).
    private let limit: Int

    private var byRecording: [UUID: [String: Observation]] = [:]
    /// Insertion order, oldest first — the eviction queue.
    private var order: [UUID] = []

    init(limit: Int = 20) {
        self.limit = max(1, limit)
    }

    /// Observe a settings object so an opt-out discards everything held.
    func clearOnOptOut(of settings: VoiceRecognitionSettings) {
        settings.addEnabledObserver { [weak self] nowEnabled in
            guard !nowEnabled else { return }
            self?.removeAll()
        }
    }

    /// Snapshot a recording's pool. Call once, at stop, **before** anything
    /// can trigger `RecordingStore.onSpeakerNamed` for this recording.
    ///
    /// Every pool entry is kept, not just seeded ones: a brand-new speaker
    /// the user names by hand is the primary way profiles get created in the
    /// first place, and that path needs the same lookup.
    ///
    /// Re-snapshotting the same recording replaces its entry and keeps its
    /// original position in the eviction queue.
    ///
    /// **Whole-map replace, and callers must want that.** This is the live
    /// stop path's method: it hands over the complete pool, so replacing is
    /// right. A caller holding observations for *some* of a recording's
    /// speakers wants `merge` — passing a partial set here silently discards
    /// every speaker it does not mention (island-io/mila#237).
    func record(
        _ entries: [(id: String, observedCentroid: [Float], observedCount: Int, profileName: String?)],
        for recordingID: UUID
    ) {
        store(observations(from: entries), for: recordingID, mergingIntoExisting: false)
    }

    /// Add observations for *some* of a recording's speakers, leaving the
    /// ones already held for speakers this call does not mention untouched.
    ///
    /// The on-demand embedding path (`OfflineVoiceEmbedder`) writes one
    /// speaker at a time — naming `SPEAKER_00` and then `SPEAKER_01` on an
    /// old recording are two independent extractions — and with `record`
    /// the second wiped the first. That is not cosmetic: un-naming the
    /// first speaker afterwards finds no observation, so the profile it
    /// polluted is never corrected, which is the whole point of #237.
    func merge(
        _ entries: [(id: String, observedCentroid: [Float], observedCount: Int, profileName: String?)],
        for recordingID: UUID
    ) {
        store(observations(from: entries), for: recordingID, mergingIntoExisting: true)
    }

    private func observations(
        from entries: [(id: String, observedCentroid: [Float], observedCount: Int, profileName: String?)]
    ) -> [String: Observation] {
        var observations: [String: Observation] = [:]
        for entry in entries {
            observations[entry.id] = Observation(observedCentroid: entry.observedCentroid,
                                                 observedCount: entry.observedCount,
                                                 profileName: entry.profileName)
        }
        return observations
    }

    private func store(_ incoming: [String: Observation],
                       for recordingID: UUID,
                       mergingIntoExisting: Bool) {
        var observations = mergingIntoExisting ? (byRecording[recordingID] ?? [:]) : [:]
        observations.merge(incoming) { _, new in new }
        if byRecording.updateValue(observations, forKey: recordingID) == nil {
            order.append(recordingID)
        }
        while order.count > limit {
            let evicted = order.removeFirst()
            byRecording.removeValue(forKey: evicted)
        }
        snapshotLog.log("snapshot: \(observations.count, privacy: .public) speakers for a recording (holding \(self.order.count, privacy: .public))")
    }

    /// Forget everything held for one recording.
    ///
    /// Called when a pass re-keys that recording's `SPEAKER_NN` ids. The ids
    /// are positional — pyannote assigns them by first-appearance order on
    /// each clustering — so after a re-transcribe or an offline re-diarize
    /// the *same string* denotes a possibly different person. Keeping the
    /// old observations would resolve a name applied to the new
    /// `SPEAKER_00` against the previous run's voice: precisely the
    /// cross-recording confusion this type's header says the recording-id
    /// keying exists to prevent, reintroduced across a re-clustering
    /// boundary instead of across recordings (island-io/mila#237).
    ///
    /// Deliberately ungated: dropping held data is always safe, and a gate
    /// would leave stale embeddings behind for anyone who opted out between
    /// the pass starting and finishing.
    func invalidate(_ recordingID: UUID) {
        guard byRecording.removeValue(forKey: recordingID) != nil else { return }
        order.removeAll { $0 == recordingID }
        snapshotLog.log("snapshot invalidated for a re-keyed recording (holding \(self.order.count, privacy: .public))")
    }

    /// Forget one speaker's observation within a recording, for a raw id
    /// that has stopped existing there — the source of a merge, or a
    /// speaker whose last segment was reassigned away.
    ///
    /// Without this the observation outlives the id, and `SPEAKER_NN` ids
    /// get reused: `splitSegmentSpeaker` mints the lowest free number, so a
    /// merged-away `SPEAKER_01` is handed straight back to the next split.
    /// Naming that new speaker would then fold the *previous* speaker's
    /// embedding into their profile.
    func forget(speaker rawID: String, in recordingID: UUID) {
        guard var observations = byRecording[recordingID],
              observations.removeValue(forKey: rawID) != nil else { return }
        // Dropping the last one releases the recording rather than leaving an
        // empty entry, which would hold one of the 20 retention slots while
        // describing no voice at all — and evict a recording that still has
        // observations a later un-name needs. Same rule `remapSpeakerIDs`
        // applies when a mapping carries nothing.
        guard !observations.isEmpty else {
            invalidate(recordingID)
            return
        }
        byRecording[recordingID] = observations
        snapshotLog.log("snapshot: dropped a retired speaker id")
    }

    /// Move one speaker's observation onto another within a recording: the
    /// source id has stopped existing and its audio is now the target's.
    ///
    /// **This is the snapshot half of a merge, and it is not optional.** The
    /// store's merge also moves the source's *profile* contribution to the
    /// target (subtract from the old name, add to the new). If the snapshot
    /// did not follow, the target would carry two observations' worth of
    /// profile weight while its snapshot still described one — and
    /// `subtractObservation` is only an inverse of `updateProfile` while the
    /// two agree. Un-naming the target afterwards would take back half of
    /// what this recording contributed and leave the rest in the profile
    /// with no way to reach it.
    ///
    /// Combined with the same weighted fold `updateProfile` uses, which is
    /// what makes "add A then add B" and "add mean(A, B) with the summed
    /// count" interchangeable.
    func absorb(speaker sourceRawID: String, into targetRawID: String, in recordingID: UUID) {
        guard sourceRawID != targetRawID else { return }
        guard var observations = byRecording[recordingID],
              let source = observations.removeValue(forKey: sourceRawID) else { return }
        if let target = observations[targetRawID] {
            if let combined = Self.combined(target, source) {
                observations[targetRawID] = combined
            } else {
                // Dimension mismatch (a model change between the two
                // extractions). Keep the target's own and drop the source's
                // rather than persist a centroid of two different spaces.
                snapshotLog.log("snapshot: cannot absorb across embedding dimensions — source dropped")
            }
        } else {
            observations[targetRawID] = source
        }
        byRecording[recordingID] = observations
    }

    /// Weighted mean of two observations, weighting by their sample counts.
    /// `nil` when they cannot be combined (different embedding dimensions, an
    /// empty centroid, or a non-finite result) — a caller must then keep one
    /// and drop the other rather than persist a centroid of two spaces.
    ///
    /// The fold matches `SpeakerProfileStore.updateProfile`'s, which is what
    /// makes "add A then add B" and "add mean(A, B) with the summed count"
    /// interchangeable — so a caller holding several observations that went
    /// into ONE profile under ONE name can combine them into the single entry
    /// whose subtraction reverses all of them exactly. `absorb` uses it for a
    /// merge; `OfflineVoiceEmbedder` uses it to carry a name's contribution
    /// across a re-transcribe (island-io/mila#260).
    static func combined(_ a: Observation, _ b: Observation) -> Observation? {
        guard a.observedCentroid.count == b.observedCentroid.count,
              !a.observedCentroid.isEmpty else { return nil }
        let total = a.observedCount + b.observedCount
        guard total > 0 else { return nil }
        var merged = [Float](repeating: 0, count: a.observedCentroid.count)
        for i in merged.indices {
            merged[i] = (a.observedCentroid[i] * Float(a.observedCount)
                       + b.observedCentroid[i] * Float(b.observedCount)) / Float(total)
        }
        guard merged.allSatisfy({ $0.isFinite }) else { return nil }
        return Observation(observedCentroid: merged,
                           observedCount: total,
                           profileName: a.profileName)
    }

    /// Carry a recording's observations across a pass that re-keyed its
    /// `SPEAKER_NN` ids, using the same new→old mapping
    /// `SpeakerNameRemapper` uses to carry the *names*.
    ///
    /// **Why remap rather than invalidate.** Dropping everything was the
    /// first answer here, and it was wrong in a way that only shows up one
    /// step later: the offline re-diarize keeps the names (so the profile
    /// contributions those names justified are still on disk) while the
    /// observations that would reverse them are gone. Un-naming a speaker
    /// after a re-diarize then silently corrects nothing — the whole point
    /// of island-io/mila#237 — on every VAD recording with enough speakers
    /// to trigger the pass. Remapping keeps the two sides agreeing, on
    /// exactly the evidence the name remap already trusts: `rediarizeSegments`
    /// reassigns `.speaker` on the *same* segment array, so per-index pairs
    /// say which old speaker each new one was.
    ///
    /// **Carries exactly one old observation per new id: the dominant one,
    /// the same old id `SpeakerNameRemapper.remap` took that new id's NAME
    /// from.** That pairing is the whole safety argument. The name and the
    /// embedding arrive from the same fragment, so un-naming the new speaker
    /// subtracts precisely what naming that old fragment added — an exact
    /// inverse, with no knowledge of the other fragments required.
    ///
    /// **What is deliberately given up.** When the pass collapses several old
    /// ids into one — which is the main reason it runs — the non-dominant
    /// fragments' observations are dropped rather than folded in, so that
    /// audio stops contributing to any profile. That is an accuracy loss, and
    /// it is the one taken on purpose.
    ///
    /// **What is no longer given up.** A non-dominant fragment that had been
    /// NAMED used to leave its contribution behind as residue: the re-key
    /// dropped its name through a wholesale `speakerNames` write, so nothing
    /// fired `onSpeakerUnnamed` and there was no label left to un-name. The
    /// caller now retires such a name in the same operation and BEFORE this
    /// runs — `SpeakerNameRemapper.retiredNames` decides which ones, and
    /// `RecordingStore.update(_:retiringSpeakerNames:)` fires the hook while
    /// the observation is still keyed to the old id, so the subtraction takes
    /// back exactly what naming that id added. Same for the split case below.
    /// What this type carries and what the profiles hold therefore stay
    /// reconstructible from each other across a re-key (island-io/mila#254).
    ///
    /// **Why folding every fragment in is still wrong, with the arithmetic.** An
    /// earlier revision folded every fragment onto the survivor, reasoning
    /// that `finish` had folded them all into the profile. It has not:
    /// `finish` snapshots *every* pool entry but names only the ones seeded
    /// from a stored profile or typed by hand, and over-segmentation is
    /// exactly the case that produces unseeded, unnamed fragments of a person
    /// who also has a named one. With a profile at `S` samples, a named
    /// fragment `(obs_A, n_A)` and an unnamed `(obs_B, n_B)`, the profile
    /// holds `S + n_A` while the folded snapshot claims `n_A + n_B` — so
    /// un-naming leaves `S − n_B`, which **deletes the profile** whenever
    /// `S ≤ n_B` (reachable at `S == 1`, the count of a profile created once
    /// through the on-demand path) and otherwise writes back a centroid
    /// dragged toward a voice the profile never received.
    ///
    /// Under-correcting is recoverable — the user can delete the profile and
    /// let it re-learn. A deleted profile is not, and a quietly corrupted
    /// centroid is worse than either, because it degrades recognition
    /// invisibly, which is the failure this whole feature exists to remove.
    ///
    /// **Do not "fix" this by folding again without also knowing which
    /// fragments the profile actually received.** That information is not in
    /// this type — it holds what was *observed*, which stops being the same
    /// thing the moment a fragment goes unnamed. The retire pass above needs
    /// no such knowledge: it only ever reverses a name that a hook already
    /// applied, one fragment at a time.
    ///
    /// A split is the other direction: one old id dominating two new ids
    /// would hand its observation to both, and un-naming both would subtract
    /// it twice. Such an id is dropped rather than duplicated — again the
    /// under-correcting side.
    ///
    /// **The survival rule below — `timesDominant[oldID] == 1` — is mirrored
    /// by `SpeakerNameRemapper.retiredNames`**, which retires exactly the
    /// names whose old id does NOT survive it. Change one and change the
    /// other: retiring a name whose observation is carried over subtracts the
    /// same contribution twice, and not retiring one whose observation is
    /// dropped is the residue this pair exists to remove.
    func remapSpeakerIDs(_ newToOld: [String: String], in recordingID: UUID) {
        guard let existing = byRecording[recordingID] else { return }
        var timesDominant: [String: Int] = [:]
        for oldID in newToOld.values { timesDominant[oldID, default: 0] += 1 }

        var remapped: [String: Observation] = [:]
        for (newID, oldID) in newToOld {
            guard timesDominant[oldID] == 1, let observation = existing[oldID] else { continue }
            remapped[newID] = observation
        }
        guard !remapped.isEmpty else {
            invalidate(recordingID)
            return
        }
        byRecording[recordingID] = remapped
        snapshotLog.log("snapshot: carried \(remapped.count, privacy: .public) of \(existing.count, privacy: .public) observations across a re-key")
    }

    /// The observation for `rawID` **in that specific recording**, or nil
    /// when this recording was never snapshotted (or has been evicted) — in
    /// which case the caller must persist nothing rather than fall back to
    /// the live pool.
    func observation(forSpeaker rawID: String, in recordingID: UUID) -> Observation? {
        byRecording[recordingID]?[rawID]
    }

    func removeAll() {
        byRecording.removeAll()
        order.removeAll()
    }

    /// Number of recordings currently held. For tests and diagnostics.
    var heldRecordingCount: Int { order.count }
}
