# Python Subprocess Integration in Swift

When integrating Python ML pipelines (pyannote.audio, torch, speechbrain) into this macOS app:

## Process Setup
- Use `Process` with `Task.detached(priority: .userInitiated)` to avoid blocking the main actor
- Pass the Python script inline via `-c` argument, not as a file path -- app bundle path resolution is fragile
- Diarization models are bundled in the app — the models directory path is passed as a CLI argument to the inline script
- Always capture stdout and stderr into separate Pipes

## stdout/stderr Separation
Python ML libraries (torch, speechbrain, pyannote) emit copious warnings and progress info to stderr. The diarization script outputs structured JSON to stdout. If you mix them (or read only one), JSON parsing breaks silently. Always:
1. Read stdout for data (JSON)
2. Read stderr for diagnostics/error messages
3. Log stderr content for debugging but never try to parse it as data

## Pipe Drain Ordering (Deadlock Prevention)
**Always drain stdout and stderr pipes BEFORE calling `process.waitUntilExit()`.** On macOS (and POSIX generally), pipe buffers are ~64 KB. If a subprocess fills a pipe buffer before the parent reads from it, the subprocess blocks on `write()`. If the parent is blocked on `waitUntilExit()`, neither side can make progress -- classic deadlock.

This is not theoretical: it caused transcription to hang at 100% on files longer than ~25 minutes (PR #15), because pyannote's stderr logging exceeded the buffer on long runs.

**Correct pattern:**
```swift
let stdoutRead = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }
let stderrRead = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }

process.waitUntilExit()

let stdoutData = await stdoutRead.value
let stderrData = await stderrRead.value
```

**Why `Task.detached` instead of `DispatchGroup`:** In Swift 6 strict concurrency, calling `DispatchGroup.wait()` inside an async context triggers a warning (blocking a cooperative thread). `Task.detached` with `await` is the idiomatic async-safe alternative.

**Wrong pattern (will deadlock on large output):**
```swift
process.waitUntilExit()
let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()  // too late
let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
```

## Never Park a Blocking Subprocess Wait on `DispatchQueue.global()`

The global concurrent queues are **non-overcommit**: libdispatch will not spin
up a thread for a queued work item just because the existing ones are blocked in
the kernel. It notices the stall on a delay and grows the pool slowly, up to a
hard cap. So every blocking item you park there makes the *next* one slower to
be **scheduled at all** — and that delay is unbounded in the bad case.

A subprocess wait is three blocking items if you write it the obvious way: two
pipe readers parked in `availableData` until EOF, and one thread parked in
`waitUntilExit()`. The caller then blocks a fourth waiting on the group. Under
load this produced ordinary-looking timeouts on commands that had already
succeeded (issue #246):

```text
git checkout -b main did not exit within 60s and was killed
  (stderr so far: Switched to a new branch 'main'
```

`Switched to a new branch 'main'` is git's own success message. git ran,
succeeded, and wrote to a pipe we were reading — and 65s later the work item
meant to notice its exit still had not run. Not a slow command; a wait that
never started.

**Rules:**

1. Observe the exit with `process.terminationHandler` plus a
   `DispatchSemaphore`, installed **before** `process.run()`. That costs no
   thread of ours at all.
2. Anything that must genuinely block — a pipe reader, a `waitUntilExit()`
   backstop, a synchronous `runSync` body — goes on a thread of its own via
   `BlockingWork.onDedicatedThread(named:)` (`Mila/Actions/BlockingWork.swift`).
   A dedicated thread cannot be starved, cannot starve anyone else, and if it
   leaks (a grandchild holding a pipe open forever) it costs one thread rather
   than a slot in a pool the whole process shares.
3. Keep the `waitUntilExit()` backstop even with a `terminationHandler`: macOS
   26 has a reaping race where `waitUntilExit` never returns even after
   `SIGKILL`. The two paths fail independently; whichever notices first signals.
   Only wait on the semaphore once, so a double signal is harmless.

This applies to tests as much as to production code — the test host is one
process, and a suite that parks blocking work on the shared pool degrades every
other suite in the bundle.

## Known Compatibility Patches
These monkey-patches are required as of pyannote.audio 3.x + PyTorch >= 2.6 + speechbrain:

1. `torch.load` weights_only patch (PyTorch 2.6+ changed default)
2. speechbrain `LazyModule.ensure_module` patch (pytorch_lightning stack inspection triggers lazy imports)

If a future pyannote or speechbrain release fixes these, the patches can be removed. Check on each dependency upgrade.

## Bundled Model Path Naming
When bundling ML models that are normally loaded via HuggingFace model IDs (e.g., `pyannote/wespeaker-voxceleb-resnet34-LM`), the local directory names must preserve the original model ID structure. ML frameworks like pyannote use **substring matching on the file path** to dispatch to different backends:
- A path containing `"pyannote"` routes to the **torch** backend
- A path containing `"wespeaker"` (without `"pyannote"`) routes to the **ONNX** backend (requires onnxruntime)

The bundled directory must be named to match the same substring the framework expects. For example, `pyannote-wespeaker-voxceleb-resnet34-LM` (preserving the `pyannote` prefix) -- not just `wespeaker-voxceleb-resnet34-LM`. This applies to any model where the framework infers behavior from the path string rather than from metadata inside the model files.

**Why:** This caused a production bug (PR #14) where diarization silently failed because the wrong embedding backend was selected based on the directory name.

## Dependency Installation
- Use `python3 -m pip install` (not bare `pip`) to ensure the correct Python environment
- Pin `huggingface_hub<1.0` to avoid breaking changes in the HF API
- The Settings UI handles dep installation via `SpeakerDiarizer.installDependencies()`
