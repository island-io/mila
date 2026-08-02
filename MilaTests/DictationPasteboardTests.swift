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
