import Foundation
import os

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
    func matchAfterPass(recordingID: UUID) {
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
                // Sorted: `Dictionary` order is unspecified per process, and
                // this drives `.srt` rewrites and log lines.
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
                    store.setSpeakerName(profile.name, forSpeaker: rawID,
                                         recordingID: recordingID)
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
