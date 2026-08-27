import Foundation

/// Applies stored voice-profile names to the speakers a finished recording
/// actually recognised, and snapshots that recording's observations so a
/// later rename can persist the right voice.
///
/// Extracted from `MilaApp` for one reason above all: **it must be told which
/// recording finished, never infer it.** The previous version ran off
/// `.onChange(of: actions.isRecording)` — which carries no id — and recovered
/// one with `store.recordings.first`. That is wrong twice over:
///
///   * `RecordingStore.add` does `recordings.insert(_, at: 0)` with no
///     re-sort, so *any* recording added afterwards becomes `first`. The
///     Voice Memos importer calls `add` from its own async flow, so a memo
///     landing between the meeting's `add` and SwiftUI delivering the
///     `.onChange` made the memo "the recording that just stopped".
///   * `load()` and `recoverOrphanRecordings()` sort by `createdAt`
///     descending, and imported memos carry their *own* dates, so ordering
///     is not a reliable proxy for recency of *finishing* either.
///
/// Misidentifying the recording degraded safely — an unknown id resolves to
/// no snapshot, so the profile silently fails to learn rather than merging a
/// stranger's voice — and that fail-closed property is deliberate and worth
/// keeping. But failing safely is not the same as being right, so the id is
/// now carried: `QuickActionsController` invokes `finish(recording:)` from
/// inside its finalize drain, where it holds the exact id.
///
/// That call site is also the only moment when reading the live diarizer is
/// sound. It sits after `awaitPending()` (so `intervals` are final) and
/// before `liveDiarizer?.stop()`, inside the window `isFinalizingRecording`
/// holds the next recording off — so the pool is guaranteed to still be this
/// recording's. The old deferred `.onChange` had no such guarantee: a user
/// hitting Record again promptly could `reset()` the pool first.
@MainActor
final class RecognisedSpeakerAssigner {

    private let store: RecordingStore
    private let diarizer: LiveSpeakerDiarizer
    private let snapshots: ObservedVoiceSnapshots
    private let settings: VoiceRecognitionSettings

    init(store: RecordingStore,
         diarizer: LiveSpeakerDiarizer,
         snapshots: ObservedVoiceSnapshots,
         settings: VoiceRecognitionSettings) {
        self.store = store
        self.diarizer = diarizer
        self.snapshots = snapshots
        self.settings = settings
    }

    /// Call once per finished recording, with that recording's id.
    ///
    /// No-ops entirely while voice recognition is off — the pool would carry
    /// no `profileName` anyway (nothing was seeded), but an explicit gate
    /// keeps the guarantee readable rather than emergent, and it also stops
    /// the snapshot below from holding embeddings for an opted-out user.
    ///
    /// **On the removed `intervals` check.** This loop used to also require
    /// `diarizer.intervals.contains { $0.speaker == entry.id }`, justified as
    /// proving the speaker "reached the transcript". That justification was
    /// wrong on both halves. `intervals` holds *diarizer utterance*
    /// intervals, appended in `process` before anything is matched against
    /// transcript segments (`applySpeakerLabels` does that later), so it
    /// never evidenced transcript presence. And it was redundant:
    /// `observedCount` is only ever incremented by `assign`, whose sole
    /// production caller is `process`, which appends an interval for exactly
    /// the id `assign` returned — so `observedCount > 0` already implies an
    /// interval for that speaker. `reset()` clears pool and intervals
    /// together, so they cannot drift apart either. Do not re-add it
    /// expecting extra safety; it adds none, and it made this method
    /// unreachable from a unit test (`intervals` is `private(set)` and only
    /// fills via the daemon).
    func finish(recording recordingID: UUID) {
        guard settings.isConfigured else { return }
        let poolEntries = diarizer.currentProfiles()

        // Snapshot against this recording's id BEFORE naming anything:
        // `setSpeakerName` fires `onSpeakerNamed` synchronously, and that
        // hook resolves the voice through this snapshot. Every pool entry is
        // kept, not just seeded ones, because a speaker the user names by
        // hand later needs the same lookup.
        snapshots.record(poolEntries, for: recordingID)

        // Persistence is `setSpeakerName`'s job, not this loop's — one
        // recognition must fold into the stored centroid exactly once.
        // `setSpeakerName` synchronously fires `store.onSpeakerNamed`, which
        // `MilaApp.init` wires to `SpeakerProfileStore.updateProfile`. This
        // used to *also* call `updateProfile` directly with the same entry,
        // so every recognised speaker merged twice per recording: the
        // centroid value survives that (a weighted average of x with x is x)
        // but `sampleCount` doubles, and since the merge weights by sample
        // count the profile goes progressively rigid and quietly stops
        // adapting — recognition decays with no visible failure. Do not
        // re-add a second persistence call here. The single call below is
        // deliberately the only one, and it is what makes re-running this
        // for the same recording idempotent: the name already matches, so
        // `setSpeakerName` returns without firing the hook.
        for entry in poolEntries {
            // 1. Seeded from a stored profile — there is a name to assign.
            guard let profileName = entry.profileName else { continue }
            // 2. Confidently matched this recording. `assign` deliberately
            //    attaches *borderline* utterances (and anything under a
            //    second) to the nearest existing speaker without folding
            //    them into the centroid — so such an utterance produces an
            //    interval while leaving `observedCount` at zero. Gating on
            //    intervals alone therefore stamped a stored profile's name
            //    onto a speaker that never confidently matched it: a
            //    misattributed transcript, and the wrong person's name shown
            //    against their words. `observedCount` is precisely the
            //    "confidently observed this recording" signal.
            guard entry.observedCount > 0 else { continue }
            store.setSpeakerName(profileName, forSpeaker: entry.id, recordingID: recordingID)
        }
    }
}
