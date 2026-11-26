import XCTest
import AppKit
@testable import Mila

/// Regression coverage for dictation's clipboard save/restore.
///
/// The paste flow used to snapshot only `string(forType: .string)`: if the
/// user had an image / file / rich content on the clipboard, dictating
/// destroyed it permanently — `clearContents()` wiped the pasteboard and the
/// restore step was skipped entirely because the string snapshot was nil.
/// `snapshotPasteboard`/`restorePasteboard` capture every item with every
/// type it carries. Tested against a private named pasteboard so the user's
/// real clipboard is untouched.
@MainActor
final class DictationPasteboardTests: XCTestCase {

    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: .init("MilaTests.pasteboard.\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    func test_non_string_content_survives_snapshot_clear_restore() {
        let fakeImage = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])  // PNG-ish bytes
        let item = NSPasteboardItem()
        item.setData(fakeImage, forType: .png)
        item.setString("caption", forType: .string)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        let snapshot = DictationController.snapshotPasteboard(pasteboard)
        XCTAssertFalse(snapshot.isEmpty, "Snapshot must capture the existing item")

        // What paste() does: clobber the clipboard with the transcript.
        pasteboard.clearContents()
        pasteboard.setString("the dictated text", forType: .string)
        XCTAssertNil(pasteboard.pasteboardItems?.first?.data(forType: .png))

        DictationController.restorePasteboard(pasteboard, from: snapshot)

        XCTAssertEqual(pasteboard.pasteboardItems?.first?.data(forType: .png), fakeImage,
                       "Non-string content must survive the dictation round trip")
        XCTAssertEqual(pasteboard.pasteboardItems?.first?.string(forType: .string), "caption")
    }

    /// A screen lock in the paste's activation delay must not type ⌘V into
    /// the lock screen, and must leave the clipboard exactly as it was: the
    /// transcript is never written, so nothing can sync it elsewhere, and the
    /// user's own clipboard survives. Unlocked, the paste goes ahead as before.
    func test_a_paste_at_a_locked_screen_never_touches_the_clipboard() throws {
        pasteboard.clearContents()
        pasteboard.setString("what the user copied", forType: .string)
        var typed = 0

        let skipped = DictationController.pasteUnlessLocked(
            "the dictated text", into: pasteboard,
            isScreenLocked: { true }, typeCommandV: { typed += 1 })
        XCTAssertNil(skipped, "a locked screen skips the paste")
        XCTAssertEqual(typed, 0, "no Cmd-V into the lock screen")
        XCTAssertEqual(pasteboard.string(forType: .string), "what the user copied",
                       "the clipboard is not touched")

        let prior = DictationController.pasteUnlessLocked(
            "the dictated text", into: pasteboard,
            isScreenLocked: { false }, typeCommandV: { typed += 1 })
        XCTAssertEqual(typed, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "the dictated text")
        let snapshot = try XCTUnwrap(prior, "an unlocked paste returns the earlier clipboard")
        XCTAssertFalse(snapshot.isEmpty)
        DictationController.restorePasteboard(pasteboard, from: snapshot)
        XCTAssertEqual(pasteboard.string(forType: .string), "what the user copied")
    }

    func test_multiple_items_round_trip() {
        pasteboard.clearContents()
        let a = NSPasteboardItem(); a.setString("first", forType: .string)
        let b = NSPasteboardItem(); b.setString("second", forType: .string)
        pasteboard.writeObjects([a, b])

        let snapshot = DictationController.snapshotPasteboard(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("transcript", forType: .string)
        DictationController.restorePasteboard(pasteboard, from: snapshot)

        let strings = (pasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .string) }
        XCTAssertEqual(strings, ["first", "second"],
                       "Every pasteboard item must be restored, in order, not just the first")
    }

    func test_empty_pasteboard_snapshot_is_empty() {
        pasteboard.clearContents()
        XCTAssertTrue(DictationController.snapshotPasteboard(pasteboard).isEmpty)
    }
}
