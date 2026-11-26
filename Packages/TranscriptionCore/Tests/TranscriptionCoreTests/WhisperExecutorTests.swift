import Foundation
import XCTest
@testable import TranscriptionCore

/// #401: whisper.cpp's blocking calls run on a dedicated thread, not on a
/// thread of Swift's cooperative pool, and moving them there did not make
/// the engine re-entrant.
final class WhisperExecutorTests: XCTestCase {

    func test_engine_code_runs_on_the_dedicated_whisper_thread() async {
        let engine = WhisperEngine()
        let onWhisperThread = await engine.isOnWhisperThreadForTesting()
        XCTAssertTrue(onWhisperThread)
        // Every engine instance shares the one thread.
        let other = WhisperEngine()
        let otherOnWhisperThread = await other.isOnWhisperThreadForTesting()
        XCTAssertTrue(otherOnWhisperThread)
        XCTAssertEqual(WhisperThreadExecutor.shared.threadName, "io.island.mila.whisper")
    }

    func test_the_test_itself_is_not_on_the_whisper_thread() async {
        // Sanity check for the test above: the probe is not trivially true.
        XCTAssertFalse(WhisperThreadExecutor.shared.isCurrentThread)
    }

    /// The safety property the executor design rests on: an engine call that
    /// is running (standing in for `whisper_full`) cannot be overtaken by
    /// `shutdown()` or `unload()`, which `whisper_free` the context. They
    /// queue behind it and run only once it returns.
    ///
    /// `engine.unload()` here is a call on the concrete type, which is what
    /// first caught `unload()` resolving to `TranscribingEngine`'s no-op
    /// default: that returned at once, while the call was still in flight.
    func test_shutdown_and_unload_wait_for_the_call_in_flight() async throws {
        let engine = WhisperEngine()
        let log = EventLog()
        let release = DispatchSemaphore(value: 0)

        let running = Task {
            await engine.blockForTesting(entered: { log.append("entered") }, release: release)
            log.append("call returned")
        }
        // Polled rather than awaited on an expectation, so the wait parks no
        // thread and needs nothing beyond what corelibs XCTest has on Linux.
        let deadline = Date().addingTimeInterval(10)
        while log.events.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(log.events, ["entered"], "the blocking call never started")

        let unload = Task { await engine.unload(); log.append("unload") }
        let shutdown = Task { await engine.shutdown(); log.append("shutdown") }
        // Give both every chance to run early if they could.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(log.events, ["entered"], "free ran while a whisper call was in flight")

        log.append("released")
        release.signal()
        await running.value
        await unload.value
        await shutdown.value
        XCTAssertEqual(Array(log.events.prefix(2)), ["entered", "released"])
        XCTAssertEqual(Set(log.events.dropFirst(2)), ["call returned", "unload", "shutdown"])
    }
}

extension WhisperEngine {
    /// Isolated, so it runs on the engine's executor. Blocks that thread the
    /// way `whisper_full` does until `release` is signalled.
    func blockForTesting(entered: @Sendable () -> Void, release: DispatchSemaphore) {
        entered()
        release.wait()
    }

    func isOnWhisperThreadForTesting() -> Bool {
        WhisperThreadExecutor.shared.isCurrentThread
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ event: String) { lock.lock(); storage.append(event); lock.unlock() }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}
