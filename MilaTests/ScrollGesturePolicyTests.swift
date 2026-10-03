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

    /// The mouse event types the fallback accepts when they land on the scroll
    /// view. Deliberately spelled out rather than derived from the policy.
    private let mouseEvents: [NSEvent.EventType] = [
        .leftMouseDown, .leftMouseDragged, .leftMouseUp, .otherMouseDragged,
    ]

    func test_silentDuringALiveScroll() {
        // Every event type that would otherwise qualify, while a live scroll is
        // running: the live-scroll notifications own the gesture, not us.
        for event in mouseEvents + [.keyDown] {
            XCTAssertFalse(
                ScrollGesturePolicy.shouldSynthesizeGesture(isLiveScrolling: true,
                                                            isLiveResizing: false, event: event,
                                                            eventIsOverScrollView: true),
                "\(event) must not synthesize a gesture mid-live-scroll")
        }
    }

    func test_scrollWheelNeverSynthesizes() {
        // A wheel/trackpad scroll that moves the clip view always posts
        // live-scroll notifications, so the fallback must never claim it —
        // including the trailing bounds change just after didEndLiveScroll,
        // when isLiveScrolling has already been cleared.
        XCTAssertFalse(ScrollGesturePolicy.shouldSynthesizeGesture(isLiveScrolling: true,
                                                                   isLiveResizing: false,
                                                                   event: .scrollWheel,
                                                                   eventIsOverScrollView: true))
        XCTAssertFalse(ScrollGesturePolicy.shouldSynthesizeGesture(isLiveScrolling: false,
                                                                   isLiveResizing: false,
                                                                   event: .scrollWheel,
                                                                   eventIsOverScrollView: true))
    }

    func test_keyboardScrollingStillSynthesizes() {
        // Page Up/Down and the arrow keys post no live-scroll notification at
        // all — this fallback is the only thing that sees them. A key event has
        // no meaningful location, so it is judged on the type alone.
        for overScrollView in [true, false] {
            XCTAssertTrue(
                ScrollGesturePolicy.shouldSynthesizeGesture(isLiveScrolling: false,
                                                            isLiveResizing: false, event: .keyDown,
                                                            eventIsOverScrollView: overScrollView),
                "keyboard scrolling must not depend on the pointer's location")
        }
    }

    func test_scrollerInteractionStillSynthesizes() {
        for event in mouseEvents {
            XCTAssertTrue(
                ScrollGesturePolicy.shouldSynthesizeGesture(isLiveScrolling: false,
                                                            isLiveResizing: false, event: event,
                                                            eventIsOverScrollView: true),
                "\(event) over the scroll view should still count as manual")
        }
    }

    /// Dragging the window's edge or the split-view divider carries the SAME
    /// event types as a scroller drag and also moves the clip view — AppKit
    /// clamps `bounds.origin.y` as the content re-flows. Accepting those
    /// disengaged following on a window resize, which is the layout-driven
    /// change this guard exists to ignore.
    func test_mouseDragOutsideTheScrollViewIsNotAScroll() {
        for event in mouseEvents {
            XCTAssertFalse(
                ScrollGesturePolicy.shouldSynthesizeGesture(isLiveScrolling: false,
                                                            isLiveResizing: false, event: event,
                                                            eventIsOverScrollView: false),
                "\(event) away from the scroll view is a resize, not a scroll")
        }
    }

    /// The location test alone is not enough for a RIGHT-edge window resize:
    /// the transcript runs to the window's right edge, so the pointer can be
    /// inside the scroll view's bounds while the drag is a resize. AppKit's own
    /// live-resize flag covers that case, and the location test covers the
    /// divider drag that may not raise it — so neither may fire.
    func test_liveResizeIsNeverAScroll() {
        for event in mouseEvents + [.keyDown] {
            XCTAssertFalse(
                ScrollGesturePolicy.shouldSynthesizeGesture(isLiveScrolling: false,
                                                            isLiveResizing: true, event: event,
                                                            eventIsOverScrollView: true),
                "\(event) during a live resize is the window changing size, not a scroll")
        }
    }

    func test_layoutDrivenChangesAreIgnored() {
        // No current event: the LazyVStack loading more rows moves the clip
        // view without the user touching anything.
        XCTAssertFalse(ScrollGesturePolicy.shouldSynthesizeGesture(isLiveScrolling: false,
                                                                   isLiveResizing: false,
                                                                   event: nil,
                                                                   eventIsOverScrollView: true))
        // An unrelated event being current is not a scroll either.
        XCTAssertFalse(ScrollGesturePolicy.shouldSynthesizeGesture(isLiveScrolling: false,
                                                                   isLiveResizing: false,
                                                                   event: .mouseMoved,
                                                                   eventIsOverScrollView: true))
    }
}
