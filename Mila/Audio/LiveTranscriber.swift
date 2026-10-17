import Foundation
import Combine
import OSLog
import TranscriptionCore
import MilaKit

private let liveLog = Logger(subsystem: "io.island.whisper.IslandWhisper", category: "LiveTranscriber")

/// Per-tick output of the live transcriber. Kept around for back-compat
/// with `LiveSpeakerDiarizer` (which still publishes intervals that view
/// code may want to consume) and the unit tests. The view layer reads
/// `fullText`, not segments.
struct LiveSegment: Identifiable, Hashable {
    let id: UUID
    var startSeconds: Double
    var endSeconds: Double
    var text: String
    var speaker: String?
    var stable: Bool
}

/// Streams whisper output during a recording and ACCUMULATES timed
/// segments across ticks. Every `chunkSeconds`, we transcribe the
/// trailing `windowSeconds` of audio. Whisper returns multiple
/// timestamped segments per window; we merge them into a growing
/// `segments` list using time-based dedup against what we already
/// have. This preserves per-utterance timing for the live UI (one
/// line per segment) and for downstream consumers (e.g. matching
/// speakers to segments by time once live diarization comes back).
///
/// Merge rules per incoming segment (windowAbsoluteStart added so its
/// `start` / `end` are absolute recording-time seconds):
///   * If it overlaps the LAST existing segment by start time AND its
///     end extends further, REPLACE the last segment (whisper got more
///     audio and decided the same utterance is longer).
///   * Else if its start is strictly past the last segment's end, APPEND.
///   * Else (start is well before last.end, not a longer rewrite),
///     SKIP — same content we already have from a previous tick.
@MainActor
final class LiveTranscriber: ObservableObject {
    /// Accumulated, growing transcript. Drives the live transcript pane.
    @Published private(set) var fullText: String = ""
    /// Set true while a whisper call is in flight — drives the
    /// "thinking" indicator in the UI. Backed by an internal counter
    /// (`activeTranscribeCount`) so concurrent transcribes don't
    /// trample each other: a stale call returning while a fresh one
    /// is in flight no longer flips the indicator off prematurely.
    @Published private(set) var isTranscribing: Bool = false
    @Published private(set) var lastError: String?

    /// True while the remote transcription server cannot be reached
    /// mid-recording (the network dropped, the connection was lost, the
    /// upload timed out). Drives the NON-blocking "connection lost —
    /// still recording" banner in the live pane, and clears itself the
    /// moment an upload gets through again (#355). Recording is never
    /// affected: capture writes the WAV whatever the network does, and the
    /// utterances that failed are kept and retried (see
    /// `transcribeUtterance`).
    ///
    /// Published only on a TRANSITION (`noteConnectionInterrupted` /
    /// `noteConnectionRestored` compare first), so an outage costs two
    /// publishes, not one per failed upload — `LiveTranscriber` is an
    /// App-level `@StateObject`, and see CLAUDE.md on what a high-frequency
    /// publish there costs. Always `false` for the on-device backend.
    @Published private(set) var isConnectionInterrupted: Bool = false

    /// Whether some of THIS recording's audio never made it into the live
    /// transcript because the server stayed unreachable through the
    /// end-of-recording drain (VAD path), or a fixed-window tick was lost to
    /// it (chunk path). Read at Stop by `QuickActionsController.stopRecording`,
    /// which then hands the recording to the batch pass instead of saving a
    /// live transcript with a hole in it. Reset by `reset()` / `start()`;
    /// deliberately NOT by `stop()`, which runs after Stop has read it — the
    /// same lifecycle as `segments`.
    private(set) var hasUntranscribedAudio: Bool = false

    /// Backoff for re-sending an utterance whose upload could not reach the
    /// server: `connectionRetryBaseDelay` doubling per attempt, capped at
    /// `connectionRetryMaxDelay`. Small enough that the transcript catches up
    /// within seconds of the connection coming back. Settable for tests.
    var connectionRetryBaseDelay: TimeInterval = 2
    var connectionRetryMaxDelay: TimeInterval = 10

    /// Set by `transcribeNow()` for the end-of-recording drain. While it is
    /// set, an utterance that cannot reach the server gives up after one
    /// attempt (and marks `hasUntranscribedAudio`) instead of waiting for the
    /// connection — otherwise Stop would hang for as long as the outage lasts.
    private var isDraining = false

    /// Number of currently-running transcribe invocations. Always
    /// mutated alongside `isTranscribing = (count > 0)` via
    /// `beginTranscribe()` / `endTranscribe()` so the published
    /// indicator reflects whether *any* transcribe is still in
    /// flight, not just whichever one returned last.
    private var activeTranscribeCount: Int = 0

    /// Authoritative per-utterance list with whisper's absolute
    /// recording-time start/end. The live view renders one line per
    /// entry; `fullText` is a derived join of `segments.map(\.text)`
    /// kept in sync for back-compat with callers that still want one
    /// flat string (e.g. the LLM feed via `formattedTranscript`).
    @Published private(set) var segments: [LiveSegment] = []

    /// User-assigned display names for live speakers (raw `SPEAKER_NN`
    /// → name), set from the live pane's rename popover mid-recording.
    /// Copied into the saved `Recording` at stop (QuickActionsController),
    /// where the post-stop re-diarize remaps them onto the re-keyed IDs.
    @Published var speakerNames: [String: String] = [:]

    var chunkSeconds: Double = 30.0
    var windowSeconds: Double = 30.0
    /// When true, route incoming audio through `UtteranceDetector` and
    /// transcribe once per detected utterance instead of on the fixed
    /// `chunkSeconds` timer. Set by `MilaApp.wireLiveAIPipeline` from
    /// `LiveAISettings.useVAD` before `start()`.
    var useVAD: Bool = false
    /// Fires alongside each VAD utterance transcribe with the same
    /// samples and absolute time range. Wired in `MilaApp` to feed
    /// `LiveSpeakerDiarizer.process(samples:startSeconds:endSeconds:)`
    /// — the diarizer needs utterance-shaped chunks to embed against
    /// its speaker pool. Each chunk should contain one speaker;
    /// VAD-bounded utterances satisfy that by construction.
    var onUtteranceCaptured: (([Float], Double, Double) -> Void)?
    /// Optional neural (Silero) speech gate. When set, each VAD-emitted
    /// utterance is re-checked for actual human speech before whisper
    /// runs; utterances with none (room noise, music, AC hum that
    /// cleared the RMS cutoff) are dropped so whisper never hallucinates
    /// filler on them. Wired in `MilaApp.wireLiveAIPipeline` from
    /// `LiveAISettings.useNeuralVAD`; nil disables the gate. Only the
    /// VAD path (`useVAD`) consults it — the fixed-timer path has no
    /// per-utterance boundary to gate.
    var speechGate: SileroVAD?
    private let sampleRate: Double = 16_000

    private let transcription: TranscriptionService
    private var detector: UtteranceDetector?
    /// VAD path serialises transcribes via task chaining: each new
    /// utterance creates a Task that awaits the previous one before
    /// running whisper. We never null this — Swift's runtime drops the
    /// chain naturally once each Task body completes.
    private var lastUtteranceTask: Task<Void, Never>?
    /// Rolling window of recent samples — we keep only the last
    /// `windowSeconds` worth (plus a small headroom; see `trimBuffer`)
    /// because anything older was already transcribed and merged. For
    /// a 1-hour meeting at 16 kHz f32 the full unbounded buffer would
    /// be ~230 MB; with trimming it caps at ~2 MB regardless of
    /// recording length. Caught by Cursor Bugbot in PR #20.
    private var buffer: [Float] = []
    /// Sample-index of `buffer[0]` in absolute recording time. When
    /// the trim drops the head of `buffer`, we bump this by the same
    /// amount so `windowAbsoluteStart` in `runOnce` keeps producing
    /// correct absolute timestamps for the segment merge.
    private var samplesDropped: Int = 0
    /// Absolute time ranges of segments the user deleted from the live
    /// pane. Incoming whisper output overlapping any of these is dropped so
    /// a just-deleted line can't reappear on a later tick — the fixed-window
    /// path re-transcribes a rolling buffer and would otherwise re-emit the
    /// deleted content. The VAD path emits each utterance once, so this is
    /// mostly a safety net there. Cleared on `start()` AND on `stop()` — it is
    /// per-recording state, and `start()` is not the only way a new recording
    /// begins (see `stop()`).
    private var deletedRanges: [(start: Double, end: Double)] = []
    private var inFlight: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var language: String = "he"
    /// Incremented on every `stop()` — and so on every `reset()` and
    /// `start()`, which begin with one. A `transcribeUtterance` call
    /// captures this at entry and re-checks before mutating state —
    /// drops the result if the user started a new recording mid-flight.
    /// Without this, a late-arriving whisper result from recording N
    /// appends to recording N+1's segments (user reported seeing the
    /// previous conversation's text in a fresh recording). `runOnce()`,
    /// the fixed-window tick, does the same: whisper does not observe
    /// Task cancellation, so the `inFlight` cancel in `stop()` cannot
    /// stop a tick that is already inside the engine, and its result
    /// comes back after the teardown — into whichever recording owns
    /// `segments` by then.
    private var epoch: Int = 0

    init(transcription: TranscriptionService) {
        self.transcription = transcription
    }

    /// Inject canned segments without touching whisper. Used by the
    /// UI test for Hebrew RTL alignment (see `--ui-test-rtl-live-hebrew`
    /// path in `MilaApp.init`). Production paths must not call this.
    func seedForTesting(_ initial: [LiveSegment]) {
        self.segments = initial
        self.fullText = initial.map(\.text).joined(separator: " ")
    }

    /// Stop, and drop everything the previous recording left behind — its
    /// transcript, speaker names, buffered audio and deletions — without
    /// arming anything new. `start()` begins with this; a recording that does
    /// NOT run the live pipeline needs it on its own, because `stop()` keeps
    /// `segments` (stopRecording snapshots them first) and stopRecording would
    /// otherwise save the previous meeting's live transcript as this one's —
    /// marked final, so its batch pass would never run. `epoch` is bumped
    /// too (by `stop()`), so a whisper result still in flight from that
    /// meeting is dropped rather than merged here.
    func reset() {
        stop()
        self.buffer.removeAll(keepingCapacity: true)
        self.samplesDropped = 0
        self.deletedRanges = []
        self.deletionCount = 0
        self.fullText = ""
        self.segments = []
        self.speakerNames = [:]
        self.lastError = nil
        self.hasUntranscribedAudio = false
    }

    func start(language: String) {
        reset()
        self.language = language
        liveLog.log("LiveTranscriber.start lang=\(language, privacy: .public) chunk=\(self.chunkSeconds, privacy: .public)s window=\(self.windowSeconds, privacy: .public)s useVAD=\(self.useVAD, privacy: .public) epoch=\(self.epoch, privacy: .public)")

        if useVAD {
            let det = UtteranceDetector()
            det.onUtterance = { [weak self] samples, startSec in
                self?.scheduleUtteranceTranscribe(samples: samples, startSec: startSec)
            }
            self.detector = det
            return
        }

        tickTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.chunkSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.kickIfIdle()
            }
        }
    }

    @discardableResult
    func stop() -> String {
        tickTask?.cancel()
        tickTask = nil
        inFlight?.cancel()
        inFlight = nil
        detector = nil
        lastUtteranceTask?.cancel()
        lastUtteranceTask = nil
        // Every `stop()` is a teardown, so nothing that was in flight when it
        // ran may be merged afterwards: a whisper pass already inside the
        // engine ignores the cancellations above and returns later — after
        // `stopRecording` has snapshotted this recording, or after the next
        // recording's `reset()`. Bumping here, rather than only in
        // `reset()`/`start()`, is what makes the epoch guards in `runOnce()`
        // and `transcribeUtterance` drop that result in both cases.
        epoch &+= 1
        // The deletions belong to the recording that just ended. `start()` is
        // NOT the only way the next one begins — a recording that skips the
        // live pipeline gets `reset()` instead, which clears them as well — so
        // this is the teardown-side half of the same guarantee, covering every
        // path that ends with `stop()` (end of recording, failed stop,
        // dictation). Leaving them behind would let a previous recording's
        // emptying make the NEW recording's genuinely-empty transcript look
        // authoritative, so its batch pass would never be enqueued and it
        // would save with no transcript at all — a silent total loss, and a
        // worse failure than the one the flag prevents. (Cursor Bugbot on #229.)
        //
        // Suppression is unaffected: every `stop()` call site is a teardown
        // (end of recording, failed stop, gated re-arm, dictation), and
        // `stopRecording` snapshots `hasUserDeletedSegments` before its own
        // `stop()` — the same ordering it already relies on for `segments`.
        deletedRanges = []
        // The recording is over, so is any "connection lost" warning about
        // it. `hasUntranscribedAudio` is left for `reset()` — Stop has
        // already read it by the time it calls this.
        isDraining = false
        noteConnectionRestored()
        return fullText
    }

    /// Flip the connection banner on. Compares first, so it publishes once
    /// per outage — see `isConnectionInterrupted`.
    private func noteConnectionInterrupted() {
        guard !isConnectionInterrupted else { return }
        liveLog.log("LiveTranscriber: remote server unreachable — recording continues, live transcription will retry")
        isConnectionInterrupted = true
    }

    /// Flip the connection banner off. Called on every answer from the
    /// backend, so it compares first — see `isConnectionInterrupted`.
    private func noteConnectionRestored() {
        guard isConnectionInterrupted else { return }
        liveLog.log("LiveTranscriber: remote server reachable again")
        isConnectionInterrupted = false
    }

    /// Sleep out a retry backoff, but wake early when the end-of-recording
    /// drain starts (so Stop waits for one more attempt, not for the rest of
    /// a 10 s backoff) or when the recording is torn down. Sliced into short
    /// sleeps because the drain cannot cancel this task: it is usually not
    /// `lastUtteranceTask` but an earlier link of the chain.
    private func waitBeforeRetry(_ delay: TimeInterval, scheduledEpoch: Int) async {
        let deadline = Date().addingTimeInterval(delay)
        while !isDraining, scheduledEpoch == epoch, !Task.isCancelled {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(Swift.min(remaining, 0.25) * 1_000_000_000))
        }
    }

    /// Seconds to wait before the `attempt`-th re-send (1-based) of an
    /// utterance that could not reach the server.
    nonisolated static func connectionRetryDelay(attempt: Int, base: TimeInterval, max maxDelay: TimeInterval) -> TimeInterval {
        let exponent = Double(Swift.max(0, attempt - 1))
        return Swift.min(base * pow(2, exponent), maxDelay)
    }

    /// Bump the in-flight counter and publish `isTranscribing = true`.
    /// Pair with `endTranscribe()` (typically via `defer`) so the count
    /// stays balanced even on early returns. Reads as `true` whenever
    /// at least one transcribe is running, which is what the UI's
    /// "thinking" indicator actually wants.
    ///
    /// Exposed as `internal` (not `private`) so the unit tests can
    /// drive overlapping-transcribe scenarios deterministically — the
    /// natural in-flight overlap is hard to reproduce against the
    /// stub engine because cancellation collapses the simulated
    /// delay before the test can interleave a second call.
    func beginTranscribe() {
        activeTranscribeCount += 1
        if !isTranscribing { isTranscribing = true }
    }

    /// Decrement the in-flight counter and publish
    /// `isTranscribing = false` only when the count hits zero. Without
    /// this, a stale transcribe finishing while a fresh one is still
    /// running would flip the indicator off and the UI would falsely
    /// show "idle" mid-recording.
    func endTranscribe() {
        activeTranscribeCount = max(0, activeTranscribeCount - 1)
        if activeTranscribeCount == 0, isTranscribing {
            isTranscribing = false
        }
    }

    func ingest(_ samples: ArraySlice<Float>) {
        if let detector {
            detector.ingest(samples)
        } else {
            buffer.append(contentsOf: samples)
        }
    }

    /// Called when the recording is paused. In VAD mode, close the current
    /// utterance at the pause point — otherwise resume would append post-pause
    /// audio onto the same utterance, gluing the two sides of the gap into a
    /// single segment with a bogus duration. Uses `flushForPause()` (not
    /// `flush()`) so the detector's recording clock is preserved: post-resume
    /// utterances keep their absolute timestamps instead of restarting at 0.
    /// The fixed-window path keeps a plain rolling buffer with no in-flight
    /// utterance to close, so this is a no-op there (paused audio simply
    /// never arrives via `ingest`).
    func pauseBoundary() {
        detector?.flushForPause()
    }

    /// Delete a line from the live transcript. Records the segment's time
    /// range so a later whisper tick (fixed-window mode re-transcribes a
    /// rolling buffer) can't re-emit it, removes it from `segments`, and
    /// recomputes `fullText`. Because `segments` is `@Published`, the app's
    /// feed loop picks the change up automatically (MCP sidecar + LLM
    /// re-feed), and the Stop-time snapshot excludes the deleted line.
    func removeSegment(id: UUID) {
        guard let idx = segments.firstIndex(where: { $0.id == id }) else { return }
        let seg = segments[idx]
        deletedRanges.append((start: seg.startSeconds, end: seg.endSeconds))
        // Bumped BEFORE `segments` is published: the Live AI feed loop wakes on
        // `$segments`, and it must already see the new count on the tick that
        // carries the shortened transcript. The other order would feed the
        // post-deletion text to a session still resuming the history that
        // contains it (issue #239).
        deletionCount += 1
        segments.remove(at: idx)
        fullText = segments.map(\.text).joined(separator: " ")
        liveLog.log("LiveTranscriber.removeSegment start=\(seg.startSeconds, privacy: .public) end=\(seg.endSeconds, privacy: .public) remaining=\(self.segments.count, privacy: .public)")
    }

    /// How many lines the user has deleted from THIS recording's live
    /// transcript (reset by `start()` along with `deletedRanges`).
    ///
    /// Published, and a monotonically increasing count rather than a Bool,
    /// because the Live AI feed loop needs to spot *each* deletion — not just
    /// "has there ever been one" — to tell `LiveAISession` that text it has
    /// already shipped to the model is gone. See issue #239: the LLM runs in
    /// session mode, so a `--resume` tick carries every earlier turn and the
    /// deleted line survives in the model's history unless the session is
    /// restarted. A count also coalesces naturally: several deletions between
    /// two ticks are one restart, because the loop compares counts rather than
    /// reacting to events.
    @Published private(set) var deletionCount: Int = 0

    /// Whether the user deleted at least one line from THIS recording's live
    /// transcript (reset by `start()` along with `deletedRanges`).
    ///
    /// Read at Stop, where it is the only thing that tells an *emptied* live
    /// transcript apart from one that was never produced. Those two look
    /// identical in `segments` and must be handled oppositely — see
    /// `liveTranscriptIsAuthoritative` in `QuickActionsController.stopRecording`.
    var hasUserDeletedSegments: Bool { !deletedRanges.isEmpty }

    /// Whether an incoming segment's absolute time range overlaps a range
    /// the user deleted. Any positive overlap counts — the intent of a
    /// delete is "drop what was said in that span," so re-emitted content
    /// there should stay gone.
    private func isSuppressed(start: Double, end: Double) -> Bool {
        for r in deletedRanges where start < r.end && end > r.start {
            return true
        }
        return false
    }

    func transcribeNow() async {
        // End of recording: an utterance that can't reach the server gets
        // one more attempt, not an open-ended wait. See `isDraining`.
        isDraining = true
        defer { isDraining = false }
        if let detector {
            // End-of-recording flush: force-emit any in-progress
            // utterance (which schedules onto lastUtteranceTask), then
            // await it so the saved transcript includes the tail.
            detector.flush()
            await lastUtteranceTask?.value
            return
        }
        await runOnce()
    }

    /// Idempotent end-of-recording flush. The cumulative model doesn't
    /// have "tentative" segments to promote, but the dictation flow
    /// still calls this — keep as a no-op.
    func finalizeAllSegments() {}

    /// Attach speaker labels to live segments by matching each
    /// segment's `[startSeconds, endSeconds]` against the diarizer's
    /// running intervals. The interval with the largest temporal
    /// overlap wins.
    ///
    /// Already-labelled segments are skipped — once we've committed a
    /// speaker to a segment we keep it stable in the UI rather than
    /// re-flipping it as more intervals arrive. The diarizer-output
    /// model produces stable speaker IDs once a voice profile is seen
    /// twice, so the early match for a segment is almost always
    /// correct; the cost of keeping it stable is a marginal accuracy
    /// gain we'd otherwise get by re-evaluating.
    ///
    /// Cost: O(unlabelled_segments × intervals). At a 2 min recording
    /// with one utterance per 500 ms and one diarizer interval per
    /// 500 ms, that's 240 × 240 = 57 600 cheap arithmetic ops per
    /// call — well under 1 ms on Apple Silicon. The caching keeps
    /// the typical-tick cost proportional to the NEW utterances
    /// since the last tick (usually 1-2 segments) × all intervals.
    func applySpeakerLabels(_ intervals: [(start: Double, end: Double, speaker: String)]) {
        guard !intervals.isEmpty, !segments.isEmpty else { return }
        var copy = segments
        var changed = false
        for i in 0..<copy.count {
            if copy[i].speaker != nil { continue }
            let segStart = copy[i].startSeconds
            let segEnd = copy[i].endSeconds
            var bestOverlap: Double = 0
            var bestSpeaker: String? = nil
            for iv in intervals {
                let overlap = min(segEnd, iv.end) - max(segStart, iv.start)
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestSpeaker = iv.speaker
                }
            }
            if let bestSpeaker {
                copy[i].speaker = bestSpeaker
                changed = true
            }
        }
        if changed {
            segments = copy
        }
    }

    /// Used by `LiveAISession` as the LLM-feed format. Newline-separated
    /// so the LLM can see utterance boundaries, with `[mm:ss]` prefix
    /// per line for time anchoring.
    var formattedTranscript: String {
        segments.map { seg in
            let mm = Int(seg.startSeconds) / 60
            let ss = Int(seg.startSeconds) % 60
            return String(format: "[%02d:%02d] %@", mm, ss, seg.text)
        }.joined(separator: "\n")
    }

    /// The live segments as `TranscriptSegment`s — the shape the
    /// formatter/exporter share with finished recordings, so copy and
    /// SRT export mid-recording produce the same output the detail view
    /// would for the same content.
    var transcriptSegments: [TranscriptSegment] {
        segments.map {
            TranscriptSegment(start: $0.startSeconds, end: $0.endSeconds,
                              text: $0.text, speaker: $0.speaker)
        }
    }

    /// Clipboard rendering of the in-progress transcript — same format
    /// as the detail view's "Copy transcript" (speaker-prefixed turns
    /// once live diarization has labelled anyone, plain joined text
    /// otherwise), so copying mid-recording and copying after the fact
    /// produce the same text.
    var clipboardText: String {
        TranscriptFormatter.plainText(segments: transcriptSegments,
                                      fallback: fullText,
                                      names: speakerNames)
    }

    /// VAD path: enqueue a transcribe for a complete utterance. New
    /// utterances chain on top of the previous task so whisper runs
    /// strictly serially (the engine actor enforces this anyway, but
    /// the chain also keeps the publish order stable).
    ///
    /// `epoch` is captured RIGHT HERE at schedule time — i.e. at the
    /// moment the VAD emitted the utterance, while we still know the
    /// audio belongs to the current recording. If we waited until
    /// `transcribeUtterance` actually started running (potentially
    /// after a fresh recording incremented the epoch), we'd compare
    /// the stale audio against the new recording's epoch and the
    /// guard would falsely pass.
    private func scheduleUtteranceTranscribe(samples: [Float], startSec: Double) {
        let scheduledEpoch = epoch
        let prev = lastUtteranceTask
        lastUtteranceTask = Task { @MainActor [weak self] in
            await prev?.value
            await self?.transcribeUtterance(samples: samples,
                                            startSec: startSec,
                                            scheduledEpoch: scheduledEpoch)
        }
    }

    private func transcribeUtterance(samples: [Float], startSec: Double, scheduledEpoch: Int) async {
        // Stale-result drop, applied BEFORE the diarizer feed so we
        // don't pollute the new recording's speaker intervals with
        // embeddings derived from the previous recording's audio. The
        // old placement of this guard (after whisper returned) only
        // protected the segment append; the diarizer's queue still
        // got fed for stale audio, leaking speakers across recordings.
        guard scheduledEpoch == epoch else {
            liveLog.log("LiveTranscriber utterance dropped at entry — epoch changed (scheduled=\(scheduledEpoch, privacy: .public) current=\(self.epoch, privacy: .public))")
            return
        }
        // Neural-VAD gate: drop utterances the RMS detector emitted that
        // contain no actual human speech (noise that merely cleared the
        // energy cutoff). Runs BEFORE the diarizer feed and whisper so a
        // noise burst never produces a hallucinated segment nor pollutes
        // the speaker pool. Fail-open by construction (`containsSpeech`
        // returns true on any VAD error), so a broken gate degrades to
        // today's behaviour rather than silencing the transcript. Cheap
        // relative to whisper — and when it drops, it skips whisper
        // entirely, a net CPU win.
        if let speechGate {
            let hasSpeech = await speechGate.containsSpeech(samples)
            // Re-check epoch: the async VAD call could straddle a new
            // recording, same as the whisper call below.
            guard scheduledEpoch == epoch else { return }
            if !hasSpeech {
                liveLog.log("LiveTranscriber utterance dropped by neural VAD — no speech (samples=\(samples.count) startSec=\(startSec, privacy: .public))")
                return
            }
        }
        beginTranscribe()
        defer { endTranscribe() }
        // Hand the same utterance to the speaker diarizer in parallel
        // with whisper. The diarizer maintains its own pool of speaker
        // centroids; the matching back to segments happens via
        // `applySpeakerLabels` on the next $segments tick.
        let utteranceEnd = startSec + Double(samples.count) / sampleRate
        onUtteranceCaptured?(samples, startSec, utteranceEnd)
        // Pad short utterances to a minimum length with trailing silence.
        // Whisper.cpp's beam-search decoding (with our suppress_blank +
        // patience=-1 params) goes into an infinite loop on inputs much
        // shorter than the model's 30s receptive field — the model wants
        // to emit blank tokens but can't, with no patience cap. Padding
        // to 5s gives the decoder enough room to converge.
        let minSamples = Int(sampleRate * 5)
        let padded: [Float]
        if samples.count < minSamples {
            var p = samples
            p.append(contentsOf: Array(repeating: 0, count: minSamples - samples.count))
            padded = p
        } else {
            padded = samples
        }
        let startedAt = Date()
        // A remote upload that cannot reach the server is RETRIED, not
        // dropped (#355): this utterance's audio is kept and re-sent with
        // backoff until the connection is back. Utterances spoken meanwhile
        // queue up behind it on the `lastUtteranceTask` chain, so once it
        // goes through they drain in order and the live transcript fills
        // the gap by itself — no reordering, no insertion. The live
        // diarizer was already fed above, exactly once.
        var whisperSegs: [TranscriptSegment] = []
        var failedAttempts = 0
        attempts: while true {
            // VAD-bounded short utterances: use the WhisperEngine.computeAudioCtx
            // formula (`audioCtx: nil`). This is the path the labelled-fixture
            // sweep validated — see WhisperEngine.swift's `params.audio_ctx` block.
            let outcome = await transcription.transcribeLiveSegments(
                samples: padded, language: language, audioCtx: nil
            )
            // Second epoch check post-whisper: the entry check covered the
            // diarizer feed, but the user could still have started a new
            // recording between then and now (whisper takes seconds), in
            // which case we must drop the segment to avoid bleeding the
            // previous conversation into the fresh transcript. It also
            // keeps a stale failure from raising the NEXT recording's
            // connection banner.
            guard scheduledEpoch == self.epoch else {
                liveLog.log("LiveTranscriber utterance dropped post-whisper — epoch changed (scheduled=\(scheduledEpoch, privacy: .public) current=\(self.epoch, privacy: .public))")
                return
            }
            switch outcome {
            case .transcribed(let segs):
                noteConnectionRestored()
                whisperSegs = segs
                break attempts
            case .skipped:
                break attempts
            case .connectionUnavailable:
                noteConnectionInterrupted()
                failedAttempts += 1
                // End of recording (or a torn-down chain): stop waiting.
                // Stop sees `hasUntranscribedAudio` and sends the WAV to
                // the batch pass, which covers this utterance.
                if isDraining || Task.isCancelled {
                    hasUntranscribedAudio = true
                    liveLog.log("LiveTranscriber utterance left untranscribed — server unreachable at end of recording (startSec=\(startSec, privacy: .public) attempts=\(failedAttempts, privacy: .public))")
                    return
                }
                let delay = Self.connectionRetryDelay(attempt: failedAttempts,
                                                      base: connectionRetryBaseDelay,
                                                      max: connectionRetryMaxDelay)
                liveLog.log("LiveTranscriber utterance: server unreachable, retrying in \(delay, privacy: .public)s (startSec=\(startSec, privacy: .public) attempt=\(failedAttempts, privacy: .public))")
                await waitBeforeRetry(delay, scheduledEpoch: scheduledEpoch)
                guard scheduledEpoch == self.epoch else {
                    liveLog.log("LiveTranscriber utterance retry abandoned — epoch changed (scheduled=\(scheduledEpoch, privacy: .public) current=\(self.epoch, privacy: .public))")
                    return
                }
            }
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        liveLog.log("LiveTranscriber utterance: samples=\(samples.count) padded=\(padded.count) elapsed=\(elapsed, privacy: .public)s segments=\(whisperSegs.count) startSec=\(startSec, privacy: .public) epoch=\(scheduledEpoch, privacy: .public) currentEpoch=\(self.epoch, privacy: .public)")
        guard !whisperSegs.isEmpty else { return }

        // VAD utterances are non-overlapping by construction, so we
        // just append — no merge dedup needed. Drop segments that
        // whisper hallucinated inside the padded silence tail (their
        // start time falls past the original audio duration).
        let originalDuration = Double(samples.count) / sampleRate
        for s in whisperSegs {
            let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard s.start < originalDuration else { continue }
            let absStart = startSec + s.start
            // Whisper can extend a last segment into the silence we padded
            // onto short utterances. Clamp to the real audio so a delete
            // cannot mark later utterances as suppressed.
            let absEnd = min(startSec + s.end, startSec + originalDuration)
            // Skip anything the user deleted from this time span.
            guard !isSuppressed(start: absStart, end: absEnd) else { continue }
            segments.append(LiveSegment(
                id: UUID(),
                startSeconds: absStart,
                endSeconds: absEnd,
                text: text,
                speaker: nil,
                stable: true
            ))
        }
        fullText = segments.map(\.text).joined(separator: " ")
    }

    private func kickIfIdle() {
        guard inFlight == nil else {
            liveLog.log("LiveTranscriber.kickIfIdle SKIP: tick already in flight")
            return
        }
        inFlight = Task { @MainActor [weak self] in
            await self?.runOnce()
            self?.inFlight = nil
        }
    }

    private func runOnce() async {
        // Captured before the suspension below; see `epoch`. A tick that was
        // in flight when `stop()`/`reset()` ran belongs to a recording that
        // is over, and its result must not be merged into whatever recording
        // owns `segments` by the time whisper returns.
        let runEpoch = epoch
        let total = buffer.count
        // Need at least 1s of audio before whisper produces anything
        // useful — below that, segment timestamps are garbage and the
        // first-tick noise burst would otherwise show up as gibberish
        // in the UI.
        let minSamples = Int(sampleRate)
        guard total >= minSamples else {
            liveLog.log("LiveTranscriber.runOnce SKIP: buffer=\(total) < \(minSamples) samples")
            return
        }
        beginTranscribe()
        defer { endTranscribe() }

        let windowSamples = Int(windowSeconds * sampleRate)
        let windowStartIndex = max(0, total - windowSamples)
        let windowAbsoluteStart = Double(samplesDropped + windowStartIndex) / sampleRate
        let slice = Array(buffer[windowStartIndex..<total])

        let startedAt = Date()
        // Non-VAD fixed-window tick (legacy chunked live path). The slice is
        // up to `windowSeconds` (= 30s default) of audio, not a VAD-bounded
        // utterance, so the labelled-fixture sweep doesn't cover it. Opt out
        // of the audio_ctx truncation; whisper's default 1500-token ctx
        // applies.
        let outcome = await transcription.transcribeLiveSegments(
            samples: slice, language: language, audioCtx: 0
        )
        let elapsed = Date().timeIntervalSince(startedAt)
        // The pipeline was torn down — or a new recording begun — while
        // whisper ran. Not even `trimBuffer()`: the buffer is the new
        // recording's now.
        guard runEpoch == epoch else {
            liveLog.log("LiveTranscriber tick dropped post-whisper — epoch changed (run=\(runEpoch, privacy: .public) current=\(self.epoch, privacy: .public))")
            return
        }
        let whisperSegs: [TranscriptSegment]
        switch outcome {
        case .transcribed(let segs):
            noteConnectionRestored()
            whisperSegs = segs
        case .skipped:
            whisperSegs = []
        case .connectionUnavailable:
            // No retry here: the next tick re-sends the trailing window
            // anyway, and the buffer is left untrimmed. Audio that slides
            // out of the window meanwhile is covered by the batch pass —
            // which a fixed-window recording always gets at Stop — so the
            // flag is belt and braces on this path (#355).
            noteConnectionInterrupted()
            hasUntranscribedAudio = true
            liveLog.log("LiveTranscriber tick: server unreachable — samples=\(slice.count) elapsed=\(elapsed, privacy: .public)s")
            return
        }
        liveLog.log("LiveTranscriber tick: samples=\(slice.count) elapsed=\(elapsed, privacy: .public)s segments=\(whisperSegs.count) lang=\(self.language, privacy: .public)")
        guard !whisperSegs.isEmpty else { return }

        let absoluteSegs: [LiveSegment] = whisperSegs.compactMap { s in
            let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let absStart = windowAbsoluteStart + s.start
            let absEnd = windowAbsoluteStart + s.end
            // Don't resurrect a line the user deleted from this span.
            guard !isSuppressed(start: absStart, end: absEnd) else { return nil }
            return LiveSegment(
                id: UUID(),
                startSeconds: absStart,
                endSeconds: absEnd,
                text: text,
                speaker: nil,
                stable: true
            )
        }
        Self.merge(incoming: absoluteSegs, into: &segments)
        fullText = segments.map(\.text).joined(separator: " ")
        trimBuffer()
    }

    /// Drop samples from the head of `buffer` that we'll never read
    /// again. Anything older than the rolling whisper window is dead
    /// weight; keeping it grows the buffer linearly with recording
    /// length (Cursor Bugbot, PR #20).
    ///
    /// Keeps `windowSeconds` of samples (everything the next tick's
    /// slice could possibly need) plus a half-chunk of headroom so
    /// we don't churn the array every single tick when the buffer is
    /// only just past the window size.
    private func trimBuffer() {
        let keep = Int(windowSeconds * sampleRate) + Int(chunkSeconds * sampleRate / 2)
        guard buffer.count > keep else { return }
        let drop = buffer.count - keep
        buffer.removeFirst(drop)
        samplesDropped += drop
    }

    /// Merge `incoming` (already in absolute time) into `existing`.
    /// Rules in the file header — exposed for tests.
    /// - `sameUtteranceStartTolerance`: how close two segment starts
    ///   have to be to be considered "the same utterance whisper just
    ///   re-emitted with more audio." 0.6s matches whisper's typical
    ///   start-time jitter across overlapping windows.
    /// - `appendGapTolerance`: how strictly past the last existing
    ///   segment a new one has to start to be considered new content.
    ///   0.2s of slack absorbs jitter without letting clearly-overlap
    ///   text through.
    static func merge(
        incoming: [LiveSegment],
        into existing: inout [LiveSegment],
        sameUtteranceStartTolerance: Double = 0.6,
        appendGapTolerance: Double = 0.2
    ) {
        for seg in incoming {
            if let last = existing.last,
               abs(last.startSeconds - seg.startSeconds) <= sameUtteranceStartTolerance,
               seg.endSeconds > last.endSeconds {
                // Same utterance, whisper now has more audio → replace.
                var updated = last
                updated.endSeconds = seg.endSeconds
                updated.text = seg.text
                existing[existing.count - 1] = updated
                continue
            }
            let cutoff = existing.last.map { $0.endSeconds - appendGapTolerance } ?? -.infinity
            if seg.startSeconds >= cutoff {
                existing.append(seg)
            }
            // Otherwise the incoming segment is fully inside content we
            // already finalized — skip.
        }
    }
}
