# Managing Mila with MDM (configuration profiles)

A `.milaconfig` file lets one person hand teammates a ready-made setup that
they choose to apply. For an organization that wants **everyone** on the same
transcription server, Mila also reads the same settings from a **configuration
profile** — pushed by your MDM (Jamf, Kandji, Intune, Mosyle, …) or installed
by hand. Settings delivered this way are *locked*: Mila uses them, shows them
as **Managed by your organization** in Settings, and does not let the user (or
a `.milaconfig`) change them.

## Precedence

| Source | Wins over | Notes |
|---|---|---|
| **Configuration profile (managed)** | everything | Read at launch. Locked in the UI. Never written to the user's preferences. |
| **`.milaconfig`** | the user's current value | A one-time import the user confirms. It *writes* the user's settings, so afterwards the user can change them again. Fields that are managed are skipped, and the confirmation sheet lists them as "managed by your organization". |
| **The user's own setting** | — | What the user picked in Settings. |

Only the keys present in the profile are managed. Anything the profile leaves
out stays under the user's control, so a profile that only sets the server URL
does not touch anyone's language, Live AI or diarization choice.

The user's own values are kept underneath the managed ones. **Removing the
profile restores whatever the user had before** — Mila never copies a managed
value into the user's preferences.

## Payload

- **Preference domain:** `io.island.whisper.IslandWhisper` (Mila's bundle id,
  `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`).
- **Payload type:** a *forced* custom-settings payload for that domain —
  `com.apple.ManagedClient.preferences` with a `Forced` →
  `mcx_preference_settings` entry, as in the example below, or your MDM's
  "Application & Custom Settings" / "Preference domain + plist" equivalent.
  Mila only honours **forced** values; "set once" / "often" (non-forced) MCX
  settings are ignored.
- **Keys:** the same as a `.milaconfig`, **with the same nesting** — four
  top-level *dictionaries* plus one top-level string. `version` is not needed
  and is ignored. Write them as nested dictionaries, exactly as shown here;
  don't flatten them into one key with a dot in its name (see the note below
  the table).

```text
remoteTranscription        dictionary   the remote (OpenAI-compatible) transcription backend
├─ enabled                 boolean      true = use the remote backend, false = on-device whisper.cpp
├─ endpoint                string       base URL, e.g. https://mila-asr.your-org.example/v1
├─ model                   string       model id the server expects
├─ englishModel            string       model id for English recordings ("" = use model for all)
└─ apiKey                  string       bearer token — read "Secrets" below first
recordingLanguage          string       he or en (regional forms like en-US accepted)
liveAI                     dictionary
├─ enabled                 boolean      Live AI mode on/off
└─ model                   string       model passed to the AI CLI for the live loop
diarization                dictionary
└─ enabled                 boolean      speaker diarization on/off
meetingDetection           dictionary
└─ enabled                 boolean      the "meeting detected — start transcribing?" prompt on/off
```

| Top-level key | Type | Keys inside it |
|---|---|---|
| `remoteTranscription` | dictionary | `enabled` (boolean), `endpoint` (string), `model` (string), `englishModel` (string), `apiKey` (string) |
| `recordingLanguage` | string | — (`he` or `en`) |
| `liveAI` | dictionary | `enabled` (boolean), `model` (string) |
| `diarization` | dictionary | `enabled` (boolean) |
| `meetingDetection` | dictionary | `enabled` (boolean) |

Notes on individual keys:

- `endpoint`: Mila appends `audio/transcriptions` to it.
- `englishModel`: for servers whose main model is Hebrew-only (an ivrit.ai
  finetune, for example). An empty string means `model` handles every language.
- `recordingLanguage`: must be `he`, `iw` or `en`, or a regional form of one
  (`en-US`, `he_IL`). **Any other value is not applied** (and is logged):
  rather than guessing a language, the setting stays locked at whatever each
  user already had. **Locking it disables the language
  picker in the toolbar**, so users can no longer switch language per recording
  — leave it out unless that is what you want.

> **Flat keys.** Some MDM consoles make it easy to enter a key like
> `diarization.enabled` as a single flat key. That name happens to be the key
> Mila itself stores the setting under, so forcing it really does override the
> setting — and Mila therefore recognises it and treats it as managed (locked
> control, note in Settings), as it does for its other internal keys
> (`transcription.backend` = `"remote"`/`"local"`, `remote.endpoint`,
> `remote.model`, `remote.model.en`, `recording.language`, `liveAI.enabled`,
> `liveAI.model`, `meetingDetection.enabled`) and for the dotted form of every
> field above (`remoteTranscription.endpoint`, …). It is still a fallback: use
> the nested dictionaries, which are the documented format and what a
> `.milaconfig` uses. When both are present the nested value wins.

Values must have the right plist type — `<true/>`/`<false/>` for booleans,
`<string>` for strings. A value of the wrong type (for example the *string*
`"true"`), or a `recordingLanguage` Mila doesn't recognise, is not applied and
Mila logs the key name (see [Troubleshooting](#troubleshooting)). Mila then
tries the other spellings of that field (the flat keys below); if none of the
forced keys holds a usable value, the setting is still **locked** — you clearly
meant to manage it — but keeps the value it already had. Only that one field is
affected.

Settings that are machine-specific — the audio input device, the recordings
folder, hotkeys — are not manageable, for the same reasons they are not part of
a `.milaconfig`.

## Example profile

[`example.mobileconfig`](example.mobileconfig) points Mila at a self-hosted
server and turns diarization on:

```xml
<key>PayloadType</key>
<string>com.apple.ManagedClient.preferences</string>
...
<key>PayloadContent</key>
<dict>
  <key>io.island.whisper.IslandWhisper</key>
  <dict>
    <key>Forced</key>
    <array>
      <dict>
        <key>mcx_preference_settings</key>
        <dict>
          <key>remoteTranscription</key>
          <dict>
            <key>enabled</key>       <true/>
            <key>endpoint</key>      <string>https://mila-asr.your-org.example/v1</string>
            <key>model</key>         <string>ivrit-ai/whisper-large-v3-turbo-ct2</string>
            <key>englishModel</key>  <string>deepdml/faster-whisper-large-v3-turbo-ct2</string>
          </dict>
          <key>diarization</key>
          <dict>
            <key>enabled</key>       <true/>
          </dict>
        </dict>
      </dict>
    </array>
  </dict>
</dict>
```

Before deploying it, replace the server URL and model ids, give both
`PayloadUUID`s fresh values (`uuidgen`), change the `PayloadIdentifier`s to
your own reverse-DNS prefix, and delete every key you don't want to lock.

If your MDM asks for a **preference domain and a plist** instead of a whole
profile, use the domain `io.island.whisper.IslandWhisper` and a plist holding
just the keys:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>remoteTranscription</key>
  <dict>
    <key>enabled</key>   <true/>
    <key>endpoint</key>  <string>https://mila-asr.your-org.example/v1</string>
    <key>model</key>     <string>ivrit-ai/whisper-large-v3-turbo-ct2</string>
  </dict>
</dict>
</plist>
```

## What users see

- In **Settings**, each managed control is disabled and captioned **Managed by
  your organization** (Models → backend, endpoint, model, English model, API
  key; AI Features → Live AI and its model; Speakers → diarization; Meetings →
  the meeting prompt). A managed recording language disables the toolbar's
  language picker.
- Opening a `.milaconfig` still works for everything that isn't managed; the
  confirmation sheet lists the managed fields it will leave alone.
- Profile changes take effect the **next time Mila launches**. Quit and reopen
  Mila after installing, changing or removing a profile.

## Secrets

`remoteTranscription.apiKey` **is supported**, so a shared server's token can be
rolled out with the rest of the configuration. Understand what that means
before you use it:

- **A configuration profile is not a secret store.** macOS writes managed
  preferences to `/Library/Managed Preferences/` as ordinary property lists,
  readable by local users and by any process running as them, and the profile's
  contents can be inspected in **System Settings → General → Device
  Management** (**Privacy & Security → Profiles** on macOS 14). Anyone with
  the Mac can read the token.
- Mila keeps a managed token **in memory only**: it is not written to the
  user's Keychain, the Keychain is not read (so no Keychain prompt), and
  removing the profile removes the token.
- Treat the token as shared and low-privilege: one that only grants access to
  the transcription endpoint, that you can rotate by pushing an updated
  profile, and ideally behind network controls (VPN / internal-only DNS) as
  well. Don't reuse a token that unlocks anything else.
- If that isn't acceptable, leave `apiKey` out of the profile. Users then enter
  their own key in Settings, where it is stored encrypted in their Keychain, or
  get it from a `.milaconfig` you share over a trusted channel.

The managed-settings check is about *configuration*, not a security boundary:
it keeps Mila pointed where IT wants it, not a determined local user out of
the files on their own Mac.

## Testing locally

`defaults write io.island.whisper.IslandWhisper …` does **not** simulate a
profile: it writes the user's own (non-forced) preferences, which Mila ignores
for these keys. To test, use a real forced value:

1. **Install a profile (recommended).** Edit `docs/example.mobileconfig`,
   double-click it, then approve it in **System Settings → General → Device
   Management** (on macOS 14: **Privacy & Security → Profiles**). Quit and
   relaunch Mila. To undo, remove the profile there and relaunch Mila again.
2. **Write the managed plist directly (quick, throwaway).** As an admin:

   ```bash
   sudo mkdir -p "/Library/Managed Preferences/$USER"
   sudo plutil -convert binary1 -o \
     "/Library/Managed Preferences/$USER/io.island.whisper.IslandWhisper.plist" \
     my-mila-settings.plist          # a plist holding just the keys, as above
   sudo killall cfprefsd
   ```

   Then relaunch Mila. Remove the file (and `killall cfprefsd` again) to undo.
   On an MDM-enrolled Mac the MDM agent may delete or replace files in that
   folder, so prefer option 1 there.

To check that the value reached the preferences system at all:

```bash
defaults read io.island.whisper.IslandWhisper remoteTranscription
```

(This prints the value whatever its source, forced or not — Mila's own log,
below, is what says whether it was treated as managed.)

## Troubleshooting

At launch Mila logs which fields are managed (names only, never values):

```bash
log show --last 10m --predicate \
  'subsystem == "io.island.whisper.IslandWhisper" AND category == "ManagedSettings"'
```

You should see `managed by configuration profile: …` followed by the managed
fields (written as paths, e.g. `remoteTranscription.endpoint` for the
`endpoint` key inside the `remoteTranscription` dictionary). A line starting
`ignored managed preference value(s)` names keys whose value had the wrong
plist type or wasn't recognised (those settings stay locked at their current
value). No line at all means no forced keys
were found — check the preference domain, that the payload is *Forced*, and
that Mila was relaunched after the profile was installed.
