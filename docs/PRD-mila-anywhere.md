# PRD — "Mila Anywhere": Flexible Backends, Mobile Capture, and Knowledge-Base Destinations

**Status:** Draft for review
**Author:** (you)
**Date:** 2026-07-15
**Related docs:** `docs/REMOTE_TRANSCRIPTION_SERVER.md`, `docker/speaches-hebrew/README.md`, `CLAUDE.md`

> This is a **draft PRD written to be argued with**. Every section that
> depends on a decision you haven't made yet is marked with **[OPEN
> QUESTION]**. Nothing here is committed until we resolve the questions in
> §10 and agree on phasing (§9). Do not treat this as a build spec yet.

---

## 1. Summary

Mila today is a **macOS-only** local-first transcription app. It records
(mic / system audio / meetings), transcribes with `whisper.cpp` (ivrit.ai
Hebrew + OpenAI English), optionally diarizes, and can summarize via a local
LLM CLI (`claude` / `cursor-agent`). It **already** supports offloading
transcription to any OpenAI-compatible `/v1/audio/transcriptions` endpoint
(`TranscriptionBackend.remote`), and ships a Docker image
(`docker/speaches-hebrew`) that serves ivrit.ai Hebrew behind that protocol.

This PRD proposes four new capabilities:

1. **First-class dual-mode transcription** — make "run fully local" vs "run
   fully on my own cloud/remote server (ivrit.ai + Whisper)" a deliberate,
   well-documented product surface rather than a Settings toggle. *(Largely
   built on macOS already; this is mostly hardening, packaging, and mobile
   parity.)*
2. **Simple mobile capture apps (iOS + Android)** — record audio on a phone
   and send it for transcription, targeting **either** a cloud server **or**
   the user's own Mac/home server that is **securely exposed to the
   internet**.
3. **Post-transcription destinations** — after a transcript exists, route it
   to **NotebookLM** (upload) or a **local Obsidian vault** (Markdown note).
4. **Gemini CLI support** — add Google's `gemini` CLI as a third option
   alongside `claude` and `cursor-agent` for naming/summary/actions.

The through-line: **Mila becomes a small ecosystem** (capture clients + a
transcription backend you choose + knowledge-base sinks), while keeping the
existing privacy-first, local-only path fully intact as the default.

---

## 2. Goals & non-goals

### Goals

- G1. A user can flip Mila (desktop and mobile) between **100% on-device** and
  **100% on a remote server they control**, with the privacy trade-off made
  explicit in the UI.
- G2. A user can record on their **phone** and get a transcript back, sending
  audio to either a cloud endpoint or their **own Mac exposed securely**.
- G3. After any transcript is produced, the user can **push it to NotebookLM
  or an Obsidian vault** with minimal friction.
- G4. `gemini` joins `claude`/`cursor-agent` as a supported LLM CLI on desktop.
- G5. The existing macOS local-only experience is **unchanged by default** —
  no regression, no new mandatory network/account dependency.

### Non-goals (this round)

- NG1. A hosted, Mila-operated multi-tenant SaaS with sign-up/billing. The
  "cloud" here is **the user's own server**, not a service we run. **[OPEN
  QUESTION Q1 — confirm.]**
- NG2. On-device transcription **on mobile** (running whisper.cpp on the
  phone). The mobile app is "record & send", per your description. **[OPEN
  QUESTION Q4.]**
- NG3. Real-time / live transcription on mobile.
- NG4. Editing/organizing the full recording library on mobile (mobile is a
  capture + view-result client, not a full port of the desktop UI).
- NG5. Windows/Linux desktop clients.

---

## 3. Users & top scenarios

- **U1 — The privacy maximalist.** Runs everything on-device on an M-series
  Mac. Never wants audio to leave hardware they own. (Today's default; must
  stay intact.)
- **U2 — The self-hoster.** Runs the ivrit.ai/Whisper server on a home box or
  a VPS they control, exposes it securely, and points both the Mac and their
  phone at it. Wants Hebrew accuracy without a beefy laptop.
- **U3 — The mobile capturer.** Out and about, opens the phone app, records a
  meeting/voice note, and it lands transcribed — then flows into their
  Obsidian vault or a NotebookLM notebook for later synthesis.
- **U4 — The knowledge worker.** Lives in Obsidian and/or NotebookLM; wants
  every transcript to auto-file into their existing knowledge base.

Primary flow (U3 → U4) — refined per the folder-sync + Drive-hand-off model:

```
PHONE (iOS/Android)
  [record] → [save into chosen local folder]
  [periodic sync tick] → find untranscribed recordings
     → batch-upload audio to cloud transcription (ASYNC job)
        ... cloud transcribes as a batch, out of band ...
     ← transcript result arrives → attach to the recording in the app
  [option] → save transcript as a NEW Google Drive file

MAC (Mila desktop) — the destination hub
  [track transcription files in Google Drive]
     → for each new transcript file
        → fan out to configured destinations
           (Obsidian vault | NotebookLM | … whatever is enabled in Mila)
```

Google Drive is the **sync / hand-off layer** between phone and Mac; the Mac
app is the **router** that turns tracked Drive transcripts into knowledge-base
entries.

---

## 4. Current-state review (what already exists — reuse, don't rebuild)

Grounding the plan in the existing design (per project workflow rules):

- **Remote transcription backend already exists.**
  `Mila/Models/RemoteTranscriptionSettings.swift` +
  `Mila/Transcription/RemoteWhisperEngine.swift` implement
  `TranscriptionBackend.local | .remote`, talking to any OpenAI-compatible
  `/v1/audio/transcriptions` endpoint, with the API key in Keychain and a
  "Test connection" probe. **Capability G1 is ~80% done on desktop.** The new
  work is UX framing, docs, and porting the same client contract to mobile.
- **The server piece exists.** `docker/speaches-hebrew` serves
  `ivrit-ai/whisper-large-v3-turbo-ct2` behind the OpenAI protocol. This is
  the reference "cloud/home server". The gap is **secure exposure + auth**,
  not the transcription server itself.
- **LLM CLI abstraction is a clean extension point.**
  `Mila/Actions/LLMSettings.swift` defines `enum LLMTool { none, claude,
  cursor }` and `arguments(prompt:model:session:)`. Adding `.gemini` is a
  small, well-bounded change (see §7.4). Verified invocation: `gemini -p
  "<prompt>"`, optional `-m <model>`, `--output-format text`.
- **Export today = SRT sidecars** (`Mila/Transcription/TranscriptExporter.swift`)
  and `.txt` / `.summary.txt` sidecars managed by `RecordingStore`. There is
  **no** concept of an external "destination" yet — NotebookLM/Obsidian is
  net-new (see §7.3).
- **Data model.** `Mila/Models/Recording.swift` carries everything a
  destination needs: `title`, `fullText`, `segments` (timestamps + speaker),
  `speakerNames`, `summary`, `actionItems`, `language`, `createdAt`.
- **No mobile targets exist.** `project.yml` has a single macOS `application`
  target. iOS/Android is greenfield (see §6, §8).
- **Precedent for the Drive-tracking hub + idempotent import:** the Voice Memos
  importer (`Mila/VoiceMemos/`) already ingests iPhone recordings from a synced
  folder and dedups via a stable per-item ID (`voiceMemoUniqueID`). The same
  pattern applies to the Mac tracking transcript files in Drive (§7.1).

---

## 5. Capability 1 — Dual-mode (local / remote) transcription

### 5.1 What changes

- Promote the local-vs-remote choice to a clear, first-run-visible decision
  with three named presets:
  - **On-device (private)** — today's default. Audio never leaves the device.
  - **My server** — point at a self-hosted ivrit.ai/Whisper endpoint (home box
    or VPS). Requires endpoint URL + optional API key/token.
  - **Third-party API** — e.g. OpenAI Whisper. (Already supported.)
- Consistent privacy banner whenever audio leaves the device (already present
  on desktop; must be mirrored on mobile).
- **Shared transcription-client contract** so desktop and mobile speak to the
  same server the same way (multipart upload, `verbose_json`, language hint).

### 5.2 Open items

- **[Q2]** Does "run fully on cloud" mean strictly the **transcription
  server**, or do you also want the LLM/summary + destination routing to run
  server-side (so a thin phone client offloads *everything*)? This materially
  changes the mobile architecture (§7.2).
- **[Q3]** Diarization currently runs **locally** (reads on-disk audio via
  pyannote). On a remote/mobile path, do we (a) skip diarization, (b) require
  the server to diarize, or (c) rely on the server returning speaker labels if
  it supports them? Today's remote path silently loses diarization on mobile
  because there's no local pyannote.

---

## 6. Capability 2 — Mobile capture apps (iOS + Android)

### 6.1 Product shape (folder + async-batch-sync model)

A deliberately **simple** app on both platforms, built around a **watched
recordings folder** and a **periodic async sync**, not a synchronous
record-and-wait loop:

1. **Pick a recordings folder** (once, in setup). Every recording is saved
   there as a compact audio file (`.m4a`/AAC, mono 16 kHz — matches the
   desktop remote path). On iOS this is a security-scoped folder via the
   document picker (Files / iCloud Drive); on Android a Storage Access
   Framework tree URI.
2. One big **Record** button. Show elapsed time + level meter. On stop, write
   the audio file into the folder and mark it `untranscribed` in a small local
   index.
3. **Periodic sync tick** (configurable interval): find recordings in the
   folder that are `untranscribed` and **batch-upload** their audio to the
   cloud transcription service. This is an **async job submission**, not a
   blocking request — the app doesn't wait for the transcript inline.
4. **Result attach:** when a transcript for a submitted job becomes available
   (next tick / push), the app downloads it and **attaches it to the matching
   recording**, flipping its state to `transcribed`.
5. **Save to Drive (option):** for a transcribed recording, the user can save
   the transcript as a **new Google Drive file** (this is what the Mac app
   later tracks — see §7).
6. A minimal local history list of this device's recordings with per-item
   state (`untranscribed` / `uploading` / `processing` / `transcribed` /
   `failed`).

**Resolves Q2/Q4:** the phone does **capture + async transcription offload +
optional push-to-Drive** only. It runs **no** on-device model and does **no**
destination fan-out itself — routing to Obsidian/NotebookLM happens on the Mac
(§7). The phone's contract with the "cloud" is: submit audio → later, get text.

### 6.1a The async / batch transcription contract (new backend shape)

This is a **new requirement that the existing synchronous OpenAI-compatible
`/v1/audio/transcriptions` endpoint does not satisfy.** That endpoint is
request/response: one upload blocks until one transcript returns. A
**batch/async** model needs a **job protocol**:

```
POST  /jobs        (multipart audio [+ language])   → { job_id, status: queued }
GET   /jobs/{id}                                    → { status, transcript? }
      (optional) webhook/push on completion
```

- This lets the cloud process uploads **as a batch**, decouples upload from
  result, and tolerates the phone going to sleep between submit and fetch.
- **Notable fit:** ivrit.ai's own serving project
  (`ivrit-ai/runpod-serverless`) already speaks an **async RunPod job
  protocol** (submit → poll), not the OpenAI API — so an async model may map
  onto it more naturally than the synchronous speaches path does.
- **[Q16]** Do we (a) define our own small job server (a thin wrapper the user
  self-hosts in front of speaches/whisper), (b) adopt RunPod-style async
  jobs, or (c) shim async on top of the synchronous endpoint (the client just
  submits+polls against a queue we run on the Mac/server)? This decides the
  backend contract for the whole mobile path.
- **[Q17] Mobile background-execution reality check.** A "sync interval" that
  fires reliably in the background is **constrained by the mobile OS**: iOS
  only grants opportunistic `BGProcessingTask`/`BGAppRefreshTask` windows (no
  guaranteed timer, especially for uploads), and Android `WorkManager`
  periodic work has a **15-minute minimum** and Doze/battery limits. Practical
  implication: "upload every N minutes" is really "upload on next granted
  background window, and immediately when the app is foregrounded." We should
  spec the interval as a *target*, not a guarantee, and always sync on app
  open.

### 6.2 The hard part: securely exposing "my local device to the world"

This is the riskiest requirement and needs an explicit decision. Options,
cheapest/safest first:

- **Option A — Overlay VPN (Tailscale/WireGuard).** Phone and Mac join a
  private mesh; the phone hits the Mac's stable private IP. No public exposure
  at all. **Safest**, but requires the VPN app on the phone and isn't
  "exposed to the world" literally — it's "reachable by *my* devices".
- **Option B — Reverse tunnel (Cloudflare Tunnel / ngrok / Tailscale
  Funnel).** A stable public HTTPS URL fronts the Mac's local server; TLS +
  auth handled at the edge. Closest to "exposed to the world securely" with
  managed TLS.
- **Option C — DIY port-forward + reverse proxy (Caddy/nginx) + Let's
  Encrypt + token auth.** Most control, most footguns (router config, dynamic
  DNS, cert renewal, brute-force surface).

In all cases the Mac must run a **local HTTP server** exposing the
OpenAI-compatible transcription endpoint (the speaches container, or a thin
Mila-hosted proxy) **with mandatory auth** (bearer token) once it's reachable
off-LAN.

- **[Q5]** Which exposure model do we support/recommend/document first? My
  recommendation: **document Option A (Tailscale) as the blessed path** and
  **Option B as the "public URL" path**, and explicitly *not* build custom
  tunneling into Mila. Ship a setup guide, not a networking stack.
- **[Q6]** Does Mila's Mac app need to **run/host** the transcription server
  itself (spawn/manage the speaches container or an embedded whisper HTTP
  server), or do we just document "run the container + a tunnel"? Hosting it
  in-app is a big surface (lifecycle, ports, health, security).

### 6.3 Auth & pairing

Any off-device endpoint (cloud or exposed Mac) needs authentication.

- **[Q7]** Auth model: (a) a static **bearer token** the user pastes into the
  phone (simple, matches current `RemoteTranscriptionSettings.apiKey`), or (b)
  a **pairing flow** (Mac shows a QR code encoding URL+token, phone scans)?
  QR pairing is much nicer UX for "point my phone at my Mac" and is the
  recommended default.

### 6.4 Non-goals restated

No on-device model, no live mode, no full library management on mobile
(NG2–NG4).

---

## 7. Capability 3 — Destinations via Google Drive tracking (Mac is the hub)

**Refined model.** Destinations are **not** driven from the phone. The phone's
only outbound step is "save transcript as a new Google Drive file" (§6.1
step 5). The **Mac Mila app tracks the transcription files in Google Drive**
and fans each new one out to whatever destinations the user has configured
(Obsidian vault, NotebookLM, future sinks). This cleanly resolves the earlier
"how does a phone write to a Mac's Obsidian vault?" problem (old Q8): it
doesn't — Drive is the hand-off and the Mac does the filing.

### 7.1 Drive tracking on the Mac (the new core piece)

- Mila (Mac) is configured with a **tracked Drive folder** (where phone
  transcripts land) via Google OAuth (Drive scope).
- Mila detects new transcript files there — either by **polling** the Drive
  API on an interval, or via **Drive push notifications** (`changes.watch`).
  **[Q18]** Poll vs push? (Polling is simpler and robust; push is timelier but
  needs a public webhook — awkward for a desktop app.)
- For each new/unseen transcript file, Mila runs the **destination fan-out**
  (§7.4), then marks it processed (a local seen-index keyed by Drive file ID
  so re-scan/restart never double-files — same idempotency discipline as the
  Voice Memos importer's `voiceMemoUniqueID`).
- **[Q19]** What exactly lands in Drive from the phone — a **plain-text/Markdown
  transcript file**, or a **native Google Doc**? (A native Doc is what
  NotebookLM can live-sync; a `.md`/`.txt` is simplest for Obsidian. We may
  write the Doc for NotebookLM and derive the Markdown for Obsidian, or store
  one canonical format and convert on the Mac.)

### 7.2 Obsidian vault (local, written by the Mac)

An Obsidian vault is **just a folder of Markdown files** — so the fan-out step
is a Markdown formatter + a file write, done **on the Mac** where the vault
lives.

- Write a `.md` note (front-matter: title, date, duration, language, source;
  body: summary → action items → transcript) into a user-chosen vault folder
  (security-scoped bookmark, same pattern as the configurable recordings
  directory). Optional filename template and target subfolder (e.g.
  `Transcripts/`).
- Because the Mac is the writer, **mobile-origin transcripts reach Obsidian
  the same way desktop ones do** — via the Drive-tracking fan-out. No phone→Mac
  vault write, no Obsidian URI hacks needed. (Old Q8 dissolved.)
- **[Q9]** Format details: one note per recording (default, matches the
  per-file Drive model)? Include timestamps? Link vs copy the audio (audio
  isn't in Drive/vault by default)?

Desktop-native recordings can also fan out directly (no Drive round-trip
required) — the Drive path is specifically the bridge for **phone-origin**
transcripts.

### 7.3 NotebookLM (the constrained sink in the fan-out)

Within the Drive-tracking fan-out (§7.1), Obsidian is trivial (write a file);
**NotebookLM is the hard sink** because consumer NotebookLM has **no official
public write API**. Note the per-transcript-file phone model (§6.1 step 5,
Q19) leans toward the **new-file-per-transcript** shape (Q10-c), which is the
tension below. Verified current (2026) state:

- **Official API exists only for NotebookLM *Enterprise*** (Google Cloud
  "discoveryengine" surface): `notebooks.create`,
  `notebooks.sources.uploadFile`, `notebooks.sources.batchCreate`. Requires a
  **GCP project, enterprise entitlement, and OAuth/service-account auth**.
  This is a real, supported path *if the user is a Google Cloud/NotebookLM
  Enterprise customer*.
- **Consumer NotebookLM:** no official API. Community SDKs
  (`notebooklm-py`, `notebooklm-kit`) exist but **automate the web UI** — they
  depend on browser session cookies, break when Google changes internals, and
  are **against ToS to varying degrees**. Not a stable base to build a product
  feature on.
- **Can we lean on Drive auto-sync to auto-ingest transcripts?** Verified
  current (2026) behavior: NotebookLM's May-2026 "automatic Drive syncing"
  **does not watch a Drive folder for new files**. It only keeps the *content*
  of **already-added** sources (native Google **Docs/Sheets/Slides**) in sync
  with the original file every few minutes, and removes sources deleted in
  Drive. Adding a *new* file as a source is still a **manual, per-file action**
  (consumer accounts). PDFs / uploaded files / web links do **not** auto-sync
  at all. So "drop a file in a folder → it becomes a new NotebookLM source
  automatically" is **not possible** on consumer accounts today.
- **The exploitable pattern — one "living" Doc per notebook.** Because an
  already-added Doc *does* stay live-synced, Mila can maintain a single
  long-lived Google **Doc** (e.g. `Mila Transcripts — 2026`) and **append**
  each new transcript to it via the official Drive/Docs API. The user adds
  that Doc to their notebook **once**; every subsequent transcript then flows
  in automatically via NotebookLM's background sync. This is the closest thing
  to "NotebookLM auto-consumes my new transcripts" achievable with official
  APIs on a consumer account. Trade-off: all transcripts share one growing
  source (not separately-citable per meeting) and hit a per-source size
  ceiling eventually.

Given that, **[Q10]** decides the NotebookLM scope:

- **Q10-a — Official Enterprise API only.** Clean, supported, and the *only*
  path that can programmatically **add new sources** (`notebooks.sources.
  uploadFile` / `batchCreate`). But it serves only Google Cloud/NotebookLM
  Enterprise users (narrow audience) and needs GCP project config + OAuth.
- **Q10-b — "Living Doc" append (recommended).** Append each transcript to a
  single Drive-native Doc the user has added to their notebook once; NotebookLM
  auto-syncs it. Fully official APIs, and gives an "automatic" feel without a
  per-transcript manual step. One shared source; size-capped.
- **Q10-c — "New Doc per transcript" + manual add.** One Doc per recording via
  Drive API → clean per-meeting sources, but the user must click "add to
  notebook" each time (consumer) unless on Enterprise (Q10-a).
- **Q10-d — Community web-automation SDK.** Full "one-click new source into a
  consumer notebook" UX, but **fragile + ToS risk + browser-auth pain**. Not
  recommended for shipping; acceptable only as clearly-labelled
  experimental/personal-use.

My recommendation: **Q10-b (living Doc)** as the default — it's the only way to
get hands-off "new transcripts appear in my notebook" on a normal Google
account using supported APIs — with **Q10-a** as an opt-in for Enterprise users
who want each transcript as a distinct source. Treat one-click consumer
*new-source* creation as blocked-on-Google until an official consumer API
exists.

### 7.4 Destination fan-out abstraction

Introduce a small `TranscriptDestination` protocol (name TBD) so Obsidian,
NotebookLM, "copy/share", and future sinks share one plumbing path. **Routing
runs on the Mac** (resolves old Q2 for the destination side): both
desktop-native transcripts and phone-origin transcripts pulled from the
tracked Drive folder (§7.1) flow through the same fan-out. Each enabled
destination is invoked per new transcript; failures are per-destination and
retryable without re-filing the ones that succeeded.

---

## 8. Capability 4 — Gemini CLI support (smallest, do-first candidate)

- Add `case gemini` to `LLMTool` (`Mila/Actions/LLMSettings.swift`):
  - `executableName = "gemini"`, `displayName = "Gemini (gemini CLI)"`.
  - `arguments(prompt:...)` → `["-p", prompt]`, append `["-m", model]` when a
    model is set. (Verified: `gemini -p` is one-shot non-interactive and
    prints to stdout; `-m/--model` selects the model.)
  - Session handling: like `cursor`, Gemini has no `claude`-style
    `--session-id`/`--resume` in `-p` mode, so `LLMSession` is ignored for
    Gemini (Live AI session continuity won't apply — matches cursor behavior).
- `LLMRunner` already discovers binaries on `$PATH` + common dirs and sandboxes
  the CWD — `gemini` benefits from all of it for free. Add `~/.gemini`-style
  install dirs to the PATH fallback if needed.
- Tests: extend `MilaTests/LLMRunnerTests.swift` for the new arg vector; the
  existing `scripts/fake-llm-cli.sh` harness can stand in for `gemini`.
- Docs/release notes per `CLAUDE.md` release process.

This is low-risk and independently shippable **now**, decoupled from the
mobile/cloud/destination work.

---

## 9. Proposed phasing (for discussion)

Ordered by value-to-risk. Each phase is independently shippable.

- **Phase 0 — Gemini CLI.** Days. No architectural risk. (§8)
- **Phase 1 — Desktop destinations: Obsidian + Google Drive export.** Reuses
  the security-scoped-folder + exporter patterns. Ships U4 value on the
  platform that already has the transcripts. (§7.2)
- **Phase 2 — Mac Drive-tracking + fan-out.** Mila (Mac) watches a tracked
  Drive folder and fans transcripts out to enabled destinations, idempotently.
  This is the hub the mobile path plugs into; build it before mobile so the
  desktop can exercise it. (§7.1, §7.4)
- **Phase 3 — Async transcription job server + dual-mode hardening.** Stand up
  the submit→poll job contract (§6.1a, Q16), add mandatory bearer-token auth,
  and write the "expose your server/Mac securely (Tailscale/Cloudflare)" guide.
  (§5, §6.1a, §6.2)
- **Phase 4 — Mobile capture app (one platform first).** Folder capture →
  periodic async batch upload → attach result → save transcript to Drive.
  **[Q11]** iOS or Android first (iOS recommended: Swift codebase + iCloud
  Voice-Memos precedent).
- **Phase 5 — Second mobile platform + NotebookLM Enterprise API** (if in
  scope).

---

## 10. Open questions (must-answer before build)

Consolidated. The **bolded** ones are blocking / high-impact.

- **Q1.** Is "cloud" strictly **the user's own self-hosted server** (no
  Mila-operated SaaS, no accounts we manage)? (§2 NG1)
- **Q2.** ~~Mobile: server-does-everything vs phone-routes-destinations?~~
  **RESOLVED (2026-07-16):** phone = capture + async transcription offload +
  optional push-to-Drive; the **Mac** does destination routing by tracking
  Drive. (§6.1, §7)
- **Q3.** Diarization on the remote/mobile path: skip, require server-side, or
  best-effort from server labels? (§5.2)
- **Q4.** ~~Confirm no on-device transcription on mobile?~~ **RESOLVED
  (2026-07-16):** yes, record & send only. (§2 NG2, §6.1)
- **Q5.** Blessed **secure-exposure** mechanism to document first: Tailscale
  (VPN), Cloudflare Tunnel (public URL), or DIY proxy? (§6.2)
- **Q6.** Should the **Mac app host/manage** the transcription server itself,
  or do we only document running the container + tunnel? (§6.2)
- **Q7.** Mobile **auth**: pasted bearer token vs **QR pairing**? (§6.3)
- **Q8.** ~~Mobile→Obsidian delivery mechanism?~~ **RESOLVED (2026-07-16):**
  Mac-as-hub via Drive tracking — the phone never writes to the vault; the Mac
  fans transcripts out from the tracked Drive folder. (§7)
- **Q9.** Obsidian note **format**: per-recording vs daily-note append;
  timestamps/audio linking; copy vs link audio. (§7.2)
- **Q10.** **NotebookLM** scope: Enterprise API (a), "living Doc" append (b,
  recommended), new-Doc-per-transcript + manual add (c), or community
  web-automation (d)? Note: Drive auto-sync updates *existing* sources only —
  it does **not** auto-ingest new files from a folder. (§7.2)
- **Q11.** Which **mobile platform first** (iOS recommended)? (§9)
- **Q12.** **Cross-platform strategy** for mobile: two native apps
  (Swift + Kotlin), or one shared codebase (Kotlin Multiplatform / Flutter /
  React Native)? Affects team, repo layout, and long-term cost. (§ implied by
  §6, §8)
- **Q13.** Distribution: TestFlight/App Store + Play Store (accounts,
  review, privacy nutrition labels), or sideload/self-host builds only?
- **Q14.** Does the mobile app need **offline queueing** (record now, upload
  when connectivity/pairing returns)? (Now core to the design — the folder +
  async-batch model *is* an offline queue; see §6.1.)
- **Q15.** Where should product docs live going forward — this `docs/` folder,
  or bootstrap the `.context/` structure (roadmap/tasks/decisions/sessions)
  referenced in the workspace rules?
- **Q16.** **Async/batch transcription contract:** own job server, RunPod-style
  async, or a submit+poll shim over the synchronous endpoint? **Blocking for
  the whole mobile path.** (§6.1a)
- **Q17.** Accept that the mobile **"sync interval" is best-effort** (iOS
  BGTask windows; Android WorkManager 15-min minimum + Doze), always syncing on
  foreground? (§6.1a)
- **Q18.** Mac Drive tracking: **poll** the Drive API vs `changes.watch`
  **push**? (§7.1)
- **Q19.** What the phone writes to Drive: **plain `.md`/`.txt`** (best for
  Obsidian) vs **native Google Doc** (needed for NotebookLM live-sync) — one
  canonical format + convert, or write both? (§7.1)
- **Q20.** Do phone recordings and their transcripts **also** need to appear in
  the **Mac Mila library** (unified history), or do they live only on the phone
  + flow through to destinations? (Affects whether the Mac imports the audio or
  just the transcript.)

---

## 11. Risks

- **R1 — NotebookLM has no official consumer API.** Even with the Mac
  fan-out tracking Drive, NotebookLM can't have *new sources* added
  programmatically on consumer accounts. Mitigation: "living Doc" append
  (Q10-b) or Enterprise API (Q10-a); treat one-click consumer new-source as
  blocked-on-Google. Obsidian and other file sinks are unaffected. (§7.3)
- **R1b — Async job server is net-new infra.** The mobile batch model needs a
  submit→poll job contract the current synchronous endpoint doesn't provide
  (Q16); this is a real backend build, not just a client. (§6.1a)
- **R2 — Exposing a home Mac to the internet is a security liability.**
  Mandatory auth + TLS + a documented, hardened path (prefer VPN/tunnel over
  raw port-forward). A misconfigured setup could expose a mic-recording server.
- **R3 — Scope explosion.** Two new OS platforms + an async job backend +
  Drive tracking + third-party integrations is far beyond the current single
  macOS target. Phasing (§9) and answering Q12/Q16 early are the main
  mitigations.
- **R4 — Cross-platform maintenance cost.** Two native apps double UI work;
  a shared framework adds its own complexity. (Q12)
- **R5 — Privacy expectation regression.** Mila's brand is "audio never leaves
  your device." Cloud/mobile paths must make the trade-off explicit and keep
  local-only the default (G5), or risk eroding user trust.

---

## 12. Success criteria (to be firmed up with the Tests section later)

- Existing macOS local-only flow: **zero behavioral change** by default;
  full test suite green.
- Gemini CLI: name/summary/action produce output via `gemini -p`; unit tests on
  the arg vector; test panel works end-to-end.
- Destinations: a transcript lands as a correctly-formatted `.md` in a chosen
  Obsidian vault, and as a Doc/file in Google Drive, verified on disk / via API.
- Mobile: a recording made on the phone returns a transcript from a configured
  backend (cloud and "my Mac") and can be routed to at least one destination.

---

*Next step: resolve §10 (especially Q2, Q5, Q10, Q12), then I'll write the
per-phase implementation plan + Tests section per the project's plan-first,
test-first workflow.*
