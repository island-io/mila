# User-Editable Recording Languages — Design

**Status:** approved design, not yet implemented
**Date:** 2026-09-22

**Goal:** Replace the hardcoded two-case `RecordingLanguage` enum with a
user-editable list. The user can add a language (name, ISO code, flag, script
direction, transcription model), edit one, and remove one — while every
recording already on disk keeps displaying and re-transcribing correctly,
including in a language that has since been removed from the list.

**Motivating case:** Russian. The catalog's `openaiTurbo` is the multilingual
`large-v3` turbo checkpoint and handles Russian well, so nothing about the
engine blocks this. The limit is purely that the language set is a two-case
enum.

---

## Non-goals

These are deliberately excluded. Each is additive later and none of them
changes the design below.

- **User-supplied model URLs.** A language picks from the built-in catalog.
  Pasting an arbitrary ggml URL collides with the SHA-256 pinning in
  `WhisperModel` (`ModelManager.swift:14`), which exists so a compromised
  HuggingFace repo is rejected before bytes reach the GGML loader. Supporting
  it needs a trust-on-first-use flow (download → compute hash → show it → user
  confirms → pin) and its own security review. Because the language record
  stores a model *name* referencing the catalog, that feature only grows the
  catalog; the language→model join is unaffected.
- **Reordering the list.** Order is insertion order; seeds are `[Hebrew,
  English]`.
- **Localizing Mila's own UI chrome.** This is the language spoken *into* the
  app, not the language the app's buttons are written in.

---

## Background: where "exactly two" is currently encoded

`RecordingLanguage` (`Mila/Models/RecordingLanguageSettings.swift:18`) is a
two-case `String` enum. Five separate facts hang off it:

| Fact | Today |
|---|---|
| Display name + flag | `displayName` / `flagEmoji` switches |
| Script direction | implicit — `.hebrew` is the only RTL case |
| Local model | `WhisperModel.bestModel(for:)` switch (`ModelManager.swift:74`) |
| Remote model id | `RemoteTranscriptionSettings.model` + `englishModel` — a two-slot **storage** shape, not just a switch |
| Dictation hotkey | `HotkeyAction.dictateHebrew` / `.dictateEnglish`, `CaseIterable` |

**The one thing that is already dynamic:** `Recording.language` is stored as a
`String` ISO code, not as the enum. recordings.json, MilaKit's
`StoredRecording`, and the `StoredRecordingDriftTests` tripwire are therefore
**untouched by this change**. The enum was only ever a UI and routing layer.
This is what makes the work a type swap rather than a schema migration.

---

## Data model

```swift
struct RecordingLanguage: Identifiable, Hashable, Codable {
    var code: String           // "he" — the id; normalized to lowercase
    var displayName: String    // "Hebrew"
    var flagEmoji: String      // "🇮🇱"
    var isRTL: Bool
    var modelName: String?     // → WhisperModel.name; nil = multilingual default
    var remoteModelID: String? // per-language model id for a remote endpoint
    var id: String { code }
}
```

`isRTL` becomes explicit data instead of "is it the Hebrew case". `modelName`
is a catalog reference, not an inline model definition — see Non-goals.

---

## Storage and seeding

- New namespaced key **`recording.languages`**, a JSON array of the struct.
- The existing **`recording.language`** key keeps its exact current meaning:
  the active code. Nothing to migrate.
- **Seeding triggers on the key being absent**, not on the list being empty
  (empty is forbidden — see Invariants — so "empty" can only mean corruption,
  which should not silently re-seed over a user's edits). Seeds:

  | code | name | flag | RTL | model | remote id |
  |---|---|---|---|---|---|
  | `he` | Hebrew | 🇮🇱 | yes | `ivrit-ai-whisper-large-v3` | `nil` — falls through to `remote.model` |
  | `en` | English | 🇬🇧 | no | `openai-whisper-large-v3-turbo` | migrated from `remote.englishModel` |

Existing users see no behavioral change on first launch of the new build.

---

## Resolution: two lookups, never one

This is the core of the design and the part most easily got wrong.

```swift
func configured(_ code: String) -> RecordingLanguage?  // the list — drives every picker
                                                       // exact-or-variant match, like `resolve`
func resolve(_ code: String) -> RecordingLanguage      // never nil — for displaying
                                                       // and re-transcribing stored rows
```

**Why the split.** "Remove Hebrew" cannot mean purge. Every recording already
on disk stores `language: "he"`, and Hebrew is additionally today's `fromCode`
fallback for every unrecognised code. Removal must therefore mean *stop
offering it for new recordings* while stored codes stay resolvable **forever**.

`resolve` order:

1. exact match in the configured list (lowercased)
2. variant match in the list — `he-IL`, `he_IL`, `iw` → `he`. The existing
   `isVariant` guard is kept verbatim: a bare `hasPrefix` would route
   `"enochian"` to English, so `"enochian"` must miss.
3. **compiled-in built-in table** — the same two seed entries above
4. synthesized display-only entry: `displayName` = code uppercased, flag 🏳️,
   `isRTL` = false, `modelName` = nil

Step 3 is what makes deletion *correct* rather than merely non-crashing:
after deleting Hebrew, `resolve("he")` still returns "Hebrew 🇮🇱 RTL" for old
recordings instead of a bare `HE 🏳️`.

**Every existing `RecordingLanguage.fromCode(recording.language)` call site
becomes `resolve`:** `RecordingContextMenu.swift:123`,
`RecordingDetailView.swift:179` and `:477`,
`RemoteTranscriptionSettings.swift:399`, `MilaConfigImporter.swift:152` and
`:191`. Pickers iterate the configured list instead.

> **Regression note for reviewers.** If the list is built but this split is
> not, deleting Hebrew silently breaks display and re-transcription of every
> pre-existing Hebrew recording — and the current `fromCode` tests pass the
> whole way, because they exercise the code path being replaced.

---

## Invariants

1. **The list is never empty.** Remove is disabled at one entry.
2. **Codes are unique, case-insensitively, and stored lowercased.** A new
   code is also rejected when it *variant-matches* an existing entry —
   adding `he-IL` alongside `he` would make `resolve` order-dependent.
3. **Deleting the active language re-points `recording.language`** at the
   first surviving entry.
4. Deleting a language never touches any stored recording.

---

## Model routing

### Local

`ModelManager` must not learn about `RecordingLanguageSettings` — wrong
dependency direction, and it would tangle two App-level objects. Instead:

```swift
var languageModelResolver: (String) -> String?   // code → WhisperModel.name
```

defaulting to the compiled-in behavior and wired to the settings object in
`MilaApp.init`. Consequences:

- All four call sites keep calling `model(for: code)` unchanged:
  `TranscriptionService.swift:263`, `:483`, `:713`,
  `RecordingDetailView.swift:284`.
- The **best → selected → best** fallback chain in `model(for:)` is preserved
  verbatim, so a language whose model is mid-download still dictates.
- Tests inject a stub resolver rather than standing up settings.
- `WhisperModel.bestModel(for:)` loses its Hebrew branch and returns the
  multilingual turbo. The he → ivrit.ai join then lives in exactly one place:
  the seed table.
- **`WhisperModel.languageHint` is deleted.** It is set on both models and
  read nowhere; the language→model join replaces it.

### Remote

`RemoteTranscriptionSettings` is the only place where **storage**, not just
logic, encodes exactly two languages (`model` + `englishModel`).

- The per-language id moves onto the language record as `remoteModelID`.
- `model` remains the primary/default for any language without one.
- `model(for:)` becomes `resolve(code).remoteModelID ?? Self.resolve(model)`,
  **except** that the explicit legacy `"auto"` branch is preserved: `auto`
  resolves as if it were the English entry. This is deliberate and already
  tested (`RemoteTranscriptionTests:101`) — only a multilingual model can
  serve a detect-the-language request, and English is seeded to the
  multilingual turbo. Dropping the branch would silently reroute
  re-transcription of pre-`auto`-retirement recordings to the Hebrew-only
  primary.
- Migration: the existing `remote.englishModel` value is written into the
  English entry's `remoteModelID` on first launch of the new build **only
  when it is non-empty after trimming; otherwise `nil`**. Today `model(for:)`
  short-circuits on `guard !english.isEmpty else { return primary }`, so a
  single-model endpoint puts every language on the primary. Migrating `""`
  verbatim would make `remoteModelID ?? primary` yield `""` instead of
  falling through — sending an empty model id to the endpoint.
  `remoteModelID` is trimmed-and-nilled on every write for the same reason.
- `MilaConfig` keeps accepting its `englishModel` field for backward
  compatibility, applying it to the English entry.

**Decision — importing a config naming an unconfigured language is ignored,
not auto-added.** `MilaConfigImporter.apply` currently does
`language.current = fromCode(langCode)` (`:191`). Setting the active code to a
language that is not in the list would violate invariant 3 by a different
door. Since the list is user-owned, a config file should not silently grow it.
The preview row (`:152`) uses `resolve` for its label and says the language
will be skipped; `apply` leaves the active language untouched. Flip this to
auto-add from the built-in table if configs should be able to provision
languages.

---

## Hotkeys

`HotkeyAction` stops being a `CaseIterable` enum and becomes a struct with a
stable string `id` (`"dictate.he"`), used as both the dictionary key and the
UserDefaults key suffix (`hotkey.dictate.he`).

- **Legacy keys migrate:** `hotkey.dictateHebrew` / `hotkey.dictateEnglish`
  are read once and rewritten, so nobody loses ⌘3 / ⌘2.
- **`carbonID` is allocated per registration pass** from list position. It
  only needs uniqueness among currently-live registrations, which avoids any
  hash-collision scheme for user-supplied codes.
- **New languages default to unbound.** Auto-assigning ⌘4, ⌘5… invites
  `eventHotKeyExistsErr` and quietly stomps other apps' shortcuts. An explicit
  "Set shortcut" is the honest default.
- `binding(for:)` therefore returns an **optional**. The dictation rows in
  `MilaApp.swift:1102` and `HomeView.swift:223` become a `ForEach` over the
  configured list, rendering "Set shortcut" where unbound.

---

## Live AI output language

`LiveAISettings.OutputLanguage` is a **second, independent** enum
(`auto`/`en`/`he`). On `auto` — the default — both
`RecordingSummarizer.swift:368` and `LiveAISession.swift:467` resolve via
`isPredominantlyHebrew ? "Hebrew" : "English"`. Left alone, the first Russian
recording gets an **English** summary and action items.

- `OutputLanguage` becomes a stored `String`: `"auto"` or a language code.
- The picker offers `Auto` + the configured list.
- `auto` resolves to **the recording's own language code** —
  `resolve(recording.language).displayName` — which is both more accurate and
  more predictable than inspecting the text.
- The `isPredominantlyHebrew` heuristic survives **only** as the last resort,
  for a recording whose code resolves to a synthesized unknown.
- `LiveAIRecordingView.aiOutputIsRTL` reads the resolved `isRTL` instead of
  switching on the enum.

---

## UI

**Settings → Languages** (new `SettingsTab` case at `SettingsView.swift:23`,
switch arm at `:284`):

- rows showing flag / name / code / model / shortcut
- add-and-edit sheet: Name, Code, Flag, Script (RTL/LTR), Model (catalog
  picker), optional remote model id, optional shortcut
- remove, disabled at one entry; confirm when removing the active language

**Re-transcribe becomes a submenu.** `RecordingLanguage.other` assumed a pair
and is deleted. `RecordingDetailView.swift:477` and
`RecordingContextMenu.swift:123` become "Re-transcribe in ▸" over the
configured list minus the recording's current language.

**Decision — the submenu also offers the recording's own language when it is
no longer configured.** Otherwise: delete Hebrew, open a `he` recording,
re-transcribe it in English by accident, and there is no way back to Hebrew —
whereas today's `.other` always round-trips. `resolve` already returns the
built-in Hebrew entry with its model, so this costs nothing but an explicit
union. Flip this only if you would rather a removed language be truly gone
from every menu, accepting the one-way trip.

**Toolbar picker** (`ContentView.swift:461`) iterates the configured list
instead of `allCases`; otherwise unchanged.

**Built-in constants.** The built-in table is exposed as
`RecordingLanguage.builtInHebrew` / `.builtInEnglish` statics, because a
struct has no `.hebrew` case and `FileTranscriber.importFile`
(`FileTranscriber.swift:13`) takes `language: RecordingLanguage = .hebrew` as
a **default argument**. That default becomes `.builtInHebrew`, preserving
today's behavior exactly — every real caller passes
`languageSettings.current`, so the default is only a compile-time
placeholder.

---

## Script direction: `isRTL` replaces eight hardcoded checks

RTL is not currently a property of anything — it is the literal comparison
`language == "he"`, repeated across the views, sometimes OR'd with the
`isPredominantlyHebrew` text heuristic:

- `DictationOverlayWindow.swift:122`
- `RecordingDetailView.swift:473`
- `LiveAIRecordingView.swift:64`, `:105`, `:418`, `:859`
- `AIOverviewSection.swift:55`
- `LiveAIRecordingView.aiOutputIsRTL` (`:101`, covered above)

All become `resolve(code).isRTL`. Without this the new `isRTL` field is
decorative: adding Arabic or Farsi would store `isRTL = true` and still render
left-to-right everywhere. Russian is LTR, so the motivating case would not
have exposed it.

The `isPredominantlyHebrew` heuristic is **kept** where it currently OR's with
the code — it catches a recording whose declared language is wrong, and
`HebrewDetection.swift` is unaffected by this change.

---

## Performance note

`RecordingLanguageSettings` remains an App-level `@StateObject`
(`MilaApp.swift:338`). Adding a mutable `languages` array is safe under the
#280 rule in CLAUDE.md: it publishes on user edits, not at audio or timer
cadence, so the `AppSceneChurnTests` publish budget is unaffected. Stated here
so a reviewer does not have to re-derive it.

---

## Testing

**Replaced contracts** (these fail by design; one is a semantic replacement,
not an update):

- `test_unknown_language_code_falls_back_to_hebrew` → **replaced** by
  "unknown code resolves to a display-only synthesized entry"
- `test_only_hebrew_and_english_are_offered` → seeded-list assertion
- `test_persisted_auto_migrates_to_hebrew` → legacy `"auto"` still resolves
- `.other` pair assertions → deleted with the property
- `ModelManagerTests.test_best_model_for_language_routes_hebrew_to_ivrit` →
  moves to the seed table / resolver
- `RemoteTranscriptionTests:72-109` → per-language `remoteModelID`
- `MilaConfigTests:221` → language round-trip

**New coverage:**

- seeding happens on absent key, and not over an existing list
- adding a language: code normalization, duplicate rejection
- deleting the active language re-points `recording.language`
- **deleting Hebrew while `he` recordings exist** — they still resolve, still
  display RTL, still re-transcribe
- hotkey legacy-key migration preserves ⌘2 / ⌘3; a new language is unbound
- `remote.englishModel` migrates into the English entry
- Live AI `auto` follows the recording's code, with the heuristic only for
  unknown codes
- an RTL language added by the user renders right-to-left — asserted on
  `resolve(code).isRTL`, since the eight call sites are view code
- the re-transcribe submenu still offers the recording's own language after
  that language is removed from the list (the round-trip guarantee)
- an imported config naming an unconfigured language leaves the active
  language untouched
- a remote endpoint with an empty `englishModel` migrates to `nil`, and every
  language still resolves to the primary

---

## Risks

- **Silent breakage of old recordings** if `resolve` is skipped in favor of a
  single lookup. Mitigated by the dedicated "delete Hebrew, old rows survive"
  test.
- **Hotkey registration failures** if new languages were auto-bound. Mitigated
  by defaulting to unbound.
- **Scope creep into custom model URLs.** Explicitly deferred; the catalog
  reference keeps it additive.
