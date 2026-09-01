import Foundation

/// Somewhere to park a **blocking** wait that is not
/// `DispatchQueue.global()`.
///
/// ## Why this exists (issue #246)
///
/// Every subprocess we run — `LLMRunner.executeProcess`,
/// `ProcessGitCommandRunner.runSync`, and the `runGit` helper in
/// `ObsidianGitSyncerIntegrationTests` — used to hand three *blocking* work
/// items to `DispatchQueue.global()` per invocation: two pipe readers parked
/// in `FileHandle.availableData` until EOF, and one thread parked in
/// `Process.waitUntilExit()`. The caller then blocked a fourth pooled thread
/// waiting on the resulting `DispatchGroup`.
///
/// The global concurrent queues are **non-overcommit**: libdispatch will not
/// spin up a thread for a queued item just because the existing ones are
/// blocked in the kernel. It notices the stall on a delay and grows the pool
/// slowly, up to a hard cap on constrained threads. So the more of these waits
/// are in flight, the longer an item sits before it is *scheduled at all* —
/// which is exactly the "10-15s of dispatch latency on this CI image" that
/// several comments in this codebase already record as ordinary.
///
/// That latency is not a slow wait, it is a wait that has not started, and it
/// is unbounded in the bad case. It produced this signature on CI:
///
/// ```text
/// git checkout -b main did not exit within 60s and was killed
///   (stderr so far: Switched to a new branch 'main'
/// ```
///
/// `Switched to a new branch 'main'` is git's own success message. git ran,
/// succeeded, and wrote to a pipe we were reading — and 65s later the item
/// that was supposed to observe its exit still had not run. The two
/// `LLMSandboxDirectoryTests` timeouts in the same run have the same shape:
/// each overshot its bound by ~6s, which is precisely the SIGTERM + SIGKILL
/// grace, i.e. the exit observer never reported in even after the child was
/// killed.
///
/// A thread of our own cannot be starved and cannot starve anybody else, and
/// if it does leak (a grandchild holding a pipe open forever) it costs one
/// thread rather than one slot in a pool the whole process shares.
///
/// This is deliberately not a queue. A `DispatchQueue(label:)` would also
/// work — private serial queues target an *overcommit* root queue, so they
/// always get a thread — but that is a subtle property to rely on, and it is
/// invisible at the call site. `Thread` says what it means.
enum BlockingWork {

    /// Start `body` on a thread of its own, right now.
    ///
    /// `name` shows up in a sample / crash report, which is the whole reason
    /// to prefer this over `Thread.detachNewThread`: the point of the change
    /// is to make "who is blocked on what" legible, and an unnamed thread is
    /// not.
    static func onDedicatedThread(named name: String,
                                  _ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = name
        thread.start()
    }
}
