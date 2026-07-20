import XCTest
@testable import Mila

/// Unit tests for `ProgressCoalescer` — the piece that stopped whisper's
/// high-frequency progress callbacks from flooding the main actor with one
/// `Task` per tick (and applying them out of order). See the UI-freeze fix in
/// `docs/PLAN-ui-render-flood-freeze.md`.
final class ProgressCoalescerTests: XCTestCase {

    /// The first `offer` schedules a flush; further offers while that flush is
    /// still pending do NOT — that single-pending-flush property is what caps
    /// the flood.
    func test_only_first_offer_schedules_until_flushed() {
        let c = ProgressCoalescer()
        XCTAssertTrue(c.offer(0.1), "first offer should schedule a flush")
        XCTAssertFalse(c.offer(0.2), "second offer with a flush pending must not schedule")
        XCTAssertFalse(c.offer(0.3), "third offer with a flush pending must not schedule")
        _ = c.flush()
        XCTAssertTrue(c.offer(0.4), "after a flush, the next offer schedules again")
    }

    /// `flush` returns the max of everything offered since the last flush —
    /// intermediate values are coalesced, the latest/highest wins.
    func test_flush_returns_max_offered() {
        let c = ProgressCoalescer()
        _ = c.offer(0.1)
        _ = c.offer(0.5)
        _ = c.offer(0.4)
        XCTAssertEqual(c.flush(), 0.5, accuracy: 1e-9,
                       "flush must return the highest value offered in the window")
    }

    /// Out-of-order offers never regress the reported value: progress only ever
    /// moves forward, so the bar can't jump backward or freeze below a value it
    /// already passed.
    func test_progress_is_monotonic_across_flushes() {
        let c = ProgressCoalescer()
        _ = c.offer(0.2)
        XCTAssertEqual(c.flush(), 0.2, accuracy: 1e-9)

        // A stale, lower value arriving later must not lower the reported value.
        _ = c.offer(0.15)
        XCTAssertEqual(c.flush(), 0.2, accuracy: 1e-9,
                       "a lower late value must not regress progress")

        _ = c.offer(1.0)
        XCTAssertEqual(c.flush(), 1.0, accuracy: 1e-9)
    }

    /// A realistic burst: many rapid offers collapse to a single scheduled
    /// flush that reports the final value.
    func test_burst_collapses_to_single_flush_with_final_value() {
        let c = ProgressCoalescer()
        var scheduledCount = 0
        for i in 0...100 {
            if c.offer(Double(i) / 100.0) { scheduledCount += 1 }
        }
        XCTAssertEqual(scheduledCount, 1, "a burst with no interleaved flush schedules exactly once")
        XCTAssertEqual(c.flush(), 1.0, accuracy: 1e-9, "flush reports the final (max) value")
    }
}
