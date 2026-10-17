# Using Mila with Claude (MCP)

Mila ships an MCP server — `mila-mcp`, embedded in the app bundle — that
lets any Claude session (Claude Code, Claude Desktop) read your
transcriptions: past recordings with resolved speaker names, and the
live transcript of a meeting **while it's still happening**.

Everything stays local: the server reads Mila's own on-disk store; no
audio or text leaves your Mac unless you ask Claude to do something
with it. Its one write is `save_transcript`, which saves a transcript to
a file you (or Claude, on your behalf) name — it never changes Mila's own
data, and it needs a second opt-in of its own (below).

## Turn it on first

**MCP access is off by default.** Enable it in Mila under **Settings →
Storage → "Allow MCP access to transcriptions"**. Until you do, every tool
call is refused with a message pointing back at that toggle, and the
setting takes effect immediately — turning it off cuts access to an
already-running Claude session without restarting anything.

**Saving files is a separate opt-in, also off by default.** Beneath the
first toggle, **"Also allow saving transcripts to files"** lets
`save_transcript` create files. Turning on read access — including
having turned it on before `save_transcript` existed — does not turn this
on, and turning read access off turns it off too. While it is off,
`save_transcript` is refused with a message naming the toggle, and every
other tool works as before. Like the first toggle it is re-checked on
every call.

The toggle is a consent control, not a security boundary, and it's worth
being straight about the difference. `mila-mcp` runs as you, and so does
everything else you run; anything with your user account can already read
`~/Library/Application Support/Mila/` directly, with or without this
setting. What the toggle prevents is the realistic accident — an MCP
client that happens to be configured quietly reading meeting transcripts
and sending them to a cloud model because the tools were simply there. It
does not, and cannot, defend against a hostile program already running as
you.

## Setup (once)

The helper lives inside the app bundle, so its path depends on where
Mila is installed. **Settings ▸ Storage shows the exact command for
your install, with a Copy button** — use that rather than retyping the
examples below, which assume `/Applications/Mila.app` and will not start
the helper if Mila lives anywhere else (a dev build, `~/Applications`, a
different volume).

Claude Code:

```bash
claude mcp add mila -- '/Applications/Mila.app/Contents/MacOS/mila-mcp'
```

Claude Desktop — add to `claude_desktop_config.json`, replacing the path
with your own:

```json
{
  "mcpServers": {
    "mila": {
      "command": "/Applications/Mila.app/Contents/MacOS/mila-mcp"
    }
  }
}
```

Optionally install the bundled skill so Claude knows the workflows
without being told (see `skills/mila-meetings/`):

```bash
mkdir -p ~/.claude/skills
cp -R skills/mila-meetings ~/.claude/skills/
```

## Tools

| Tool | What it does |
|---|---|
| `list_recordings` | List/filter recordings — by speaker display name, title/app/folder text, source, date range; sortable by date/duration/title. A row whose transcription the user stopped to run later carries `transcription_stopped: true` (its `status` reads `failed`, but nothing failed). |
| `get_transcript` | One recording's full speaker-named transcript + summary + action items. Omit `id` for the latest completed recording. Trashed recordings are not reachable, by id or otherwise. `format: "srt"` returns SubRip subtitles instead (one timed cue per segment, speaker names as cue prefixes — byte-identical to the app's **Export Subtitles (.srt)**); it is refused for recordings that have no timed segments, and `max_chars` then drops whole cues rather than cutting one. Each action item carries a `source` — `voice_command` (the speaker dictated it out loud) or `inferred` (Live AI derived it from the conversation). Those are not the same claim, so a client should not present the second as the first. |
| `save_transcript` | Writes one recording's complete transcript (`text` or `srt`) to a file and replies with `saved_to` / `bytes` instead of the text. The only tool that writes: it needs the separate "Also allow saving transcripts to files" opt-in, and is kept separate from `get_transcript` so a client asks for permission to use it on its own. See [Saving to a file](#saving-to-a-file-save_transcript). |
| `search_transcripts` | Full-text search over titles + transcripts with context snippets; relevance or date sort. |
| `get_live_transcript` | The in-progress recording's transcript, with a polling cursor for cheap deltas. |

### What a search costs

Nothing is cached — every call reads the store as it is right now, which is
what makes the answers trustworthy while you're still recording. So the
work a `search_transcripts` call does is worth knowing:

- `sort: "created_at"` stops at the `limit`-th match: no transcript past it is
  opened or rendered, however large the store is. The `recordings.json` index
  is still read whole — it is one small file, and the date order the early stop
  relies on comes from it — so what `limit` bounds here is the per-recording
  transcript work, not the metadata read.
- `sort: "relevance"` (the default) ranks by match count, and that means
  scoring every recording before it can pick the top few — it never gives up
  on part of your library to go faster, so the best match is always found.
  Its cost grows with the size of that library. Recordings with speaker
  labels are scored straight out of `recordings.json`, without opening or
  formatting anything; the rest cost one transcript file read each, because
  that file *is* the transcript. Only the results that come back are
  formatted, at most `limit` of them.

If you only want the most recent mentions, `sort: "created_at"` with a small
`limit` is both cheaper and usually the better question.

## Reading past recordings

Just ask, e.g.:

> Read my last transcription with John Doe and summarize it.

Claude calls `list_recordings(speaker: "john doe", limit: 1)` and then
`get_transcript(id: …)`. Speaker filters match the display names you
assigned in Mila's rename popover — unnamed speakers stay `SPEAKER_NN`.

For subtitles — "export my last meeting as an .srt next to the video" —
Claude calls `save_transcript(id: …, format: "srt", path: "<folder>")`.
The cues are the same ones the app's own export produces.

### Saving to a file (`save_transcript`)

`save_transcript(path: …)` writes the complete transcript (text or SRT)
to disk from the helper itself and replies with `saved_to`, `bytes` and
`characters` in place of the transcript text. Use it whenever the end
product is a file. The alternative — fetch the text, have the model write
it out — makes the model re-generate every character as output tokens;
Hebrew runs close to one token per character, so a 40 KB transcript of a
20-minute meeting took about three minutes per file that way, against
milliseconds here.

- `path` is an absolute path (`~` is expanded) or an existing folder,
  which gets `<date> <title>.txt` / `.srt`. A path ending in `/` always
  means a folder. The folder must exist; nothing is created on a guess.
- An existing file is refused unless `overwrite: true`; the refusal is
  atomic, so a file that appears mid-write is not replaced either. On
  volumes without an exclusive rename (exFAT, FAT, some network shares)
  the helper falls back to `link(2)`, then to an exclusive create, so the
  default still works there.
- A destination that is a symbolic link (or a folder, or anything but a
  regular file) is refused, and a replace swaps the directory entry —
  it never writes through a link.
- Only finished transcripts are saved. A recording that is still
  transcribing, failed, or was stopped to transcribe later is refused
  (`get_transcript` shows its draft), and so is an empty transcript — a
  file carries no "this is partial" note, and with `overwrite` it would
  replace a good export.
- There is no `max_chars`: a saved file is always complete.
- It is a separate tool from `get_transcript` on purpose. Clients ask
  permission per tool, so having always-allowed reading transcripts does
  not also allow writing files.
- Mila's app-support folder is off limits, however it is spelled:
  containment is decided by the folder's identity on disk, not by
  comparing path strings, so a differently-cased path or a symlinked
  folder lands on the same refusal. A **relocated** recordings folder
  may be somewhere ordinary like `~/Documents`, so new exports may be
  created there — but no file already in it is ever replaced, Mila's own
  names (`recordings.json`, `folders.json`, …) and audio extensions are
  refused, and so is a name that is one of a recording's sidecars
  (`<audio name>.txt` / `.srt`). Like the access toggles, these checks
  prevent accidents; the helper runs as you and is not a sandbox.

## Following a live meeting

1. Start a recording in Mila (any mode with the live transcript pane —
   mic, system audio, or meeting).
2. In a Claude session:

> Follow my current Mila meeting via the mila MCP server. Poll
> get_live_transcript with the cursor every ~15–20 seconds; whenever
> something new lands, suggest in one or two sentences what I should
> say next. When the status becomes "completed", fetch the final
> transcript and give me a summary.

How the polling works under the hood:

- Each recording session has a `session_id`; the snapshot carries a
  `revision` that bumps only when content changes. Claude echoes
  `session_id`, `since_revision`, and `since_segment_index` back on each
  poll.
- Nothing new → a tiny `{changed: false}` response.
- New content → only the new segments (the last previously-seen segment
  is re-sent, since live transcription may rewrite it; Claude replaces
  its copy).
- A `session_id` mismatch means a new recording started between polls —
  Claude gets the new meeting's transcript from the top with
  `new_session: true`.
- If you **delete a line** from the live transcript, the next poll whose
  cursor predates the deletion gets the whole segment set back with
  `segments_removed: true`, and is told to discard its previous copy
  rather than append. The incremental cursor is a count plus a "re-read
  the last entry" rule, so it cannot express a removal on its own — and
  a deletion is a privacy action, so the poller must not be left holding
  the line you removed.
- `status` values: `recording` (keep polling), `stale` (the app stopped
  updating the snapshot — likely crashed), `recording_live_unavailable`
  (live transcription is off for this recording — turned off in
  Settings, or gated off on this hardware — wait for completion), `completed` (stop polling; `final_recording_id`
  hands off to `get_transcript` **when present** — a recording can
  complete without one, and the reply says so and points at
  `list_recordings` instead), `not_recording`.

## How it finds your data

- `~/Library/Application Support/Mila/store-location.json` — written by
  the app on every launch and whenever you relocate the recordings
  folder (Settings ▸ Storage), so the server follows the move.
- `~/Library/Application Support/Mila/live/current.json` — the live
  transcript sidecar, written during recording (throttled, atomic) and
  closed with the saved recording's id at Stop. It is closed only after
  the saved recording's transcript is final, never before: `completed` +
  `final_recording_id` is a promise that following the id yields the
  authoritative text, and a poller is free to act on it the instant it
  lands. Stop therefore keeps the snapshot in `recording` (heartbeat
  still ticking) for the second or two the post-stop drain takes, and
  publishes the handoff last.

- `~/Library/Application Support/Mila/mcp-access.json` — the consent
  flags, written by the app whenever a setting changes and re-mirrored
  on every launch. Missing or unreadable means **denied**. `enabled`
  grants the read tools; `fileExportEnabled` additionally grants
  `save_transcript` and counts only alongside `enabled`. A file without
  `fileExportEnabled` — every file written before it existed — grants
  reads only.

  Two things have to be true for it to say yes: you turned the toggle on,
  **and** Mila could confirm that `store-location.json` names the store it
  is really using. If a relocation left that pointer stale, the helper
  would answer from the store Mila stopped writing to — so access is
  paused instead, and Settings says so. It comes back by itself once the
  pointer is written again (every launch rewrites it).

  Turning access off also fails closed, for either flag: if the file
  can't be rewritten, Mila deletes it, and if it can't do that either the
  toggle concerned stays ON rather than showing an off state it never
  achieved.

If the app has never run (no pointer file), the server falls back to
the default layout. Changes to the `recordings.json` schema must be
mirrored in MilaKit's `StoredRecording` — `StoredRecordingDriftTests`
guards this.

## Why it reads files instead of calling a local API

The alternative considered was for Mila to serve a local API over a unix
domain socket, with `mila-mcp` as a thin client. That decouples the
helper from the store's on-disk format and would give a third party a
versioned contract to build against. It was declined for now, for two
reasons.

The first is availability. Mila is an ordinary dock app — no login item,
not a background agent — and the common question ("what did we decide on
Tuesday?") gets asked days later with Mila closed. Reading files answers
it either way; a socket only answers while the app is running.

The second is that the socket buys no security here. A socket at `0600`
is reachable by exactly the same principals as a file at `0600`: your own
user. The isolation it appears to add over reading files directly is not
real.

What made the trade acceptable is that it stays reversible.
`MilaDataSource` is the seam: `FileBackedDataSource` is the only
implementation today, and a socket-backed one would be the whole change
on this side — the tool handlers don't move. If a third-party consumer
shows up, or the store format starts churning, that's the moment to
revisit.
