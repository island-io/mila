import AppKit
import XCTest
@testable import Mila

/// Pins when a raw clip-bounds change may be reported as a complete manual
/// scroll gesture.
///
/// The bug this guards against (Bugbot, PR #287): the bounds fallback reports a
/// start AND an end together, so firing it during a live scroll ended the
/// gesture while the user was still scrolling. `userScrollEnded` then re-engaged
/// following as soon as any part of the highlighted row was on screen, and the
/// programmatic scroll issued by the next segment change fought the gesture —
/// its 0.45s suppression window swallowing the user's continuing scroll too.
final class ScrollGesturePolicyTests: XCTestCase {

    func test_silentDuringALiveScroll() {
        // Every event type that would otherwise qualify, while a live scroll is
        // running: the live-scroll notifications own the gesture, not us.
        for event in [NSEvent.EventType.leftMouseDown, .leftMouseDragged,
                      .leftMouseUp, .otherMouseDragged, .keyDown] {
            XCTAssertFalse(
                ScrollGesturePolicy.shouldSynthesizeGesture(isLiveScrolling: true, event: event),
                "\(event) must not synthesize a gesture mid-live-scroll")
        }
    }

    func test_scrollWheelNeverSynthesizes() {
        // A wheel/trackpad scroll that moves the clip view always posts
        // live-scroll notifications, so the fallback must never claim it —
        // including the trailing bounds change just after didEndLiveScroll,
        // when isLiveScrolling has already been cleared.
        XCTAssertFalse(ScrollGesturePolicy.shouldSynthesizeGesture(isLiveScrolling: true,
                                                                   event: .scrollWheel))
        XCTAssertFalse(ScrollGesturePolicy.shouldSynthesizeGesture(isLiveScrolling: false,
                                                                   event: .scrollWheel))
    }

    func test_keyboardScrollingStillSynthesizes() {
        // Page Up/Down and the arrow keys post no live-scroll notification at
        // all — this fallback is the only thing that sees them.
        XCTAssertTrue(ScrollGesturePolicy.shouldSynthesizeGesture(isLiveScrolling: false,
                                                                  event: .keyDown))
    }

    func test_scrollerInteractionStillSynthesizes() {
        for event in [NSEvent.EventType.leftMouseDown, .leftMouseDragged,
                      .leftMouseUp, .otherMouseDragged] {
            XCTAssertTrue(
                ScrollGesturePolicy.shouldSynthesizeGesture(isLiveScrolling: false, event: event),
                "\(event) outside a live scroll should still count as manual")
        }
    }

    func test_layoutDrivenChangesAreIgnored() {
        // No current event: a window resize or the LazyVStack loading more rows
        // moves the clip view without the user touching anything.
        XCTAssertFalse(ScrollGesturePolicy.shouldSynthesizeGesture(isLiveScrolling: false,
                                                                   event: nil))
        // An unrelated event being current is not a scroll either.
        XCTAssertFalse(ScrollGesturePolicy.shouldSynthesizeGesture(isLiveScrolling: false,
                                                                   event: .mouseMoved))
    }
}
