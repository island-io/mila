# Mila

A native macOS app that records, dictates, and transcribes locally on your Mac
— no audio leaves the device. Hebrew transcription is powered by the
[ivrit.ai `large-v3` finetune](https://huggingface.co/ivrit-ai/whisper-large-v3-ggml)
of Whisper, English by
[OpenAI's `large-v3-turbo`](https://huggingface.co/ggerganov/whisper.cpp), both
running through `whisper.cpp` (GPU via Metal).

**Download:** [island-io.github.io/mila](https://island-io.github.io/mila/)

## Features

- **Record from the microphone** at any time.
- **Record system audio** from a single app (Zoom, Google Meet in Chrome,
  Slack, etc.) via `ScreenCaptureKit` — no virtual audio device required.
- **Record meetings** = mic + system audio mixed into one mono 16 kHz WAV file.
- **Dictate in two languages** with separate global hotkeys:
    - `⌘2` — English dictation (OpenAI `large-v3-turbo`)
    - `⌘3` — Hebrew dictation (ivrit.ai `large-v3`)
  Both hotkeys are user-configurable in **Settings → General**.
- **Transcribe on-device** with ivrit.ai `large-v3` (Hebrew) or OpenAI
  `large-v3-turbo` (English / multilingual). Audio never leaves your Mac.
- **Transcribe on a remote server** — point Mila at any OpenAI-compatible
  `/v1/audio/transcriptions` endpoint (OpenAI's hosted Whisper API, or a
  self-hosted server) via **Settings → Models → Backend**. Useful on
  lower-powered Macs or when you want a Hebrew model too large to run locally.
  See [Setting up a remote transcription server](#remote-transcription-optional).
- **Speaker diarization** — identifies who said what, displayed as color-coded
  per-speaker labels. **Name your speakers**: rename labels to real names from
  a persistent directory that's reused across recordings.
- **AI summaries and titles** — after each recording, Mila shells out to a
  local Claude/Cursor/OpenAI-compatible CLI to auto-name the recording and
  generate an AI overview. Point Mila at a provider once in
  **Settings → AI Provider**, then turn features on and edit their prompts in
  **Settings → AI Features** (which also hosts Live AI mode).
- **iPhone Voice Memos sync** — Mila watches the folders iCloud syncs from your
  iPhone and auto-transcribes new recordings. Set up in **Settings → Voice Memos**.
- **One-click team setup with `.milaconfig` files** — double-click a config file
  to apply the transcription server, model, language, and more in one step.
  Perfect for handing a team a ready-made configuration.
- **Organization-wide settings via MDM** — the same settings a `.milaconfig`
  carries can be pushed as a configuration profile (Jamf, Kandji, Intune, …)
  and are then locked for every user ("Managed by your organization"), e.g. to
  put a whole company on one transcription server. Managed settings win over a
  `.milaconfig`, which wins over the user's own choice. See
  [`docs/mdm.md`](docs/mdm.md).
- **Share a recording with a colleague** — right-click → **Share Recording…**
  produces a single `.milashare` file (audio + transcript + speaker names +
  summary + action items, optionally the speakers' voice profiles). They
  double-click it and it arrives in their library tagged "Shared by …";
  re-sharing an updated transcript updates their copy instead of duplicating
  it. See [`docs/sharing.md`](docs/sharing.md).
- **Transcription queue** — view queued, in-progress, and recently-deleted jobs;
  stop or remove any item from the queue at any time.
- **SRT export** (including mid-recording), per-segment timestamps, click to seek,
  copy/share transcript, RTL rendering for Hebrew.
- **Auto-discard accidental clips** — very short recordings with no speech are
  dropped automatically (threshold configurable in **Settings → Storage**).
- **Opt into pre-release builds** via **Settings → General → Updates**.

## Changelog

- Automatic meeting recording cancels pending countdowns and startup when the
  screen locks. Unlocking requires a fresh countdown before recording can start.

## System requirements

To **run** Mila:

- **macOS 14 (Sonoma) or later.**
- **Apple Silicon (M-series) strongly recommended.** Transcription runs on the
  Metal GPU (`whisper.cpp`) and speaker diarization on MPS/CPU (pyannote). Intel
  Macs fall back to CPU and are much slower.
- **Disk:** ~4.6 GB for the two default Whisper models, downloaded on first
  launch (ivrit.ai `large-v3` ~3.0 GB + OpenAI `large-v3-turbo` ~1.6 GB). Add
  ~1 GB more if you enable speaker diarization (bundled Python runtime plus a
  torch download on first enable).
- **Memory (approximate):** 16 GB unified memory recommended. 8 GB is workable
  for plain transcription but tight with diarization. Rough working set: Hebrew
  `large-v3` ~3.5–4 GB, English `large-v3-turbo` ~1.5–2 GB, speaker diarization
  adds ~1–2 GB. (RAM figures are approximate guidance, not a hard spec.)
- **Live (real-time) mode** — running transcription and diarization concurrently
  in real time is the heaviest path. It's **automatically disabled on MacBook
  Air–class chips** (they can't keep up in real time) and recommended on M-series
  Pro/Max, or M2 and newer. Recording plus after-the-fact transcription still
  works on Air.

To **build** Mila:

- Xcode 15.3 or newer (Command Line Tools alone are not enough).
- Homebrew (used to install [`xcodegen`](https://github.com/yonaskolb/XcodeGen)).

## Build & run

From the project root:

```bash
make bootstrap   # one time: installs xcodegen via brew if missing
make project     # generates Mila.xcodeproj from project.yml
make open        # opens Xcode
```

Or do it all from the CLI:

```bash
make run
```

The first build will resolve `Packages/WhisperBinary`, which downloads the
`whisper.xcframework` (~65 MB) from the official `ggml-org/whisper.cpp` v1.8.4
release. The checksum is pinned in `Packages/WhisperBinary/Package.swift`.

## Models

On first launch the app downloads both default models in the background:

- `ivrit-ai/whisper-large-v3-ggml` — Hebrew (~3.0 GB). Empirically more
  accurate on Hebrew speech than the smaller `large-v3-turbo` finetune,
  which is why we ship the larger one despite the size and ~2× inference
  cost.
- `openai whisper-large-v3-turbo` (the `ggerganov/whisper.cpp` build) —
  English / multilingual (~1.6 GB).

You can monitor progress in the in-app banner or pre-download from the CLI:

```bash
make models
```

Models live at:

```
~/Library/Application Support/Mila/Models/
    ivrit-ai-whisper-large-v3.bin
    openai-whisper-large-v3-turbo.bin
```

The app picks them up from that directory automatically.

### Remote transcription (optional)

By default Mila transcribes entirely on-device — audio never leaves your Mac.
If you'd rather offload transcription (e.g. on a low-powered Mac, or to use a
Hebrew-tuned model that's too large to run locally), **Settings → Models** lets
you switch the backend to any OpenAI-compatible `/v1/audio/transcriptions`
endpoint: OpenAI's own Whisper API, or a self-hosted server. The API key is
stored in your Keychain, and the UI flags that audio leaves the device while
this backend is active.

To run [ivrit.ai](https://www.ivrit.ai/)'s Hebrew models (or any other Whisper
model) behind this API on your own machine, see
**[docs/REMOTE_TRANSCRIPTION_SERVER.md](docs/REMOTE_TRANSCRIPTION_SERVER.md)**.

To deploy a **shared team server** on Kubernetes (one GPU, many users — Mila
points at it via the Remote backend, audio stays on infrastructure you control),
see **[docs/self-hosted-server/](docs/self-hosted-server/)**. That folder
contains Kubernetes manifests and a step-by-step guide, plus an
`example.milaconfig` you can hand to teammates for one-click setup. To lock
every Mac in your organization to that server instead, push the same settings
as a configuration profile — see **[docs/mdm.md](docs/mdm.md)**.

## Required permissions

On first use macOS will prompt for the following — all are required for the
relevant feature to work:

| Feature                   | System Settings panel                     |
|---------------------------|-------------------------------------------|
| Microphone recording      | Privacy & Security → Microphone           |
| System / app audio        | Privacy & Security → Screen Recording     |
| Dictation paste-at-cursor | Privacy & Security → Accessibility        |

## How meeting capture works

`ScreenCaptureKit` allows audio capture per-application. When you pick *Zoom*
in the **New recording** sheet, only Zoom's audio output is captured (not your
own mic; not other apps). The mic is captured separately via `AVAudioEngine`
and the two streams are downmixed (averaged) into a single mono 16 kHz WAV file
that's fed into Whisper. SCK requires a video stream to function, so a 2×2
placeholder is configured and discarded.

## Project layout

```
Mila/
├── App/MilaApp.swift          # SwiftUI @main entry + AppDelegate
├── Actions/                   # LLM action runner (title, summary, send-to-LLM)
├── Audio/
│   ├── AudioUtilities.swift            # Conversion to 16k mono Float32
│   ├── MicrophoneRecorder.swift        # AVAudioEngine input tap
│   ├── SystemAudioRecorder.swift       # ScreenCaptureKit per-app audio
│   └── RecordingSession.swift          # Mix mic + system → WAV
├── Transcription/
│   ├── ModelManager.swift              # Download / select ggml models
│   ├── TranscriptionService.swift      # Orchestrates jobs + remote backend
│   └── SpeakerDiarizer.swift           # pyannote.audio via bundled Python
├── Dictation/
│   ├── HotkeyManager.swift             # Carbon global hotkeys (multi-binding)
│   └── DictationController.swift       # Mic → Whisper → paste
├── VoiceMemos/                         # iPhone Voice Memos import + iCloud watcher
├── Views/                              # SwiftUI screens incl. Settings
├── Models/Recording*.swift             # Persisted recording metadata
└── Resources/
    ├── Info.plist
    ├── Mila.entitlements
    └── DiarizationModels/              # Bundled pyannote model weights (~31 MB)
Packages/
├── TranscriptionCore/                  # Cross-platform Swift package (whisper.cpp bindings, WAVReader)
└── WhisperBinary/                      # SPM wrapper for whisper.cpp xcframework
docs/
├── REMOTE_TRANSCRIPTION_SERVER.md      # Single-host Docker quickstart
├── mdm.md                              # Managing settings with MDM / configuration profiles
├── example.mobileconfig                # Example profile for docs/mdm.md
└── self-hosted-server/                 # Shared team server on Kubernetes (K8s manifests + guide)
docker/speaches-hebrew/                 # Docker image with ivrit.ai Hebrew model pre-loaded
scripts/make-dmg.sh                     # Builds a release DMG for distribution
```

## Building a release DMG

```bash
# 1. Bump MARKETING_VERSION + CURRENT_PROJECT_VERSION in project.yml
# 2. make dmg                       # builds an ad-hoc-signed Mila-<version>.dmg
```

`make dmg` produces an **ad-hoc-signed** DMG suitable for local testing and
self-distribution. macOS Gatekeeper will show the standard prompt on first
launch (right-click → Open). To ship a notarized build, sign the app with your
own Apple Developer ID and run it through Apple's `notarytool` — see the code
signing notes below.

## Code signing notes

`project.yml` sets `CODE_SIGN_IDENTITY: "-"` (ad-hoc) and disables sandbox so
the dev build can use `ScreenCaptureKit` without provisioning. For
distribution via the App Store you'd:

- Re-enable `com.apple.security.app-sandbox`
- Add the appropriate entitlements (`com.apple.security.device.screen-recording`,
  `com.apple.security.network.client`, etc.)
- Provide your team ID in `DEVELOPMENT_TEAM`.

## License

Mila is licensed under the [Apache License 2.0](./LICENSE). See [`NOTICE`](./NOTICE)
for required attribution.

Originally developed by Uri Harduf at Island Technology, Inc.

## Credits

- [ivrit.ai](https://www.ivrit.ai) for the Hebrew Whisper finetunes.
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (MIT) for the local inference.
- [OpenAI Whisper](https://github.com/openai/whisper) for the English model
  weights (re-packaged as ggml by `ggerganov/whisper.cpp`).
- [Sparkle](https://github.com/sparkle-project/Sparkle) (MIT) for auto-updates.
