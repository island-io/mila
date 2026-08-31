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

## What to flag

- `print(` carrying a title, path, transcript or subprocess output.
- Public `Logger` interpolation of anything the user can relocate or name.
- `error.localizedDescription` logged publicly where the error came from a file
  operation on a user-chosen path.
- An `errorDescription` that embeds stdout/stderr from a child process.
- Redaction of a value that is purely diagnostic (domain, code, counts,
  durations, exit codes) — flag that as over-redaction.
