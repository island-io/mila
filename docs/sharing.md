# Sharing recordings between Mila users (`.milashare`)

Mila can hand a recording — audio, transcript, speaker names, summary and
action items — to another person who also uses Mila, as a single
`.milashare` file. The recipient double-clicks it and gets a full, editable
copy in their own library, tagged with who shared it.

## Sharing

Right-click a completed recording → **Share Recording…** (or use the share
button in the recording's header → **Share for Mila…**). Mila asks where to
save `<title>.milashare`, then reveals it in Finder. Send it however you send
any confidential attachment: Slack, Drive, AirDrop, mail.

Only completed, untrashed recordings with a transcript can be shared.

### What is in the file

A `.milashare` is a zip archive with three fixed entries:

| Entry | Contents |
|---|---|
| `manifest.json` | Title, date, duration, source, language, segments with timings and speaker ids, speaker names, summary, action items, who exported it and when, and (optionally) voice profiles. |
| `audio.m4a` or `audio.wav` | The recording's audio, copied as-is. |
| `transcript.txt` | The plain-text transcript. |

Rename it to `.zip` on a Mac without Mila and Archive Utility will open it.

### Voice profiles (optional, off by default)

If voice recognition is on and the recording's named speakers have voice
profiles, the share flow shows a checkbox: **Include voice profiles for the
speakers in this recording**. It is off by default and never remembered
between shares. Ticking it copies each selected speaker's voice fingerprint
— their name, the 256-number centroid, how many samples went into it, and
which embedding model produced it — into `manifest.json`, so the recipient's
Mila can recognise those people in their own recordings. You can untick
individual speakers (for example, your own voice).

A fingerprint cannot be played back, but it does identify a person. Share it
only where that is yours to decide.

## Importing

Double-click the file, drop it on Mila, or use **File → Import Shared
Recording…**. Mila verifies the archive (size and SHA-256 of the audio
against the manifest), then shows what will happen before anything is
written:

- **Added to your library** when you do not have this recording.
- **Replaces your existing copy** when you do — a recording keeps its id
  across shares, so re-sending an updated transcript updates rather than
  duplicates. Your local transcript edits are overwritten; the folder you
  filed it in is kept. If your copy was in Recently Deleted it is restored.

The imported recording is an ordinary recording: rename it, re-summarise it,
move it, delete it. It shows "Shared by <name>" in the list and in the
header. Its audio is stored under a filename Mila chooses; nothing in the
archive names a file on your Mac.

Imports count against the storage limit in Settings → Storage and are
refused when they would exceed it.

### Voice profiles on import

When the file carries voice profiles, the sheet lists one row per shared
speaker:

- Mila compares each shared voice with your own profiles (cosine
  similarity, using your threshold from Settings → Live AI). The closest
  match above the threshold is suggested as **Merge into "…"**, with the
  match percentage. A same-name profile whose voice scores low is still
  suggested, flagged in orange so you look twice. A speaker that matches
  nothing is suggested as **Add as new**.
- **Every row has a menu with every one of your profiles**, plus *Add as
  new* and *Skip*. Pick a different profile to merge into, keep a speaker
  separate under a new name ("Alex (from Daniel)"), or skip.
- *Merge* folds the sender's samples into your profile as a weighted mean
  (their 200 samples will outweigh your 3 — that is more data, not less).
  *Add as new* creates a profile with the sender's fingerprint as-is.
  *Skip* writes nothing; the transcript keeps the name as text.
- The recording's speaker labels follow your choice: a speaker merged into
  your "Dan" is labelled "Dan".
- Importing the same file twice shows those speakers as *Already imported*
  and defaults them to skip, so samples are not counted twice. Deleting a
  profile forgets its imports.

With voice recognition off, the rows are shown but disabled — nothing is
written behind an opted-out user, and the recording still imports.
Fingerprints made with an embedding model this version of Mila does not
know are refused.

## For developers

- Format: `Mila/Models/ShareManifest.swift` (versioned; a newer `version`
  is refused with an "update Mila" message). The recording DTO is
  deliberately separate from `Recording`'s Codable — see the type comment
  and `ShareManifestTests.test_every_recording_key_is_shared_or_deliberately_excluded`.
- Export: `Mila/Actions/RecordingShareExporter.swift`, zip via
  `Mila/Actions/ZipArchiver.swift` (`ditto`).
- Import: `Mila/Models/RecordingShareImporter.swift`; voice profiles via
  `SpeakerProfileImportResolver` / `SpeakerProfileImportApplier`.
- `Recording.sharedBy` / `sharedAt` are persisted in `recordings.json` and
  mirrored in MilaKit's `StoredRecording` (`shared_by` in `list_recordings`).
