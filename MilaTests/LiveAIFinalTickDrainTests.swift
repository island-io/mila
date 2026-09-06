import Foundation
import XCTest
@testable import Mila

/// `LiveAISession.awaitFinalTick()` must END when the tick slot is stranded,
/// rather than spin on it (issue #259).
///
/// The drain is `while let handle = inFlight { _ = await handle.value }`.
/// `await` on a task that has ALREADY finished resumes immediately, so a slot
/// left pointing at a finished task does not make that loop hang -- it makes
/// it re-read the same handle forever, at full tilt, on the main actor. The
/// cause (a stranded slot) is already bad: `scheduleKick` coalesces every
/// later tick behind a non-nil `inFlight`, so Live AI is silently dead for the
/// rest of the meeting. This loop turns that silent stall into a spinning
/// core, which on a laptop mid-meeting is audible and expensive.
///
/// #242's `defer` clears the slot on every exit path, so the strand is not
/// reachable in the app today; this pins the guard that keeps the loop
/// terminating if some future exit path stops going through it.
///
/// Nothing here bets on a clock. #256 was a 30s bound in this area that turned
/// out to be a lost wakeup in the test's own helper, and the lesson taken from
/// it (see `LiveAIDeletedLineSessionTests.waitUntil`) is that a positive wait
/// cannot tell a wedge from a loaded runner. Every wait below awaits the exact
/// task it is reasoning about and then reads `inFlightTickForTesting` -- the
/// seam #257 added for precisely this question.
@MainActor
final class LiveAIFinalTickDrainTests: XCTestCase {

    func test_awaitFinalTick_ends_on_a_stranded_slot_and_clears_it() async {
        let (session, calls) = makeSession(suite: "LiveAIFinalTickDrainTests.stranded")

        // Launch a tick. `feed` is synchronous on the main actor and `kick()`
        // fills the slot before it returns, so the handle is readable here.
        session.feed(transcript: "[00:00] One.", immediate: true)
        guard let stranded = session.inFlightTickForTesting else {
            XCTFail("precondition: an immediate feed must launch a tick")
            return
        }

        // Strand the slot the way the production code could: cancel the TICK,
        // not the session. `LiveAISession.cancel()` cancels the task AND
        // clears `inFlight` itself, whereas a tick cancelled from anywhere
        // else takes the `defer`'s `if !Task.isCancelled` branch and skips the
        // clear -- leaving the slot holding a task that has finished. That
        // asymmetry is deliberate (a cancelled tick must never clobber the
        // newer handle `start()` may have put in the slot), and it is the one
        // real seam through which the state in #259 can exist. Nothing is
        // faked and no write seam is needed: `inFlightTickForTesting` hands
        // back the task, and cancelling a task is something any holder can do.
        stranded.cancel()
        _ = await stranded.value   // the tick body, `defer` included, is done
        guard let slot = session.inFlightTickForTesting else {
            XCTFail("precondition: the slot must still hold the finished tick")
            return
        }
        XCTAssertEqual(slot, stranded,
                       "precondition: the slot must still hold the tick that just finished")

        // The property under test: this call has to come back. On the pre-#259
        // loop it never does and never suspends either, so there is no honest
        // timeout to wrap it in -- a watchdog task cannot run while the drain
        // holds the main actor without yielding. Reaching the next line is the
        // assertion.
        await session.awaitFinalTick()

        XCTAssertNil(session.inFlightTickForTesting,
                     "the drain must clear the dead handle, not merely stop looking at it")

        // Clearing it is what un-wedges the session, which is why the guard
        // clears rather than only breaking: with the strand gone, a later feed
        // gets a tick of its own instead of being coalesced behind a task that
        // will never complete again.
        let before = calls.value.count
        session.feed(transcript: "[00:00] One.\n[00:05] Two.", immediate: true)
        XCTAssertNotNil(session.inFlightTickForTesting,
                        "a later tick must be able to run once the strand is cleared")
        await settle(session)
        XCTAssertGreaterThan(calls.value.count, before,
                             "the later tick must actually reach the runner")
    }

    // MARK: - Helpers
    //
    // Deliberately the same shape as `LiveAIDeletedLineSessionTests`, minus
    // the gate: this suite never needs a tick held open inside the runner.

    private final class Calls {
        var value: [LiveAISession.LLMCall] = []
    }

    private func makeSession(suite: String) -> (LiveAISession, Calls) {
        UserDefaults().removePersistentDomain(forName: "\(suite).llm")
        UserDefaults().removePersistentDomain(forName: "\(suite).live")
        let llm = LLMSettings(defaults: UserDefaults(suiteName: "\(suite).llm")!)
        llm.tool = .claude
        let live = LiveAISettings(defaults: UserDefaults(suiteName: "\(suite).live")!)
        live.enabled = true
        live.llmMinIntervalSeconds = 0

        let calls = Calls()
        let session = LiveAISession(llmSettings: llm, liveAISettings: live)
        session.performCall = { call in
            calls.value.append(call)
            return #"{"summary":"ok","items":[]}"#
        }
        session.start()
        return (session, calls)
    }

    /// Settle whatever tick is outstanding by awaiting the task itself, so no
    /// tick outlives the test. Stops as soon as the slot stops changing, so a
    /// strand ends this loop too -- the same shape as
    /// `LiveAIDeletedLineSessionTests.waitUntilIdle`, and the same shape the
    /// production drain now uses.
    private func settle(_ session: LiveAISession) async {
        var previous: Task<Void, Never>?
        while let tick = session.inFlightTickForTesting {
            if let previous, previous == tick { break }
            _ = await tick.value
            previous = tick
        }
    }
}
