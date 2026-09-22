# User-Editable Recording Languages — Implementation Plan

**Design:** `docs/plans/2026-09-22-user-editable-recording-languages-design.md` (rev 2)
**Branch:** `feat/user-editable-languages`
**Date:** 2026-09-22

Every task ends with a commit, and after each one `make test` and
`make package-test` pass. Tests go first within each task. Line numbers were
taken from `60dfe63` and may drift by a few lines.

The enum → struct swap cannot be split across commits without a temporary
second type, so Task 2 is the single atomic swap. It is deliberately
behavior-preserving: seeds only, no UI, and routing still hardcoded. Everything
before it is additive, and everything after it changes one behavior at a time.

---

## Task 0 — GitHub issue

Open the issue with `gh issue create` before any PR, as
`.claude/rules/pull-requests.md` requires. Use the design doc's Goal and the
Background table as its body. The PR description later says `Closes #<n>`.
Confirm with the user before creating it.

---

## Task 1 — whisper's language list (TranscriptionCore)

**Files:** `Packages/TranscriptionCore/Sources/TranscriptionCore/WhisperEngine.swift`,
`Packages/TranscriptionCore/Tests/TranscriptionCoreTests/LanguageParamsTests.swift`

1. Tests:
   - `supportedLanguageCodes` contains `he`, `en`, `ru`, `ar`
   - it has no duplicates
   - every entry is lowercase with no `-` or `_`
   - it does not contain `auto`
2. Add `public static let supportedLanguageCodes: [String]`, built from
   `0...whisper_lang_max_id()` via `whisper_lang_str`. It needs no loaded
   model; these are static tables in whisper.cpp.
3. `make package-test`.
4. Commit `feat(transcription-core): expose whisper's supported language codes`.

---

## Task 2 — swap the enum for the struct (behavior-preserving)

**Files:**
- `Mila/Models/RecordingLanguageSettings.swift` (rewrite)
- every file that uses `RecordingLanguage`:
  - `ContentView`
  - `RecordingContextMenu`
  - `RecordingDetailView`
  - `FileTranscriber`
  - `RemoteTranscriptionSettings`
  - `MilaConfigImporter`
  - `SettingsView`
- `MilaTests/RecordingLanguageSettingsTests.swift`

### 2a. Tests first (`RecordingLanguageSettingsTests`)

Rewrite the file against the new API. Keep every contract that survives, and
replace the ones the design replaces.

| Existing test | Becomes |
|---|---|
| `test_fresh_install_defaults_to_hebrew` | kept |
| `test_assignment_persists_across_instances` | kept (assign by code) |
| `test_other_returns_opposite_language` | **deleted** (`.other` goes) |
| `test_flag_emojis_are_stable` | seeds carry 🇮🇱 / 🇬🇧 |
| `test_language_code_decoding_handles_legacy_iso_variants` | `resolve("he-IL"/"he_IL"/"iw"/"en-US").code` |
| `test_unknown_language_code_falls_back_to_hebrew` | **replaced**: `resolve("auto").code == "he"`; `resolve("fr")` is synthesized French, not stored, flag `""`, model nil |
| `test_language_code_decoding_does_not_prefix_match_unrelated_codes` | `resolve("enochian").code == "enochian"` (synthesized; never `en`) |
| `test_only_hebrew_and_english_are_offered` | `visible.map(\.code) == ["he", "en"]` on a fresh suite |
| `test_legacy_auto_code_reads_as_hebrew` | kept via `resolve` |
| `test_persisted_auto_migrates_to_hebrew` | kept: stored `auto` loads as `current.code == "he"` and rewrites the key |
| `test_fresh_install_does_not_write_a_language` | kept; also asserts `recording.languages` **is** written by seeding |

New tests in this task:
- `test_seeding_happens_only_when_the_key_is_absent`: pre-write a list with
  only `ru` and assert it is not reseeded.
- `test_undecodable_list_uses_seeds_without_overwriting`: garbage bytes stay
  byte-identical after `init`.
- `test_display_name_and_rtl_are_derived`: `ar`/`fa`/`he` RTL; `ru`/`en` LTR;
  `ru` → "Russian".

### 2b. Implementation

- `struct RecordingLanguage` exactly as in the design. `displayName` and
  `isRTL` are computed; `CodingKeys` exclude them.
- `static let seeds: [RecordingLanguage]` for he and en.
- `RecordingLanguageSettings`:
  - `@Published private(set) var languages: [RecordingLanguage]`
  - `@Published var current: RecordingLanguage`, persisted as its code under
    the unchanged key
  - `var visible: [RecordingLanguage]`
  - `configured(_:)` / `resolve(_:)` following the design's four-step order
  - the private `isVariant(_:of:)` helper moved over verbatim, including its
    doc comment about `enochian`
- `resolve` is also needed by non-MainActor code (`RemoteTranscriptionSettings`
  and the summarizer). Put the pure lookup in a `nonisolated static func
  resolve(_ code: String, in list: [RecordingLanguage]) -> RecordingLanguage`,
  and have the instance method call it.
- **Call sites, mechanically.** Behavior stays the same while the list equals
  the seeds:
  - `fromCode(x)` → `languageSettings.resolve(x)`
  - `.other` in `RecordingDetailView.swift:477` / `RecordingContextMenu.swift:123`:
    for now, take the first visible entry whose code differs. The submenu
    arrives in Task 7.
  - `allCases` in `ContentView.swift:461` → `visible`
  - `FileTranscriber.swift:13`: delete the `= .hebrew` default
  - `RemoteTranscriptionSettings.model(for:)` and `MilaConfigImporter`: keep
    the current switch semantics via `resolve(code).code == "he"` /
    `== "en"`. Task 4 changes the remote rule.
- Pass the settings object where a call site had only the static
  `fromCode`. `RecordingContextMenu` / `RecordingDetailView` already sit
  under the environment object. `RemoteTranscriptionSettings` uses the static
  `resolve(_:in: RecordingLanguage.seeds)` until Task 4.

### 2c. Verify and commit

`make test`, including `StoredRecordingDriftTests`, which must be untouched and
green. Commit `refactor(language): RecordingLanguage becomes a stored,
seeded list`.

---

## Task 3 — local model routing through the list

**Files:** `Mila/Transcription/ModelManager.swift`, `Mila/App/MilaApp.swift`,
`MilaTests/ModelManagerTests.swift`

1. Tests:
   - `test_best_model_for_language_routes_hebrew_to_ivrit` becomes a test
     with a stub resolver: `he` → ivrit, `ru` → turbo (`modelName` nil),
     unknown → turbo
   - **`test_auto_routes_to_turbo_even_though_it_resolves_to_hebrew`**
   - the fallback chain is unchanged: best not installed → selected → best
2. Add `var languageModelResolver: (String) -> String?`, defaulting to
   `{ _ in nil }`.
3. In `model(for:)`, handle `code == "auto"` first (turbo), then
   `resolver(code).flatMap(WhisperModel.named) ?? .openaiTurbo`, then the
   existing fallback chain, unchanged.
4. `bestModel(for:)` loses its Hebrew branch. Delete `languageHint` from both
   catalog entries and the struct.
5. `MilaApp.init`: set
   `modelManager.languageModelResolver = { languageSettings.resolve($0).modelName }`.
   Capture the settings object, which is already constructed there.
6. Commit `feat(language): local model comes from the language entry`.

---

## Task 4 — remote routing rule

**Files:** `Mila/Models/RemoteTranscriptionSettings.swift`, the Settings remote
section in `SettingsView.swift`, `MilaTests/RemoteTranscriptionTests.swift`

1. Tests: `:72-109` stay as they are. Add:
   - `test_non_hebrew_language_routes_to_the_multilingual_model`: `ru` →
     `englishModel` on a two-model endpoint
   - `ru` → primary when `englishModel` is empty
   - removed `he` (hidden) still → primary
2. `model(for:)`, in order:
   - empty `englishModel` → primary
   - `auto` → english
   - `resolve(code).code == "he"` → primary
   - else → english

   It needs the list only for aliases and variants. `resolve(_:in: seeds)` is
   enough, because a hidden he is still `he`. No injection is needed.
3. Relabel the field "Multilingual model (all languages except Hebrew)". The
   key `remote.englishModel` and the `MilaConfig` field stay the same.
4. Commit `fix(remote): non-Hebrew languages use the multilingual model`.

---

## Task 5 — list editing API and invariants

**Files:** `Mila/Models/RecordingLanguageSettings.swift`, tests

1. Tests:
   - `add("ru")` appends a visible entry with an empty flag and nil model
   - `add` rejects a code not in `WhisperEngine.supportedLanguageCodes`
   - `add` of an already-visible code is a no-op
   - `add` of a hidden code un-hides it, keeping its flag and model
   - `remove` sets `isHidden` and keeps the record in `languages`
   - `remove` of the last visible entry is refused
   - removing the active language re-points `current` to the first visible
     entry and persists it
   - `update(_:)` changes flag and model and persists across instances
   - **removing Hebrew with `he` recordings**: `resolve("he")` still has its
     flag, `isRTL`, and the ivrit model. The same holds for a user-added `ar`.
2. Implement `add(code:)`, `remove(code:)`, `update(_:)`. Each call persists
   the whole array once, so there is one publish per edit (the #280 rule).
3. Commit `feat(language): add, hide and edit languages`.

---

## Task 6 — hotkeys keyed by language code

**Files:**
- `Mila/Dictation/HotkeyManager.swift`
- `Mila/Dictation/HotkeySettings.swift`
- `Mila/Dictation/DictationController.swift`
- `Mila/App/MilaApp.swift:1102`
- `Mila/Views/HomeView.swift:223`
- `SettingsView.swift:505-620`
- `MilaTests/HotkeySettingsTests.swift`

1. Tests:
   - `test_fresh_install_returns_compiled_in_defaults`: `en` ⌘2, `he` ⌘3
   - legacy migration:
     - a custom binding stored under `hotkey.dictateHebrew` loads for `he`
       and is rewritten to `hotkey.dictate.he`
     - the old key is removed
     - with no legacy key present, nothing is written
   - `binding(for: "ru")` is nil, and `reset` of `ru` leaves it unbound
   - the existing persist, reset, display-name and codable tests are ported
2. `HotkeyAction` becomes
   `struct HotkeyAction: Hashable, Identifiable { let languageCode: String }`,
   with `id = "dictate.\(code)"`. `displayLabel` is
   `"\(resolve(code).displayName) dictation"`. The compiled defaults map is
   keyed by code and has only `en` and `he`.
3. `HotkeySettings`: `binding(for:) -> HotkeyBinding?`. Run a one-time
   legacy-key migration in `init`.
4. `HotkeyManager`: `dispatch(carbonID:)` (`:296`) currently matches
   `action.carbonID`. Instead:
   - store the id on `RegisteredHotkey`, taken from a monotonically
     increasing `UInt32` counter in `register`
   - match on the stored id

   Use a monotonic counter, not the design's "per-pass" allocation.
   `suspendAll`/`resumeAll` and single-action rebinding re-register outside
   any full pass, and a counter can never hand a live id out twice. Test:
   register `he`, rebind `he`, then register `ru`, and dispatch each id to the
   right handler.
5. `DictationController`:
   - take `RecordingLanguageSettings`
   - register over `visible` where a binding exists
   - re-register when `languages` or `bindings` change: a Combine sink with
     `removeDuplicates`, never inside a view
   - `State` cases keep carrying `HotkeyAction`
6. `MilaApp` menu (`:1102`) and `HomeView` hint: use
   `ForEach(languageSettings.visible)`, with the item disabled or showing
   "Set shortcut in Settings" when unbound.
7. Settings shortcut rows (`SettingsView.swift:518`): `ForEach` over the
   visible list. The conflict check (`:582`) iterates the visible list.
8. Commit `feat(dictation): one optional hotkey per configured language`.

---

## Task 7 — re-transcribe submenu, toolbar, config import

**Files:** `RecordingDetailView.swift:477`, `RecordingContextMenu.swift:123`,
`MilaConfigImporter.swift:152,:191`, `MilaTests/MilaConfigTests.swift`

1. Tests. Extract the submenu contents as a pure function
   `retranscribeTargets(for code:, in settings)` so the view does not need
   testing:
   - visible minus own
   - own included when own is hidden
   - config: `language: "ru"` with `ru` not visible leaves `current`
     unchanged, and the preview row says it will be skipped
   - config round-trip for `he`/`en` (`MilaConfigTests:221`)
2. "Re-transcribe in ▸" `Menu` in both places. Delete the Task 2 stopgap.
3. Importer: `apply` sets `current` only if `configured(code) != nil`.
4. Commit `feat(language): re-transcribe into any configured language`.

---

## Task 8 — RTL from the language

**Files:**
- `DictationOverlayWindow.swift:122`
- `RecordingDetailView.swift:473`
- `LiveAIRecordingView.swift:64, :105, :418, :859`
- `AIOverviewSection.swift:55`

1. Test: add `static func isRTL(code:text:in:) -> Bool` on
   `RecordingLanguageSettings`, returning `resolve(code).isRTL ||
   text.isPredominantlyHebrew`, and test it. All eight sites call it. The
   views then have no logic worth testing.
2. Replace each literal `== "he"`. Where a site has no heuristic today
   (`DictationOverlayWindow:122`), keep it heuristic-free: pass `text: ""` or
   use `resolve(code).isRTL` directly.
3. Run `grep -rn '== "he"' Mila/`. It should return nothing outside
   `RecordingLanguageSettings` and the remote rule.
4. Commit `feat(language): script direction follows the language`.

---

## Task 9 — Live AI output language

**Files:**
- `Mila/Models/LiveAISettings.swift`
- `RecordingSummarizer.swift:367`
- `LiveAISession.swift:465`
- `LiveAIRecordingView.swift:101`
- `SettingsView.swift:1938`
- `MilaTests/AISettingsKeyCompatibilityTests.swift`

1. Tests:
   - `test_outputLanguage_still_uses_the_liveAI_key`: now a String (`"he"`
     round-trips, no migration)
   - a new pure `static func promptLanguageName(output:recordingCode:text:list:)`:
     - `auto` + `ru` → "Russian"
     - `auto` + `he` → "Hebrew"
     - `auto` + legacy `auto` → heuristic
     - `auto` + unknown `xx` → heuristic
     - explicit `"ru"` → "Russian"
     - an explicit code that is now hidden → still its name
2. `outputLanguage: String`, default `"auto"`. Delete the enum. The three
   switch sites call `promptLanguageName`. `LiveAISession` passes the live
   session's language code, which it has from the recording session.
3. The Settings picker changes from `.segmented` to a menu picker, because
   the list can be long. It shows Auto + visible, plus the current value if
   it is hidden.
4. Commit `feat(live-ai): output language follows the recording's language`.

---

## Task 10 — Settings → Languages tab

**Files:** `SettingsView.swift` (`SettingsTab` `:23`, switch `:284`), a new
`Mila/Views/LanguagesSettingsView.swift`, and UI test identifiers

1. Add `case languages` after `.general`, titled "Languages", with an SF
   Symbol `globe`.
2. List rows show flag (or a code badge when the flag is empty), name, code,
   model, and shortcut.
3. The Add sheet is a searchable `List` over
   `WhisperEngine.supportedLanguageCodes` minus visible, sorted by
   `displayName`. Hidden codes are marked "previously added". After a pick it
   shows fields for flag, model picker (`WhisperModel.all`, default turbo) and
   shortcut capture (reuse the General tab's capture control).
4. The Edit sheet uses the same fields with the code fixed.
5. Remove is disabled at one visible entry. When removing the active
   language, a confirmation says existing recordings are kept and re-adding
   restores settings.
6. Move the dictation-shortcut rows here from General, and update the HomeView
   `.help` text ("Configure in Settings → Languages").
7. Run a manual pass on a build (`make dmg VERSION=…` or run from Xcode):
   - add Russian and dictate
   - remove Hebrew, then open an old Hebrew recording; it should be RTL and
     re-transcribable in Hebrew
   - re-add Hebrew; ⌘3 should be back
8. Commit `feat(settings): Languages tab`.

---

## Task 11 — wrap-up

- Run `grep -rn 'fromCode\|\.dictateHebrew\|\.dictateEnglish\|OutputLanguage\.' Mila MilaTests`.
  It should be empty.
- Run `make test`, then `make package-test`.
- The `AppSceneChurnTests` budget is expected to be unchanged. It is CI-only,
  so check the PR run.
- Mark the design doc status "implemented". Don't add release notes here;
  they belong to the release commit.
- Push and open a PR with `Closes #<issue>`, but only when the user asks.

---

## Order and risk

The main risk sits in Tasks 2 and 6: the type swap and Carbon registration.
Everything else is local. If Task 6 grows, it can ship as a follow-up PR,
because after Task 2 the seeds keep ⌘2/⌘3 working, with `HotkeyAction` still
mapping `dictateHebrew` to `he`. Every other task is small enough for one
sitting.
