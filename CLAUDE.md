# Mila

A macOS (Swift/SwiftUI) local transcription app built on whisper.cpp, with optional speaker diarization via pyannote.audio.

## Architecture

- **Build system:** XcodeGen (`project.yml` is the source of truth, not the .xcodeproj)
- **Minimum deployment target:** macOS 14.0, Swift 5.10
- **Key dependencies:** TranscriptionCore (local Swift package wrapping whisper.cpp), Sparkle (auto-updates)
- **Project layout:**
  - `Mila/Models/` — data models and settings (`Recording`, `DiarizationSettings`, etc.)
  - `Mila/Transcription/` — transcription engine, speaker diarizer, exporter
  - `Mila/Views/` — SwiftUI views (ContentView, SettingsView, SidebarView, etc.)
  - `Mila/Resources/` — Info.plist, entitlements, bundled diarization models
  - `Mila/Resources/DiarizationModels/` — bundled pyannote speaker diarization model weights (~31 MB)
  - `MilaTests/` — unit tests
  - `Packages/TranscriptionCore/` — cross-platform Swift package: WhisperEngine (whisper.cpp bindings), WAVReader, WER calculator, and E2E transcription test fixtures
  - `scripts/` — release/build scripts (make-dmg.sh, etc.)

## Conventions

### Environment Objects
New app-wide settings (like `DiarizationSettings`) must be:
1. Instantiated in `MilaApp.init()` as a `@StateObject`
2. Injected via `.environmentObject()` on both the main window and the Settings scene
3. Accepted in tests via a custom `UserDefaults` suite (not `.standard`) to avoid polluting state

### Python Subprocess Integration
When calling Python ML pipelines from Swift via `Process`:
- Use inline Python scripts via `-c` argument (not bundled .py files) for the main pipeline -- this avoids path-resolution issues with app bundles
- Always separate stdout (JSON data) from stderr (diagnostic logs) -- pyannote and torch emit warnings to stderr that corrupt JSON parsing
- **Drain both pipes concurrently BEFORE `waitUntilExit()`** -- macOS pipe buffers are ~64 KB; if the subprocess fills a pipe before the parent reads, both sides deadlock. Use `Task.detached` to read pipes, then await after `waitUntilExit()`. See `.claude/rules/python-subprocess.md` for the correct pattern.
- Run Python processes on `Task.detached(priority: .userInitiated)` to avoid blocking the main actor
- Diarization models are bundled in the app (no HuggingFace token needed). The inline script receives the bundle models path as a CLI argument and loads the pipeline from a local config.yaml with `Pipeline.from_pretrained()`
- **Bundled model directory names must preserve the original HuggingFace model ID structure.** pyannote dispatches embedding backends via substring matching on the path (e.g., `"pyannote"` -> torch, `"wespeaker"` -> ONNX). See `.claude/rules/python-subprocess.md` for details.

### Python / PyTorch Compatibility Patches
The pyannote.audio + speechbrain stack requires two runtime monkey-patches (applied in the inline script):
1. **torch.load `weights_only` patch:** PyTorch >= 2.6 changed the default to `True`, breaking pyannote's checkpoint loading. Patch `torch.load` to force `weights_only=False`.
2. **speechbrain LazyModule patch:** pytorch_lightning stack inspection triggers speechbrain's lazy imports for optional packages (k2_fsa, nlp, huggingface.wordemb). Patch `LazyModule.ensure_module` to return a dummy module instead of raising `ImportError`.

These patches live in `SpeakerDiarizer.swift`'s inline diarize script. If upgrading pyannote.audio or speechbrain, check if these patches are still needed.

### Settings Persistence with UserDefaults
- Use namespaced keys: `"diarization.enabled"`, `"diarization.pythonPath"`, etc.
- For verification/setup state that should survive app restarts, persist a `verified` flag alongside the verified parameter values (path). On launch, restore only if current values match the persisted ones.
- Computed `status` properties must check `verificationStatus` before `lastVerifyResult` -- the persisted verified state should take precedence over nil in-memory verify results on launch.

### Tests
- `TranscriptionService` now requires a `diarizationSettings:` parameter. In tests, always pass `DiarizationSettings(defaults: .init(suiteName: "TestClassName.diarization")!)` to isolate from user defaults.
- Run tests with `make test` or via Xcode.

## Release Process
Releases are cut via the **`mila-sign-and-notarize` Jenkins job** on
`jenkins.island.io` — **Island employees only**, and only reachable on the
Island VPN (it is NOT reachable from outside the corp network, so it can't be
triggered/inspected from a plain dev environment). The job builds a Release
`Mila.app`, re-signs it with the Island **Developer ID Application** identity,
notarizes via Apple `notarytool`, staples, and archives `Mila-<version>.dmg`.
Trigger it manually from the Jenkins UI with params: `gitRef` (branch/tag/SHA,
default `main`), `skipNotarize` (sign-only for fast iteration), and
`sharedLibraryRef`. Pipeline + script live in `jenkins/sign-and-notarize.Jenkinsfile`
and `scripts/sign-and-notarize.sh`. See `.cursor/rules/release.mdc` for the SOP.

Key points:
- Version is bumped only in `project.yml` (`MARKETING_VERSION` + `CURRENT_PROJECT_VERSION`).
- Tags are `v`-prefixed: `v1.2.8`.
- The old GitHub Actions release workflow (`release.yml`) was **removed** —
  release/build-for-release no longer lives in `.github/workflows` (CI/e2e
  workflows stay). Do not re-add a GitHub release workflow.
- The Jenkins job notarizes + archives the DMG but does **not yet** upload to
  the `island-whisper-updates` S3 bucket or update the Sparkle appcast — so
  Sparkle auto-updates are not published by it. Enabling that needs the
  `mac-builder` IAM principal granted S3 write on `island-whisper-updates` in
  the infrastructure repo's `environments/prod/zero-abstraction/iam/policies/jenkins-worker-policy.json`
  (mirroring infra PR #7888, which granted read on `island-browser-releases`).
