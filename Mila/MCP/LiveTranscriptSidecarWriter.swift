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
    func finish(recordingID: UUID?) {
        cancelTimers()
        guard var current = snapshot, current.state == .recording else { return }
        current.state = .completed
        current.finalRecordingID = recordingID
        current.revision += 1
        snapshot = current
        writeNow()
        snapshot = nil
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
