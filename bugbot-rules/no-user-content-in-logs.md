# Keep user content out of public log fields

Recording titles are meeting names — often a client or an employer. User-chosen
storage paths name folders. Transcripts and model output are the user's own
words. None of it belongs in a log field readable without private-data logging
enabled.

Three mechanisms make this leak more than it appears, all confirmed in this repo:

1. **`print` has no privacy annotation at all.** Everything it emits is public by
   construction, and a launchd-launched app has its stdio captured anyway.
2. **Cocoa quotes the offending path — including its containing folder — inside
   `localizedDescription`.** Redacting a URL while logging the error object still
   leaks the path through the error string.
3. **Transcript filenames are derived from titles**, so logging a filename logs a
   meeting name.

A fourth case cannot be fixed by annotating call sites at all: when an error
type's `errorDescription` **embeds subprocess output**, the content is already in
the string before any `Logger` sees it. Such types need a separate loggable
description.

## Do not over-redact

`NSError.domain` and `code` should stay **public** — they distinguish "no
permission" from a full disk or a missing directory and reveal nothing. A blanket
redaction that makes real failures undiagnosable is its own bug. Where a message
must identify *which* item failed, log the recording's UUID publicly.

Redacting a log line is also not a reason to degrade a **user-facing** message.
The user seeing their own content, on a surface they asked for, on their own
screen, is not a leak — prefer splitting the loggable message from the displayed
one over weakening the UI.

## Redaction is per branch, not per function

The most common way this reappears is **half-fixed**: the success log in a
function is redacted and the error / `catch` / fallback branch a few lines below
still interpolates the same value — or the `localizedDescription` that quotes it
— as `.public`. It reads as done, and the failure branch is the worse of the two
to leak from, because Cocoa's message names the *containing folder* as well as
the file.

Bugbot caught exactly this on PR #218 in `WAVHeaderRepair.repairIfNeeded`: the
success line marked the title-derived WAV name `.private`, while the write-failure
and `fsync`-failure lines above it still published `error.localizedDescription`.
The same sweep found it again in `MilaConfigImporter.handleOpen`, whose success
line redacts the user-chosen `.milaconfig` filename and whose `catch` logged
`String(describing: error)` — the same filename, plus its folder.

So: check **every** branch that logs, not the one the diff draws attention to.
A `catch` is not exempt for being an error path.

## What to flag

- `print(` carrying a title, path, transcript or subprocess output.
- Public `Logger` interpolation of anything the user can relocate or name.
- `error.localizedDescription` logged publicly where the error came from a file
  operation on a user-chosen path.
- A function whose success log redacts a title or path while its error, `catch`
  or fallback branch still logs that value — or an error message that quotes it
  — `.public`.
- An `errorDescription` that embeds stdout/stderr from a child process, **or a
  response body from a remote endpoint**. Both are output Mila did not write, and
  a 401 body commonly quotes a fragment of the user's API key.
- Redaction of a value that is purely diagnostic (domain, code, counts,
  durations, exit codes) — flag that as over-redaction.
