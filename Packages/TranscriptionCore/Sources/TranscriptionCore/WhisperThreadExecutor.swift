import Foundation

/// The serial executor every `WhisperEngine` runs on: one dedicated thread
/// for the process, outside Swift's cooperative pool.
///
/// **Why.** whisper.cpp's entry points are synchronous and long: `whisper_full`
/// runs for the whole transcription (minutes for a long file), and
/// `whisper_init_from_file_with_params` can spend ~13 s compiling the CoreML
/// encoder. On the default actor executor each of those parks one thread of
/// the cooperative pool, which has only as many threads as the Mac has cores
/// and never grows. Diarization and every other `async` caller in the app
/// queue behind it (#401; the subprocess half of the same problem was #399).
///
/// **Why this shape, rather than `whisper_full` on a thread of its own plus a
/// continuation.** Awaiting a continuation inside the actor is a suspension
/// point, and an actor is re-entrant across suspension points: `shutdown()`,
/// `unload()` or a `loadIfNeeded` for another model could run in the gap and
/// `whisper_free` the context `whisper_full` is still using. Moving the
/// ACTOR onto this thread instead changes where its code runs and nothing
/// else. `transcribe`, `loadIfNeeded`, `unload` and `shutdown` stay isolated
/// and contain no `await`, so each runs to completion and they cannot interleave:
/// a `shutdown()` that arrives mid-transcription waits behind it exactly as
/// it did on the default executor. Cancellation is unchanged too — whisper
/// polls `abort_callback` from its own compute threads.
///
/// **Order.** Waiting jobs run highest priority first and in arrival order
/// within a priority, which is how the default actor executor orders its
/// queue. What a custom executor cannot do is escalate: a high-priority task
/// that waits on a running job does not raise this thread's QoS. The thread
/// runs at a fixed `.userInitiated`, the level whisper's callers (the batch
/// worker, live utterances, dictation, prewarm) usually run at, and
/// escalation could never preempt a running `whisper_full` in any case.
/// A waiting job's rank is its priority when it was queued: escalating its
/// task afterwards does not move it up. None of those callers sets a
/// priority explicitly, so each job carries the priority of the task that
/// made the call, and a lower-priority one (a batch pass enqueued from a
/// background task, say) waits for as long as higher-priority jobs keep
/// arriving.
///
/// **One thread, shared.** `static let shared` lives as long as the process,
/// so the thread is never torn down and never leaks per instance. Every
/// `WhisperEngine` shares it (the app has exactly one), which serializes
/// whisper work across instances; whisper.cpp's Metal backend is process-global
/// state anyway. Of `WhisperEngine`'s whisper.cpp calls, the one that does
/// not run here is the `whisper_free` in `WhisperEngine.deinit`, which runs
/// on whichever thread drops the last reference, as it always has. The app
/// never drops its engine. `SileroVAD`'s `whisper_vad_*` calls do not run
/// here either, and are unchanged by #401: its model load (in its
/// synchronous `init`) and free (in `deinit`) run on the caller's thread,
/// and its speech check runs on that actor's default executor, concurrent
/// with this thread. All of them are short, CPU-only, and on their own VAD
/// context.
///
/// Rule this follows: `.claude/rules/python-subprocess.md` — anything that
/// genuinely blocks gets a thread of its own, never a slot in a shared pool.
final class WhisperThreadExecutor: SerialExecutor, @unchecked Sendable {
    static let shared = WhisperThreadExecutor(name: "io.island.mila.whisper")

    private let condition = NSCondition()
    /// Jobs not yet run, in arrival order. `nextJob()` takes the first one of
    /// the highest priority. Only the few callers of one engine queue here,
    /// so the queue stays short and a linear scan is the right cost.
    private var jobs: [UnownedJob] = []
    /// Written once, in `init`, before the thread starts.
    private var thread: Thread!

    private init(name: String) {
        // Strong capture on purpose: `shared` is process-lifetime, and so is
        // the thread that serves it.
        let thread = Thread { [self] in self.runJobs() }
        thread.name = name
        // Fixed, see "Order" above.
        thread.qualityOfService = .userInitiated
        // A secondary thread's default stack is 512 KiB, which is what the
        // cooperative pool's threads have too and what whisper ran on before.
        // Headroom costs only address space.
        thread.stackSize = 4 << 20
        self.thread = thread
        thread.start()
    }

    /// True on the executor's thread. For tests and diagnostics.
    var isCurrentThread: Bool { Thread.current === thread }

    var threadName: String? { thread.name }

    /// Jobs waiting to run (not counting the one running). For tests.
    var queuedJobCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return jobs.count
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        condition.lock()
        jobs.append(job)
        condition.signal()
        condition.unlock()
    }

    private func runJobs() {
        let executor = asUnownedSerialExecutor()
        while true {
            condition.lock()
            while jobs.isEmpty { condition.wait() }
            let job = nextJob()
            condition.unlock()
            run(job, on: executor)
        }
    }

    /// Removes and returns the earliest-queued job of the highest priority.
    /// Call with `condition` held and `jobs` non-empty.
    private func nextJob() -> UnownedJob {
        var best = 0
        for i in jobs.indices.dropFirst() where jobs[i].priority > jobs[best].priority {
            best = i
        }
        return jobs.remove(at: best)
    }

    /// One job per autorelease pool. GCD threads, the cooperative pool's
    /// included, drain a pool around every work item; a raw thread drains
    /// only when it exits, and this one never does. ggml-metal and CoreML
    /// are Objective-C underneath, so without this every load and every
    /// transcription would leave its autoreleased objects behind for the
    /// life of the process.
    private func run(_ job: UnownedJob, on executor: UnownedSerialExecutor) {
        #if canImport(ObjectiveC)
        autoreleasepool { job.runSynchronously(on: executor) }
        #else
        job.runSynchronously(on: executor)
        #endif
    }
}
