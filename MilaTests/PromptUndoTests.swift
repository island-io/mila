import XCTest
import AppKit
import SwiftUI
@testable import Mila

/// Undo for the Settings prompt editors (#176).
///
/// The bug these cover: "Reset to default" and the Examples list each assign
/// straight to the prompt binding, so a hand-written prompt vanished in one
/// click with `⌘Z` doing nothing. The fix routes every change — typed or
/// assigned — through one `UndoManager` per editor, so the tests here drive the
/// real `UndoableTextEditor` machinery (coordinator, text view, bridge) with no
/// UI to click: a SwiftUI binding stands in for the settings object, and
/// `applyExternalChange` is exactly what `updateNSView` calls when the binding
/// changed behind the text view's back.
@MainActor
final class PromptUndoTests: XCTestCase {

    /// Stands in for the `@Published` prompt on `LLMSettings` / `LiveAISettings`.
    private final class TextBox {
        var value: String
        init(_ value: String) { self.value = value }
    }

    private struct Editor {
        let box: TextBox
        let bridge: PromptUndoBridge
        let textView: UndoableNSTextView
        let coordinator: UndoableTextEditor.Coordinator
        var text: String { box.value }
    }

    private func makeEditor(_ initial: String) -> Editor {
        let box = TextBox(initial)
        let binding = Binding<String>(get: { box.value }, set: { box.value = $0 })
        let bridge = PromptUndoBridge()
        let coordinator = UndoableTextEditor.Coordinator(text: binding, undo: bridge)
        let textView = UndoableTextEditor.makeTextView(coordinator: coordinator,
                                                      undo: bridge,
                                                      initialText: initial)
        return Editor(box: box, bridge: bridge, textView: textView, coordinator: coordinator)
    }

    /// AppKit closes the automatic undo group at the end of the event, so let
    /// the run loop turn before asking whether anything is undoable.
    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    /// Mimics SwiftUI: the binding already carries the new value by the time
    /// `updateNSView` notices the text view is out of date.
    private func applyExternally(_ new: String, to editor: Editor) {
        editor.box.value = new
        editor.coordinator.applyExternalChange(new)
        settle()
        endEventGroup(editor)
        editor.bridge.refresh()
    }

    /// Tidies up any group AppKit would have closed at the end of an event.
    ///
    /// This is housekeeping, not the fix -- an earlier commit of mine claimed
    /// otherwise and was wrong. `applyExternalChange` now opens and closes its
    /// own group, so undo steps are already one-per-overwrite here.
    ///
    /// `NSUndoManager.groupsByEvent` is true: it opens a group when an AppKit
    /// event begins and closes it when the event ends. XCTest has no AppKit
    /// event loop, so that group is never closed here, and every change in a
    /// test lands in one group -- which made a single `undo()` unwind several
    /// overwrites at once and looked exactly like an undo bug in the editor.
    ///
    /// In the app, each "Reset to default" or Examples click is its own event
    /// and therefore its own group, so undo steps back one overwrite at a
    /// time. Closing the group here is what models that; it is a property of
    /// the harness, not a workaround in the code under test.
    private func endEventGroup(_ editor: Editor) {
        let manager = editor.bridge.undoManager
        while manager.groupingLevel > 0 { manager.endUndoGrouping() }
    }

    // MARK: - The two destructive one-click overwrites

    func test_undo_restores_custom_prompt_after_reset_to_default() {
        let custom = "You are my meeting scribe.\nAlways answer in Hebrew.\nNever invent action items."
        let editor = makeEditor(custom)

        applyExternally(LLMSettings.defaultNamePrompt, to: editor)
        XCTAssertEqual(editor.textView.string, LLMSettings.defaultNamePrompt)
        XCTAssertTrue(editor.bridge.canUndo, "Reset to default must be undoable")

        editor.bridge.undo()

        XCTAssertEqual(editor.textView.string, custom, "⌘Z must put the custom prompt back")
        XCTAssertEqual(editor.text, custom, "the restored text must reach the settings binding")
    }

    func test_undo_restores_custom_prompt_after_picking_an_example() {
        let custom = "Title the recording after the loudest argument in it."
        let editor = makeEditor(custom)
        let example = LLMSettings.nameExamples[1]

        applyExternally(example, to: editor)
        XCTAssertEqual(editor.text, example)

        editor.bridge.undo()
        XCTAssertEqual(editor.text, custom)

        // And redo brings the example back, so undo isn't a one-way trap of
        // its own.
        XCTAssertTrue(editor.bridge.canRedo)
        editor.bridge.redo()
        XCTAssertEqual(editor.text, example)
    }

    func test_sequential_overwrites_undo_newest_first() {
        let editor = makeEditor("original")
        applyExternally("first overwrite", to: editor)
        applyExternally("second overwrite", to: editor)

        editor.bridge.undo()
        XCTAssertEqual(editor.text, "first overwrite")

        editor.bridge.undo()
        XCTAssertEqual(editor.text, "original")
    }

    // MARK: - Ordinary editing

    func test_typing_is_undoable_and_writes_back_to_the_binding() {
        let editor = makeEditor("Summarize the transcript.")
        let end = NSRange(location: (editor.textView.string as NSString).length, length: 0)

        editor.textView.insertText(" In bullet points.", replacementRange: end)
        settle()
        editor.bridge.refresh()

        XCTAssertEqual(editor.text, "Summarize the transcript. In bullet points.",
                       "typing must reach the settings binding")
        XCTAssertTrue(editor.bridge.canUndo)

        editor.bridge.undo()
        XCTAssertEqual(editor.text, "Summarize the transcript.")
    }

    // MARK: - Guards

    func test_no_undo_step_is_registered_when_the_text_is_unchanged() {
        let editor = makeEditor("same")
        applyExternally("same", to: editor)
        XCTAssertFalse(editor.bridge.canUndo,
                       "a no-op re-render must not push an undo step")
    }

    func test_undo_with_an_empty_stack_is_a_no_op() {
        let editor = makeEditor("untouched")
        editor.bridge.undo()
        editor.bridge.redo()
        XCTAssertEqual(editor.text, "untouched")
        XCTAssertFalse(editor.bridge.canUndo)
        XCTAssertFalse(editor.bridge.canRedo)
    }

    /// Each prompt editor owns its stack: undoing next to the Name prompt must
    /// not reach into whatever was last typed on another tab.
    func test_undo_stacks_are_per_editor() {
        let name = makeEditor("name prompt")
        let action = makeEditor("action prompt")

        applyExternally("name overwritten", to: name)
        XCTAssertFalse(action.bridge.canUndo)

        action.bridge.undo()
        XCTAssertEqual(name.text, "name overwritten", "one editor's undo touched another's text")

        name.bridge.undo()
        XCTAssertEqual(name.text, "name prompt")
        XCTAssertEqual(action.text, "action prompt")
    }
}
