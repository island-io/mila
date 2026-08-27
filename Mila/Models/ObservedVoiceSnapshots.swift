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

    /// How many recordings' snapshots to keep. Naming happens right after a
    /// recording in the overwhelming majority of cases; a handful of slots
    /// covers "record a few back-to-back, then go back and label them"
    /// without letting embeddings accumulate for the life of the process.
    private let limit: Int

    private var byRecording: [UUID: [String: Observation]] = [:]
    /// Insertion order, oldest first — the eviction queue.
    private var order: [UUID] = []

    init(limit: Int = 8) {
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
    func record(
        _ entries: [(id: String, observedCentroid: [Float], observedCount: Int, profileName: String?)],
        for recordingID: UUID
    ) {
        var observations: [String: Observation] = [:]
        for entry in entries {
            observations[entry.id] = Observation(observedCentroid: entry.observedCentroid,
                                                 observedCount: entry.observedCount,
                                                 profileName: entry.profileName)
        }
        if byRecording.updateValue(observations, forKey: recordingID) == nil {
            order.append(recordingID)
        }
        while order.count > limit {
            let evicted = order.removeFirst()
            byRecording.removeValue(forKey: evicted)
        }
        snapshotLog.log("snapshot: \(observations.count, privacy: .public) speakers for a recording (holding \(self.order.count, privacy: .public))")
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
