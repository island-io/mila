# Sticky Model Deletion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deleting a downloaded Whisper model in Settings must stay deleted — `ensureDefaultModelsInstalled()` currently re-downloads any missing default model on every app launch (including after every update, since a launch is a launch), because `ModelManager` has no concept of "the user doesn't want this," only "is the file on disk."

**Architecture:** Add a persisted `Set<String>` of declined model names to `ModelManager`, backed by `UserDefaults.standard` (matching the existing `selectedModelName` persistence pattern in the same class — no new settings object, no new `UserDefaults` suite). `delete(_:)` adds the model to the set; `download(_:)` removes it (an explicit download request, whether from the Settings "Download" button or a future caller, means the user wants it again). The launch-time auto-download loop in `MilaApp.swift` gains one extra condition: skip any model that is declined.

**Tech Stack:** Swift, XCTest, `UserDefaults`.

## Global Constraints

- Persistence key: `"model.declinedNames"` (namespaced like the existing `"selectedModelName"` key already in this file — not `diarization.*`-style namespacing, since `ModelManager` doesn't use that convention).
- No new `UserDefaults` suite / no new `ObservableObject` — this lives inside the existing `ModelManager` class, consistent with how `selectedModelName` already works there.
- `WhisperModel` is `Hashable`/`Codable`; the declined set stores `WhisperModel.name` (`String`), matching how `installed: Set<String>` and `downloads: [String: Double]` already key by name.
- Existing tests in `MilaTests/ModelManagerTests.swift` save/restore `UserDefaults.standard.string(forKey: "selectedModelName")` around each test to avoid cross-test pollution — the new tests must do the same for `"model.declinedNames"`.

---

### Task 1: Persist declined models in `ModelManager`

**Files:**
- Modify: `Mila/Transcription/ModelManager.swift`
- Test: `MilaTests/ModelManagerTests.swift`

**Interfaces:**
- Produces: `ModelManager.isDeclined(_ model: WhisperModel) -> Bool` — later tasks (Task 2) call this from `MilaApp.swift`.
- Produces: `ModelManager.delete(_ model: WhisperModel) throws` (existing signature, unchanged) — now also marks the model declined.
- Produces: `ModelManager.download(_ model: WhisperModel)` (existing signature, unchanged) — now also clears declined status for that model.

- [ ] **Step 1: Write the failing tests**

Add to `MilaTests/ModelManagerTests.swift`. First extend `setUp`/`tearDown` to also save/restore the new key:

```swift
    private var savedSelection: String?
    private var savedDeclined: [String]?

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelManagerTests-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        savedSelection = UserDefaults.standard.string(forKey: "selectedModelName")
        savedDeclined = UserDefaults.standard.array(forKey: "model.declinedNames") as? [String]
    }

    override func tearDown() {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        if let savedSelection {
            UserDefaults.standard.set(savedSelection, forKey: "selectedModelName")
        } else {
            UserDefaults.standard.removeObject(forKey: "selectedModelName")
        }
        if let savedDeclined {
            UserDefaults.standard.set(savedDeclined, forKey: "model.declinedNames")
        } else {
            UserDefaults.standard.removeObject(forKey: "model.declinedNames")
        }
        super.tearDown()
    }
```

Then add the new test cases:

```swift
    func test_delete_marks_model_declined() throws {
        let mgr = ModelManager(modelsDirectory: tempRoot)
        let path = mgr.url(for: .ivritLarge)
        try Data("not-a-real-model".utf8).write(to: path)
        mgr.refreshInstalled()
        XCTAssertFalse(mgr.isDeclined(.ivritLarge))

        try mgr.delete(.ivritLarge)

        XCTAssertTrue(mgr.isDeclined(.ivritLarge),
                      "Deleting a model must mark it declined so launch-time auto-download skips it")
    }

    func test_declined_status_persists_across_reload() throws {
        let mgr = ModelManager(modelsDirectory: tempRoot)
        let path = mgr.url(for: .ivritLarge)
        try Data("not-a-real-model".utf8).write(to: path)
        mgr.refreshInstalled()
        try mgr.delete(.ivritLarge)

        let reloaded = ModelManager(modelsDirectory: tempRoot)

        XCTAssertTrue(reloaded.isDeclined(.ivritLarge),
                      "Declined status must survive process relaunch, same as selectedModelName")
    }

    func test_download_clears_declined_status() throws {
        let mgr = ModelManager(modelsDirectory: tempRoot)
        let path = mgr.url(for: .ivritLarge)
        try Data("not-a-real-model".utf8).write(to: path)
        mgr.refreshInstalled()
        try mgr.delete(.ivritLarge)
        XCTAssertTrue(mgr.isDeclined(.ivritLarge))

        mgr.download(.ivritLarge)
        mgr.shutdown() // cancel the in-flight network task; we only care about the declined-set side effect

        XCTAssertFalse(mgr.isDeclined(.ivritLarge),
                       "An explicit download request means the user wants the model again")
    }

    func test_declining_one_model_does_not_affect_another() throws {
        let mgr = ModelManager(modelsDirectory: tempRoot)
        let path = mgr.url(for: .ivritLarge)
        try Data("not-a-real-model".utf8).write(to: path)
        mgr.refreshInstalled()

        try mgr.delete(.ivritLarge)

        XCTAssertTrue(mgr.isDeclined(.ivritLarge))
        XCTAssertFalse(mgr.isDeclined(.openaiTurbo))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test` (or, for just this file, open Xcode and run `MilaTests/ModelManagerTests.swift`).
Expected: build FAILS — `isDeclined` doesn't exist yet on `ModelManager`. (If it somehow compiles, something's wrong — there is no such member yet.)

- [ ] **Step 3: Implement the declined-set persistence**

In `Mila/Transcription/ModelManager.swift`, add the storage key near the top of the class (after `private let modelsDirectory: URL`):

```swift
    private static let declinedModelsKey = "model.declinedNames"

    /// Names of models the user explicitly deleted via Settings. Consulted
    /// by `MilaApp.ensureDefaultModelsInstalled()` so a deliberate delete
    /// doesn't come back on the next launch — `isInstalled` alone can't
    /// distinguish "never downloaded" from "downloaded, then removed on
    /// purpose." Cleared the moment `download(_:)` is called again for that
    /// model, since that's an explicit request for it.
    @Published private(set) var declinedModelNames: Set<String>
```

In `init(modelsDirectory:)`, initialize it alongside the existing `selectedModelName` load (replace the current init body):

```swift
    init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory
        let lastUsed = UserDefaults.standard.string(forKey: "selectedModelName")
        self.selectedModelName = lastUsed ?? WhisperModel.ivritLarge.name
        let declined = UserDefaults.standard.array(forKey: Self.declinedModelsKey) as? [String] ?? []
        self.declinedModelNames = Set(declined)
        super.init()
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        refreshInstalled()
    }
```

Add the query method next to `isInstalled(_:)`:

```swift
    func isDeclined(_ model: WhisperModel) -> Bool {
        declinedModelNames.contains(model.name)
    }
```

Add a private persistence helper, and wire it into `delete(_:)` and `download(_:)`:

```swift
    private func setDeclined(_ declined: Bool, for model: WhisperModel) {
        if declined {
            declinedModelNames.insert(model.name)
        } else {
            declinedModelNames.remove(model.name)
        }
        UserDefaults.standard.set(Array(declinedModelNames), forKey: Self.declinedModelsKey)
    }

    func delete(_ model: WhisperModel) throws {
        try FileManager.default.removeItem(at: url(for: model))
        refreshInstalled()
        setDeclined(true, for: model)
    }

    func download(_ model: WhisperModel) {
        guard downloads[model.name] == nil else { return }
        guard !didShutDownSession else { return }
        setDeclined(false, for: model)
        // A fresh attempt supersedes the previous failure report for THIS
        // model only — a concurrent sibling download's error must survive.
        lastDownloadErrors[model.name] = nil
        downloads[model.name] = 0
        let task = session.downloadTask(with: model.url)
        observers[task.taskIdentifier] = model
        task.resume()
    }
```

(Only the two new lines — `setDeclined(true, for: model)` in `delete`, `setDeclined(false, for: model)` in `download` — are additions; everything else in those two methods is unchanged from the current file.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: PASS — all four new tests green, and every pre-existing `ModelManagerTests` test still green (in particular `test_install_state_reflects_files_in_directory`, which also calls `delete(_:)`).

- [ ] **Step 5: Commit**

```bash
git add Mila/Transcription/ModelManager.swift MilaTests/ModelManagerTests.swift
git commit -m "$(cat <<'EOF'
fix(models): make Settings model deletion stick across relaunch

ModelManager only ever asked "is the file on disk" to decide whether to
auto-download a default model at launch, so a deliberate delete via
Settings was indistinguishable from "never downloaded" and silently
came back on the very next launch (including after every app update).
Persist which models the user explicitly declined and skip them.

Claude-Session: https://claude.ai/code/session_018PknxN13oghDt2XTHu7fPL
EOF
)"
```

---

### Task 2: Skip declined models in the launch-time auto-download

**Files:**
- Modify: `Mila/App/MilaApp.swift:1440-1458` (`ensureDefaultModelsInstalled()`)

**Interfaces:**
- Consumes: `ModelManager.isDeclined(_ model: WhisperModel) -> Bool` from Task 1.

There is no existing unit-test harness for `MilaApp`'s private launch-time methods (`MilaTests/` has no test that constructs `MilaApp` — it's a SwiftUI `App` with heavy environment wiring). Task 1's `ModelManager` tests are what actually exercise this behavior; this task is a one-line consumer change plus a manual smoke check.

- [ ] **Step 1: Modify `ensureDefaultModelsInstalled()`**

In `Mila/App/MilaApp.swift`, change the download loop (currently at lines 1447-1451):

```swift
        modelManager.setSelected(WhisperModel.ivritLarge)
        for model in [WhisperModel.ivritLarge, WhisperModel.openaiTurbo] {
            if !modelManager.isInstalled(model) && modelManager.downloads[model.name] == nil {
                modelManager.download(model)
            }
        }
```

to:

```swift
        modelManager.setSelected(WhisperModel.ivritLarge)
        for model in [WhisperModel.ivritLarge, WhisperModel.openaiTurbo] {
            if !modelManager.isInstalled(model)
                && !modelManager.isDeclined(model)
                && modelManager.downloads[model.name] == nil {
                modelManager.download(model)
            }
        }
```

(This plan intentionally leaves `modelManager.setSelected(WhisperModel.ivritLarge)` and the "always fetch both models" behavior untouched — those are separate, out-of-scope issues from the same investigation. This task only stops a *declined* model from silently reappearing.)

- [ ] **Step 2: Build**

Run: `xcodebuild -project Mila.xcodeproj -scheme Mila -configuration Debug build` (or open in Xcode and build) to confirm it compiles against the `isDeclined` API added in Task 1.

- [ ] **Step 3: Manual smoke test**

Using the `build-mila-locally` skill, build a local debug DMG and confirm end to end:
1. Launch the freshly built app; let a default model finish downloading (or drop a placeholder file at the path `ModelManager.url(for:)` would use, matching the test pattern, if you don't want to wait on a real multi-GB download).
2. Settings → Models → Delete the model. Confirm the deletion dialog and the "Installed" badge disappearing.
3. Quit and relaunch the app.
4. Confirm in Settings → Models the deleted model shows "Download" (not auto-re-downloading) and no download progress bar appears for it on launch.
5. Click "Download" on that model manually; confirm it starts downloading again (proves `download(_:)` clearing the declined flag didn't break the manual path).

- [ ] **Step 4: Commit**

```bash
git add Mila/App/MilaApp.swift
git commit -m "$(cat <<'EOF'
fix(models): stop launch-time bootstrap from re-fetching declined models

Consumes ModelManager.isDeclined(_:) so ensureDefaultModelsInstalled()
no longer treats "user deleted this on purpose" the same as "never
downloaded yet."

Claude-Session: https://claude.ai/code/session_018PknxN13oghDt2XTHu7fPL
EOF
)"
```

---

## Explicitly out of scope (from the same investigation, not this plan)

- `ensureDefaultModelsInstalled()` still eagerly downloads **both** catalog models (Hebrew `large-v3` *and* the OpenAI turbo) for every user regardless of `RecordingLanguageSettings.current` — an English-only user still gets the 3 GB Hebrew model on first run. Scoping to the user's selected language was discussed but deferred.
- The same function unconditionally calls `modelManager.setSelected(WhisperModel.ivritLarge)` on every launch, overwriting whatever model the user picked in Settings → Models. `ModelManager.init` already restores the persisted selection correctly on its own; this call is a leftover from the initial release. Left untouched here since it's a separate bug from the deletion-doesn't-stick complaint this plan addresses.

Per `.claude/rules/pull-requests.md`, since this is a bug fix, a GitHub issue describing the repro (delete model → still comes back on relaunch/update) should be opened and linked with `Closes #<n>` before/when the PR is opened — not covered by this plan's tasks, but required before merging.
