# PLAN: Fix UI freeze when opening menus during recording/transcription

## Feature description

Opening the folder picker `Menu` on a screen that is receiving high-frequency
`@Published` updates (the live recording screen, the recording detail view
during active transcription, and the post-stop rename sheet) can beachball the
whole app. This plan removes that class of freeze — and the related jank —
without migrating off `ObservableObject` (the `@Observable` migration was
explicitly deferred). The user-visible outcome: folder/meeting-name controls
stay responsive while a recording is being captured or transcribed, and the
progress indicator no longer stalls/jumps.

## Goal / success criteria

- **Primary (manual, reproducible):** With a recording actively transcribing
  (or a live recording in progress), opening the folder `Menu` on the live
  recording screen, the recording detail view, and the rename sheet does **not**
  freeze the UI. A `sample Mila`/`spindump` taken while the menu is open shows
  the main thread idle in menu tracking — not stacked with SwiftUI/AttributeGraph
  re-render work.
- **Progress is smooth + monotonic:** the transcription progress bar/percent
  advances without jumping backward and does not visibly stall just short of
  completion.
- **No regressions:** folder assignment, meeting-name entry, live auto-scroll,
  and transcript rendering behave exactly as before (same final state, same
  persisted data).
- **Unit-testable cores pass:** the progress-coalescing/monotonic guard and any
  extracted pure helpers have tests (see Tests section).

## Files explored

| File | Why it matters |
|---|---|
| `Mila/Views/LiveAIRecordingView.swift` | `metaRow` (L142–181) puts a folder `Menu` + meeting-name `TextField` in `header`/`body`, which observes `transcriber`/`diarizer`/`aiSession` (high-frequency). Also owns the per-tick auto-scroll (L475–501). Contains the `RecordingElapsedLabel` leaf (L627) — the isolation pattern to reuse. |
| `Mila/Views/RecordingDetailView.swift` | `folderMenu` (L97–125) in `header`/`body`; view observes `transcription`, so `progress` floods it during active transcription of the open recording. |
| `Mila/Views/RenameRecordingSheet.swift` | Folder `Menu` (L379–420) in a body that renders `transcription.progress` (L100–118, L492–496); sheet appears right after Stop while batch transcription runs. |
| `Mila/Views/HomeView.swift` | `folderPicker` (L202–230) in a body observing `transcription` + `actions`; lower-risk instance of the same pattern. |
| `Mila/Transcription/TranscriptionService.swift` | `progress` `@Published` (L28) updated via one unstructured `Task` per whisper tick (L672–678). Source of the flood + out-of-order/stall. |
| `Mila/Audio/LiveTranscriber.swift` | `@Published fullText` (L42) + `segments` (L63) update at partial-transcript cadence; drive the live view flood and the per-tick auto-scroll. |
| `Mila/Models/RecordingStore.swift` | `assign` (L427–441) → `persist()` (L782–792) synchronously encodes the entire recordings array + atomic disk write on the main thread on every folder selection. |

## Existing-design review

The fix deliberately reuses patterns already in the codebase:

- **Leaf-isolation of high-frequency observers** — `RecordingElapsedLabel`
  (`LiveAIRecordingView.swift` L627) observes only `RecordingSession` so the
  parent body isn't rebuilt at audio cadence. The folder/meeting controls will
  follow the same shape: small leaf views observing only what they render
  (`store.folders`, the `actions` bindings), never `transcriber` /
  `transcription` / `aiSession`.
- **`LazyVStack` + deferred `scrollTo`** — already used for the transcript; the
  scroll debounce builds on the existing `scrollToBottom` runloop-hop.
- **`@MainActor` service classes** — `TranscriptionService` is already
  `@MainActor`; the coalesced progress update stays on it, just fed by a single
  throttled path instead of N Tasks.
- **Serial background work** — the codebase already offloads heavy work off the
  main actor (`finalizeTail`, `Task.detached`); persistence debouncing/off-main
  will match that convention.

## Deviation justification (if any)

*None — reuses existing patterns (leaf isolation à la `RecordingElapsedLabel`,
throttled main-actor updates, existing off-main task conventions). The
`@Observable` framework migration — which would solve observation granularity
structurally — is explicitly out of scope for this plan per the user's
decision, and is noted below as a future option only.*

## Scope (ordered by impact)

1. **Leaf-isolate the folder picker + meeting-name controls** so they no longer
   sit in a body observing the high-frequency objects. Extract a
   `RecordingFolderMenu` (and, where present, isolate the meeting-name field)
   used by `LiveAIRecordingView`, `RecordingDetailView`, `RenameRecordingSheet`,
   and `HomeView`. Each observes only `store` (for `folders`) and the relevant
   `actions`/store binding. **This directly kills the reported freeze.**
2. **Coalesce + guard `TranscriptionService.progress`.** Replace the
   one-`Task`-per-tick pattern with a single ordered update path that (a) applies
   values monotonically (never regress), and (b) throttles to a sane cadence
   (e.g. only when it changes by ≥1% or every ~100ms). Fixes the "stuck/jumpy
   progress" and reduces flood pressure.
3. **Debounce the live auto-scroll** so `fullText` growth triggers at most one
   `withAnimation` scroll per animation window instead of one per partial tick.
4. **Move `persist()` off the main thread (or debounce it)** so folder
   assignment on a large library doesn't stall the main thread.

Steps 1–2 are the core of the fix; 3–4 are the related "similar behaviour"
items surfaced in review. Each step is independently landable.

## Open questions

1. **Scope confirmation:** do you want all four steps in one pass, or land
   step 1 (freeze fix) first and treat 2–4 as follow-ups? Recommendation: land
   1 + 2 together (they share the root cause), then 3 + 4.
2. **Progress throttle policy:** is "publish on ≥1% change or every 100ms,
   monotonic" acceptable, or do you want a specific cadence?
3. **Persistence (step 4):** debounce on the main actor (simplest, keeps
   ordering) vs. serialize encoding onto a background actor/queue (removes the
   stall entirely, more moving parts). Recommendation: start with a short
   debounce; only go off-main if profiling still shows a stall.
4. **Meeting-name field:** confirm you want it isolated too (it re-renders on
   every tick today, causing typing lag), or is only the `Menu` in scope?

---

## Tests

> Draft — to be confirmed in workflow step 3 before implementation.

### What to test

- **Progress coalescing/monotonic guard (unit):** feeding an out-of-order /
  regressing sequence (e.g. 0.1, 0.5, 0.4, 1.0, 0.9) yields a non-decreasing
  published sequence ending at the max; sub-threshold deltas are dropped.
- **Auto-scroll debounce (unit, if extracted as a pure throttle):** N rapid
  triggers within one window collapse to a single scroll invocation.
- **Folder assignment behavior unchanged (unit):** `store.assign` still files
  the recording under the (case-insensitively deduped) folder and persists;
  debouncing/off-main persistence still results in the same on-disk JSON
  (flush-and-read in the test).
- **Manual (freeze repro):** enumerated steps to open each folder menu during
  active transcription/recording and confirm no beachball (+ optional spindump).

### How to test

- Framework: XCTest (`MilaTests/`), matching existing suites like
  `QuickActionsControllerTests` / `TranscriptionService`-adjacent tests.
- Isolation: any `TranscriptionService`/`RecordingStore` under test uses the
  existing test-injection conventions (custom `UserDefaults` suite; temp store
  directory) per `CLAUDE.md`.
- Manual: `make dmg VERSION=<x.y.z>` local build; repro script in the plan.

### Done definition

- New unit tests pass; `make test` + `make package-test` green.
- Manual freeze repro no longer reproduces on the three screens.
- No behavioral change to folder assignment / transcript content.

---

## Implementation notes (filled in as you go)

Implemented 2026-07-20. Decisions made (user said "implementation" without
answering the open questions, so the plan's recommended defaults were used):

- **Step 1 — leaf isolation (done).** New `Mila/Views/RecordingFolderControls.swift`
  with three leaves that observe only `RecordingStore` / `QuickActionsController`:
  - `NextRecordingFolderPicker` — used by `HomeView` + `LiveAIRecordingView`.
  - `NextRecordingMeetingNameField` — used by `HomeView` + `LiveAIRecordingView`
    (meeting-name field isolated too, per open question #4 recommendation).
  - `RecordingFolderMenu(recordingID:currentFolder:)` — used by
    `RecordingDetailView`; owns its own "New Folder…" alert state.
  Rationale: a leaf with constant/stable inputs is not re-invoked when its
  parent body churns, so the open NSMenu host is never reconciled mid-tracking.
  Removed now-unused `@EnvironmentObject store` from `HomeView` and
  `LiveAIRecordingView`, and the dead folder-alert `@State` from
  `RecordingDetailView`.
- **Step 3 — rename sheet (done).** `RenameRecordingSheet` no longer holds
  `@EnvironmentObject transcription`. All progress/status rendering moved into a
  new file-private `RenameTranscriptionStatusRow` leaf (observes `transcription`
  + `store`). The sheet body — including the folder `Menu` — therefore no longer
  re-renders on progress ticks.
- **Step 2 — progress coalescing (done).** Added `ProgressCoalescer`
  (lock-guarded, `@unchecked Sendable`) in `TranscriptionService.swift`. The
  whisper progress callback now `offer`s into a per-run coalescer and only
  schedules a main-actor flush when none is pending; `flush` applies the
  monotonic max. Chosen over the "≥1%/100ms" throttle from open question #2
  because single-pending-flush coalescing bounds outstanding work to one Task
  AND guarantees monotonicity with less machinery. Unit-tested in
  `MilaTests/ProgressCoalescerTests.swift`.
- **Step 5 — auto-scroll debounce (done).** `scrollToBottom` in
  `LiveAIRecordingView` now cancels/replaces a `DispatchWorkItem` (0.1s), so the
  per-`fullText`-tick scroll collapses to one animation per window.
- **Step 4 (persistence) — DEFERRED.** Making `persist()` async/debounced risks
  flaking ~8 tests that read `recordings.json` synchronously after a mutation
  (diagnostics, storage relocation, `StoredRecordingDrift`). It's also a
  separate pre-existing perf issue (select-time stall, not the reported
  menu-open freeze). Left synchronous; should be handled in its own change with
  dedicated tests.

### Verification

- `make build` — BUILD SUCCEEDED.
- `xcodebuild ... -only-testing:MilaTests test` — all pass **except** two
  pre-existing, environment-dependent `LLMRunnerTests`
  (`test_gemini_cli_returns_a_title_for_a_sample_transcript`,
  `test_runner_passes_prompt_in_argv_and_closes_stdin`) that shell out to real
  LLM CLIs / temp scripts. No LLM/subprocess code was touched, so these are
  unrelated. `ProgressCoalescerTests` + all folder/rename/transcription tests
  pass. No lint errors on edited files.
- **Manual freeze repro still outstanding:** open the folder menu on the live
  recording screen / detail view during active transcription and confirm no
  beachball (optionally `sample Mila` while the menu is open).

## Follow-up 2026-07-20 — Step 1 was necessary but INSUFFICIENT

The user reported the freeze STILL reproduced when opening the folder menu on
the live recording window during recording. Root cause: Step 1 leaf-isolated
the menu's *content* (`NextRecordingFolderPicker` / `RecordingFolderMenu`), but
the menu's **ancestors** still re-rendered every tick. `LiveAIRecordingView`
held `@EnvironmentObject transcriber/diarizer/aiSession` at the top level, so
its whole body — including `header`/`metaRow` (which host the folder menu) —
re-executed on every partial-transcript / AI tick. Reconciling the ancestors
of an OPEN NSMenu-backed control (nested modal tracking runloop) beachballs the
app. Same latent bug in `RecordingDetailView`, which held
`@EnvironmentObject transcription` and read `progress` in its body while
hosting `RecordingFolderMenu`.

Fix: push the high-frequency observation DOWN out of the menu's ancestors.

- **`LiveAIRecordingView` (done).** Extracted `LiveTranscriptPane` (owns
  `LiveTranscriber` + the scroll debounce/`exportLiveSRT`), `ActionItemsPane`
  (owns `LiveAISession` + `LiveTranscriber` for speaker names + the AI-pane RTL
  logic), and `LiveThinkingIndicator` (owns `LiveAISession` for the header
  "Thinking…" dot). Removed `transcriber`/`diarizer`/`aiSession` (and the
  now-dead `diarizer` subscription) + the `pendingScroll` `@State` from the
  parent. The parent now observes only `actions` / `languageSettings` /
  `liveAISettings` / `llmSettings` — none tick during recording — so the header
  + folder menu no longer re-render at transcript cadence. `bulletsFromSummary`
  kept static on `LiveAIRecordingView` so `LiveAIBulletsTests` is unaffected.
- **`RecordingDetailView` (done).** Extracted `RecordingDetailActionButtons`
  (owns `TranscriptionService` for the `busy` gate + `enqueue`) and
  `RecordingTranscriptArea` (owns `TranscriptionService` `progress`/active/
  queued state + `ModelManager`). Removed `@EnvironmentObject transcription`
  (and the now-unused `modelManager`) from the parent. `EmptyTranscriptPlaceholder`
  + `emptyTranscriptPlaceholder` kept on `RecordingDetailView` so
  `RecordingDetailPlaceholderTests` is unaffected.

Surroundings: `RenameRecordingSheet` was already correctly isolated
(`RenameTranscriptionStatusRow` leaf). `HomeView` still holds
`@EnvironmentObject transcription` but only shows its folder menu when NOT
recording; a background batch job could still flood it — noted as a lower-risk
optional follow-up, not done here.

### Verification (follow-up)

- `make build` — BUILD SUCCEEDED.
- `xcodebuild ... -only-testing:MilaTests/LiveAIBulletsTests
  -only-testing:MilaTests/RecordingDetailPlaceholderTests test` — TEST
  SUCCEEDED. No lint errors on either edited view.
- **Manual freeze repro still outstanding:** open the folder menu on the live
  recording window AND the recording detail view during active transcription;
  confirm no beachball (optionally `sample Mila` while the menu is open — the
  main thread should be idle in menu tracking, not in SwiftUI/AttributeGraph
  re-render).

## Blockers hit

_(none)_
