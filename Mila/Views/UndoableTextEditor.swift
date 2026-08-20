import AppKit
import SwiftUI

/// A multi-line text editor with a **real macOS undo stack**.
///
/// SwiftUI's `TextEditor` gave the Settings prompt editors no working `⌘Z`
/// (issue #176): the Settings scene has no undo manager in the SwiftUI
/// environment, so the standard Edit ▸ Undo item is inert, and the two
/// one-click controls above each editor — "Reset to default" and the Examples
/// list — replace a hand-written prompt outright by assigning straight to the
/// binding. A carefully tuned multi-line prompt could be destroyed by a single
/// misclick with no way back.
///
/// This wrapper fixes that at the level users actually reach for. It hosts an
/// `NSTextView` (which has had first-class undo since forever) and gives it a
/// **dedicated** `UndoManager`, owned by `PromptUndoBridge`, so:
///
/// * ordinary typing and deletion are undoable, coalesced the way AppKit does
///   it everywhere else;
/// * a change that arrives through the *binding* — "Reset to default", picking
///   an Example, a `.milaconfig` import — is applied **as an undoable edit**
///   rather than a raw string assignment, so it lands on the same stack and
///   `⌘Z` puts the previous prompt back (see `Coordinator.applyExternalChange`);
/// * undo is reachable three ways that all drive that one stack: the `⌘Z` /
///   `⇧⌘Z` key equivalents, the responder-chain `undo:` / `redo:` actions (what
///   a nil-targeted Edit-menu item sends), and the visible "Undo" link
///   `AIPromptEditor` shows while `PromptUndoBridge.canUndo` is true.
///
/// The undo stack is per editor rather than per window on purpose: "undo" next
/// to the Name prompt has to mean "undo what happened to *this* prompt", not
/// whatever was last touched on some other Settings tab.
@MainActor
struct UndoableTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// Owns the undo stack and publishes `canUndo` / `canRedo` for the UI.
    let undo: PromptUndoBridge
    var isEnabled = true

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, undo: undo)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = Self.makeTextView(coordinator: context.coordinator,
                                        undo: undo,
                                        initialText: text)
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        return scrollView
    }

    /// The text view, configured. Factored out of `makeNSView` so unit tests
    /// can exercise the real editor — undo stack, delegate wiring and all —
    /// without a SwiftUI `Context` or a window.
    static func makeTextView(coordinator: Coordinator,
                             undo: PromptUndoBridge,
                             initialText: String) -> UndoableNSTextView {
        let textView = UndoableNSTextView()
        textView.delegate = coordinator
        textView.promptUndoManager = undo.undoManager
        textView.allowsUndo = true
        textView.isRichText = false
        textView.drawsBackground = false
        // Prompts contain `{{LANGUAGE}}`, quoted JSON and hyphens that macOS's
        // smart substitutions would silently rewrite into something the LLM
        // sees differently. Off, like every other code-ish field.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = Self.promptFont
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.string = initialText
        coordinator.textView = textView
        return textView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? UndoableNSTextView else { return }
        context.coordinator.text = $text
        context.coordinator.textView = textView
        textView.promptUndoManager = undo.undoManager

        // The binding changed behind the text view's back — "Reset to default",
        // an Example, a config import. Route it through the undo stack instead
        // of clobbering `string`, which is what made the overwrite
        // unrecoverable.
        if textView.string != text {
            context.coordinator.applyExternalChange(text)
        }

        textView.isEditable = isEnabled
        textView.isSelectable = true
        textView.textColor = isEnabled ? .labelColor : .disabledControlTextColor
    }

    static var promptFont: NSFont {
        NSFont.monospacedSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize,
            weight: .regular)
    }

    // MARK: - Coordinator

    /// Main-actor isolated: SwiftUI calls in on the main actor and AppKit
    /// guarantees text-view delegate callbacks arrive there too, so the
    /// coordinator can touch `PromptUndoBridge`'s published state directly.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        let undo: PromptUndoBridge
        weak var textView: UndoableNSTextView?
        /// Suppresses the write-back while we are pushing the binding's own
        /// value into the text view — otherwise `didChangeText` would set the
        /// binding to the value it already has, mid-SwiftUI-update.
        private var isApplyingExternalChange = false

        init(text: Binding<String>, undo: PromptUndoBridge) {
            self.text = text
            self.undo = undo
            super.init()
            // Undo can also be driven from outside the text view (the visible
            // "Undo" link). Whatever the trigger, the restored text has to make
            // it back into the binding — and thence into UserDefaults.
            undo.onUndoRedoApplied = { [weak self] in self?.syncAfterUndoRedo() }
        }

        /// The stack every edit in this editor registers on — typing included.
        /// AppKit asks the delegate for it, which is how one editor's undo
        /// stays out of the next editor's history.
        func undoManager(for view: NSTextView) -> UndoManager? {
            undo.undoManager
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            guard !isApplyingExternalChange else { return }
            let new = textView.string
            if text.wrappedValue != new { text.wrappedValue = new }
            undo.refresh()
        }

        /// Apply `text` (the binding's current value) to the text view as a
        /// **registered, undoable** replacement.
        ///
        /// `shouldChangeText(in:replacementString:)` is the AppKit-sanctioned
        /// way to make a programmatic edit behave like a user one: it registers
        /// the undo action for the range being replaced. `didChangeText()` then
        /// posts the change notification, so redo/undo both round-trip back
        /// into the binding through `textDidChange`.
        func applyExternalChange(_ newValue: String) {
            guard let textView else { return }
            // A re-render that changes nothing must not push an undo step.
            // `updateNSView` already compares before calling, but this method is
            // the whole entry point for external edits, so it owns the invariant
            // rather than trusting every caller to remember it.
            guard textView.string != newValue else {
                undo.refresh()
                return
            }

            // Register the inverse ourselves rather than going through
            // `shouldChangeText` + `didChangeText`.
            //
            // Letting NSTextView record these was the obvious route and it does
            // not hold up: its text undo is built for typing, so it coalesces
            // and groups by event, and two overwrites arriving in one run-loop
            // pass collapsed into a single step -- one Cmd+Z threw away both,
            // losing the intermediate prompt. `breakUndoCoalescing()` did not
            // separate them either, because the grouping is what merges them,
            // not the coalescing.
            //
            // One explicit registration per call is exactly one undo step,
            // whatever the run loop is doing. Because the undo block calls this
            // same method, NSUndoManager records *its* registration as the redo,
            // so redo is symmetric for free. Typing is untouched and keeps using
            // the text view's own undo on the same manager.
            let previous = textView.string
            // The group has to be opened explicitly. `groupsByEvent` is true,
            // which means NSUndoManager expects an AppKit event to have opened
            // one -- and `registerUndo` *throws*
            // ("must begin a group before registering undo") when nothing has.
            // In the app an event is always in flight so it happens to work;
            // anywhere without an event loop it does not. Owning the group here
            // also makes each overwrite exactly one undo step, which is the
            // behaviour we actually want: two Examples picks take two presses
            // to walk back.
            undo.undoManager.beginUndoGrouping()
            undo.undoManager.registerUndo(withTarget: self) { coordinator in
                MainActor.assumeIsolated { coordinator.applyExternalChange(previous) }
            }
            // Reads better in the Edit menu than the generic "Undo".
            undo.undoManager.setActionName("Prompt Change")
            undo.undoManager.endUndoGrouping()

            isApplyingExternalChange = true
            textView.string = newValue
            isApplyingExternalChange = false

            // The binding is the source of truth for persistence, and an undo
            // reaching here must push the restored text back out to it.
            if text.wrappedValue != newValue { text.wrappedValue = newValue }

            let end = (newValue as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
            undo.refresh()

            // The click that caused this landed on a link-styled button, so the
            // insertion point may no longer be here -- and Cmd+Z only reaches a
            // text view that is first responder. Take focus back, but never out
            // from under someone typing in a different field.
            if let window = textView.window, window.isKeyWindow,
               !(window.firstResponder is NSTextView) {
                window.makeFirstResponder(textView)
            }
        }

        /// Undo/redo driven from outside the text view (the "Undo" link, or a
        /// menu item) still has to land back in the binding, which it does via
        /// `textDidChange` — this just keeps the published flags honest.
        func syncAfterUndoRedo() {
            if let textView, text.wrappedValue != textView.string {
                text.wrappedValue = textView.string
            }
            undo.refresh()
        }
    }
}

// MARK: - Text view

/// `NSTextView` that undoes onto a supplied stack and answers `⌘Z` itself.
///
/// Two reasons this is not stock `NSTextView`:
///
/// 1. `promptUndoManager` — the per-editor stack. The property override matters
///    as well as the delegate hook, because our own key handling asks
///    `self.undoManager` and must get the same object AppKit registers into.
/// 2. `performKeyEquivalent` — the app's Edit ▸ Undo item is driven by SwiftUI
///    and inert in the Settings scene, so waiting for `undo:` to be sent down
///    the responder chain is not enough. A disabled menu item does not consume
///    its key equivalent, so the keystroke reaches the view hierarchy and we
///    handle it here.
final class UndoableNSTextView: NSTextView {
    /// Held weakly: `PromptUndoBridge` owns the manager, and the manager's
    /// registered actions retain this view.
    weak var promptUndoManager: UndoManager?

    override var undoManager: UndoManager? { promptUndoManager ?? super.undoManager }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        guard key == "z", window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        if flags == [.command], performPromptUndo() { return true }
        if flags == [.command, .shift], performPromptRedo() { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Nil-targeted `undo:` / `redo:` — what a standard Edit-menu item sends
    /// down the responder chain. Answering them here means a working menu item
    /// drives this editor's stack rather than the window's empty one.
    @objc func undo(_ sender: Any?) { _ = performPromptUndo() }
    @objc func redo(_ sender: Any?) { _ = performPromptRedo() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(UndoableNSTextView.undo(_:)): return undoManager?.canUndo ?? false
        case #selector(UndoableNSTextView.redo(_:)): return undoManager?.canRedo ?? false
        default: return super.validateUserInterfaceItem(item)
        }
    }

    @discardableResult
    private func performPromptUndo() -> Bool {
        guard let manager = undoManager, manager.canUndo else { return false }
        manager.undo()
        (delegate as? UndoableTextEditor.Coordinator)?.syncAfterUndoRedo()
        return true
    }

    @discardableResult
    private func performPromptRedo() -> Bool {
        guard let manager = undoManager, manager.canRedo else { return false }
        manager.redo()
        (delegate as? UndoableTextEditor.Coordinator)?.syncAfterUndoRedo()
        return true
    }
}

// MARK: - Undo bridge

/// Owns one editor's `UndoManager` and republishes its state for SwiftUI.
///
/// Two jobs. It keeps the stack alive across the view updates that recreate
/// `UndoableTextEditor` (a struct) on every keystroke — an undo history that
/// resets whenever SwiftUI re-renders would be worse than none. And it exposes
/// `canUndo` so the editor can show a visible "Undo" affordance: `⌘Z` is what
/// users try first, but a link they can see is the recovery path that cannot
/// depend on where first responder happens to be.
@MainActor
final class PromptUndoBridge: ObservableObject {
    let undoManager: UndoManager
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// Called after an undo or redo has been applied, so the owner can push the
    /// restored text back into its binding. Set by
    /// `UndoableTextEditor.Coordinator`.
    var onUndoRedoApplied: (() -> Void)?

    private var observers: [NSObjectProtocol] = []

    /// `nonisolated` so a SwiftUI `@StateObject` default value can create the
    /// bridge from a view's (nonisolated) property initialiser. It only stores
    /// properties and registers observers; every mutation afterwards happens on
    /// the main actor.
    nonisolated init(undoManager: UndoManager = UndoManager()) {
        self.undoManager = undoManager
        // AppKit closes typing groups on its own schedule, so poll the manager
        // whenever it says something happened rather than guessing.
        let names: [Notification.Name] = [
            .NSUndoManagerDidCloseUndoGroup,
            .NSUndoManagerDidUndoChange,
            .NSUndoManagerDidRedoChange,
            .NSUndoManagerDidOpenUndoGroup
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name, object: undoManager, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func refresh() {
        if canUndo != undoManager.canUndo { canUndo = undoManager.canUndo }
        if canRedo != undoManager.canRedo { canRedo = undoManager.canRedo }
    }

    /// Undo the last change to this prompt. Safe to call when there is nothing
    /// to undo.
    func undo() {
        guard undoManager.canUndo else { return }
        undoManager.undo()
        onUndoRedoApplied?()
        refresh()
    }

    func redo() {
        guard undoManager.canRedo else { return }
        undoManager.redo()
        onUndoRedoApplied?()
        refresh()
    }
}
