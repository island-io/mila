import Foundation

/// Reconciles a finished recording's speaker names: applies the names the
/// user typed into the live transcript, applies stored voice-profile names to
/// the speakers it actually recognised, and snapshots that recording's
/// observations so a later rename can persist the right voice.
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
    private let profileStillStored: (String) -> Bool

    /// `profileStillStored` answers "is there still a stored profile under
    /// this name?", read at stop rather than at record-start. A closure
    /// rather than a `SpeakerProfileStore` reference, following
    /// `VoiceRecognitionSettings.diarizationReady`: this object has no
    /// business mutating the store, and the gate is trivially testable. It
    /// has no default — a defaulted `{ true }` would fail open, which is the
    /// bug it exists to prevent.
    init(store: RecordingStore,
         diarizer: LiveSpeakerDiarizer,
         snapshots: ObservedVoiceSnapshots,
         settings: VoiceRecognitionSettings,
         profileStillStored: @escaping (String) -> Bool) {
        self.store = store
        self.diarizer = diarizer
        self.snapshots = snapshots
        self.settings = settings
        self.profileStillStored = profileStillStored
    }

    /// Call once per finished recording, with that recording's id and the
    /// names the user assigned from the live transcript while it ran.
    ///
    /// **Why the live names arrive here rather than being written onto the
    /// row.** There is no `Recording` in the store while a recording is
    /// running — `QuickActionsController.stopRecording` calls `store.add`
    /// *after* `session.stop()` — so `setSpeakerName(recordingID:)` is
    /// literally unreachable from the live pane: it resolves the id to a row
    /// index and returns when there is none. The live pane therefore holds
    /// the name in `LiveTranscriber.speakerNames`, and the drain used to copy
    /// that map straight onto the row (`store.add(speakerNames:)`, then
    /// `updated.speakerNames = …`). The label stuck and nothing was learned:
    /// by the time this method ran, the row already carried the name, so
    /// `setSpeakerName`'s no-change guard returned before firing
    /// `onSpeakerNamed` — the one hook that persists a voice profile
    /// (island-io/mila#209). Naming the same speaker afterwards from the
    /// detail view *did* persist, which is what made it easy to miss.
    ///
    /// So the drain no longer writes those names at all; it hands them here,
    /// and they go through `store.setSpeakerName` like every other name. That
    /// keeps **one** persistence trigger, which is the invariant the loop
    /// below documents at length — a second, parallel write is what caused
    /// the double-merge fixed in #204.
    ///
    /// The voice-recognition gate covers the snapshot and the auto-naming
    /// loop, **not** the live names: a display name is not voice data, it
    /// must keep working with recognition switched off (see
    /// `VoiceRecognitionGateTests.test_while_off_naming_a_speaker_persists_no_embedding`),
    /// and gating it would have silently dropped every mid-recording label
    /// for the majority of users who never opt in.
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
    func finish(recording recordingID: UUID, liveSpeakerNames: [String: String] = [:]) {
        // `isConfigured` is a computed property over two settings values, and
        // it now gates two separate things here (the snapshot, and the
        // auto-naming loop) with an ungated stretch between them. Read once
        // into a local so those two can never disagree — snapshotting
        // embeddings and then skipping the loop that consumes them, or the
        // reverse, would each be a silent half-behaviour.
        let recognitionOn = settings.isConfigured
        let poolEntries = recognitionOn ? diarizer.currentProfiles() : []

        // Snapshot against this recording's id BEFORE naming anything:
        // `setSpeakerName` fires `onSpeakerNamed` synchronously, and that
        // hook resolves the voice through this snapshot. Every pool entry is
        // kept, not just seeded ones, because a speaker the user names by
        // hand — mid-recording in the loop just below, or later from the
        // detail view — needs the same lookup.
        //
        // Gated: an opted-out user has no embeddings held here either. That
        // is also why `poolEntries` is left empty above rather than read and
        // discarded.
        if recognitionOn {
            snapshots.record(poolEntries, for: recordingID)
        }

        // The names the user typed into the live transcript while this
        // recording ran. Applied through `setSpeakerName` — the single
        // persistence trigger — and applied FIRST, so a label the user chose
        // deliberately is never overwritten by the auto-naming loop below,
        // and so each raw id fires `onSpeakerNamed` at most once.
        //
        // Sorted for a deterministic order: `Dictionary` iteration order is
        // unspecified and varies per process, and this drives log lines and
        // an `.srt` rewrite per entry.
        for (rawID, name) in liveSpeakerNames.sorted(by: { $0.key < $1.key }) {
            store.setSpeakerName(name, forSpeaker: rawID, recordingID: recordingID)
        }

        guard recognitionOn else { return }

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
            // 0. The user did not already name this speaker themselves.
            //    Their label wins over a recogniser's guess, and skipping
            //    is what keeps the hook to one fire per raw id: overwriting
            //    "Bob" with "Alice" here would fire `onSpeakerNamed` a second
            //    time and fold this recording's centroid into *both*
            //    profiles. (Before the live names came through this method
            //    the auto-name silently clobbered them — the label the user
            //    typed mid-recording was replaced by the seeded profile's.)
            guard liveSpeakerNames[entry.id] == nil else { continue }
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
            // 3. The profile is still stored. The pool was seeded at
            //    record-start and holds its own copy of the centroid, so a
            //    profile can disappear underneath it while the recording
            //    runs — the user deleting their voice profiles from Settings
            //    is the case that matters, and merging or renaming one has
            //    the same shape. Naming a speaker here fires
            //    `RecordingStore.onSpeakerNamed`, which persists; and
            //    `updateProfile` *creates* when the name is absent, because
            //    that is how a hand-named speaker gets a profile at all. So
            //    an ungated auto-name recreates exactly what the user just
            //    erased, file and all, with this recording's centroid — a
            //    fingerprint that matches the deleted one to better than
            //    0.999 cosine.
            //
            //    `SpeakerProfileStore`'s deletion observer already strips
            //    `profileName` out of the pool, so deletion normally never
            //    reaches this line. This is the second lock: it keeps the
            //    guarantee local to the write path, covers the routes that
            //    do not notify (a rename, or the absorbed half of a merge),
            //    and does not depend on a caller having wired the observer
            //    up. Note it can only *suppress* an auto-name — naming a
            //    speaker by hand still creates a profile, as it must.
            guard profileStillStored(profileName) else { continue }
            store.setSpeakerName(profileName, forSpeaker: entry.id, recordingID: recordingID)
        }
    }
}
