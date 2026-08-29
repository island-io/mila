# Using Mila with Claude (MCP)

Mila ships an MCP server — `mila-mcp`, embedded in the app bundle — that
lets any Claude session (Claude Code, Claude Desktop) read your
transcriptions: past recordings with resolved speaker names, and the
live transcript of a meeting **while it's still happening**.

Everything stays local: the server reads Mila's own on-disk store; no
audio or text leaves your Mac unless you ask Claude to do something
with it.

## Turn it on first

**MCP access is off by default.** Enable it in Mila under **Settings →
Storage → "Allow MCP access to transcriptions"**. Until you do, every tool
call is refused with a message pointing back at that toggle, and the
setting takes effect immediately — turning it off cuts access to an
already-running Claude session without restarting anything.

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
| `list_recordings` | List/filter recordings — by speaker display name, title/app/folder text, source, date range; sortable by date/duration/title. |
| `get_transcript` | One recording's full speaker-named transcript + summary + action items. Omit `id` for the latest completed recording. Trashed recordings are not reachable, by id or otherwise. Each action item carries a `source` — `voice_command` (the speaker dictated it out loud) or `inferred` (Live AI derived it from the conversation). Those are not the same claim, so a client should not present the second as the first. |
| `search_transcripts` | Full-text search over titles + transcripts with context snippets; relevance or date sort. |
| `get_live_transcript` | The in-progress recording's transcript, with a polling cursor for cheap deltas. |

## Reading past recordings

Just ask, e.g.:

> Read my last transcription with John Doe and summarize it.

Claude calls `list_recordings(speaker: "john doe", limit: 1)` and then
`get_transcript(id: …)`. Speaker filters match the display names you
assigned in Mila's rename popover — unnamed speakers stay `SPEAKER_NN`.

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
- `status` values: `recording` (keep polling), `stale` (the app stopped
  updating the snapshot — likely crashed), `recording_live_unavailable`
  (recording on hardware where live transcription is gated off — wait
  for completion), `completed` (stop polling; `final_recording_id`
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
  flag, written by the app whenever the setting changes and re-mirrored
  on every launch. Missing or unreadable means **denied**.

  Two things have to be true for it to say yes: you turned the toggle on,
  **and** Mila could confirm that `store-location.json` names the store it
  is really using. If a relocation left that pointer stale, the helper
  would answer from the store Mila stopped writing to — so access is
  paused instead, and Settings says so. It comes back by itself once the
  pointer is written again (every launch rewrites it).

  Turning access off also fails closed: if the file can't be rewritten,
  Mila deletes it, and if it can't do that either the toggle stays ON
  rather than showing an off state it never achieved.

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
