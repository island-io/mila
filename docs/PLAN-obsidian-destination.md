# PLAN — Obsidian destination (macOS)

**Status:** IMPLEMENTED (direct-write). See §0 for the shipped design; §1–§9
below are retained as historical record of the earlier delegate approach.
**Scope:** First slice of the PRD's "destinations" capability
(`docs/PRD-mila-anywhere.md` §7), narrowed to Obsidian on the existing macOS
app.

---

## 0. Re-pivot (2026-07-19): Mila writes the notes directly

The delegate design in §1–§9 (Mila asks the user's LLM CLI + an Obsidian
skill/MCP to file the note) was **superseded**. Mila now **writes the Markdown
note itself** into a user-picked vault folder, and optionally commits + pushes
the vault's git repo. This is simpler, LLM-independent (a transcript-only user
still gets notes), and needs no MCP/skill setup by the user.

### What shipped

- **`Mila/Models/ObsidianVaultSettings.swift`** — opt-in `enabled`, a
  security-scoped bookmark to the vault folder (mirrors
  `RecordingStorageSettings`), a `subfolder` (default `Transcripts`, blank =
  vault root), and git fields (`gitSyncEnabled`, `gitBranch` default `main`,
  plus a non-persisted `lastSyncError` for the UI). `destinationDirectory`
  resolves `vault/subfolder`.
- **`Mila/Actions/ObsidianExporter.swift`** — builds the note and writes it.
  Content is **summary + action items**, falling back to **transcript
  (`TranscriptFormatter.plainText`) + action items** when no summary exists.
  One `.md` per recording named `<yyyy-MM-dd> <sanitized title>.md`. A
  per-recording seen-index (`obsidian.writtenIndex` in `UserDefaults`) maps
  recording ID → last relative path so a title edit / re-transcription
  overwrites (and renames) the same note instead of duplicating. A `pending`
  set is the sequencing gate: only recordings marked pending on a fresh
  completion are exported, so a launch-time summary backfill never spams the
  vault. On success it kicks the git syncer when enabled.
- **`Mila/Actions/ObsidianGitSyncer.swift`** — an `actor` (serializes concurrent
  completions) running `rev-parse --show-toplevel` → `add` → `commit` →
  `pull --rebase origin <branch>` → `push origin HEAD:<branch>`. "Nothing to
  commit" is treated as success; a rebase conflict triggers `rebase --abort`
  (never leaves the vault mid-rebase, local commit preserved for the next
  push). Runs git non-interactively (`GIT_TERMINAL_PROMPT=0`, SSH `BatchMode`)
  with a bounded timeout. A `GitCommandRunning` seam lets tests assert the exact
  command sequence without a real repo.
- **`RecordingSummarizer.onSummaryFinished`** — fired once per summarize attempt
  after the summary state is final (generated / skipped / failed), passing the
  latest recording; NOT fired for a dedup early-return or a deleted recording.
  This is the "summary is ready" signal the exporter waits on (resolves the
  §4.3 ordering race), with a synchronous fire on the skip paths so a
  transcript-only export never hangs.
- **Wiring** — `MilaApp` constructs `ObsidianVaultSettings` + `ObsidianExporter`,
  sets `summarizer.onSummaryFinished` (export if pending, then clear), and marks
  fresh completions pending in both the batch path
  (`TranscriptionService.onTranscriptionCompleted`) and the live path
  (`QuickActionsController`). The re-transcription + summaries-off case exports
  immediately (no summarizer hook to await).
- **`Mila/Views/ObsidianSettingsSection.swift`** — an Obsidian section embedded
  in the **Storage** settings tab (not a standalone tab, to avoid overflowing
  the fixed-width tab bar): enable toggle, vault folder picker (`NSOpenPanel`),
  subfolder field, git toggle + branch field, stale-bookmark notice, and
  last-sync error display. `StorageSettingsTab` wraps its content in a
  `ScrollView` and appends this section below a divider.
- **Tests** — `ObsidianVaultSettingsTests`, `ObsidianExporterTests`,
  `ObsidianGitSyncerTests`, `ObsidianGitSyncerIntegrationTests`,
  `ObsidianExportSequencingTests`. All green.

### Follow-up (2026-07-19b): backfill + Mila-folder mirroring

- **Backfill existing transcripts** — `ObsidianExporter.exportAll([Recording])`
  writes every recording that has content and kicks a **single** git sync for
  the whole batch. Surfaced as a "Sync existing transcripts" button in the
  Obsidian section (`ObsidianSettingsSection`, gated on a chosen vault). Solves
  "Obsidian was enabled after recordings already existed".
- **Mila folder → vault subfolder** — a note now lands in
  `vault/<subfolder>/<Mila folder>/<file>.md` when the recording is filed under
  a Mila folder (`Recording.folder`), created if needed and sanitized like a
  title; unfiled recordings stay in the base dir. The seen-index tracks the
  full relative path, so moving a recording between folders removes the old note.
- **Git staging generalized** — `ObsidianGitSyncer.sync` now takes
  `changedPaths: [URL]` and stages with `git add --all --` (captures the new
  note, a renamed note's deletion, and a whole backfill batch) without touching
  unrelated vault files.

### Mila-folder assignment UI (2026-07-19c)

Three surfaces to file a recording into a Mila folder (which the Obsidian
exporter then mirrors into the vault, per above):

- **Record-start (Home)** — a "Save to" folder dropdown under the record
  controls, bound to `QuickActionsController.nextRecordingFolder` (sticky,
  persisted in `UserDefaults`). Applied when the recording is saved in
  `stopRecording` (`folder:` on the `Recording` + `store.assign` to register
  the folder). "All Transcriptions" = unfiled.
- **Finalize (rename sheet)** — a "Folder" menu (None / existing / New Folder…)
  in `RenameRecordingSheet`, applied on Save/Send via `store.assign`.
- **Detail view** — a folder chip in `RecordingDetailView`'s header metadata row
  (None / existing / New Folder… via an alert) that reassigns live.

New recordings still land in "All Transcriptions" by default and can be dragged
into a folder from the sidebar (pre-existing behavior).

### Not in this pass

- No manual per-recording "Export to Obsidian" button (auto-run + bulk backfill only).
- Git credential/auth management (the vault must already push non-interactively).
- Front-matter / audio links / per-note customization beyond the above.

---

## 1. Goal (restated after the pivot)

When a recording finishes transcribing, Mila **automatically** runs the user's
LLM CLI with the recording's **summary + action items** and asks it to file
them into Obsidian, **using a skill/MCP tool the CLI has for Obsidian**. Mila's
new reusable capability: *"when calling the LLM CLI, request specific
skills/tools to be used."*

**Success criteria**
- With an Obsidian skill/MCP configured in the user's CLI, a completed
  recording's summary + action items land in Obsidian without manual steps.
- Users who don't configure this see no behavior change (feature is opt-in/off).
- The "request skills/tools" mechanism is generic (not Obsidian-hardcoded) and
  works for the CLIs Mila supports.
- New logic is unit-tested; existing suite stays green.

---

## 2. Confirmed decisions (2026-07-16 review)

| # | Decision |
|---|----------|
| Trigger | **Automatic** on transcription complete (+ a manual re-run path for the existing library — see §5 note). |
| Content | **Summary + Action items only** (no transcript, no front-matter). |
| Audio | **Nothing** — not attached/linked. |
| Filing/location | **Delegated to the LLM + its Obsidian skill/MCP** — Mila does not compute paths or write files. |
| Granularity | **One note per recording** (the skill/prompt decides layout). |

---

## 3. Method research — "request skills/tools when calling the CLI"

Verified current (2026). Two distinct mechanisms:

### 3.1 Claude "Agent Skills" (Claude-only)
- Skills are `SKILL.md` folders auto-discovered from `~/.claude/skills/` (user)
  and `.claude/skills/` (project); **model-invoked**.
- Headless `-p` mode: no interactive toggle, **but** you can **invoke a skill
  by prefixing the prompt** — `claude -p "/obsidian <prompt>"` — and chain up
  to six (`/a /b <prompt>`), added in Claude Code **v2.1.199**.
- Tool gating: `--allowedTools` restricts which tools may run.
- Easiest to wire from Mila: it's just **prompt text** (`/skillname ` prefix) —
  no new config plumbing, no flags.

### 3.2 MCP servers (portable across claude / cursor-agent / gemini)
- The cross-tool standard. Good Obsidian MCP servers exist (e.g.
  `@yanxue06/obsidian-mcp`, `mcp-obsidian`); most need Obsidian's **Local REST
  API** community plugin + an API key, or a vault path.
- Configured once per CLI:
  - Claude: `claude mcp add obsidian -e OBSIDIAN_API_KEY=… -- npx -y …`
    (→ `~/.claude/settings.json` / `.mcp.json`).
  - Cursor: `.cursor/mcp.json` (or `~/.cursor/mcp.json`).
  - Gemini: `~/.gemini/settings.json` `mcpServers`; per-invocation
    `--allowed-mcp-server-names obsidian`; headless requires
    `"mcp": { "autoAllowInHeadless": true }` (default-deny otherwise).
- Per-invocation enabling flags differ by tool (Gemini has a first-class flag;
  Claude/Cursor lean on config + allowed-tools).

### 3.3 What already works in Mila today (don't rebuild)
`LLMSettings.extraArgs` (free-text CLI args, tokenized) + the editable
`postActionPrompt` already let a user, right now: configure an Obsidian
MCP/skill in their CLI, write "file this into Obsidian" as the action, and pass
e.g. `--allowed-mcp-server-names obsidian` via extra args. The gap is: (a) it's
not **automatic** on completion, (b) skills/tools aren't a **first-class,
per-tool-aware** field, and (c) `gemini` isn't a supported tool yet.

### 3.4 Recommended method (for confirmation)
- **Ship `gemini` support first** (`LLMTool.gemini`) — needed regardless, tiny.
- **Add a first-class "Skills / tools to use" field** on the action config that
  is applied per-tool:
  - Claude → prepend `/skill` tokens to the prompt (§3.1) and/or add
    `--allowedTools`.
  - Gemini → inject `--allowed-mcp-server-names <names>` (§3.2).
  - Cursor → rely on its MCP config (document it); no per-invocation flag.
- **Recommendation:** treat **MCP as the primary, portable path** (works on all
  three tools, and Obsidian has solid MCP servers), and support **Claude skill
  prompt-prefix** as the zero-config bonus for Claude users. This is the
  "best + easy" balance: MCP for robustness/portability, `/skill` prefix for
  Claude convenience.

**→ Open choice C1 (see §7): confirm MCP-primary vs Claude-skills-primary vs both.**

---

## 4. Design (delegate approach)

Builds entirely on the existing LLM integration
(`Mila/Actions/LLMSettings.swift`, `LLMRunner.swift`, `LLMTool`,
`PostRecordingCoordinator`, `RecordingSummarizer`). **No** `ObsidianExporter`,
**no** vault folder picker, **no** new entitlement.

### 4.1 Gemini support
- Add `case gemini` to `LLMTool`: `executableName = "gemini"`,
  `arguments → ["-p", prompt]` (+ `["-m", model]` when set). Session ignored
  (like `cursor`). Extend PATH fallback to include `~/.gemini` if needed.

### 4.2 First-class "skills/tools" on the action
- Add to `LLMSettings`: `actionSkills: [String]` (or a single free-text field
  tokenized like `extraArgs`) + persistence.
- Extend `LLMTool.arguments(...)` / `LLMRunner.run(...)` to apply skills
  per-tool:
  - Claude: prepend `/name ` tokens to the composed prompt.
  - Gemini: append `--allowed-mcp-server-names <csv>`.
  - Cursor: no-op at the flag level (documented as config-driven).

### 4.3 Auto-run action on completion
- New toggle `autoRunActionEnabled` (default OFF).
- Wire a hook off `TranscriptionService.onTranscriptionCompleted` (same seam
  `RecordingSummarizer` uses in `MilaApp.init`): when enabled + LLM configured,
  after the summary/action items exist, run `LLMRunner.run` with
  `postActionPrompt` + the configured skills, feeding **summary + action
  items** (not the transcript — per §2). Runs on the background/`.userInitiated`
  path with the existing `cliTimeout`.
- **Ordering caveat [risk]:** the summary is itself produced by an async LLM
  call (`RecordingSummarizer`). Auto-run must fire **after** summary+actions are
  ready, or it'll send empty content. Needs sequencing against the summarizer.

### 4.4 Settings UI
- Extend the existing **LLM** settings tab (not a new tab): add the
  "Auto-run action after transcription" toggle and the "Skills / tools to use"
  field, with a short helper explaining MCP setup + the Claude `/skill` prefix.
  Reuse the existing test panel to dry-run the action + skills.

---

## 5. Test plan (test-first)

- `LLMTool.arguments` unit tests for `gemini` (arg vector) and for skill
  application per tool (Claude `/skill` prefix present; Gemini
  `--allowed-mcp-server-names` appended; Cursor unchanged). Extend
  `MilaTests/LLMRunnerTests.swift`.
- Prompt-composition test: auto-run feeds **summary + action items** and NOT
  the transcript; empty summary/actions → no-op (don't invoke the CLI).
- Auto-run sequencing test: action fires only after summary/actions are
  populated (guard against the §4.3 ordering race).
- `LLMSettings` persistence test for the new toggle + skills field (injected
  `UserDefaults(suiteName:)` per project convention).
- Reuse `scripts/fake-llm-cli.sh` as a stand-in binary for an end-to-end-ish
  runner test (assert it receives the expected argv incl. skills/flags).

"Done" = new tests green + `make test` green.

---

## 6. Out of scope
- Mila writing files / a vault folder picker (rejected — the LLM+skill files it).
- Transcript body, front-matter, audio in the note.
- Google Drive, NotebookLM, mobile, OAuth.
- Bundling/installing an Obsidian MCP server with Mila (user's own setup);
  Mila only *documents* it and *requests* it at invocation.

**Manual path note:** auto-run only covers NEW completions. The existing
"Send to <LLM>…" sheet (`SendToLLMSheet`) already provides a manual per-recording
action for the back-catalogue; it will inherit the new skills field, so no
separate manual Obsidian button is strictly needed.

---

## 7. Resolved decisions (2026-07-16)

- **C1 → BOTH.** Build the portable **MCP** path (Gemini
  `--allowed-mcp-server-names`; Claude/Cursor via their MCP config + allowed
  tools) **and** the Claude **`/skill` prompt-prefix** convenience.
- **C2 → INCLUDE A SETUP GUIDE.** The user does not yet have an Obsidian
  MCP/skill configured, so this feature ships with a short doc (new deliverable,
  §8) covering the Obsidian **Local REST API** plugin + adding an Obsidian MCP
  server to each supported CLI, plus the Claude `/skill` note.

## 8. Deliverable: setup guide

New `docs/OBSIDIAN_DESTINATION.md` (user-facing), covering:
1. Enable Obsidian's **Local REST API** community plugin; copy the API key.
2. Add an Obsidian MCP server to your CLI:
   - Claude: `claude mcp add obsidian -e OBSIDIAN_API_KEY=… -- npx -y <server>`
   - Gemini: `~/.gemini/settings.json` `mcpServers` + `"mcp": {
     "autoAllowInHeadless": true }`.
   - Cursor: `.cursor/mcp.json` / `~/.cursor/mcp.json`.
3. In Mila → Settings → LLM: pick the tool, set the "Skills / tools to use"
   field (e.g. `obsidian`), enable "Auto-run action after transcription", and
   set the action prompt (e.g. "File this summary and action items into my
   Obsidian vault as a new note").
4. Claude-only convenience: reference an installed skill by prefixing the
   prompt (`/obsidian …`).

---

## 9. Status

Implementation order (tests first):

1. **`LLMTool.gemini` — DONE (2026-07-16).** Added the `.gemini` case
   (`displayName`, `executableName = "gemini"`, `arguments` → `gemini -p
   <prompt> --skip-trust` with optional `-m <model>`; session ignored).
   Picker/help text pick it up via `allCases`. Unit tests in `LLMRunnerTests`
   cover metadata, the arg vector, executable-lookup dirs, and the child
   environment; a real-CLI smoke test auto-skips when `gemini` isn't on PATH.

   Two production issues found while validating end-to-end against the real
   `gemini` CLI, both now fixed in `LLMRunner`:
   - **PATH / version managers.** `gemini` installed via **nvm** lives under
     `~/.nvm/versions/node/<v>/bin`, previously not searched. `lookupOnPath`
     was refactored to `searchDirectories(home:pathEnv:fileManager:)`, which now
     enumerates all nvm node bins (newest first) plus Volta / asdf / npm-global.
   - **node interpreter not on child PATH.** `gemini`'s shebang is
     `#!/usr/bin/env node`; a Finder-launched app has a stripped PATH so the
     child died with `env: node: No such file or directory`. New
     `childEnvironment(for:base:)` augments the child's PATH with the resolved
     executable's own dir (its sibling `node`) + the well-known dirs.
   - **Workspace trust.** We launch in an isolated empty sandbox (TCC safety),
     which gemini rejects as untrusted in headless mode. `--skip-trust` (the
     gemini analogue of cursor's `-f`) is now always passed.

   **Remaining, out of our control:** on the dev machine the smoke test now gets
   all the way to auth and fails with gemini's `IneligibleTierError`
   (free-tier "Gemini Code Assist for individuals" is deprecated). Users resolve
   this with `GEMINI_API_KEY` or a supported tier. CI is unaffected — the smoke
   test skips when `gemini` isn't installed.
2. skills/tools plumbing in `LLMSettings`/`LLMTool`/`LLMRunner` (MCP flags +
   Claude `/skill` prefix);
3. auto-run-action-on-completion with the summary-ready sequencing guard;
4. LLM settings-tab UI;
5. `docs/OBSIDIAN_DESTINATION.md`.
