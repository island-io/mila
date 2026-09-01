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
        byRecording[recordingID] = observations
        snapshotLog.log("snapshot: dropped a retired speaker id")
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
