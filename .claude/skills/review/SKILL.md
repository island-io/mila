---
name: review
description: Pre-push code review that catches CodeRabbit/Copilot/maintainer issues before submitting. Run with /review before pushing. Loops fix→review until clean. Learns from past PR feedback.
---

# Pre-Push Code Review

## Overview

Review all staged/unstaged changes against the project's code quality standards, CodeRabbit patterns, and maintainer (Uri) preferences BEFORE pushing. Fix issues automatically, then re-review until clean.

## How to run

The user invokes `/review`. You then:

1. **Collect the diff** — `git diff HEAD` (unstaged) + `git diff --cached` (staged) + any new files
2. **Review against ALL checklists below** — every item, no skipping
3. **Fix every issue found** — edit the files directly
4. **Re-review the fixes** — loop until zero issues
5. **Report** — show a summary of what was found and fixed
6. **Build** — run `make build` to confirm it compiles
7. **Only then** tell the user it's ready to commit and push

## Review Checklist

### Swift Code Quality (CodeRabbit patterns)

- [ ] **Privacy logging**: No bare `print()` with user-assigned names, file paths, or PII. Use `os.Logger` with `privacy: .private` for names, `.public` for counts/status.
- [ ] **Input validation**: All public API entry points validate inputs — reject empty strings, nil, zero/negative counts, empty arrays. Guard at the boundary, not deep inside.
- [ ] **Dimension safety**: Any array index access on embeddings/centroids must guard equal dimensions first. Never use `min(a.count, b.count)` to silently truncate — reject with a log instead.
- [ ] **`deinit` convention**: Every `class` must have an explicit `deinit {}` (project uses SwiftLint `required_deinit` rule).
- [ ] **`@StateObject` pattern**: Declare without inline default, assign via `_x = StateObject(wrappedValue:)` in `init()`. Never `@StateObject private var x = X()` in MilaApp.
- [ ] **Directory creation**: Before writing any file, ensure the parent directory exists (`createDirectory(withIntermediateDirectories: true)`). Clean install has no `~/Library/Application Support/Mila/`.
- [ ] **Duplicate name guards**: Before renaming speakers, folders, or profiles — check if the target name already exists. Reject or prompt, never silently merge.
- [ ] **SRT regeneration**: When mutating `segments[*].speaker` or `speakerNames`, regenerate the `.srt` sidecar for completed recordings (call `TranscriptExporter.writeSRT`).
- [ ] **Data leak prevention**: Only assign speaker names/embeddings for speakers who actually spoke — check `diarizer.intervals`. Seeded pool entries that never matched must not leak into recordings.
- [ ] **Biometric consent**: Voice profiles must be opt-in (gated on `enabled` toggle). Never create profiles automatically without user action.
- [ ] **`try!` in tests**: Use `throws` on test methods + `try`, never `try!`.
- [ ] **Sendable compliance**: All `@Published` types must be `Sendable`.
- [ ] **Retain cycles**: Use `[weak self]` in escaping closures that outlive the call.

### Architecture (Mila conventions from CLAUDE.md)

- [ ] **Never modify the transcription pipeline**: Do not change `SpeakerDiarizer.diarize()` return type or `TranscriptionService` transcription flow. Add new functionality as separate methods.
- [ ] **Environment objects**: New app-wide settings must be instantiated in `MilaApp.init()`, injected via `.environmentObject()` on BOTH the main window AND the Settings scene.
- [ ] **Python subprocess safety**: Drain both pipes concurrently BEFORE `waitUntilExit()`. Use `Task.detached` to read pipes.
- [ ] **Feature gates**: `isConfigured` must mean "enabled AND ready to use" — never just "enabled".
- [ ] **Settings persistence**: Use namespaced UserDefaults keys (e.g., `"voiceRecognition.enabled"`).
- [ ] **Build system**: Edit `project.yml`, never `.xcodeproj`. Version bumps only in `project.yml`.

### Maintainer Preferences (learned from Uri's reviews)

- [ ] **Sequencing over scope**: Uri prefers small, focused PRs over large ones. If a change touches >10 files, consider splitting.
- [ ] **Privacy-first**: Any new data storage (especially biometric) must answer: Is it opt-in? Is there a delete path? Is it excluded from diagnostics?
- [ ] **Unit tests required**: New logic needs tests. Follow existing test patterns — isolated `UserDefaults` suite, temp directories for file tests.
- [ ] **Every fix PR links to an issue**: Bug fixes must reference `Closes #N`. Features should reference the issue they implement.
- [ ] **Don't break existing behavior**: Additive changes only. New fields must default to empty/nil so existing recordings decode correctly.
- [ ] **Comment style**: Match the codebase — doc comments explain WHY, not WHAT. Comments in `//` for inline, `///` for API docs.

### Common CodeRabbit Findings (from past PRs)

- [ ] **Persistence payload growth**: Adding fields to `Recording` (which is fully serialized on every mutation) — note if the field is large (embeddings). Consider if it should be in a sidecar file instead.
- [ ] **Python script duplication**: If adding a new inline Python script, extract shared patches (speechbrain LazyModule, torch.load) into a constant.
- [ ] **Accessibility identifiers**: New interactive UI elements (TextFields, Buttons, Toggles) should have `.accessibilityIdentifier()` for XCUITest.
- [ ] **No stale UI state**: `@State` in views that can be navigated away from and back — will the state survive? If it needs to, move to a store/observable.

## Learning

After each CodeRabbit review on a PR, update this checklist:
1. Read the new findings
2. Add any NEW patterns not already covered
3. Remove patterns that are no longer relevant

This file is the single source of truth for what to check before pushing.
