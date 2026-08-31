## BugBot Rules (Index)

This file is the **entry point** for Cursor BugBot instructions. Paths below are
relative to the **repository root**.

In addition to this file, you **must read and apply** the rules listed under
[Rules](#rules).

---

## How to review (read this first)

Mila is a **local-first macOS app** (Swift 5.10 / SwiftUI, min macOS 14) that
records meetings, transcribes them on-device via whisper.cpp, and optionally runs
speaker diarization through a bundled Python pipeline. It handles microphone
audio, meeting transcripts and learned voice profiles — the most private data on
a user's machine — and it exposes an **opt-in MCP server** that other tools can
read transcripts through.

That shapes what a costly bug looks like here. This is not a service that can be
rolled back centrally: a shipped build runs on someone's laptop against files
written by older builds, and the damage from a privacy or data-integrity mistake
is silent and often unrecoverable. Evaluate every PR through these lenses, in
roughly this priority order, **before** local correctness nits:

1. **Consent and revocation must fail closed.** Anything gating access to
   recordings, transcripts or voice data must deny on a missing, unreadable or
   malformed input, and revocation must take effect **immediately and
   completely** — stopping reads, not just writes. Ask: if this file were absent
   or corrupt, does it grant or deny? If the user revokes mid-operation, does
   in-memory state still serve the old answer? Both directions have failed here
   before. See `bugbot-rules/consent-and-revocation.md`.
2. **Deleted user data must stay deleted.** A delete is a privacy action. Check
   that no cache, in-flight snapshot or copied buffer can write it back
   afterwards — including at the end of an operation that began before the
   delete. See `bugbot-rules/deleted-data-stays-deleted.md`.
3. **User content must not reach public log fields.** Recording titles, meeting
   names, user-chosen paths and subprocess output are user content. `print` has
   no privacy annotation at all; Cocoa quotes the offending path (and its
   *containing folder*) inside `localizedDescription`; transcript filenames are
   derived from titles. Keep `NSError.domain`/`code` public — a blanket redaction
   that makes real failures undiagnosable is its own bug. See
   `bugbot-rules/no-user-content-in-logs.md`.
4. **Untrusted on-disk data reaching arithmetic or indexing.** Files under
   Application Support are user-editable and written by older versions. A value
   that is merely *decodable* is not valid: check for zero/negative divisors,
   dimension mismatches before vector math, and unbounded sums that can trap on
   overflow. Float division does not trap — it yields NaN/inf that propagates
   silently and can be worse than a crash. Validate at the decode boundary. See
   `bugbot-rules/untrusted-persisted-data.md`.
5. **Cross-process and cross-version file contracts.** Several files are read by
   a *different process* or an *older build* than wrote them. Any change to what
   is persisted must keep readers working, and any mirror of a persisted type
   must be updated in lockstep — including **nested** types, where a top-level
   key check silently passes while element fields drift. See
   `bugbot-rules/persisted-contracts-and-mirrors.md`.
6. **Subprocess integration.** The Python pipeline is driven via `Process`.
   Pipes must be drained **before** `waitUntilExit()` or long runs deadlock on a
   full buffer; stdout (data) and stderr (diagnostics) must stay separate; waits
   must be bounded. This is a known, previously-shipped failure class. See
   `.claude/rules/python-subprocess.md`.
7. **Concurrency.** `@MainActor`/actor isolation, `Sendable`, task ordering and
   cancellation, and retain cycles in escaping closures that outlive their call
   (a stored `Task` or long-lived closure needs `[weak self]`).
8. **SwiftUI layout must be bounded.** An unbounded flexible frame in a fixed
   window has shipped a completely unusable screen here. A view given
   `min`/`ideal` without a `max` adopts its content's size; if that content can
   grow, the window cannot contain it.
9. **Local correctness and edge cases** — the usual (nil handling, races,
   off-by-one, error paths). Report these too, but do not let them crowd out the
   above.

When a change touches consent, deletion, persisted formats or the MCP surface,
**say so explicitly and hold it to a higher bar even if the code is correct** —
prefer raising the systemic concern over staying silent because no local bug is
present.

These are review priorities, **not a license to invent issues**. Only raise a
systemic concern when the diff actually touches one of these surfaces. If a
change is small, local and reversible, a short review is the right review.

### Tests

Treat tests as part of the change, and apply two checks that have caught real
defects here:

- **Does a test pin the bug?** A fixture asserting the buggy behaviour has twice
  survived into `main` and made a defect look intentional. If a test documents
  the behaviour a PR is fixing, it must change with it.
- **Is the assertion discriminating?** An assertion that would also pass against
  the unfixed code proves nothing. Prefer a negative control that reproduces the
  old shape and asserts it fails.

Also flag assertions that **trap instead of failing** — a subscript on an
optional-defaulted-to-empty collection aborts the runner and hides which
invariant broke — and any test whose outcome depends on machine state (real
subprocesses, shared temp paths, wall-clock sleeps), which is the current source
of CI flakiness.

---

## Rules

### Systemic risk — apply to every PR

- `bugbot-rules/consent-and-revocation.md` — gates must deny on missing/malformed
  input; revocation must stop reads as well as writes, immediately.
- `bugbot-rules/deleted-data-stays-deleted.md` — no cache or in-flight copy may
  resurrect deleted user data.
- `bugbot-rules/no-user-content-in-logs.md` — titles, paths and subprocess
  output stay out of public log fields; keep the diagnostic parts public.
- `bugbot-rules/untrusted-persisted-data.md` — validate decoded values before
  they reach arithmetic or indexing.
- `bugbot-rules/persisted-contracts-and-mirrors.md` — persisted-format changes
  must keep cross-process and older readers working, mirrors included.

### Conventions — read & enforce these existing rules (BugBot does not auto-load them)

Read and apply each file below as **review criteria**, scoped to the changed
files it actually covers:

- `.claude/rules/python-subprocess.md` — pipe-drain ordering before
  `waitUntilExit()`, stdout/stderr separation, bundled-model path naming.
- `.claude/rules/feature-gates.md` — `isConfigured` must mean "enabled **and**
  ready"; removing a field from a readiness guard needs an equivalent check.
- `.claude/rules/pull-requests.md` — every PR needs a linked issue (CI-enforced).
- `CLAUDE.md` — build and architecture conventions. In particular: `project.yml`
  is the source of truth (never hand-edit `.xcodeproj`, never hardcode versions
  in `Info.plist`); new app-wide settings must be injected into both the main
  window and the Settings scene, and tests must use a custom `UserDefaults`
  suite; the MCP/MilaKit invariants (MilaKit stays dependency-free, the access
  gate is re-read on every call and never cached, mirrors stay in lockstep).

### Guidance for Swift review

- Match the surrounding code's style and comment density. This codebase uses
  comments to record *why* — including which review found a bug. Do not suggest
  deleting those.
- `Packages/TranscriptionCore/**` is a **cross-platform** package wrapping
  whisper.cpp: flag anything that would break the Linux build (Apple-only
  imports need `#if` guards) and any unsafe-pointer or C-bridging lifetime
  issue.
- Flag force-unwraps and force-tries on genuinely fallible paths. Test setup
  idioms (`UserDefaults(suiteName:)!`) are established here and not worth a
  comment.

### Not worth reviewing

Generated, vendored and binary artifacts: `**/*.xcodeproj/**`, `**/*.pbxproj`,
`Mila/Resources/PythonRuntime/**`, `Mila/Resources/DiarizationModels/**`,
`Packages/TranscriptionCore/Fixtures/**`, `**/*.wav`, `**/Assets.xcassets/**`.

> To enforce another convention, add its file to the list above rather than
> duplicating the rule text here. New **systemic** concerns get a focused file in
> `bugbot-rules/`.
