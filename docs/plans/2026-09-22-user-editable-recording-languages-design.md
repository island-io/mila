# User-Editable Recording Languages — Design

**Status:** approved design (rev 2), not yet implemented
**Date:** 2026-09-22

**Goal:** Replace the hardcoded two-case `RecordingLanguage` enum with a
user-editable list. The user can add a language (picked from what whisper
supports), set its flag and transcription model, and remove one — while every
recording already on disk keeps displaying and re-transcribing correctly,
including in a language that has since been removed from the list.

**Motivating case:** Russian. The catalog's `openaiTurbo` is the multilingual
`large-v3` turbo checkpoint and handles Russian well, so nothing about the
engine blocks this. The limit is purely that the language set is a two-case
enum.

### Rev 2 changes (review against the code)

1. **Remove = hide, not delete.** Rev 1 deleted the record and fell back to a
   compiled-in table that only knew Hebrew and English — so deleting a
   user-added Arabic turned its old recordings LTR with 🏳️, and deleting
   English lost its remote model id. A hidden record keeps everything; the
   built-in fallback table and its statics are gone.
2. **Add picks from whisper's own language list** instead of free-text code.
   The stored code is handed to whisper verbatim (`WhisperEngine.languageParams`
   only rewrites `""`), so a typed `ru-RU` or `rus` would reach
   `whisper_lang_id` and not match. Picking also removes code validation and
   the add-time variant-collision rule.
3. **`displayName` and `isRTL` are derived from `Locale`**, not stored or typed.
4. **Legacy `"auto"` keeps displaying as Hebrew** (today's `fromCode` contract)
   while still routing to the multilingual model — rev 1 turned it into
   "AUTO 🏳️".
5. **Per-language remote model ids are cut** (non-goal). Rev 1 would have sent
   a new language with no id to the primary — the Hebrew ivrit fine-tune on a
   two-model endpoint. The existing two slots already express the right rule;
   no remote migration is needed.

---

## Non-goals

Each is additive later and none changes the design below.

- **User-supplied model URLs.** A language picks from the built-in catalog.
  Pasting an arbitrary ggml URL collides with the SHA-256 pinning in
  `WhisperModel` (`ModelManager.swift:14`), which exists so a compromised
  HuggingFace repo is rejected before bytes reach the GGML loader. It needs a
  trust-on-first-use flow and its own security review. Because the language
  record stores a model *name*, that feature only grows the catalog.
- **Per-language remote model ids.** See *Model routing → Remote*. Adding an
  optional `remoteModelID` override to the record later is purely additive.
- **Reordering the list.** Order is insertion order; seeds are `[Hebrew,
  English]`.
- **Languages whisper does not know.** Nothing can transcribe them.
- **Localizing Mila's own UI chrome.** This is the language spoken *into* the
  app, not the language the app's buttons are written in.

---

## Background: where "exactly two" is currently encoded

`RecordingLanguage` (`Mila/Models/RecordingLanguageSettings.swift:18`) is a
two-case `String` enum. Five facts hang off it:

| Fact | Today |
|---|---|
| Display name + flag | `displayName` / `flagEmoji` switches |
| Script direction | literal `language == "he"` at eight view sites |
| Local model | `WhisperModel.bestModel(for:)` switch (`ModelManager.swift:74`) |
| Remote model id | `fromCode` switch over `model` / `englishModel` (`RemoteTranscriptionSettings.swift:394`) |
| Dictation hotkey | `HotkeyAction.dictateHebrew` / `.dictateEnglish`, `CaseIterable` |

**Already dynamic:** `Recording.language` is stored as a `String` ISO code, not
as the enum. recordings.json, MilaKit's `StoredRecording`, and the
`StoredRecordingDriftTests` tripwire are **untouched by this change**. The enum
was only ever a UI and routing layer, which makes this a type swap rather than
a schema migration.

---

## Data model

```swift
struct RecordingLanguage: Identifiable, Hashable, Codable {
    var code: String        // a whisper language code: "he", "ru" — the id
    var flagEmoji: String   // "🇮🇱"; "" = none (UI shows the code as a badge)
    var modelName: String?  // → WhisperModel.name; nil = multilingual default
    var isHidden: Bool      // removed by the user; kept so old rows still resolve
    var id: String { code }

    var displayName: String // Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code.uppercased()
    var isRTL: Bool         // Locale.Language(identifier: code).characterDirection == .rightToLeft
}
```

- **Derived, not stored:** `displayName` uses the English locale to match
  Mila's English-only chrome; `isRTL` comes from CLDR, so Arabic, Farsi, Urdu
  and Yiddish are right without the user knowing to tick a box. Both APIs were
  checked on the macOS 14 target (`"ar"` → RTL, `"ru"` → "Russian").
- **Flag stays user-editable** because a language is not a country (English →
  🇬🇧 or 🇺🇸 is a preference, as the current code comment says).
- `modelName` is a catalog reference, not an inline model definition.

---

## Storage and seeding

- New namespaced key **`recording.languages`**, a JSON array of the struct
  (including hidden entries).
- The existing **`recording.language`** key keeps its exact meaning: the active
  code. Nothing to migrate.
- **Seeding triggers on the key being absent**, not on the list being empty.
  If the stored bytes fail to decode, the seeds are used in memory and the
  stored value is left alone until the user's next edit, so a decode bug never
  silently overwrites a user's list.

  | code | flag | model | hidden |
  |---|---|---|---|
  | `he` | 🇮🇱 | `ivrit-ai-whisper-large-v3` | no |
  | `en` | 🇬🇧 | `openai-whisper-large-v3-turbo` | no |

Existing users see no behavioral change on first launch of the new build.

---

## Resolution: two lookups, never one

This is the core of the design and the part most easily got wrong.

```swift
func configured(_ code: String) -> RecordingLanguage?  // visible entries only — every picker
func resolve(_ code: String) -> RecordingLanguage      // never nil — displaying and
                                                       // re-transcribing stored rows
```

**Why the split.** "Remove Hebrew" cannot mean purge. Every recording already
on disk stores `language: "he"`. Removal means *stop offering it for new
recordings*, while stored codes stay resolvable **forever**.

`resolve` order (all steps lowercase first):

1. **legacy aliases** → `he`: `iw` (Locale does not canonicalize it — checked)
   and `auto` (the retired auto-detect; `fromCode` documents that those
   recordings are read as Hebrew). Model routing overrides `auto` separately —
   see below.
2. exact match in the list, **hidden entries included**
3. variant match — `he-IL`, `he_IL` → `he`. The existing `isVariant` guard is
   kept verbatim: a bare `hasPrefix` would route `"enochian"` to English.
4. synthesized, not stored: the code with `Locale`-derived name and direction,
   no flag, `modelName` nil. Reachable only by a code that was never in the
   list — a hand-edited file, or a config import that was skipped.

Step 2 including hidden entries is what makes removal *correct* rather than
merely non-crashing: after removing Hebrew, `resolve("he")` still returns
Hebrew with its flag and its ivrit.ai model.

**Behavior change, stated:** today an unrecognised code (say `"fr"`) displays as
Hebrew. After this change it displays as French. Only `auto` and `iw` keep the
Hebrew fallback; that is what the legacy contract was for.

**Every `RecordingLanguage.fromCode(…)` call site becomes `resolve`:**
`RecordingContextMenu.swift:123`, `RecordingDetailView.swift:179` and `:477`,
`RemoteTranscriptionSettings.swift:399`, `MilaConfigImporter.swift:152` and
`:191`. Pickers iterate the visible list instead.

> **Regression note for reviewers.** If the list is built but this split is
> not, removing Hebrew silently breaks display and re-transcription of every
> pre-existing Hebrew recording — and the current `fromCode` tests pass the
> whole way, because they exercise the code path being replaced.

---

## Invariants

1. **At least one visible entry.** Remove is disabled at one visible entry.
2. **Codes are unique across the whole list, hidden included.** Adding a code
   that exists as hidden **un-hides it** with its previous flag, model and
   hotkey, so remove-then-add is a lossless round-trip. Because codes come
   from whisper's list, which has only base codes, a variant can never be
   added.
3. **The active code is always visible.** Removing the active language
   re-points `recording.language` at the first visible entry.
4. Removing a language never touches any stored recording.

---

## Model routing

### The `auto` exception, in one place

Legacy `auto` *displays* as Hebrew (resolve step 1) but has always
*transcribed* on the multilingual model: locally `bestModel("auto")` falls to
the turbo's `default:` branch, and remotely `model(for: "auto")` returns the
English slot (`RemoteTranscriptionTests:101`). Only a multilingual model can
serve a detect-the-language request. Both routers therefore check
`code == "auto"` **before** calling `resolve`, and route it as multilingual.
Routing through `resolve("auto")` would send it to ivrit.ai.

### Local

`ModelManager` must not learn about `RecordingLanguageSettings`. That would be
the wrong dependency direction and would tangle two App-level objects.
Instead:

```swift
var languageModelResolver: (String) -> String?   // code → WhisperModel.name
```

It defaults to the compiled-in behavior and is wired to the settings object in
`MilaApp.init`. Consequences:

- All four call sites keep calling `model(for: code)` unchanged:
  `TranscriptionService.swift:263`, `:483`, `:713`,
  `RecordingDetailView.swift:284`.
- The **best → selected → best** fallback chain in `model(for:)` is preserved
  verbatim, so a language whose model is mid-download still dictates.
- Tests inject a stub resolver rather than standing up settings.
- `WhisperModel.bestModel(for:)` loses its Hebrew branch and returns the
  multilingual turbo. The he → ivrit.ai join then lives in exactly one place:
  the seed.
- **`WhisperModel.languageHint` is deleted.** It is set on both models and
  read nowhere.

### Remote

`RemoteTranscriptionSettings` keeps its two slots and both storage keys
unchanged. `model` holds the primary (the ivrit.ai fine-tune in the tested
setup) and `englishModel` holds the multilingual one. The only change is in
`model(for:)`:

```
englishModel empty           → primary        (single-model endpoint, unchanged)
code == "auto"               → englishModel   (unchanged)
resolve(code).code == "he"   → primary        (unchanged)
anything else                → englishModel   (was: fromCode → Hebrew → primary)
```

That last row is the fix. Russian goes to the multilingual model, not to the
Hebrew fine-tune. The Settings label for `englishModel` changes to
"Multilingual model (all languages except Hebrew)". The storage key and the
`MilaConfig` field keep their names for compatibility.

**Why not per-language ids (rev 1):** two problems. A new language with no id
would fall to the primary, which is Hebrew-only. And migrating an empty
`englishModel` into a per-language slot needed special-casing to avoid sending
`""` as a model id. The two-slot rule already describes the real split:
Hebrew specialist vs everyone else. A per-language override is a non-goal and
stays additive.

**Known asymmetry.** Remote pins Hebrew to the primary even if the user sets
Hebrew's *local* model to the turbo. The two settings are independent today
too.

### Config import

**Decision: a config naming a language that is not visible is ignored, not
auto-added.** `MilaConfigImporter.apply` currently does
`language.current = fromCode(langCode)` (`:191`). Setting the active code to a
language that is not visible would violate invariant 3 by another route. The
list belongs to the user, so a config file should not silently grow it. The
preview row (`:152`) uses `resolve` for its label and says the language will
be skipped. `apply` leaves the active language untouched. Flip this to
auto-add (or auto-un-hide) if configs should be able to provision languages.

---

## Hotkeys

`HotkeyAction` stops being a `CaseIterable` enum and becomes a struct with a
stable string `id` (`"dictate.he"`). That id is both the dictionary key and the
UserDefaults key suffix (`hotkey.dictate.he`).

- **Legacy keys migrate:** `hotkey.dictateHebrew` / `hotkey.dictateEnglish`
  are read once and rewritten, so nobody loses ⌘3 / ⌘2.
- **`carbonID` is allocated per registration pass** from list position. It
  only needs to be unique among the registrations currently live.
- **Hidden languages are not registered**, but their binding stays in
  UserDefaults and comes back on un-hide (invariant 2).
- **New languages default to unbound.** Auto-assigning ⌘4, ⌘5… invites
  `eventHotKeyExistsErr` and quietly takes over other apps' shortcuts.
- `binding(for:)` therefore returns an **optional**. The dictation rows in
  `MilaApp.swift:1102` and `HomeView.swift:223` become a `ForEach` over the
  visible list, rendering "Set shortcut" where unbound.

---

## Live AI output language

`LiveAISettings.OutputLanguage` (`auto`/`en`/`he`) is a **second, independent**
enum. On `auto`, the default, both `RecordingSummarizer.swift:369` and
`LiveAISession.swift:467` fill `{{LANGUAGE}}` with
`isPredominantlyHebrew ? "Hebrew" : "English"`. That is deliberate, because
LLMs follow "Output in Hebrew" more reliably than "match the transcript"
(comment at `LiveAISession.swift:459`). It also means the first Russian
recording gets an **English** summary and action items.

- `OutputLanguage` becomes a stored `String`: `"auto"` or a language code. The
  raw values are already `auto`/`en`/`he`, so **no migration**.
- The picker offers `Auto` + the visible list. If the selected code is later
  hidden, it keeps working through `resolve`, and the picker shows it until
  the user changes it.
- `auto` resolves to `resolve(code).displayName` for the recording's (or live
  session's) own code. The result is still a concrete language name.
- The heuristic survives for two codes where the declared language says
  nothing: legacy `auto`, and a synthesized unknown (resolve step 4).
- `LiveAIRecordingView.aiOutputIsRTL` reads the resolved `isRTL`.

---

## Script direction: `isRTL` replaces eight hardcoded checks

RTL is not currently a property of anything. It is the literal comparison
`language == "he"`, repeated across the views and sometimes OR'd with the
`isPredominantlyHebrew` text heuristic:

- `DictationOverlayWindow.swift:122`
- `RecordingDetailView.swift:473`
- `LiveAIRecordingView.swift:64`, `:105`, `:418`, `:859`
- `AIOverviewSection.swift:55`
- `LiveAIRecordingView.aiOutputIsRTL` (`:101`, covered above)

All become `resolve(code).isRTL`. Without this, a derived `isRTL` would do
nothing: Arabic would still render left-to-right everywhere. Russian is LTR,
so the motivating case would not have caught it.

Where the code currently OR's in the `isPredominantlyHebrew` heuristic, the
heuristic is **kept**. It catches a recording whose declared language is
wrong, and `HebrewDetection.swift` is unaffected.

---

## UI

**Settings → Languages** (new `SettingsTab` case at `SettingsView.swift:23`,
switch arm at `:284`):

- rows for the visible entries, showing flag / name / code / model / shortcut
- **Add** sheet: a searchable picker over whisper's supported languages,
  excluding those already visible. The list comes from a new
  `WhisperEngine.supportedLanguageCodes` in TranscriptionCore, which wraps
  `whisper_lang_max_id` / `whisper_lang_str`. MilaKit is not involved. Then
  Flag (optional), Model (catalog picker, defaulting to the multilingual
  turbo), and Shortcut (optional).
- **Edit** sheet: the same fields, with the language itself fixed.
- **Remove**: disabled at one visible entry. Confirm before removing the
  active language. The confirmation text says existing recordings are kept
  and re-adding the language restores its settings.

**Re-transcribe becomes a submenu.** `RecordingLanguage.other` assumed a pair
and is deleted. `RecordingDetailView.swift:477` and
`RecordingContextMenu.swift:123` become "Re-transcribe in ▸" over the visible
list minus the recording's current language.

**Decision: the submenu also offers the recording's own language when that
language is hidden.** Otherwise a user could remove Hebrew, re-transcribe an
old `he` recording in English by accident, and have no way back, whereas
today's `.other` always round-trips. `resolve` returns the hidden record with
its model, so this costs one explicit union.

**Toolbar picker** (`ContentView.swift:461`) iterates the visible list instead
of `allCases`. Otherwise it is unchanged.

**`FileTranscriber.importFile`'s default argument is deleted.** Its
`language: RecordingLanguage = .hebrew` (`FileTranscriber.swift:13`) has no
case to name on a struct. Both callers already pass `languageSettings.current`
(`VoiceMemosImporter.swift:283`, `QuickActionsController.swift:1502`), so the
default was never used.

---

## Performance note

`RecordingLanguageSettings` remains an App-level `@StateObject`
(`MilaApp.swift:338`). Adding a mutable `languages` array is safe under the
#280 rule in CLAUDE.md. It publishes on user edits, not at audio or timer
cadence, so the `AppSceneChurnTests` publish budget is unaffected.
`displayName` and `isRTL` are computed on each read. Both are cheap `Locale`
lookups done at view-render rate, not per audio buffer.

---

## Testing

**Replaced contracts.** These fail by design. The first one replaces a
behavior rather than updating it.

- `test_unknown_language_code_falls_back_to_hebrew`: **replaced** by two tests.
  "`auto` and `iw` resolve to `he`", and "an unknown code such as `fr`
  resolves to a synthesized French entry".
- `test_only_hebrew_and_english_are_offered` → seeded-list assertion
- `test_persisted_auto_migrates_to_hebrew` → the active code `auto` loads as
  `he`, and `resolve("auto").code == "he"`
- `.other` pair assertions → deleted with the property
- `ModelManagerTests.test_best_model_for_language_routes_hebrew_to_ivrit` →
  moves to the seed and resolver. Add "`auto` routes to the turbo even though
  it resolves to Hebrew".
- `RemoteTranscriptionTests:72-109` → kept as is. Add a row: `ru` on a
  two-model endpoint routes to `englishModel`, not the primary.
- `MilaConfigTests:221` → language round-trip

**New coverage:**

- seeding happens when the key is absent, and never over an existing or
  undecodable value
- removing hides. Re-adding the same code un-hides it with its flag, model and
  hotkey intact.
- removing the active language re-points `recording.language` to a visible
  entry
- **removing Hebrew while `he` recordings exist**: they still resolve, still
  display RTL, and still re-transcribe on ivrit.ai. The same holds for a
  user-added RTL language (`ar`), which is the case rev 1 got wrong.
- `isRTL` is derived: `ar`, `fa`, `he` are RTL; `ru`, `en` are not
- the add picker offers only whisper-supported codes and excludes visible ones
- hotkey legacy-key migration preserves ⌘2 / ⌘3. A new language is unbound. A
  hidden language is not registered.
- Live AI `auto` follows the recording's code, and uses the heuristic only
  for `auto` and synthesized codes
- the re-transcribe submenu still offers the recording's own language after
  that language is hidden
- an imported config naming a language that is not visible leaves the active
  language untouched

---

## Risks

- **Silent breakage of old recordings** if `resolve` is skipped in favor of a
  single lookup. Mitigated by the dedicated "remove Hebrew, old rows survive"
  test.
- **`auto` routed through `resolve`** would move legacy re-transcription onto
  ivrit.ai. Mitigated by routing it before resolve, and pinned by a test on
  each side (local and remote).
- **Hotkey registration failures** if new languages were auto-bound. Mitigated
  by defaulting to unbound.
- **Scope creep** into custom model URLs or per-language remote ids. Both are
  explicitly deferred and both are additive.
