import XCTest
import AVFoundation
import Combine
@testable import Mila

/// Pins the split between `RecordingSession` and `RecordingMeters` (#280).
///
/// `RecordingSession` is a `@StateObject` on `MilaApp`, so every one of its
/// `objectWillChange` emissions re-evaluates the App `body` and re-diffs the
/// whole scene — window root view, sidebar outline view, main menu. While the
/// elapsed clock and the level meters were `@Published` on the session, that
/// happened at audio-buffer cadence and cost 60–75% of a core for the whole
/// recording. The readouts now live on `session.meters`, which only small
/// leaf views observe.
///
/// A round-trip test cannot catch a regression here: the values are still
/// readable through the passthroughs whichever object publishes them. What has
/// to be asserted is WHO emits — so these tests count `objectWillChange` on
/// both objects while the timer ticks.
@MainActor
final class RecordingSessionMetersTests: XCTestCase {

    /// Counts `objectWillChange` emissions until cancelled.
    private final class EmissionCounter {
        private(set) var count = 0
        private var cancellable: AnyCancellable?
        init<O: ObservableObject>(_ object: O) {
            cancellable = object.objectWillChange.sink { [weak self] _ in
                self?.count += 1
            }
        }
    }

    /// The elapsed clock ticks (200 ms timer) must publish on `meters` and
    /// leave the session silent: nothing about the session's *state* changed.
    func test_elapsed_ticks_publish_on_meters_not_on_the_session() async throws {
        let session = RecordingSession()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meters-ticks-\(UUID().uuidString).wav")
        await session.startFakeForTesting(outputURL: url)
        // Subscribe AFTER start so the `.idle → .recording` transition is not
        // counted against the session.
        let sessionEmissions = EmissionCounter(session)
        let meterEmissions = EmissionCounter(session.meters)

        try await Task.sleep(nanoseconds: 700_000_000)

        XCTAssertGreaterThanOrEqual(meterEmissions.count, 2,
                                    "the 200 ms elapsed timer should have ticked on `meters`")
        XCTAssertEqual(sessionEmissions.count, 0,
                       "an elapsed tick must not re-publish the session — that re-evaluates the App body")
        XCTAssertGreaterThan(session.elapsed, 0,
                             "the passthrough still reads the live clock")

        _ = await session.stop()
    }

    /// The audio path itself: every mic buffer updates `micLevel`, which used
    /// to re-publish the session once per buffer (~12 Hz mic-only, ~50 Hz with
    /// system audio) for the whole recording. Drive the real `consumeMic` on a
    /// fake session — `write()` no-ops without an `AVAudioFile` — and count.
    func test_mic_buffers_publish_on_meters_not_on_the_session() async throws {
        let session = RecordingSession()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meters-buffers-\(UUID().uuidString).wav")
        await session.startFakeForTesting(outputURL: url)
        let sessionEmissions = EmissionCounter(session)
        let meterEmissions = EmissionCounter(session.meters)

        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let frames: AVAudioFrameCount = 1_365   // one mic tap buffer's worth at 16 kHz
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<Int(frames) {
            channel[i] = 0.25 * sinf(Float(i) * 2 * .pi * 440 / 16_000)
        }

        let bufferCount = 120   // ~10 s of mic audio
        for _ in 0..<bufferCount {
            await session.consumeMic(buffer)
        }

        XCTAssertGreaterThan(session.micLevel, 0, "the meter saw the signal")
        XCTAssertGreaterThanOrEqual(meterEmissions.count, bufferCount,
                                    "each buffer updates the meter object")
        XCTAssertEqual(sessionEmissions.count, 0,
                       "a mic buffer must never re-publish the session — with the session a "
                       + "@StateObject on MilaApp, that was one App-body re-evaluation per buffer")

        _ = await session.stop()
    }

    /// State transitions are the session's to publish — and only the
    /// session's. A pause zeroes the meters (that is a `meters` emission) and
    /// flips `state` (a session emission); neither must leak into the other.
    func test_state_transitions_publish_on_the_session() async {
        let session = RecordingSession()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meters-state-\(UUID().uuidString).wav")
        await session.startFakeForTesting(outputURL: url)
        let sessionEmissions = EmissionCounter(session)

        await session.pause()
        XCTAssertEqual(session.state, .paused)
        XCTAssertGreaterThanOrEqual(sessionEmissions.count, 1,
                                    "a state transition is exactly what the session should publish")
        XCTAssertEqual(session.micLevel, 0)
        XCTAssertEqual(session.systemLevel, 0)

        session.resume()
        _ = await session.stop()
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.elapsed, 0, accuracy: 0.001,
                       "stop resets the clock through the meters object")
    }

    /// The readouts are one object for the life of the session, so a view
    /// that captured `session.meters` at record-start keeps observing the
    /// right thing across pause / resume / stop / the next recording.
    func test_meters_identity_is_stable_across_recordings() async {
        let session = RecordingSession()
        let meters = session.meters
        let first = FileManager.default.temporaryDirectory
            .appendingPathComponent("meters-identity-1-\(UUID().uuidString).wav")
        await session.startFakeForTesting(outputURL: first)
        _ = await session.stop()
        let second = FileManager.default.temporaryDirectory
            .appendingPathComponent("meters-identity-2-\(UUID().uuidString).wav")
        await session.startFakeForTesting(outputURL: second)
        XCTAssertTrue(session.meters === meters)
        _ = await session.stop()
    }
}
