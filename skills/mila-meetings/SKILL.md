---
name: mila-meetings
description: >
  Work with Mila transcriptions via the mila MCP server — summarize or
  search past recordings/meetings ("my last meeting with John"), and
  follow the current in-progress meeting in real time to suggest what
  to say next. Use whenever the user mentions Mila, their recordings,
  meeting transcripts, or asks for live meeting help.
---

# Mila meetings

Mila is the user's local macOS transcription app. The `mila` MCP server
exposes its recordings. If its tools (`list_recordings`,
`get_transcript`, `search_transcripts`, `get_live_transcript`) are not
available, tell the user to register the server once:
`claude mcp add mila -- /Applications/Mila.app/Contents/MacOS/mila-mcp`

## Past recordings

- "Last meeting with <name>" → `list_recordings(speaker: "<name>", limit: 1)`,
  then `get_transcript(id: …)`. Speaker matching is a case-insensitive
  substring over the display names the user assigned in Mila; if it
  finds nothing, retry with a shorter fragment (first name), then fall
  back to `search_transcripts(query: "<name>")` — the name may appear
  in the text or title rather than the speaker labels.
- "What did we say about X" → `search_transcripts(query: "X")`, then
  `get_transcript` on the interesting hits.
- Recordings may be long. For summarization, `get_transcript` already
  returns a stored `summary` when one exists — read it before deciding
  to re-summarize from the raw transcript. Transcripts may be in any
  language (often Hebrew); answer in the user's language.

## Live meeting assistant

When the user asks to follow the current meeting / act as a live
assistant:

1. Call `get_live_transcript` with no arguments. If `status` is
   `not_recording`, tell the user to start a Mila recording and
   offer to check again shortly.
2. Poll in a loop every ~15–20 seconds, passing back the previous
   response's `session_id`, `revision` as `since_revision`, and
   `next_segment_index` as `since_segment_index`.
   - `{changed: false}` → nothing new; keep waiting silently.
   - New segments → the first returned segment replaces the last one
     you already had (live transcription rewrites it); the rest append.

   **Output ordering (critical):** in harnesses that hide text written
   between tool calls, anything you write before your next tool call is
   LOST to the user. In every loop turn: poll, **arm the next wake-up
   timer first** (background sleep / scheduled wakeup), and only then
   write the echo/answer as the turn's FINAL message with no tool calls
   after it. Never end a loop turn with a placeholder like "(listening)"
   after the real content — the placeholder is all the user will see.
3. Only speak up when the new content warrants it. Default output per
   update: one or two sentences of "what to say next" — a concrete
   suggestion the user could actually say, plus (only when useful) a
   one-line reason. Don't re-summarize the whole meeting every tick.
   Match the meeting's language.
4. Special statuses:
   - `recording_live_unavailable`: no live text will appear on this
     hardware — say so and stop polling frequently; check occasionally
     for `completed`.
   - `stale`: warn that Mila seems to have stopped updating (possible
     crash); the transcript won't grow.
   - `new_session: true`: a different recording started — confirm with
     the user before following the new one.
5. On `status: completed`: stop polling, call
   `get_transcript(id: final_recording_id)`, and close with a short
   summary + action items.
