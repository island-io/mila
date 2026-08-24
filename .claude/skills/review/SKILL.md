---
name: review
description: Pre-push code review that catches CodeRabbit/Copilot/maintainer issues before submitting. Run with /review before pushing. Loops fix→review until clean. Learned from 19 upstream PRs.
---

# Pre-Push Code Review

## Overview

Review all staged/unstaged changes against the project's code quality standards before pushing. Learned from 80+ CodeRabbit findings across 19 merged upstream PRs plus maintainer (Uri) review patterns.

## How to run

The user invokes `/review`. You then:

1. **Collect the diff** — `git diff HEAD` + `git diff --cached` + new files
2. **Review against ALL checklists below** — every item, no skipping
3. **Fix every issue found** — edit the files directly
4. **Re-review the fixes** — loop until zero issues
5. **Build** — run `make build` to confirm compilation
6. **Report** — show a summary table: found | fixed | deferred
7. **Only then** tell the user it's ready to commit and push

## Review Checklist

### 1. Safety & Correctness (CRITICAL — these block merge)

- [ ] **No force-unwraps in production code**: Never `try!`, `as!`, or `!` force-unwrap outside tests. Use `guard let` / `if let` / `try?`.
- [ ] **No force-unwraps in tests either**: Use `throws` on test methods + `try`, not `try!`. (PR #188, #95)
- [ ] **Weak self in escaping closures**: Any `Task { }`, completion handler, or `sink { }` that outlives the call must capture `[weak self]`. Retain cycles are the #1 silent bug. (PR #91)
- [ ] **Cancel/stop races**: If an async operation can outlive `stop()`, guard with an epoch counter or check a cancelled flag before applying results. (PR #143 — "Both recovery paths can adopt a capture resource after stop() already finished")
- [ ] **Task cancellation honored**: Long-running async operations must check `Task.isCancelled` periodically. (PR #95)
- [ ] **No transcription pipeline changes**: Never modify `SpeakerDiarizer.diarize()` return type or `TranscriptionService` flow. Add new functionality as separate methods.

### 2. Data Integrity (MAJOR — CodeRabbit flags these consistently)

- [ ] **Input validation at boundaries**: Reject empty strings, nil, zero/negative counts, empty arrays at every public API entry point. (PR #95, #198)
- [ ] **Dimension safety**: Array index access on embeddings/centroids must guard equal dimensions. Never `min(a.count, b.count)` to silently truncate. (PR #198)
- [ ] **Duplicate name/ID guards**: Before renaming speakers, folders, or profiles — check if target exists. Reject or prompt, never silently merge. (PR #198, #171)
- [ ] **No stale data leaks**: Only assign speaker names/embeddings for speakers who actually spoke. Seeded pool entries that never matched must not leak. (PR #198, #97)
- [ ] **Concurrent mutation safety**: If two code paths can write the same data (live transcription + batch re-diarize), one must read-modify-write, not clobber. (PR #154 — "merge pass results onto the live row instead of clobbering")
- [ ] **Preserve user edits across re-processing**: Re-transcription/re-diarization must carry forward user-assigned speaker names, not wipe them. (PR #154)
- [ ] **isConfigured means ready**: Feature gates must check "enabled AND dependencies ready", never just "enabled". (CLAUDE.md)
- [ ] **Handle Application Support creation**: The Mila directory may not exist on clean install. Create with `withIntermediateDirectories: true` before first write. (PR #187, #198)

### 3. Privacy & Security (Uri cares deeply about these)

- [ ] **Privacy logging**: No bare `print()` with user names, file paths, or PII. Use `os.Logger` with `privacy: .private` for names, `.public` for counts/status. (PR #192, #198)
- [ ] **Biometric data opt-in**: Voice profiles / embeddings must be gated on an explicit user toggle (OFF by default). (PR #97 — Uri's comment)
- [ ] **Delete path exists**: Any persistent user data must have a clear deletion mechanism — individual + bulk. (PR #97 — Uri's comment)
- [ ] **Excluded from diagnostics**: Sensitive data (embeddings, speaker names, transcripts) must NOT appear in `DiagnosticReporter` output. Check `scrubbedDict`. (PR #97 — Uri's comment)
- [ ] **No secrets in examples**: API keys, tokens in docs/examples must be obvious placeholders. (PR #105)
- [ ] **Security-scoped resources released**: If using security-scoped bookmarks (vault URLs, etc.), release access in `deinit`. (PR #164)

### 4. Swift Conventions (CodeRabbit auto-flags these)

- [ ] **`deinit` on every class**: Explicit `deinit {}` required (SwiftLint `required_deinit` rule). (PR #88, #198)
- [ ] **`@StateObject` construction**: Declare without inline default, assign via `_x = StateObject(wrappedValue:)` in `init()`. (PR #88, #133, #198)
- [ ] **`@MainActor` consistency**: Classes with `@Published` that drive UI must be `@MainActor`. LLM-facing types that call CLI tools need it too. (PR #95)
- [ ] **Sendable compliance**: All `@Published` types must be `Sendable`.
- [ ] **Move heavy work off MainActor**: File I/O, subprocess calls, WAV repairs — use `Task.detached(priority:)` for blocking work. (PR #115, #198)

### 5. UI & Accessibility

- [ ] **Accessibility identifiers**: New interactive elements (TextField, Button, Toggle) need `.accessibilityIdentifier()` for XCUITest. (PR #88, #198)
- [ ] **No stale @State**: State in views that can be navigated away from — will it survive? If critical, move to a store/ObservableObject. (Previous learning)
- [ ] **SRT sidecar regeneration**: When mutating `segments[*].speaker` or `speakerNames`, call `TranscriptExporter.writeSRT` for completed recordings. (PR #198 Copilot)

### 6. Python Subprocess Integration

- [ ] **Pipe drain before waitUntilExit**: Both stdout and stderr must be read concurrently via `Task.detached` BEFORE `process.waitUntilExit()`. macOS pipe buffers are ~64KB. (CLAUDE.md)
- [ ] **Shared Python patches**: speechbrain LazyModule patch + torch.load patch must be in every inline Python script. If adding a new script, extract to a shared constant. (PR #198)
- [ ] **Null device for unread pipes**: Assign `FileHandle.nullDevice` to pipes nobody reads — an unread `Pipe()` deadlocks past 64KB. (CLAUDE.md)

### 7. Architecture & Process (Uri's preferences from PR history)

- [ ] **Small focused PRs**: If touching >10 files, consider splitting. Uri sequences features across beta cycles. (PR #97 — "slated for the next beta, not the current one")
- [ ] **Rebase before review**: Branch must be on current `main`. Uri explicitly requests this. (PR #97, #124, #154)
- [ ] **Link to issues**: Bug fixes must reference `Closes #N`. Features reference the issue they implement. (`.claude/rules/pull-requests.md`)
- [ ] **Respond to every review comment**: Fix with "Fixed in [commit]" or explain disagreement. Never leave comments unanswered. (PR #97 — "none have a reply yet")
- [ ] **CI must be green**: Uri checks CodeRabbit review + CI before merge. Trigger `@coderabbitai review` if the auto-review was rate-limited. (PR #154, #164, #187)
- [ ] **Additive only**: New fields must default to empty/nil so existing data decodes correctly. Never break backward compat.
- [ ] **Version bumps only in project.yml**: Never hardcode in Info.plist.

### 8. Testing

- [ ] **Unit tests for new logic**: Follow existing patterns — isolated `UserDefaults(suiteName:)`, temp directories for file tests. (PR #187, #198)
- [ ] **Await background work in tests**: If the code kicks off detached tasks (compression, diarization), tests must join them before asserting. (PR #154)
- [ ] **Stable locale in process-dependent tests**: Git/subprocess output depends on locale. Set `LC_ALL=C` or equivalent. (PR #164)

## Severity Guide

When reporting, use these labels:
- 🔴 **CRITICAL** — Will definitely block merge (crashes, data corruption, security)
- 🟠 **MAJOR** — CodeRabbit will flag, maintainer will request fix
- 🟡 **MINOR** — Good to fix, but won't block merge alone
- 🔵 **TRIVIAL** — Style/convention, fix if easy

## Learning

After each CodeRabbit review on a PR, update this checklist:
1. Read the new findings
2. Add any NEW patterns not already covered (with the PR number)
3. Remove patterns that are no longer relevant
4. This file is the single source of truth for what to check before pushing
