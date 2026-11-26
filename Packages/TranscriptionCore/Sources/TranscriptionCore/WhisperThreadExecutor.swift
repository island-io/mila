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
/// **One thread, shared.** `static let shared` lives as long as the process,
/// so the thread is never torn down and never leaks per instance. Every
/// `WhisperEngine` shares it (the app has exactly one), which serializes
/// whisper work across instances; whisper.cpp's Metal backend is process-global
/// state anyway.
///
/// Rule this follows: `.claude/rules/python-subprocess.md` — anything that
/// genuinely blocks gets a thread of its own, never a slot in a shared pool.
final class WhisperThreadExecutor: SerialExecutor, @unchecked Sendable {
    static let shared = WhisperThreadExecutor(name: "io.island.mila.whisper")

    private let condition = NSCondition()
    /// FIFO of jobs not yet run. `head` avoids `removeFirst`'s O(n) shift;
    /// the array is compacted whenever it drains.
    private var jobs: [UnownedJob] = []
    private var head = 0
    /// Written once, in `init`, before the thread starts.
    private var thread: Thread!

    private init(name: String) {
        // Strong capture on purpose: `shared` is process-lifetime, and so is
        // the thread that serves it.
        let thread = Thread { [self] in self.runJobs() }
        thread.name = name
        // A fixed QoS: a custom executor neither reorders its queue by task
        // priority nor escalates a running job, so the thread runs at the
        // level the work is started at in practice (the batch worker, live
        // utterances, dictation and prewarm are all tasks the main actor
        // starts). Whisper work was serial on the actor before as well;
        // only the order of WAITING jobs can differ, and they now run FIFO.
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
            while head == jobs.count { condition.wait() }
            let job = jobs[head]
            head += 1
            if head == jobs.count {
                jobs.removeAll(keepingCapacity: true)
                head = 0
            }
            condition.unlock()
            run(job, on: executor)
        }
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
