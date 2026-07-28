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
  - `Packages/MilaKit/` — zero-dependency Swift package shared by the app and the `mila-mcp` helper: TranscriptFormatter, the read-only `StoredRecording` mirror of recordings.json, `MilaStoreReader`, the live-transcript snapshot schema, and the MCP tool handlers
  - `MilaMCP/` — the `mila-mcp` executable (MCP stdio server over Mila's transcriptions), embedded at `Mila.app/Contents/MacOS/mila-mcp`; see `docs/mcp.md`
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

### MCP server (mila-mcp) and MilaKit
- The app persists two cross-process contracts for the embedded MCP helper: `store-location.json` (written by `RecordingStore` on init + relocate — where recordings.json currently lives) and `live/current.json` (the live-transcript sidecar written during recording by `LiveTranscriptSidecarWriter`). Both live at the DEFAULT app-support root and deliberately do not travel with a relocated recordings folder.
- **Any change to what `Recording.encode(to:)` writes into recordings.json must be mirrored in MilaKit's `StoredRecording`** — `StoredRecordingDriftTests` in MilaTests is the tripwire. Keep `StoredRecording` decoding lenient (`decodeIfPresent` + defaults) so an older helper survives a newer app's schema.
- MilaKit must stay dependency-free (in particular: no TranscriptionCore) — it links into `mila-mcp`, which must not drag in the whisper xcframework. Tool logic lives in `MilaMCPToolHandlers` (pure JSON), not in the executable.

### Tests
- `TranscriptionService` now requires a `diarizationSettings:` parameter. In tests, always pass `DiarizationSettings(defaults: .init(suiteName: "TestClassName.diarization")!)` to isolate from user defaults.
- Run tests with `make test` or via Xcode. Package tests: `make package-test` (TranscriptionCore + MilaKit).

## Release Process
- **Release notes are REQUIRED, first.** Every release must add
  `RELEASE_NOTES/v<MARKETING_VERSION>.md` (Markdown, user-facing). This file
  becomes the Sparkle appcast `<description>` — i.e. the in-app "What's New"
  popup users see on update. Without it that popup is blank ("a new version is
  available" with no changelog). The signing pipeline runs
  `scripts/check-release-notes.sh <version>` **before building** and FAILS the
  release if the file is missing/empty/boilerplate, so this can't be skipped.
  Do NOT rely on the `project.yml` changelog comment or the GitHub Release body —
  neither feeds the appcast. See `RELEASE_NOTES/README.md`.
- Version is bumped only in `project.yml` (`MARKETING_VERSION` +
  `CURRENT_PROJECT_VERSION`). `Info.plist` inherits both via
  `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` — never hardcode
  literals there.
- Tags are `v`-prefixed: `v1.2.8`. `CURRENT_PROJECT_VERSION` (the build
  number) must increase monotonically — Sparkle keys updates on it.
- A local DMG for testing: `make dmg VERSION=<x.y.z>` (the explicit
  `VERSION=` is required — see the build skill). It signs with the persistent
  "Mila Local Dev" cert when that cert exists in the login keychain (created
  by `scripts/install-debug.sh`; keeps TCC mic/recording grants across
  installs) and falls back to ad-hoc otherwise. To force an ad-hoc build —
  e.g. to test the Gatekeeper right-click → Open first-launch prompt — run
  `CODESIGN_IDENTITY=- make dmg VERSION=<x.y.z>`.
- Notarized, signed release builds and Sparkle appcast publishing are produced
  by a separate, private signing pipeline maintained by the original authors;
  that toolchain is not part of this repository. Forks that want notarized
  builds should sign with their own Apple Developer ID and publish their own
  appcast (see `SUFeedURL` / `SUPublicEDKey` in `project.yml`).
