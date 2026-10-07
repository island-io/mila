import SwiftUI

/// The "Summary language" submenu: Default (the global Settings → AI Features
/// → Output language value) plus the two concrete languages, with a ✓ on
/// whichever is in force for this recording. Picking an entry is expected to
/// persist the choice on the recording AND regenerate its summary + action
/// items right away — the caller's `onPick` does both.
///
/// One view for every place the choice is offered — the recording's
/// right-click menu (sidebar sub-rows + the All Transcripts list, via
/// `RecordingContextMenu`) and the summary block's own context menu
/// (`AIOverviewSection`, in the detail view and the rename sheet) — so the
/// entries, labels and ✓ convention cannot drift between them. Same reason
/// the shared recording context menu exists (issue #62).
///
/// The ✓-prefixed `Button` convention mirrors the "Move to Folder" submenu in
/// `RecordingContextMenu` rather than a `Picker`: the selection is OPTIONAL
/// (nil = Default), which a `Picker` over a non-optional enum doesn't model.
struct SummaryLanguageMenu: View {
    /// The recording's current override; nil = following the global setting.
    let current: RecordingLanguage?
    /// The global output language, shown in the Default entry's label so the
    /// user can see what "Default" will actually produce.
    let global: LiveAISettings.OutputLanguage
    /// Greys the entries out — while a summary is already in flight (the
    /// summarizer would discard and re-run anyway, but a disabled menu is
    /// clearer than a spinner that restarts), or while the recording is
    /// transcribing / has no transcript to summarise.
    var isDisabled: Bool = false
    /// nil clears the override; a language sets it.
    let onPick: (RecordingLanguage?) -> Void

    var body: some View {
        Menu("Summary language") {
            Button(label("Default (\(global.displayName))", selected: current == nil)) {
                onPick(nil)
            }
            .accessibilityIdentifier("summaryLanguage.default")
            Divider()
            ForEach(RecordingLanguage.allCases) { lang in
                Button(label("\(lang.flagEmoji) \(lang.displayName)", selected: current == lang)) {
                    onPick(lang)
                }
                .accessibilityIdentifier("summaryLanguage.\(lang.rawValue)")
            }
        }
        .disabled(isDisabled)
        .accessibilityIdentifier("summaryLanguage.menu")
    }

    private func label(_ text: String, selected: Bool) -> String {
        selected ? "✓ \(text)" : text
    }
}
