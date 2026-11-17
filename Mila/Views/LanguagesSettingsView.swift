import SwiftUI
import Carbon.HIToolbox
import TranscriptionCore

/// Settings → Languages: the user's language list (`RecordingLanguageSettings`).
/// One row per offered language, with its transcription model and its
/// dictation shortcut, plus Add / Edit / Remove.
///
/// Removing only hides an entry, so recordings already made in it keep their
/// flag, direction and model, and adding it back restores its settings. A
/// language locked by a configuration profile shows the managed note and
/// can't be removed (`ManagedSettings`, #360).
struct LanguagesSettingsTab: View {
    @EnvironmentObject private var languageSettings: RecordingLanguageSettings
    @EnvironmentObject private var hotkeys: HotkeySettings

    /// The action whose hotkey is being re-recorded; nil when no row is
    /// capturing.
    @State private var recordingAction: HotkeyAction?
    @State private var lastError: String?
    @State private var showingAdd = false
    @State private var editing: RecordingLanguage?
    /// A language just added, to open in Edit once the Add sheet has gone.
    @State private var editAfterAdd: RecordingLanguage?
    /// The active language, waiting for the user to confirm its removal.
    @State private var pendingRemoval: RecordingLanguage?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Languages")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Add Language…") {
                    endCapture()
                    showingAdd = true
                }
                    .accessibilityIdentifier("languages.add.button")
            }
            Text("The languages you record and dictate in. Each one has its own transcription model and can have a dictation shortcut: press it anywhere in macOS to start dictating, and again to stop and paste. Click a shortcut to record a new one; press Esc to cancel. Removing a language keeps every recording made in it, and adding it back restores its settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                ForEach(languageSettings.visible) { language in
                    row(for: language)
                }
            }

            if let lastError {
                Text(lastError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showingAdd, onDismiss: {
            // Only now, with the Add sheet fully dismissed: asking for the
            // Edit sheet in the same turn that closes this one is a second
            // presentation on a view that is still presenting, which SwiftUI
            // may simply drop.
            if let next = editAfterAdd {
                editAfterAdd = nil
                editing = next
            }
        }) {
            AddLanguageSheet { added in
                // Straight into Edit for a brand-new entry: it has no flag
                // yet and the default model, which is worth a look.
                editAfterAdd = added.flatMap { $0.flagEmoji.isEmpty ? $0 : nil }
                showingAdd = false
            }
        }
        .sheet(item: $editing) { language in
            EditLanguageSheet(language: language) { editing = nil }
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.displayName ?? "")?",
            isPresented: Binding(get: { pendingRemoval != nil },
                                 set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { language in
            Button("Remove", role: .destructive) {
                languageSettings.remove(code: language.code)
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { language in
            Text("New recordings will use \(languageSettings.visible.first { $0.code != language.code }?.displayName ?? "another language"). Recordings already made in \(language.displayName) are kept, and adding it back restores its settings.")
        }
        .onDisappear {
            // Window closed mid-capture: don't leave the app's hotkeys
            // parked forever.
            endCapture()
        }
    }

    /// Leave capture mode and put the parked hotkeys back.
    ///
    /// Everything that changes a binding or the list calls this FIRST. The
    /// capture field doesn't give up on its own when the user clicks
    /// elsewhere, and `DictationHotkeyBinder` re-registers on every such
    /// change: mid-capture it would register live hotkeys next to the parked
    /// set, and the later `resumeAll()` would then restore that stale set on
    /// top — bringing back the combo of a shortcut just cleared, or of a
    /// language just removed, until the next change or relaunch.
    private func endCapture() {
        guard recordingAction != nil else { return }
        recordingAction = nil
        HotkeyManager.shared.resumeAll()
    }

    private func row(for language: RecordingLanguage) -> some View {
        let action = HotkeyAction(languageCode: language.code)
        let isLocked = languageSettings.lockedCode == language.code
        return HStack(spacing: 10) {
            FlagBadge(language: language)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(language.displayName)
                    Text(language.code)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if languageSettings.current.code == language.code {
                        Text("Active")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.tint.opacity(0.15), in: Capsule())
                    }
                }
                Text((language.modelName.flatMap(WhisperModel.named) ?? .openaiTurbo).displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if isLocked { ManagedSettingNote(field: .recordingLanguage) }
            }

            // Live-registration warning: register() can fail (another app
            // owns the combo globally) and the binding then LOOKS active while
            // doing nothing. Suppressed mid-capture — suspendAll() has
            // deliberately parked everything then.
            if recordingAction == nil,
               hotkeys.binding(for: action) != nil,
               !HotkeyManager.shared.isRegistered(action) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("This shortcut couldn't be registered — another app, macOS, or another language here owns it. Pick a different one.")
                    .accessibilityIdentifier("hotkeys.\(action.id).inactive")
            }

            Spacer()

            HotkeyCaptureField(currentDisplay: hotkeys.binding(for: action)?.displayName ?? "Set shortcut",
                               isRecording: recordingAction == action,
                               onStartRecording: {
                                   recordingAction = action
                                   // Park our own registrations so the pressed
                                   // combo reaches the capture field's keyDown —
                                   // Carbon otherwise consumes a currently-bound
                                   // combo and STARTS DICTATION mid-capture.
                                   HotkeyManager.shared.suspendAll()
                               },
                               onCaptured: { applyCapture($0, for: action) },
                               onCancel: { endCapture() })
                .frame(width: 140)

            Menu {
                Button("Edit…") {
                    endCapture()
                    editing = language
                }
                // A locked language the user never added is offered from
                // memory only, so there is no stored entry for Edit to change.
                .disabled(!languageSettings.languages.contains { $0.code == language.code })
                Button(HotkeyAction.defaults[action] == nil ? "Clear Shortcut" : "Reset Shortcut") {
                    endCapture()
                    hotkeys.resetToDefault(action)
                    lastError = nil
                }
                .disabled(hotkeys.binding(for: action) == HotkeyAction.defaults[action])
                Divider()
                Button("Remove", role: .destructive) { requestRemoval(of: language) }
                    .disabled(!languageSettings.canRemove(code: language.code))
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(isLocked ? "Locked by your organization — it can't be removed" : "Edit, reset the shortcut, or remove")
            .accessibilityIdentifier("languages.\(language.code).menu")
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("languages.\(language.code).row")
    }

    /// Removing the active language changes what the next recording uses,
    /// so that one asks first. Any other removal is undone by adding the
    /// language back.
    private func requestRemoval(of language: RecordingLanguage) {
        endCapture()
        if languageSettings.current.code == language.code {
            pendingRemoval = language
        } else {
            languageSettings.remove(code: language.code)
        }
    }

    private func applyCapture(_ binding: HotkeyBinding, for action: HotkeyAction) {
        // A key that lands after capture was ended some other way (a menu
        // action, another row's field) is not a capture.
        guard recordingAction == action else { return }
        endCapture()

        // Reject empty / modifier-only combos: Carbon will accept them but
        // Apple shortcut conventions require at least one of ⌘ ⌃ ⌥.
        let needsModifier = UInt32(cmdKey | controlKey | optionKey)
        guard binding.modifiers & needsModifier != 0 else {
            lastError = "Please include at least one modifier (⌘, ⌃, or ⌥)."
            return
        }

        // Reject collisions with another offered language so the user
        // doesn't shoot themselves in the foot.
        for other in languageSettings.visible.map({ HotkeyAction(languageCode: $0.code) })
            where other != action {
            if hotkeys.binding(for: other) == binding {
                lastError = "\(binding.displayName) is already used for \(other.displayLabel)."
                return
            }
        }

        // Re-capturing the combo the action already has: nothing to do (and
        // the registrability probe below would false-positive against our own
        // live registration).
        guard binding != hotkeys.binding(for: action) else {
            lastError = nil
            return
        }

        // Validate registrability BEFORE persisting, so Settings never shows
        // a combo as active while nothing is registered.
        guard HotkeyManager.shared.canRegister(binding) else {
            lastError = "\(binding.displayName) is already taken by another app or macOS — choose a different combo."
            return
        }

        lastError = nil
        hotkeys.setBinding(binding, for: action)
    }
}

/// The flag, or the code in a rounded badge for an entry without one.
private struct FlagBadge: View {
    let language: RecordingLanguage

    var body: some View {
        Group {
            if language.flagEmoji.isEmpty {
                Text(language.code.uppercased())
                    .font(.caption.weight(.semibold).monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 20)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            } else {
                Text(language.flagEmoji)
                    .font(.system(size: 18))
                    .frame(width: 28, height: 20)
            }
        }
    }
}

/// Pick a language whisper can transcribe. Previously removed languages are
/// marked, and adding one back restores its flag and model.
private struct AddLanguageSheet: View {
    @EnvironmentObject private var languageSettings: RecordingLanguageSettings
    @State private var search = ""
    /// Called with the added entry, or nil on Cancel.
    let onDone: (RecordingLanguage?) -> Void

    var body: some View {
        let matches = languageSettings.addableLanguages().filter { $0.matches(search: search) }
        VStack(alignment: .leading, spacing: 10) {
            Text("Add Language")
                .font(.headline)
            TextField("Search languages", text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("languages.add.search")
            List(matches) { language in
                Button {
                    onDone(languageSettings.add(code: language.code))
                } label: {
                    HStack {
                        FlagBadge(language: language)
                        Text(language.displayName)
                        Text(language.code)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Spacer()
                        if language.isHidden {
                            Text("previously added")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("languages.add.\(language.code)")
            }
            .frame(minHeight: 300)
            .overlay {
                if matches.isEmpty {
                    Text("No language matches “\(search)”.")
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { onDone(nil) }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 420, height: 460)
    }
}

/// Flag and transcription model for one entry. The language itself is fixed;
/// its shortcut is edited in the row.
private struct EditLanguageSheet: View {
    @EnvironmentObject private var languageSettings: RecordingLanguageSettings
    let language: RecordingLanguage
    let onDone: () -> Void

    @State private var flag: String
    @State private var modelName: String?

    init(language: RecordingLanguage, onDone: @escaping () -> Void) {
        self.language = language
        self.onDone = onDone
        _flag = State(initialValue: language.flagEmoji)
        _modelName = State(initialValue: language.modelName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(language.displayName)
                .font(.headline)
            Form {
                TextField("Flag", text: $flag, prompt: Text("Optional, e.g. 🇷🇺"))
                    .accessibilityIdentifier("languages.edit.flag")
                Picker("Model", selection: $modelName) {
                    Text("Default — \(WhisperModel.openaiTurbo.displayName)").tag(String?.none)
                    ForEach(WhisperModel.all) { model in
                        Text(model.displayName).tag(Optional(model.name))
                    }
                }
                .accessibilityIdentifier("languages.edit.model")
            }
            Text("Press ⌃⌘Space in the Flag field to pick an emoji. The model is used when transcribing on this Mac; a remote server picks its own.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { onDone() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    languageSettings.update(RecordingLanguage(code: language.code,
                                                              flagEmoji: RecordingLanguage.normalizedFlag(flag),
                                                              modelName: modelName))
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("languages.edit.save")
            }
        }
        .padding()
        .frame(width: 420)
    }
}
