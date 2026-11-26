import Foundation
import TranscriptionCore
@testable import Mila

/// In-memory stand-in for `WhisperEngine` so transcription tests don't have to
/// load a 1.5GB model from disk. Records every call for assertions.
actor StubWhisperEngine: TranscribingEngine {

    // MARK: - Test-controlled inputs

    /// Segments returned by the next `transcribe` call. Keyed in FIFO order:
    /// first call gets `cannedQueue[0]`, second gets `cannedQueue[1]`, etc.
    /// Falls back to `defaultCanned` once the queue is exhausted.
    var cannedQueue: [[TranscriptSegment]] = []
    var defaultCanned: [TranscriptSegment] = [
        TranscriptSegment(start: 0, end: 1, text: "stub")
    ]
    /// Per-call simulated work duration. Falls back to `defaultDelay`.
    var delayQueue: [Double] = []
    var defaultDelay: Double = 0
    /// If non-nil at the time of the next call, that call throws.
    var nextError: Error?
    /// Simulated `loadIfNeeded` duration. When > 0, `loadIfNeeded`
    /// invokes the `preparationObserver` with `true`, sleeps, then
    /// invokes it with `false` — mirrors the real engine's behaviour
    /// on a first-time CoreML compile. Used by the preparing-state
    /// regression test in `TranscriptionServicePrewarmTests`.
    var loadDelay: Double = 0
    /// Status string surfaced through the preparation observer. Lets
    /// a test assert that the engine-supplied caption reaches the UI.
    var loadPreparationStatus: String? = "Preparing Neural Engine…"
    /// If non-nil, the next `loadIfNeeded` throws it (after `loadDelay`) —
    /// a model that fails to load, e.g. a corrupt or since-deleted file.
    var loadError: Error?

    // MARK: - Recorded outputs

    /// Last model handed to `loadIfNeeded`. Kept after `unload()` on purpose:
    /// tests assert which MODEL a path routed to, not whether it is still
    /// resident — `isModelLoaded` / `unloadCount` carry that.
    private(set) var loadedModel: URL?
    /// Number of `loadIfNeeded` calls, and of those that actually loaded
    /// (i.e. the idempotent early-return was NOT taken). Mirrors
    /// `WhisperEngine`, where a same-path load is a no-op, so a batch of
    /// queued recordings can be checked for one real load.
    private(set) var loadRequestCount = 0
    private(set) var loadCallCount = 0
    private(set) var isModelLoaded = false
    private(set) var unloadCount = 0
    private(set) var transcribeCalls: [(samples: [Float], language: String, audioCtx: Int32?)] = []
    private(set) var concurrentInFlight = 0
    private(set) var maxConcurrentInFlight = 0
    private(set) var transcribeEnteredCount = 0
    private(set) var shutdownCount = 0

    // MARK: - Transcribe gate

    /// Lets a test hold `transcribe` calls at a known point. Used to prove
    /// that an idle model release waits for in-flight work and cannot land
    /// between a load and its transcribe.
    private var unloadGateClosed = false
    private var unloadGateWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var unloadEnteredCount = 0
    private var transcribeGateClosed = false
    private var transcribeGateWaiters: [CheckedContinuation<Void, Never>] = []
    private var transcribeEntryWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    // MARK: - Preparation observer

    private var preparationObserver: (@Sendable (Bool, String?) -> Void)?

    func setPreparationObserver(_ observer: (@Sendable (Bool, String?) -> Void)?) {
        self.preparationObserver = observer
    }

    // MARK: - TranscribingEngine

    func loadIfNeeded(modelURL: URL, displayName: String) async throws {
        loadRequestCount += 1
        let previousPath = loadedModel
        loadedModel = modelURL
        // A test-injected failure targets the NEXT load attempt even when a
        // model is already resident: the real engine would return early after
        // a successful same-path load, but tests use `loadError` to drive the
        // service's load-failure path and expect the attempt to run.
        if let err = loadError {
            loadError = nil
            loadCallCount += 1
            if loadDelay > 0 {
                preparationObserver?(true, loadPreparationStatus)
                try? await Task.sleep(nanoseconds: UInt64(loadDelay * 1_000_000_000))
                preparationObserver?(false, nil)
            }
            isModelLoaded = false
            throw err
        }
        // Mirror `WhisperEngine`: a same-path load of an already-loaded model
        // returns without touching the context. Only a real load counts.
        guard !isModelLoaded || previousPath != modelURL else { return }
        loadCallCount += 1
        if loadDelay > 0 {
            preparationObserver?(true, loadPreparationStatus)
            try? await Task.sleep(nanoseconds: UInt64(loadDelay * 1_000_000_000))
            preparationObserver?(false, nil)
        }
        isModelLoaded = true
    }

    func transcribe(samples: [Float],
                    language: String,
                    audioCtx: Int32?,
                    progress: (@Sendable (Float) -> Void)?,
                    isCancelled: (@Sendable () -> Bool)?) async throws -> [TranscriptSegment] {
        if let err = nextError {
            nextError = nil
            throw err
        }

        concurrentInFlight += 1
        maxConcurrentInFlight = max(maxConcurrentInFlight, concurrentInFlight)
        defer { concurrentInFlight -= 1 }

        transcribeCalls.append((samples: samples, language: language, audioCtx: audioCtx))
        transcribeEnteredCount += 1
        resumeEntryWaiters()
        await waitAtTranscribeGate()
        if isCancelled?() == true { throw CancellationError() }

        let delay = delayQueue.isEmpty ? defaultDelay : delayQueue.removeFirst()
        if delay > 0 {
            let steps = 4
            for i in 1...steps {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000 / Double(steps)))
                // Mirror the real engine: bail out cleanly if the caller has
                // flipped the cancellation flag while we were sleeping.
                if isCancelled?() == true { throw CancellationError() }
                progress?(Float(i) / Float(steps))
            }
        } else {
            if isCancelled?() == true { throw CancellationError() }
            progress?(1.0)
        }

        let segments = cannedQueue.isEmpty ? defaultCanned : cannedQueue.removeFirst()
        return segments
    }

    func unload() async {
        guard isModelLoaded else { return }
        unloadCount += 1
        unloadEnteredCount += 1
        if unloadGateClosed {
            await withCheckedContinuation { unloadGateWaiters.append($0) }
        }
        isModelLoaded = false
    }

    func shutdown() async {
        shutdownCount += 1
        isModelLoaded = false
    }

    // MARK: - Test helpers

    func setCannedQueue(_ q: [[TranscriptSegment]]) { cannedQueue = q }
    func setDefaultCanned(_ s: [TranscriptSegment]) { defaultCanned = s }
    func setDelayQueue(_ q: [Double]) { delayQueue = q }
    func setDefaultDelay(_ d: Double) { defaultDelay = d }
    func setNextError(_ e: Error?) { nextError = e }
    func setLoadDelay(_ d: Double) { loadDelay = d }
    func setLoadError(_ e: Error?) { loadError = e }
    func setLoadPreparationStatus(_ s: String?) { loadPreparationStatus = s }

    func closeUnloadGate() { unloadGateClosed = true }

    func openUnloadGate() {
        unloadGateClosed = false
        let waiters = unloadGateWaiters
        unloadGateWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Hold every subsequent `transcribe` at the gate until `openTranscribeGate`.
    func closeTranscribeGate() {
        transcribeGateClosed = true
    }

    /// Resume up to `count` gated `transcribe` calls, in entry order, and open
    /// the gate once no waiter is left.
    func openTranscribeGate(count: Int = .max) {
        var remaining = count
        while remaining > 0, !transcribeGateWaiters.isEmpty {
            transcribeGateWaiters.removeFirst().resume()
            remaining -= 1
        }
        transcribeGateClosed = !transcribeGateWaiters.isEmpty
    }

    /// Await until `count` `transcribe` calls have entered (recorded + held at
    /// the gate if it is closed).
    func waitUntilTranscribeEntered(_ count: Int) async {
        guard transcribeEnteredCount < count else { return }
        await withCheckedContinuation { continuation in
            transcribeEntryWaiters.append((target: count, continuation: continuation))
        }
    }

    private func waitAtTranscribeGate() async {
        guard transcribeGateClosed else { return }
        await withCheckedContinuation { transcribeGateWaiters.append($0) }
    }

    private func resumeEntryWaiters() {
        let satisfied = transcribeEntryWaiters.filter { transcribeEnteredCount >= $0.target }
        transcribeEntryWaiters.removeAll { transcribeEnteredCount >= $0.target }
        satisfied.forEach { $0.continuation.resume() }
    }

    func resetRecording() {
        loadRequestCount = 0
        loadCallCount = 0
        loadedModel = nil
        isModelLoaded = false
        unloadCount = 0
        transcribeCalls.removeAll()
        concurrentInFlight = 0
        maxConcurrentInFlight = 0
        transcribeEnteredCount = 0
    }
}
