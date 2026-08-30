import Foundation
import Combine
import OSLog

private let diarLog = Logger(subsystem: "io.island.whisper.IslandWhisper", category: "LiveSpeakerDiarizer")

/// Streams speaker labels during a live recording by sending 5 s WAV chunks
/// to a long-running Python daemon that computes a pyannote/wespeaker
/// embedding per chunk. Swift maintains a pool of speaker centroids and
/// assigns stable `SPEAKER_00`, `SPEAKER_01`, … labels via cosine similarity.
///
/// The daemon model:
///   * loads the bundled pyannote Pipeline once at startup (~3–5 s cold
///     start — far cheaper than spawning a fresh subprocess every tick),
///   * extracts the embedding `Inference` object (`pipeline._embedding`)
///     and skips the heavy segmentation/clustering pass,
///   * reads commands as one JSON line per request on stdin
///     (`{"cmd":"embed","wav":"/tmp/…"}`), writes one JSON line per
///     response on stdout (`{"embedding":[…256 floats…]}` or
///     `{"error":"…"}`).
///
/// If the daemon fails to start (no Python, no models, dependency missing)
/// we publish `lastError` and `intervals` stays empty — the live UI just
/// shows unlabeled text. This is the documented `isConfigured` invariant
/// from `.claude/rules/feature-gates.md`: optional features must degrade
/// to a no-op rather than crashing the recording.
@MainActor
final class LiveSpeakerDiarizer: ObservableObject {
    /// Intervals labeled by this diarizer over the lifetime of the current
    /// recording. Each maps a (start, end) absolute-seconds window to one
    /// of the stable speaker IDs (`SPEAKER_00`, …).
    @Published private(set) var intervals: [(start: Double, end: Double, speaker: String)] = []
    @Published private(set) var lastError: String?
    @Published private(set) var isReady: Bool = false

    /// Cosine threshold above which an incoming embedding is considered
    /// the same speaker as an existing pool entry. 0.55 fits wespeaker's
    /// short-utterance embeddings — VAD emits 1-5s clips and same-
    /// speaker cosine similarity at that length typically lands in
    /// 0.5-0.7 (not 0.75-0.95 which is the long-clip range). Anything
    /// tighter splits the same person across many SPEAKER_NN IDs.
    /// Tunable in Settings.
    var similarityThreshold: Double = 0.55

    private var pool: [SpeakerProfile] = []
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var stdoutBuffer = Data()
    /// Pending one-shot response continuations. Each `embed` command
    /// resolves the next one — daemon protocol is strictly request /
    /// response so first-in-first-out.
    private var pending: [CheckedContinuation<EmbedResponse, Never>] = []
    private var stderrTask: Task<Void, Never>?
    /// Tail of the chained background-diarize tasks. Each `submit(...)`
    /// chains a new Task that awaits the previous one before running
    /// `process(...)`, so the chain enforces FIFO over the daemon and
    /// `awaitPending()` can join the final tail at end-of-recording.
    private var processQueue: Task<Void, Never>?

    struct SpeakerProfile {
        var id: String
        /// Matching centroid: a running mean over the seeded weight (if any)
        /// plus every embedding that matched this entry during the recording.
        /// A seeded entry starts at the persisted centroid so the first
        /// utterance can't blow it away.
        var centroid: [Float]
        /// The weight behind `centroid`. Seeded entries start at a capped
        /// share of the persisted count — see `seedPool`.
        var sampleCount: Int
        /// Running mean over **only** the embeddings observed in *this*
        /// recording, and how many there were. Empty / zero for a seeded
        /// entry until it first matches.
        ///
        /// This pair exists because `centroid` / `sampleCount` cannot be
        /// persisted: both already contain the seeded profile's own weight,
        /// which is *already on disk*. Folding them back into the stored
        /// profile counts that weight twice — a seeded entry with three
        /// carried samples and one live match persisted as four new samples,
        /// so the stored count grew ~4x per recording and the centroid froze.
        /// `currentProfiles()` therefore reports this delta, never the
        /// matching pair.
        var observedCentroid: [Float]
        var observedCount: Int
        /// Name from a stored voice profile if this pool entry was seeded.
        var profileName: String?
    }

    private struct EmbedResponse: Decodable {
        let embedding: [Float]?
        let error: String?
    }

    /// Monotonic counter pairing each recording's daemon start with the
    /// stop() that follows it. The record-start path deliberately detaches
    /// `start()` (pyannote cold-init must not block the state observer),
    /// which used to leave a race: a fast start→stop recording could run
    /// `stop()` (no-op, nothing launched yet) BEFORE the detached start
    /// body executed — the ~1 GB torch daemon then booted *after* the
    /// recording ended and idled until some future recording's stop.
    /// Claiming a session synchronously at record-start and closing it in
    /// stop() lets the late-running start body detect it was superseded.
    private var session = 0

    /// Claim a session token synchronously BEFORE detaching the async
    /// `start(diarization:session:)` call.
    func beginSession() -> Int {
        session += 1
        return session
    }

    /// Boot the Python daemon. No-op if a daemon is already running, or
    /// if diarization is disabled / not configured. Throws nothing — any
    /// failure becomes a `lastError` so callers don't have to wrap try/
    /// catch around every recording start.
    ///
    /// `session` (from `beginSession()`) ties this start to one recording;
    /// pass nil only where start/stop can't race (tests).
    func start(diarization: DiarizationSettings, session: Int? = nil) async {
        if let session, session != self.session {
            diarLog.log("start skipped — recording already stopped before the detached start ran")
            return
        }
        guard process == nil else {
            diarLog.log("start skipped — daemon already running")
            return
        }
        // Fresh launch: don't let a previous daemon's failure report leak
        // into this session's diagnostics (failPending deliberately keeps
        // the FIRST error it sees, so a stale one would win).
        lastError = nil
        guard diarization.isConfigured else {
            lastError = "Diarization is not configured"
            diarLog.log("NOT starting — isConfigured=false (isEnabled=\(diarization.isEnabled, privacy: .public) hasBundledRuntime=\(diarization.hasBundledRuntime, privacy: .public) bootstrap.isReady=\(diarization.bootstrap.isReady, privacy: .public))")
            return
        }
        guard let modelsPath = Bundle.main.path(forResource: "DiarizationModels", ofType: nil) else {
            lastError = "Bundled diarization models not found in app"
            diarLog.log("NOT starting — DiarizationModels not in app bundle")
            return
        }
        let pythonPath = SpeakerDiarizer.resolvePython(userConfigured: diarization.pythonPath)
        guard FileManager.default.fileExists(atPath: pythonPath) else {
            lastError = "Python not found at \(pythonPath)"
            diarLog.log("NOT starting — python not at \(pythonPath, privacy: .public)")
            return
        }
        diarLog.log("starting daemon python=\(pythonPath, privacy: .public)")

        let script = Self.daemonScript
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = ["-u", "-c", script, modelsPath]
        var env = ProcessInfo.processInfo.environment
        for (k, v) in SpeakerDiarizer.pythonEnvironment() {
            env[k] = v
        }
        process.environment = env
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            lastError = "Could not launch diarization daemon: \(error.localizedDescription)"
            return
        }

        self.process = process
        self.stdinPipe = stdin
        self.stdoutHandle = stdout.fileHandleForReading
        self.stderrHandle = stderr.fileHandleForReading
        startStdoutReader()
        startStderrReader()

        // Wait for the ready handshake before declaring success. The
        // daemon emits `{"ready":true}` on stdout once the pipeline and
        // embedding inference are loaded.
        let ready = await waitForReady(timeoutSeconds: 30)
        if let session, session != self.session {
            // stop() ran while we waited for the handshake — it already
            // terminated the daemon and reset the state; don't resurrect
            // any of it for a recording that's over.
            diarLog.log("start superseded during ready-wait — leaving stopped state alone")
            return
        }
        isReady = ready
        diarLog.log("daemon ready=\(ready, privacy: .public)")
        if !ready {
            lastError = lastError ?? "Diarization daemon did not become ready"
        }
    }

    /// Shut down the daemon. Idempotent. Called when a recording stops.
    func stop() {
        // Close the current session so a start() that was detached for this
        // recording but hasn't run (or is still in its ready-wait) aborts.
        session += 1
        if let stdin = stdinPipe {
            let cmd = #"{"cmd":"shutdown"}\#n"#
            try? stdin.fileHandleForWriting.write(contentsOf: Data(cmd.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        process?.terminate()
        process = nil
        stdinPipe = nil
        // Detach the readability handler BEFORE dropping the handle: bytes
        // still buffered in the dying daemon's stdout pipe would otherwise
        // keep arriving through the old handler and get matched against the
        // NEXT daemon's `pending` queue.
        stdoutHandle?.readabilityHandler = nil
        stdoutHandle = nil
        stderrHandle = nil
        stdoutBuffer.removeAll()
        for cont in pending { cont.resume(returning: .init(embedding: nil, error: "stopped")) }
        pending.removeAll()
        stderrTask?.cancel()
        stderrTask = nil
        isReady = false
    }

    /// Reset the speaker pool. New recording = fresh pool — we never carry
    /// embeddings across recordings (a participant who joined last meeting
    /// might be the same person, but assigning the same SPEAKER_00 across
    /// unrelated calls is more confusing than starting fresh).
    func reset() {
        pool.removeAll()
        intervals.removeAll()
    }

    /// Pre-populate the pool with known speaker voice profiles so
    /// returning speakers are auto-recognised. Call after `reset()` at
    /// recording start. Each entry gets a fresh `SPEAKER_NN` ID and a
    /// capped `sampleCount` so the centroid can adapt to current-session
    /// acoustics on the first few matches.
    ///
    /// The seeded weight goes into `sampleCount` only — the matching side.
    /// `observedCount` starts at zero because nothing has been observed in
    /// *this* recording yet, and that is the number the persistence path
    /// reads. A seeded entry that never speaks therefore contributes
    /// nothing to its stored profile, and one that speaks once contributes
    /// exactly one sample.
    func seedPool(with entries: [(id: String, name: String, centroid: [Float], sampleCount: Int)]) {
        for entry in entries {
            let id = String(format: "SPEAKER_%02d", pool.count)
            pool.append(SpeakerProfile(
                id: id,
                centroid: entry.centroid,
                sampleCount: min(entry.sampleCount, 3),
                observedCentroid: [],
                observedCount: 0,
                profileName: entry.name
            ))
        }
    }

    /// Drop everything the pool holds that came off disk, for the profiles
    /// the user has just deleted (`names`), or for every seeded entry when
    /// `names` is nil.
    ///
    /// Two callers, both wired in `MilaApp.init`, both answering the same
    /// question — "the user just revoked something; does the recording that
    /// is already running honour it?":
    ///
    ///   * `SpeakerProfileStore`'s deletion observer, passing the deleted
    ///     `names` (or nil for "delete everything");
    ///   * `VoiceRecognitionSettings`' enabled observer on opt-out, passing
    ///     nil — switching the feature off revokes every seeded voice at
    ///     once, not a named subset.
    ///
    /// Deleting voice profiles is a privacy action, and `seedPool` gave this
    /// object its own copy of the centroids at record-start. Deleting the
    /// file therefore does not, by itself, delete the voice from a recording
    /// that is already running: the pool goes on matching against the erased
    /// centroid for the rest of it, and `RecognisedSpeakerAssigner.finish`
    /// then names the speaker and writes the profile straight back at stop —
    /// under a fresh id and this recording's own centroid, which is the same
    /// person's fingerprint to within rounding. The user is told their voice
    /// data is gone while it quietly returns. `SpeakerProfileStore`'s
    /// deletion observer calls this so the deletion lands everywhere at
    /// once, the way opting out already does.
    ///
    /// Entries are neutralised, never removed: ids are minted positionally
    /// (`SPEAKER_%02d` from `pool.count`), so removing one would make the
    /// next minted speaker collide with an existing id, and any interval
    /// already labelled with the removed id would dangle. What each entry
    /// keeps is exactly what *this recording* heard:
    ///
    ///   * `profileName` is cleared, so nothing downstream can auto-apply
    ///     the deleted name or persist under it;
    ///   * the matching pair falls back to the observed pair, dropping the
    ///     seeded weight — the deleted centroid stops steering the match
    ///     while the speaker stays coherent for the rest of the recording
    ///     from utterances the recording itself produced.
    ///
    /// A seeded entry that never matched has no observations, so it is left
    /// with an empty centroid: inert, and skipped by `assign`'s scan.
    /// In-recording diarization is not what was deleted — the stored profile
    /// is — so this deliberately keeps the former and destroys only the
    /// latter.
    func forgetSeededProfiles(named names: Set<String>? = nil) {
        for idx in pool.indices {
            guard let name = pool[idx].profileName else { continue }
            if let names, !names.contains(name) { continue }
            pool[idx].profileName = nil
            pool[idx].centroid = pool[idx].observedCentroid
            pool[idx].sampleCount = pool[idx].observedCount
        }
    }

    /// Snapshot the pool for **persistence**: for each speaker, the mean of
    /// what was observed in this recording, how many observations that was,
    /// and the voice-profile name it was seeded from (if any).
    ///
    /// Deliberately reports `observedCentroid` / `observedCount` rather than
    /// the matching `centroid` / `sampleCount`. For a seeded entry the
    /// matching pair carries weight that is already stored on disk, and
    /// folding it back in counts it twice — see `SpeakerProfile`. For a
    /// speaker minted during this recording the two pairs are identical, so
    /// nothing changes for the common case.
    ///
    /// A seeded speaker who never matched reports `observedCount == 0`;
    /// `SpeakerProfileStore.updateProfile` refuses a zero count, so it can
    /// never write a spurious update.
    func currentProfiles() -> [(id: String, observedCentroid: [Float], observedCount: Int, profileName: String?)] {
        pool.map { ($0.id, $0.observedCentroid, $0.observedCount, $0.profileName) }
    }

    /// Fire-and-track variant of `process(...)`. Chains the call onto
    /// `processQueue` so the FIFO order matches the daemon's, and
    /// `awaitPending()` can join the tail. Use this from the live-
    /// recording pipeline; use `process(...)` directly only for tests.
    func submit(samples: [Float], startSeconds: Double, endSeconds: Double, sampleRate: Double = 16_000) {
        let prev = processQueue
        processQueue = Task { @MainActor [weak self] in
            await prev?.value
            await self?.process(samples: samples,
                                startSeconds: startSeconds,
                                endSeconds: endSeconds,
                                sampleRate: sampleRate)
        }
    }

    /// Wait for every queued `submit(...)` call to finish. Used at
    /// end-of-recording so the final utterance's interval lands in
    /// `intervals` before the saved transcript is read.
    func awaitPending() async {
        await processQueue?.value
    }

    /// Diarize one chunk of samples covering [`startSeconds`, `endSeconds`]
    /// of the recording's timeline. Writes the slice to a temp WAV and
    /// sends the path to the daemon. Returns nothing — appends to
    /// `intervals` for the live transcriber to pick up via
    /// `applySpeakerLabels(_:)`.
    func process(samples: [Float], startSeconds: Double, endSeconds: Double, sampleRate: Double = 16_000) async {
        diarLog.log("process called: samples=\(samples.count, privacy: .public) start=\(startSeconds, privacy: .public) end=\(endSeconds, privacy: .public) isReady=\(self.isReady, privacy: .public)")
        guard isReady, !samples.isEmpty else {
            diarLog.log("process SKIPPED isReady=\(self.isReady, privacy: .public) samplesEmpty=\(samples.isEmpty, privacy: .public)")
            return
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mila-live-diar-\(UUID().uuidString).wav")
        do {
            try writeMono16WAV(samples: samples, sampleRate: sampleRate, to: tempURL)
        } catch {
            lastError = "Could not write live diar chunk: \(error.localizedDescription)"
            return
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let payload: [String: Any] = ["cmd": "embed", "wav": tempURL.path]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: data, encoding: .utf8) else { return }
        let sendStart = Date()
        diarLog.log("sending embed cmd to daemon, wav=\(tempURL.path, privacy: .public)")
        let response = await sendCommand("\(line)\n")
        let elapsed = Date().timeIntervalSince(sendStart)
        diarLog.log("daemon response after \(elapsed, privacy: .public)s: embedding=\(response.embedding?.count ?? 0, privacy: .public) error=\(response.error ?? "(none)", privacy: .public)")
        guard let embedding = response.embedding, !embedding.isEmpty else {
            if let err = response.error { lastError = "Diar daemon: \(err)" }
            return
        }
        let speakerID = assign(embedding: embedding, utteranceDuration: endSeconds - startSeconds)
        intervals.append((start: startSeconds, end: endSeconds, speaker: speakerID))
        diarLog.log("interval added: \(startSeconds, privacy: .public)..\(endSeconds, privacy: .public) → \(speakerID, privacy: .public) (poolSize=\(self.pool.count, privacy: .public) totalIntervals=\(self.intervals.count, privacy: .public))")
    }

    /// Match a new embedding against the pool by cosine similarity, using a
    /// two-tier (hysteresis) policy to curb over-segmentation:
    ///
    ///   • `sim ≥ similarityThreshold` → confident match; fold the
    ///     embedding into that speaker's centroid (running mean).
    ///   • `createThreshold ≤ sim < similarityThreshold`, OR the utterance
    ///     is too short to trust as a new voice → attach to the closest
    ///     existing speaker WITHOUT updating its centroid (a marginal match
    ///     shouldn't be allowed to drift the representation).
    ///   • `sim < createThreshold` (or the pool is empty) → mint a new
    ///     speaker.
    ///
    /// Why: wespeaker cosine sim for the SAME speaker on 1-5s VAD chunks
    /// routinely dips to ~0.45-0.55, so a single hard threshold minted a
    /// fresh `SPEAKER_NN` for a big fraction of one person's sentences
    /// (observed: 7+ speakers for a single-narrator video). Requiring a
    /// clearly-dissimilar embedding — or a long-enough utterance — before
    /// creating a speaker keeps the live pool from exploding. The offline
    /// pass at stop still does the authoritative global clustering.
    func assign(embedding: [Float], utteranceDuration: Double = 2.0) -> String {
        var best: (idx: Int, sim: Double)?
        for (idx, profile) in pool.enumerated() {
            // An entry with no centroid has nothing to compare against, so
            // it cannot be anyone's best match. `cosineSimilarity` already
            // returns 0 for it, which keeps it out of the confident-match
            // branch — but not out of the borderline/short-utterance
            // *attach* branch below, which takes the best entry whatever its
            // similarity. Without this skip, a seeded entry emptied by
            // `forgetSeededProfiles` could still capture utterances into a
            // speaker whose voice the user just deleted. Unreachable
            // otherwise: `process` refuses an empty embedding, so nothing
            // else ever puts an empty centroid in the pool.
            guard !profile.centroid.isEmpty else { continue }
            let sim = cosineSimilarity(embedding, profile.centroid)
            if best == nil || sim > best!.sim {
                best = (idx, sim)
            }
        }
        let bestSim = best?.sim ?? -1.0
        let bestId = best.map { pool[$0.idx].id } ?? "(none)"
        // Floor for minting a new speaker — kept a notch below the match
        // threshold so borderline utterances attach rather than fork.
        // Clamped so a low user-set threshold can't drive it negative.
        let createThreshold = max(0.40, similarityThreshold - 0.15)
        // Short chunks give noisy embeddings; don't let them mint a new
        // speaker when we already have a pool to attach to.
        let longEnoughForNewSpeaker = utteranceDuration >= 1.0
        diarLog.log("assign: poolSize=\(self.pool.count, privacy: .public) bestMatch=\(bestId, privacy: .public) bestSim=\(bestSim, privacy: .public) threshold=\(self.similarityThreshold, privacy: .public) createThreshold=\(createThreshold, privacy: .public) dur=\(utteranceDuration, privacy: .public)")
        // A confident match must agree in *dimension* as well as in angle.
        // `cosineSimilarity` returns 0 on a count mismatch, so while the
        // threshold is positive a differently-sized centroid can never clear
        // it — but `similarityThreshold` is a plain `var` with no invariant
        // of its own (Settings clamps its slider to 0.5...0.95; nothing binds
        // a direct caller), and at a non-positive threshold that 0 would pass
        // and the fold below would index `embedding` out of bounds. The
        // mismatch itself is real, not hypothetical: `seedPool` takes
        // centroids straight off disk, so a profile written by a different
        // embedding model arrives at whatever length it was stored at.
        // Checking here keeps the fold's memory safety local instead of
        // resting on a distant clamp, and enforces exactly the outcome the
        // threshold was assumed to produce — such an entry is not a
        // confident match, so it falls through to attach-or-mint below.
        if let chosen = best,
           chosen.sim >= similarityThreshold,
           pool[chosen.idx].centroid.count == embedding.count {
            // Confident match → fold into the matching centroid (running
            // mean). The guard above makes `centroid.count` safe to index
            // `embedding` with.
            let n = pool[chosen.idx].sampleCount
            var centroid = pool[chosen.idx].centroid
            for i in 0..<centroid.count {
                centroid[i] = (centroid[i] * Float(n) + embedding[i]) / Float(n + 1)
            }
            pool[chosen.idx].centroid = centroid
            pool[chosen.idx].sampleCount = n + 1
            // The same fold over this recording's observations alone — the
            // pair that gets persisted. A seeded entry starts empty, so its
            // first match takes the embedding directly rather than averaging
            // into nothing. A non-empty `observedCentroid` was itself built
            // from embeddings that passed the dimension check above, so it is
            // the same length as `embedding` and safe to index in step.
            let observedSoFar = pool[chosen.idx].observedCount
            if observedSoFar == 0 {
                pool[chosen.idx].observedCentroid = embedding
                pool[chosen.idx].observedCount = 1
            } else {
                var observed = pool[chosen.idx].observedCentroid
                for i in 0..<observed.count {
                    observed[i] = (observed[i] * Float(observedSoFar) + embedding[i])
                        / Float(observedSoFar + 1)
                }
                pool[chosen.idx].observedCentroid = observed
                pool[chosen.idx].observedCount = observedSoFar + 1
            }
            return pool[chosen.idx].id
        }
        // Borderline, or too short to trust as a new voice → attach to the
        // closest existing speaker (leave its centroid untouched).
        if let chosen = best, chosen.sim >= createThreshold || !longEnoughForNewSpeaker {
            return pool[chosen.idx].id
        }
        // A speaker minted during this recording has no seeded weight, so
        // the matching pair and the persisted pair are the same thing.
        let nextID = String(format: "SPEAKER_%02d", pool.count)
        pool.append(SpeakerProfile(id: nextID,
                                   centroid: embedding,
                                   sampleCount: 1,
                                   observedCentroid: embedding,
                                   observedCount: 1,
                                   profileName: nil))
        return nextID
    }

    // MARK: - Daemon I/O

    private func sendCommand(_ line: String) async -> EmbedResponse {
        guard let stdin = stdinPipe else {
            return .init(embedding: nil, error: "no daemon")
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<EmbedResponse, Never>) in
            pending.append(cont)
            do {
                try stdin.fileHandleForWriting.write(contentsOf: Data(line.utf8))
            } catch {
                // The write failed (daemon likely died). The continuation
                // we just queued won't get a response from the daemon, so
                // resume it here and pop it. It must be the most recently
                // added entry since the queue is strictly FIFO.
                _ = pending.popLast()
                cont.resume(returning: .init(embedding: nil, error: error.localizedDescription))
            }
        }
    }

    private func waitForReady(timeoutSeconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            // The stdout reader fills `stdoutBuffer` and dispatches lines
            // to pending continuations. If isReady is set elsewhere, exit.
            if isReady { return true }
            // Daemon died before the handshake (missing dep, bad models
            // path) or stop() ran mid-wait: bail now instead of spinning
            // the full 30s. Whatever error line the daemon printed on its
            // way down was captured into `lastError` by handleLine /
            // failPending, so start()'s `lastError ??` fallback preserves
            // the real diagnosis over the generic "did not become ready".
            guard let process, process.isRunning else { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return isReady
    }

    private func startStdoutReader() {
        guard let handle = stdoutHandle else { return }
        // Set up a readability handler that appends data, splits on newlines,
        // and dispatches each complete line. Closures touching `self` hop
        // back to the main actor before mutating state.
        handle.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            if data.isEmpty {
                // EOF — daemon exited.
                Task { @MainActor [weak self] in
                    // Identity gate: a task enqueued just before stop()
                    // detached this handler can land AFTER a new daemon
                    // is up — it must not fail the NEW daemon's pending
                    // queue.
                    guard let self, self.stdoutHandle === fh else { return }
                    self.failPending(error: "daemon exited")
                }
                fh.readabilityHandler = nil
                return
            }
            Task { @MainActor [weak self] in
                // Same identity gate: stale bytes from a dying daemon must
                // not be matched against the next daemon's pending queue.
                guard let self, self.stdoutHandle === fh else { return }
                self.consumeStdout(data)
            }
        }
    }

    private func consumeStdout(_ data: Data) {
        stdoutBuffer.append(data)
        while let newlineIdx = stdoutBuffer.firstIndex(of: 0x0a) {
            let lineData = stdoutBuffer.prefix(upTo: newlineIdx)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newlineIdx)
            handleLine(lineData)
        }
    }

    private func handleLine(_ data: Data) {
        struct ReadyMsg: Decodable { let ready: Bool? }
        if let ready = try? JSONDecoder().decode(ReadyMsg.self, from: data), ready.ready == true {
            isReady = true
            return
        }
        guard !pending.isEmpty else {
            // Pre-ready line with no waiter. The daemon reports startup
            // failures as an {"error": ...} line right before exiting —
            // dropping it here left only the generic "did not become
            // ready" after a full timeout spin. Keep the real diagnosis.
            if let resp = try? JSONDecoder().decode(EmbedResponse.self, from: data),
               let error = resp.error {
                lastError = error
                diarLog.log("daemon pre-ready error: \(error, privacy: .public)")
            }
            return
        }
        let cont = pending.removeFirst()
        if let resp = try? JSONDecoder().decode(EmbedResponse.self, from: data) {
            cont.resume(returning: resp)
        } else {
            cont.resume(returning: .init(embedding: nil, error: "could not parse daemon response"))
        }
    }

    private func failPending(error: String) {
        for cont in pending {
            cont.resume(returning: .init(embedding: nil, error: error))
        }
        pending.removeAll()
        isReady = false
        // Keep an earlier, more specific report (e.g. the daemon's own
        // {"error": ...} startup line) over this generic one.
        lastError = lastError ?? error
    }

    private func startStderrReader() {
        guard let handle = stderrHandle else { return }
        stderrTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let data = handle.availableData
                if data.isEmpty { break }
                if let text = String(data: data, encoding: .utf8) {
                    // Route stderr through os.Logger so we can read
                    // Python progress + tracebacks via `log show`.
                    // The daemon's `print(..., file=sys.stderr,
                    // flush=True)` lines land here, including the
                    // "live-diar: embed error" traceback we'd
                    // otherwise miss on silent failures.
                    let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !stripped.isEmpty {
                        diarLog.log("daemon stderr: \(stripped, privacy: .public)")
                    }
                }
                _ = self  // keep reference alive
            }
        }
    }

    // MARK: - WAV writing

    private func writeMono16WAV(samples: [Float], sampleRate: Double, to url: URL) throws {
        // Minimal 32-bit float WAV writer — matches the format RecordingSession
        // uses so the daemon's soundfile.read returns the same float32 floats
        // Mila already has in memory.
        let bitsPerSample: UInt16 = 32
        let channels: UInt16 = 1
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign: UInt16 = channels * (bitsPerSample / 8)
        let dataBytes = UInt32(samples.count * 4)
        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(UInt32(36 + dataBytes).littleEndianData)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(UInt32(16).littleEndianData)              // fmt chunk size
        data.append(UInt16(3).littleEndianData)               // 3 = IEEE float
        data.append(channels.littleEndianData)
        data.append(UInt32(sampleRate).littleEndianData)
        data.append(byteRate.littleEndianData)
        data.append(blockAlign.littleEndianData)
        data.append(bitsPerSample.littleEndianData)
        data.append("data".data(using: .ascii)!)
        data.append(dataBytes.littleEndianData)
        let byteCount = samples.count * MemoryLayout<Float>.size
        samples.withUnsafeBytes { rawBuf in
            if let base = rawBuf.baseAddress {
                data.append(base.assumingMemoryBound(to: UInt8.self), count: byteCount)
            }
        }
        try data.write(to: url)
    }

    // MARK: - Daemon script

    private static let daemonScript = """
import json, sys, os, types, traceback
import numpy as np

# Same speechbrain lazy-module patch as the batch diarizer — pyannote 3.x
# triggers speechbrain stack inspection which tries to import optional
# packages and crashes if they're missing.
try:
    import speechbrain.utils.importutils as _sbiu
    _orig_ensure = _sbiu.LazyModule.ensure_module
    def _safe_ensure(self, *a, **kw):
        try:
            return _orig_ensure(self, *a, **kw)
        except ImportError:
            self.lazy_module = types.ModuleType(self.target)
            return self.lazy_module
    _sbiu.LazyModule.ensure_module = _safe_ensure
except Exception:
    pass

import torch
_orig_torch_load = torch.load
def _patched_torch_load(*args, **kwargs):
    kwargs["weights_only"] = False
    return _orig_torch_load(*args, **kwargs)
torch.load = _patched_torch_load

import soundfile as sf
from pyannote.audio import Pipeline

def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\\n")
    sys.stdout.flush()

def main():
    models_dir = sys.argv[1]
    config_path = os.path.join(models_dir, "config.yaml")
    import tempfile
    with open(config_path) as f:
        config_text = f.read().replace("__MODELS_DIR__", models_dir)
    tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False)
    tmp.write(config_text); tmp.close()

    try:
        print("live-diar: loading pyannote pipeline", file=sys.stderr, flush=True)
        pipeline = Pipeline.from_pretrained(tmp.name)
        if torch.backends.mps.is_available():
            pipeline.to(torch.device("mps"))
            print("live-diar: using MPS", file=sys.stderr, flush=True)
        # `_embedding` is the Inference object pyannote uses internally
        # for speaker embeddings. Public API doesn't expose it directly
        # but the attribute is stable across 3.x releases.
        embedder = getattr(pipeline, "_embedding", None)
        if embedder is None:
            emit({"error": "pipeline._embedding not available"})
            return
    finally:
        os.unlink(tmp.name)

    emit({"ready": True})
    print("live-diar: ready", file=sys.stderr, flush=True)

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            cmd = json.loads(line)
        except Exception as e:
            emit({"error": "bad json: %s" % e})
            continue
        op = cmd.get("cmd")
        if op == "shutdown":
            break
        if op != "embed":
            emit({"error": "unknown cmd %s" % op})
            continue
        wav_path = cmd.get("wav", "")
        if not wav_path or not os.path.exists(wav_path):
            emit({"error": "wav not found"})
            continue
        try:
            samples, sr = sf.read(wav_path, dtype="float32")
            if samples.ndim > 1:
                samples = samples.mean(axis=1)
            # pyannote 3.x's `pipeline._embedding` is a
            # `PretrainedSpeakerEmbedding`, NOT an `Inference` wrapper —
            # so it takes a torch.Tensor of shape
            #   (batch_size, num_channels, num_samples)
            # directly. Passing a `{"waveform": ..., "sample_rate": ...}`
            # dict (the file-input shape for `Inference`) made pyannote
            # try `.to(device)` on the dict and crash with
            # "'dict' object has no attribute 'to'" — silently swallowing
            # every embed request.
            wave = torch.from_numpy(samples).unsqueeze(0).unsqueeze(0)
            emb = embedder(wave)
            arr = emb.detach().cpu().numpy().flatten() if hasattr(emb, "detach") else np.array(emb).flatten()
            emit({"embedding": arr.tolist()})
        except Exception as e:
            tb = traceback.format_exc()
            print("live-diar: embed error %s\\n%s" % (e, tb), file=sys.stderr, flush=True)
            emit({"error": str(e)})

main()
"""
}

/// Cosine similarity between two equal-length vectors. Returns 0 for
/// zero-length / mismatched inputs so the caller still gets a Double back
/// without having to guard.
func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot: Double = 0, normA: Double = 0, normB: Double = 0
    for i in 0..<a.count {
        dot += Double(a[i]) * Double(b[i])
        normA += Double(a[i]) * Double(a[i])
        normB += Double(b[i]) * Double(b[i])
    }
    let denom = (normA.squareRoot() * normB.squareRoot())
    return denom == 0 ? 0 : dot / denom
}

private extension UInt16 {
    var littleEndianData: Data {
        withUnsafeBytes(of: self.littleEndian) { Data($0) }
    }
}

private extension UInt32 {
    var littleEndianData: Data {
        withUnsafeBytes(of: self.littleEndian) { Data($0) }
    }
}
