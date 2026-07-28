# Using Mila with Claude (MCP)

Mila ships an MCP server — `mila-mcp`, embedded in the app bundle — that
lets any Claude session (Claude Code, Claude Desktop) read your
transcriptions: past recordings with resolved speaker names, and the
live transcript of a meeting **while it's still happening**.

Everything stays local: the server reads Mila's own on-disk store; no
audio or text leaves your Mac unless you ask Claude to do something
with it.

## Setup (once)

Claude Code:

```bash
claude mcp add mila -- /Applications/Mila.app/Contents/MacOS/mila-mcp
```

Claude Desktop — add to `claude_desktop_config.json`:

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
| `get_transcript` | One recording's full speaker-named transcript + summary + action items. Omit `id` for the latest completed recording. |
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
  hands off to `get_transcript`), `not_recording`.

## How it finds your data

- `~/Library/Application Support/Mila/store-location.json` — written by
  the app on every launch and whenever you relocate the recordings
  folder (Settings ▸ Storage), so the server follows the move.
- `~/Library/Application Support/Mila/live/current.json` — the live
  transcript sidecar, written during recording (throttled, atomic) and
  closed with the saved recording's id at Stop.

If the app has never run (no pointer file), the server falls back to
the default layout. Changes to the `recordings.json` schema must be
mirrored in MilaKit's `StoredRecording` — `StoredRecordingDriftTests`
guards this.
