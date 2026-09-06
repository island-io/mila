import Foundation
import os
import TranscriptionCore

private let embedLog = Logger(
    subsystem: "io.island.whisper.IslandWhisper", category: "OfflineVoiceEmbedder")

/// One speaker's audio span, as handed to the embedder.
///
/// File scope rather than nested in `OfflineVoiceEmbedder` on purpose: a
/// global actor propagates to nested types, and this value has to be built
/// and read *off* the main actor, inside the embedding closure.
struct SpeakerAudioSpan: Equatable, Sendable {
    let rawID: String
    let start: Double
    let end: Double
}

/// The `speakerNames` a batch pass cleared off one recording, paired with the
/// voice-profile contribution each of those names had already made.
///
/// File scope rather than nested in `OfflineVoiceEmbedder`, for the same
/// reason as `SpeakerAudioSpan`: a global actor propagates to nested types,
/// and this value is captured by the extraction task, which is not
/// main-actor isolated. It therefore holds plain data rather than
/// `ObservedVoiceSnapshots.Observation` — the conversion happens on the main
/// actor at both ends.
struct ClearedSpeakerNames: Sendable {
    /// One name's contribution to its profile from this recording: what
    /// `onSpeakerNamed` folded in, and so exactly what un-naming would take
    /// back out.
    struct Contribution: Sendable, Equatable {
        let centroid: [Float]
        let count: Int
        let profileName: String?
    }

    let recordingID: UUID
    /// **Only the names whose observation is still held**, keyed by name.
    ///
    /// A name the row carried whose observation is gone is deliberately
    /// absent, not listed separately. Knowing "this recording already
    /// contributed to that profile" is not enough to act on: suppressing the
    /// re-match's fold without also re-pointing the snapshot at the
    /// observation the profile actually received would leave the snapshot
    /// claiming an observation the profile never got, and a later un-name
    /// would subtract a vector that was never added — a drifted centroid,
    /// which is worse than the residue it was avoiding. So the carry exists
    /// exactly where it can be completed, and every other name takes the
    /// ordinary path.
    ///
    /// That is not a rare gap. `ObservedVoiceSnapshots` is in-memory only, so
    /// **after any relaunch this map is empty** while the row's names (which
    /// are persisted) are not.
    let contributions: [String: Contribution]
}

/// Voice recognition for recordings the **live** diarizer pool never covered:
/// imports, batch-transcribed files, and anything recorded before the feature
/// was switched on.
///
/// `ObservedVoiceSnapshots` is filled at Stop from the live pool, so every
/// other recording resolves to `nil` and naming a speaker on it learns
/// nothing. This object closes that gap from the other end — it extracts a
/// centroid from a speaker's longest segment on the finished audio
/// (`SpeakerDiarizer.embedSpeakers`: the embedding model only, ~0.4 s, versus
/// tens of minutes for the full pipeline) and feeds it into the same snapshot
/// + profile path. Two entry points:
///
///  * `learnNamedSpeaker` — the user just named a speaker on a recording with
///    no observation for them. Extract one, snapshot it, fold it into the
///    profile.
///  * `matchAfterPass` — a batch transcription finished. Extract every
///    speaker, snapshot them, and auto-name the ones that match a stored
///    profile.
///  * `notePassClearedSpeakerNames` — the same pass, one step earlier: the
///    names it dropped off the row. Fed straight back into the `matchAfterPass`
///    that follows it, so a name coming back by voice re-attaches to the
///    contribution the profile already holds instead of adding another
///    (island-io/mila#260).
///
/// **Extracted from `MilaApp.init` for the same reason as
/// `RecognisedSpeakerAssigner`: closures in an `App`'s initializer are
/// unreachable from a unit test, and this code writes to the user's speaker
/// labels and voice profiles across an `await` that spans a Python process.
/// Every ordering hazard below was found by reading, and none of them would
/// have been caught by a test of `MilaApp`.** The embedding call is injected
/// (`embed`) so the tests drive both paths with no Python runtime; `MilaApp`
/// passes the real `SpeakerDiarizer.embedSpeakers`.
@MainActor
final class OfflineVoiceEmbedder {

    /// `(audioURL, spans) -> rawID: centroid`. Throwing and partial: a
    /// speaker whose span is too short to embed is simply absent from the
    /// result.
    ///
    /// `@Sendable` so a closure literal written inside a main-actor context
    /// does not silently inherit that isolation — which would drag the
    /// Python launch, and `AudioCompressor.decodeToTempWAV` before it, onto
    /// the main actor.
    typealias Embed = @Sendable (URL, [SpeakerAudioSpan]) async throws -> [String: [Float]]

    /// Weak: `RecordingStore.onSpeakerNamed` is wired to this object, so a
    /// strong reference here would close a retain cycle through a closure the
    /// store owns. The store outlives everything (it is a `@StateObject` on
    /// `MilaApp`), so this never observes a live recording going missing for
    /// any reason other than shutdown.
    private weak var store: RecordingStore?
    private let snapshots: ObservedVoiceSnapshots
    private let profiles: SpeakerProfileStore
    private let settings: VoiceRecognitionSettings
    private let matchThreshold: () -> Double
    private let embed: Embed

    /// In-flight extractions, keyed by a token so each clears its own entry.
    /// Exists for `awaitPending()` — see there.
    private var pending: [UUID: Task<Void, Never>] = [:]

    /// What the pass whose completion is being announced right now took off
    /// the row, waiting for the `matchAfterPass` that follows it.
    ///
    /// **One slot, and it is not a cache.** `TranscriptionService`
    /// announces the cleared names and the completion back to back with
    /// nothing between them (`announceCompletion`), and `matchAfterPass`
    /// consumes this unconditionally before doing anything else — so it is
    /// written and read inside one synchronous span. A value still sitting
    /// here when the next pass reports in belongs to a pass whose match never
    /// ran, and is dropped rather than applied to a different recording.
    private var clearedByPass: ClearedSpeakerNames?

    init(store: RecordingStore,
         snapshots: ObservedVoiceSnapshots,
         profiles: SpeakerProfileStore,
         settings: VoiceRecognitionSettings,
         matchThreshold: @escaping () -> Double,
         embed: @escaping Embed) {
        self.store = store
        self.snapshots = snapshots
        self.profiles = profiles
        self.settings = settings
        self.matchThreshold = matchThreshold
        self.embed = embed
    }

    // MARK: - Naming a speaker on a recording with no observation

    /// Wire to `RecordingStore.onSpeakerNamed`, for the branch where
    /// `ObservedVoiceSnapshots` holds nothing for `rawID`.
    ///
    /// Extraction is slow — a Python launch, torch and the pyannote pipeline
    /// — so the name the user typed is *re-read* when the result lands. In
    /// between they can perfectly well pick "Use default", and writing the
    /// profile anyway leaves a voice fingerprint attached to a name they
    /// explicitly cleared, with no route back: un-naming again is a no-op
    /// (`setSpeakerName` returns early when there is no previous name) and
    /// nothing in the UI subtracts an observation the snapshot never held.
    func learnNamedSpeaker(recordingID: UUID, rawID: String, name: String) {
        guard settings.isConfigured, let store else { return }
        guard let rec = store.recordings.first(where: { $0.id == recordingID }),
              let span = Self.longestSpan(for: rawID, in: rec) else { return }
        // Whether this name already had a profile, so the write below can
        // tell "create the profile this hand-naming is for" from "recreate
        // one the user deleted while Python was running". `updateProfile`
        // creates on a missing name — that is how hand-naming makes a
        // profile at all — so the create path cannot simply be closed.
        let profileExistedAtStart = profiles.profileExists(name: name)
        spawn { [self] in
            let embeddings = await extract(spans: [span], for: recordingID)
            guard let centroid = embeddings[rawID], !centroid.isEmpty else { return }
            await MainActor.run {
                guard self.settings.isConfigured else { return }
                // The name must still be the one this extraction was for.
                guard let live = self.store?.recordings.first(where: { $0.id == recordingID }),
                      !live.isTrashed,
                      live.speakerNames[rawID] == name else {
                    embedLog.log("on-demand embedding discarded: \(rawID, privacy: .public) is no longer that name")
                    return
                }
                // Deleting a voice profile is the strongest statement the user
                // can make about it, and this write would silently undo it —
                // recreating the file with a centroid matching the erased one
                // to better than 0.999 cosine. Same hazard, and the same
                // answer, as `RecognisedSpeakerAssigner`'s `profileStillStored`
                // gate.
                if profileExistedAtStart, !self.profiles.profileExists(name: name) {
                    embedLog.log("on-demand embedding discarded: the profile was deleted while extracting")
                    return
                }
                // `merge`, never `record`: naming a second speaker on the
                // same recording is an independent extraction, and a
                // whole-map replace would drop the first one's observation.
                self.snapshots.merge([(id: rawID,
                                       observedCentroid: centroid,
                                       observedCount: 1,
                                       profileName: nil as String?)],
                                     for: recordingID)
                self.profiles.updateProfile(name: name, embedding: centroid, sampleCount: 1)
                embedLog.log("on-demand voice profile saved for \(rawID, privacy: .public)")
            }
        }
    }

    // MARK: - Carrying a pass's cleared names into the re-match

    /// Wire to `TranscriptionService.onPassClearedSpeakerNames`.
    ///
    /// **What is being repaired.** A pass that produced segments re-keys every
    /// `SPEAKER_NN`, so the service clears `speakerNames` wholesale. Each of
    /// those names had folded an observation into a voice profile
    /// (`onSpeakerNamed`), and clearing the label fires nothing — so that
    /// contribution sits in the profile with nothing left to un-name, and
    /// #237's correction can never reach it. `matchAfterPass` then re-embeds
    /// every speaker, matches them against the same profiles and names them
    /// again, folding a SECOND observation of the same recording into the
    /// same profile. This method is what lets the second step recognise the
    /// first one's leftovers as its own (island-io/mila#260).
    ///
    /// **It resolves the observations now, not later.** They are keyed to the
    /// ids the names were attached to, and `matchAfterPass` drops every one
    /// of them (`snapshots.invalidate`) before it does anything else. This
    /// call runs while they are all still there.
    ///
    /// **Several ids under one name are combined, not listed.** Naming two
    /// clusters "Alice" — which the auto-match itself can do, two ids over
    /// one profile — folded twice into one profile, and the weighted mean
    /// carrying the summed count is the single entry whose subtraction
    /// reverses both. That is the same equivalence `ObservedVoiceSnapshots`
    /// relies on for a merge. When two observations cannot be combined at all
    /// (different embedding dimensions, i.e. a model change mid-recording),
    /// the first is kept and the second dropped: under-correcting, the same
    /// choice `absorb` makes.
    ///
    /// **A name with no observation left is simply not carried.** The whole
    /// point of the carry is to keep the profile and the snapshot describing
    /// the same contribution; with nothing to re-point, suppressing the
    /// re-match's fold would break exactly that agreement. Those names fall
    /// through to `setSpeakerName` and behave as they did before this
    /// existed. It is the common case, not the corner: the snapshots do not
    /// survive a relaunch and the names do.
    ///
    /// Nothing is written here. The worst this call can do is leave a stale
    /// value in one slot, which the next `matchAfterPass` discards.
    func notePassClearedSpeakerNames(_ previousNames: [String: String], for recordingID: UUID) {
        clearedByPass = nil
        guard settings.isConfigured, !previousNames.isEmpty else { return }
        var observations: [String: ObservedVoiceSnapshots.Observation] = [:]
        // Sorted: `Dictionary` order is unspecified per process, and which
        // observation "goes first" decides which survives a dimension clash.
        for (rawID, name) in previousNames.sorted(by: { $0.key < $1.key }) {
            guard let observed = snapshots.observation(forSpeaker: rawID, in: recordingID) else { continue }
            guard let existing = observations[name] else {
                observations[name] = observed
                continue
            }
            if let combined = ObservedVoiceSnapshots.combined(existing, observed) {
                observations[name] = combined
            } else {
                embedLog.log("cleared-name carry: cannot combine two observations of one name — the second is dropped")
            }
        }
        let contributions = observations.mapValues {
            ClearedSpeakerNames.Contribution(centroid: $0.observedCentroid,
                                             count: $0.observedCount,
                                             profileName: $0.profileName)
        }
        clearedByPass = ClearedSpeakerNames(recordingID: recordingID,
                                            contributions: contributions)
    }

    /// Consume the slot. Unconditional: a value for a different recording is
    /// a pass whose match never ran, and applying it here would credit one
    /// recording's contribution to another's speakers.
    private func takeClearedNames(for recordingID: UUID) -> ClearedSpeakerNames? {
        let held = clearedByPass
        clearedByPass = nil
        guard let held, held.recordingID == recordingID else { return nil }
        return held
    }

    // MARK: - Auto-matching after a batch pass

    /// Wire to `TranscriptionService.onTranscriptionCompleted`.
    ///
    /// **The snapshot is invalidated first, unconditionally.** Every pass
    /// that reaches this hook produced segments, and such a pass re-keys
    /// every `SPEAKER_NN` from scratch — which is why the service clears
    /// `speakerNames` in the same breath. The *embeddings* were keyed to
    /// those same ids and nothing cleared them, so a re-transcribe left run
    /// 1's voices sitting under run 2's ids: name the new `SPEAKER_00` and
    /// the old `SPEAKER_00`'s embedding — possibly a different person — went
    /// into that profile. An earlier revision made this worse in three
    /// directions at once (retention 8 → 20, snapshots recorded for batch
    /// recordings that previously had none, and a guard that *skipped*
    /// matching whenever a snapshot already existed, so the stale one could
    /// never be replaced). Dropping it and re-extracting is the fix; the
    /// skip guard is gone.
    ///
    /// **The second fold, and how it is avoided.** Removing that guard also
    /// removed the thing that prevented a profile receiving two observations
    /// of one recording, and the pass's own `speakerNames` clear is what
    /// makes them two: the label that accounted for the first one is gone by
    /// the time this runs, so re-matching by voice and naming the speaker
    /// again folds a fresh observation in beside a stranded one that nothing
    /// can ever take back out (island-io/mila#260).
    ///
    /// So a name that was on the row before the pass — and whose observation
    /// is still held — is not treated as a new name at all.
    /// `notePassClearedSpeakerNames` hands those pairs over, resolved before
    /// the invalidation above, and when the re-match resolves a speaker to
    /// one of them this **re-attaches the label to the contribution the
    /// profile already holds**: the snapshot entry for the new id is
    /// re-pointed at that observation, and the name goes on through
    /// `RecordingStore.reattachSpeakerName`, which fires no
    /// `onSpeakerNamed`. Un-naming that speaker afterwards then subtracts
    /// exactly what naming it added, once — the invariant #253 and #237 are
    /// about. Each cleared name can be claimed by at most ONE new id; a
    /// second id matching the same profile is a genuinely new contribution
    /// and folds normally.
    ///
    /// **Suppressing the fold and re-pointing the snapshot are one act, never
    /// one without the other.** The pair is what makes the correction
    /// reversible; half of it is worse than neither. A cleared name whose
    /// observation is NOT held therefore takes the ordinary path and folds,
    /// which is what `main` does — the profile ends up carrying this
    /// recording twice and the older contribution is residue. That is the
    /// common case rather than a corner: `ObservedVoiceSnapshots` is
    /// in-memory only, so every re-transcribe after a relaunch arrives with
    /// the names (persisted, on the row) and none of the observations. See
    /// the note at the fold below for the arithmetic of getting this wrong.
    ///
    /// **Nothing here subtracts, and nothing here deletes.** The retire that
    /// `RecordingStore.update(_:retiringSpeakerNames:)` performs for the
    /// re-diarize path is deliberately not used on this one, in either
    /// direction: before the re-match it would take away the weight — and
    /// shift the centroid — that the lookup is about to resolve through, and
    /// delete outright any profile whose only content came from this
    /// recording; after it there is nothing left to subtract, since the
    /// snapshot has been invalidated and refilled. A cleared name the
    /// re-match does NOT bring back therefore keeps its contribution as
    /// residue, exactly as on `main`. That is the under-correcting side, on
    /// purpose: residue is recoverable (delete the profile and let it
    /// re-learn), a profile deleted because a voice match came up short is
    /// not, and this is a batch write the user is not watching.
    ///
    /// **The `speakerNames.isEmpty` guard still means what it says**: only a
    /// recording the pass left unlabelled is auto-named. The carry does not
    /// change that — it travels beside the row rather than on it, precisely
    /// so the pass can go on clearing names it has re-keyed. A future change
    /// that preserves names ON the row has to revisit both together.
    func matchAfterPass(recordingID: UUID) {
        // Taken first: the contributions it names resolve through
        // observations that are still keyed to the pre-pass ids, and the very
        // next line drops all of them.
        let cleared = takeClearedNames(for: recordingID)
        snapshots.invalidate(recordingID)
        guard settings.isConfigured, !profiles.profiles.isEmpty, let store else { return }
        guard let rec = store.recordings.first(where: { $0.id == recordingID }),
              !rec.isTrashed,
              rec.speakerNames.isEmpty else { return }
        let spans = Self.longestSpans(in: rec)
        guard !spans.isEmpty else { return }
        spawn { [self] in
            let embeddings = await extract(spans: spans, for: recordingID)
            guard !embeddings.isEmpty else { return }
            await MainActor.run {
                guard self.settings.isConfigured else { return }
                guard let store = self.store,
                      let live = store.recordings.first(where: { $0.id == recordingID }),
                      !live.isTrashed else { return }
                // Snapshot everything that embedded, including speakers the
                // user named while this ran: the observation is what lets a
                // later un-name correct the profile.
                let observed = embeddings.map { (id: $0.key,
                                                 observedCentroid: $0.value,
                                                 observedCount: 1,
                                                 profileName: nil as String?) }
                self.snapshots.merge(observed, for: recordingID)
                let threshold = self.matchThreshold()
                // The contributions this recording made under names the pass
                // cleared, still available to be re-pointed. Claimed at most
                // once each — the second speaker to match one of these
                // profiles is a new contribution, not the old one coming
                // back — and a name that is not in here takes the ordinary
                // path below.
                var carryable = cleared?.contributions ?? [:]
                // Sorted: `Dictionary` order is unspecified per process, and
                // this drives `.srt` rewrites, log lines, and which id claims
                // a cleared name when two of them match it.
                for rawID in embeddings.keys.sorted() {
                    // A label the user typed while the embed was in flight
                    // wins over a recogniser's guess. Overwriting it would
                    // also fire `onSpeakerNamed` a second time and fold this
                    // recording's centroid into two profiles — the exact
                    // guard `RecognisedSpeakerAssigner.finish` documents.
                    guard live.speakerNames[rawID] == nil else { continue }
                    guard let centroid = embeddings[rawID],
                          let profile = self.profiles.match(embedding: centroid,
                                                            threshold: threshold) else { continue }
                    // **The suppression and the re-point are one act.**
                    // Naming without folding is only correct while the
                    // snapshot is simultaneously pointed at the observation
                    // the profile DID receive: that pair is what a later
                    // un-name reverses. With no contribution to point it at
                    // — the state after every relaunch, since the snapshots
                    // are in-memory and the names are not — suppressing the
                    // fold would leave the snapshot claiming this pass's
                    // fresh observation while the profile holds the old one,
                    // and un-naming would subtract a vector that was never
                    // added: a centroid drifted by
                    // `n·(c_old − c_fresh)/(S − n)`, which is the invisible
                    // corruption this whole feature exists to prevent, and
                    // strictly worse than the duplicate fold it was trying to
                    // avoid. So without the evidence to do better, this
                    // degrades to what `main` does: fold, stay reconcilable,
                    // leave the older contribution as residue.
                    guard let contribution = carryable.removeValue(forKey: profile.name) else {
                        store.setSpeakerName(profile.name, forSpeaker: rawID,
                                             recordingID: recordingID)
                        continue
                    }
                    // A name from before the pass, back on a new id, with the
                    // contribution it accounted for still in hand. The
                    // snapshot is re-pointed at THAT observation — what the
                    // profile actually received, and so what a later un-name
                    // has to subtract — and the label is written without
                    // firing the fold.
                    self.snapshots.merge([(id: rawID,
                                           observedCentroid: contribution.centroid,
                                           observedCount: contribution.count,
                                           profileName: contribution.profileName)],
                                         for: recordingID)
                    store.reattachSpeakerName(profile.name, toSpeaker: rawID,
                                              recordingID: recordingID)
                    embedLog.log("a name cleared by the pass came back on \(rawID, privacy: .public) — re-attached to the contribution already in the profile")
                }
                if !carryable.isEmpty {
                    // Their contributions stay where they are. Subtracting
                    // them here would delete a profile this recording is the
                    // only evidence for, on the strength of a voice match
                    // that came up short — see the note on this method.
                    embedLog.log("\(carryable.count, privacy: .public) carried contribution(s) went unclaimed — the pass did not bring those names back, and they are left in place")
                }
            }
        }
    }

    // MARK: - Extraction

    /// Resolve the recording's audio and embed. Returns `[:]` on any
    /// failure, having logged why.
    ///
    /// **The URL is resolved late, and once more on a retry.** Compression
    /// starts the moment the completion hook returns
    /// (`store.compressRecordingAudio`), transcodes to `.m4a`, swaps
    /// `audioFileName` and deletes the `.wav` — so a URL captured before the
    /// `await` names a file that is about to vanish. Capturing it *earlier*
    /// (which is what an earlier revision did, with a comment saying it
    /// prevented the race) only guarantees looking at the doomed path.
    /// Resolving inside the task usually wins the race outright, and the
    /// second attempt picks up the new `.m4a` when it doesn't —
    /// `embedSpeakers` decodes non-WAV input itself.
    private func extract(spans: [SpeakerAudioSpan], for recordingID: UUID) async -> [String: [Float]] {
        for attempt in 0..<2 {
            guard let url = currentAudioURL(recordingID) else { return [:] }
            guard FileManager.default.fileExists(atPath: url.path) else {
                if attempt == 0 { continue }
                embedLog.log("embedding skipped: the recording's audio is gone")
                return [:]
            }
            do {
                return try await embed(url, spans)
            } catch {
                embedLog.log("embedding failed: \(SpeakerDiarizer.Error.logMessage(for: error), privacy: .public)")
                if attempt == 0 { continue }
                return [:]
            }
        }
        return [:]
    }

    private func currentAudioURL(_ recordingID: UUID) -> URL? {
        guard let store else { return nil }
        return store.recordings.first(where: { $0.id == recordingID }).map { store.audioURL(for: $0) }
    }

    // MARK: - Segment selection

    /// The longest segment carrying `rawID`. One span per speaker is what
    /// the embedding model needs, and the longest is the least likely to be
    /// mostly silence.
    static func longestSpan(for rawID: String, in recording: Recording) -> SpeakerAudioSpan? {
        var best: SpeakerAudioSpan?
        for seg in recording.segments where seg.speaker == rawID {
            if best == nil || (seg.end - seg.start) > (best!.end - best!.start) {
                best = SpeakerAudioSpan(rawID: rawID, start: seg.start, end: seg.end)
            }
        }
        return best
    }

    /// The longest segment for every labelled speaker, in raw-id order.
    static func longestSpans(in recording: Recording) -> [SpeakerAudioSpan] {
        var best: [String: SpeakerAudioSpan] = [:]
        for seg in recording.segments {
            guard let rawID = seg.speaker else { continue }
            if let existing = best[rawID], (existing.end - existing.start) >= (seg.end - seg.start) {
                continue
            }
            best[rawID] = SpeakerAudioSpan(rawID: rawID, start: seg.start, end: seg.end)
        }
        return best.keys.sorted().compactMap { best[$0] }
    }

    // MARK: - Test seam

    private func spawn(_ body: @escaping @Sendable () async -> Void) {
        let token = UUID()
        pending[token] = Task.detached(priority: .utility) { [weak self] in
            await body()
            await MainActor.run { self?.pending[token] = nil }
        }
    }

    /// Await every in-flight extraction. Test seam only — nothing in the app
    /// waits on these, by design: they are background corrections, and the
    /// UI stays responsive while Python runs.
    func awaitPending() async {
        while let task = pending.values.first {
            _ = await task.value
        }
    }
}
