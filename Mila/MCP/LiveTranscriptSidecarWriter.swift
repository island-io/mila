import Foundation
import OSLog
import TranscriptionCore
import MilaKit

private let sidecarLog = Logger(subsystem: "io.island.whisper.IslandWhisper",
                                category: "LiveTranscriptSidecar")

/// Mirrors the in-progress recording's live transcript to
/// `<app-support>/Mila/live/current.json` so external tools (mila-mcp)
/// can follow the meeting in real time. The live transcript otherwise
/// exists only in `LiveTranscriber`'s memory until Stop.
///
/// Writes are throttled (content ticks arrive per whisper pass) and
/// atomic (temp + rename via `.atomic`), so a concurrent reader always
/// sees a complete document. A heartbeat refreshes `updatedAt` every few
/// seconds while recording so a reader can distinguish "meeting is quiet"
/// from "app died mid-meeting".
@MainActor
final class LiveTranscriptSidecarWriter: ObservableObject {

    private let root: URL
    private let minWriteInterval: TimeInterval
    private let heartbeatInterval: TimeInterval

    private var snapshot: LiveTranscriptSnapshot?
    private var lastWriteAt: Date = .distantPast
    private var trailingWriteTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    /// Set when `finish` closed a snapshot whose transcript was NOT yet final
    /// (chunk mode, hardware-gated, or no live segments): the recording is
    /// saved but the batch worker still has to produce its transcript, so no
    /// handoff id could be published. `attachHandoff(forRecording:)` uses this
    /// to complete the handoff once that batch pass lands.
    ///
    /// Holds the session id too, so a late completion can prove it is talking
    /// about the snapshot still on disk rather than a newer recording's.
    private var awaitingBatchHandoff: (session: UUID, recordingID: UUID)?

    /// `root` is the directory holding the `live/` subdirectory — the
    /// default app-support root in production, a temp dir in tests.
    init(root: URL = StoreLocationPointer.defaultRoot(),
         minWriteInterval: TimeInterval = 1.5,
         heartbeatInterval: TimeInterval = 5) {
        self.root = root
        self.minWriteInterval = minWriteInterval
        self.heartbeatInterval = heartbeatInterval
    }

    /// Call once at app launch: a leftover `recording` snapshot means the
    /// app died mid-recording — rewrite it as `interrupted` so a poller
    /// doesn't sit on a transcript that will never grow. (Crash recovery
    /// re-transcribes the orphan WAV through the normal batch queue.)
    func cleanupAtLaunch() {
        guard var stale = LiveTranscriptSnapshot.read(root: root),
              stale.state == .recording else { return }
        stale.state = .interrupted
        stale.revision += 1
        stale.updatedAt = Date()
        do {
            try stale.write(root: root)
            sidecarLog.log("marked leftover live snapshot interrupted (session \(stale.sessionID, privacy: .public))")
        } catch {
            sidecarLog.error("cleanupAtLaunch write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Start a new session snapshot. `liveAvailable: false` records that
    /// the capture is running but no live transcript will appear (the
    /// low-end-hardware gate) — external pollers get an honest status
    /// instead of a silent, forever-empty transcript.
    func begin(title: String?, source: String?, liveAvailable: Bool) {
        cancelTimers()
        // A new meeting supersedes any pending handoff: the old snapshot is
        // about to be overwritten, so there is nothing left to attach to.
        awaitingBatchHandoff = nil
        let now = Date()
        snapshot = LiveTranscriptSnapshot(liveTranscriptAvailable: liveAvailable,
                                          recordingStartedAt: now,
                                          updatedAt: now,
                                          title: title,
                                          source: source?.isEmpty == false ? source : nil)
        writeNow()
        startHeartbeat()
    }

    /// Content tick: replace segments + speaker names. Bumps `revision`
    /// only when something actually changed (the `$segments` feed fires
    /// on every reassignment, changed or not), and coalesces bursts down
    /// to one write per `minWriteInterval` with a guaranteed trailing
    /// write so the last tick of a burst always lands.
    func update(segments: [TranscriptSegment], speakerNames: [String: String]) {
        guard var current = snapshot, current.state == .recording else { return }
        let mapped = segments.map {
            LiveTranscriptSnapshot.Segment(start: $0.start, end: $0.end,
                                           text: $0.text, speaker: $0.speaker)
        }
        guard mapped != current.segments || speakerNames != current.speakerNames else { return }
        current.segments = mapped
        current.speakerNames = speakerNames
        current.revision += 1
        snapshot = current
        scheduleWrite()
    }

    /// Final write for this session. Pass the saved recording's id on the
    /// normal Stop path (poller handoff to `get_transcript`); nil when
    /// there's nothing to hand off (failed stop, sleep/lock teardown).
    /// The completed snapshot stays on disk until the next `begin`.
    ///
    /// `transcriptIsFinal: false` means the row is saved but its transcript
    /// isn't done — chunk mode awaiting batch diarization, the hardware-gated
    /// path, or a recording with no live segments at all. Those close WITHOUT
    /// an id, because `final_recording_id` is read as "this id resolves to the
    /// authoritative transcript" and at that moment it does not: the batch
    /// worker hasn't run. Publishing it anyway pointed clients at a `.pending`
    /// row whose text was stale or empty. (CodeRabbit on #183.) The id is
    /// remembered so `attachHandoff(forRecording:)` can publish the handoff
    /// when the batch pass completes.
    func finish(recordingID: UUID?, transcriptIsFinal: Bool = true) {
        cancelTimers()
        guard var current = snapshot, current.state == .recording else { return }
        current.state = .completed
        if let recordingID, !transcriptIsFinal {
            current.finalRecordingID = nil
            awaitingBatchHandoff = (session: current.sessionID, recordingID: recordingID)
        } else {
            current.finalRecordingID = recordingID
            awaitingBatchHandoff = nil
        }
        current.revision += 1
        snapshot = current
        writeNow()
        snapshot = nil
    }

    /// Publish the handoff for a recording whose transcript has now been
    /// produced by the batch worker, completing a `finish(…,
    /// transcriptIsFinal: false)`.
    ///
    /// Every guard here fails SAFE — a no-op leaves the `completed`-without-id
    /// snapshot exactly as it was, which is already correct and already tells a
    /// poller to check `list_recordings`. So the worst case for this whole
    /// mechanism is that the convenience handoff doesn't appear, never a wrong
    /// or clobbered snapshot:
    ///
    ///   * `awaitingBatchHandoff` must name THIS recording — the completion
    ///     hook it is called from is global and also fires for user-initiated
    ///     re-transcribes of old rows;
    ///   * `snapshot == nil` — a live recording is in progress, so the file on
    ///     disk belongs to it and must not be touched;
    ///   * the on-disk `sessionID` must still be the session we closed, which
    ///     is what stops a *later* meeting's snapshot being stamped with an
    ///     earlier recording's id;
    ///   * it must still be `completed` with no id, so we never overwrite a
    ///     handoff already published.
    func attachHandoff(forRecording recordingID: UUID) {
        guard let awaited = awaitingBatchHandoff,
              awaited.recordingID == recordingID,
              snapshot == nil,
              var onDisk = LiveTranscriptSnapshot.read(root: root),
              onDisk.sessionID == awaited.session,
              onDisk.state == .completed,
              onDisk.finalRecordingID == nil else { return }
        onDisk.finalRecordingID = recordingID
        onDisk.revision += 1
        onDisk.updatedAt = Date()
        do {
            try onDisk.write(root: root)
            awaitingBatchHandoff = nil
            sidecarLog.log("attached late handoff for \(recordingID, privacy: .public)")
        } catch {
            // Left pending on purpose: a later completion for the same
            // recording can retry, and until then the id-less snapshot stands.
            sidecarLog.error("late handoff write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Write scheduling

    private func scheduleWrite() {
        let elapsed = Date().timeIntervalSince(lastWriteAt)
        if elapsed >= minWriteInterval {
            trailingWriteTask?.cancel()
            trailingWriteTask = nil
            writeNow()
        } else if trailingWriteTask == nil {
            let delay = minWriteInterval - elapsed
            trailingWriteTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.trailingWriteTask = nil
                self.writeNow()
            }
        }
    }

    private func writeNow() {
        guard var current = snapshot else { return }
        current.updatedAt = Date()
        snapshot = current
        lastWriteAt = Date()
        do {
            try current.write(root: root)
        } catch {
            sidecarLog.error("live snapshot write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startHeartbeat() {
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.heartbeatInterval else { return }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self, self.snapshot?.state == .recording else { continue }
                // Refresh updatedAt (liveness) without touching revision
                // (content cursor) — quiet meetings stay cheap to poll.
                self.writeNow()
            }
        }
    }

    private func cancelTimers() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        trailingWriteTask?.cancel()
        trailingWriteTask = nil
    }
}
