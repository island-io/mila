import XCTest
import AVFoundation
import Combine
@testable import Mila

/// Publish budget for the App scene during a live recording (#283).
///
/// `MilaApp` holds ~35 `@StateObject`s; each one that publishes re-evaluates
/// the App `body` and re-diffs every scene. A recording once did that per
/// audio buffer — `RecordingSession.micLevel` at ~12 Hz — and pinned the main
/// thread at 60–75% for the whole recording (#280). Nothing in the pipeline
/// logs "the App body ran", so this test counts it.
///
/// **Why counts, not CPU.** A CPU threshold on a shared CI runner is a coin
/// toss: the same work reads 8% on an idle runner and 30% on a loaded one.
/// Publish counts are sample-driven — the same fixture through the same
/// pipeline publishes the same number of times whatever the machine is doing
/// — and they name the object that blew the budget, which a CPU number never
/// can. The main-thread CPU fraction is still asserted, but as a coarse
/// backstop with a wide margin (the bug read 60–75%; the fix reads single
/// digits), and the failure message points at the counts.
///
/// **Why app-hosted and CI-only.** The App scene under test is the real one:
/// `MilaTests` runs inside `Mila.app`, and `AppSceneChurnProbe` hands the test
/// the App's own `RecordingSession` / `QuickActionsController`. Driving them
/// on a developer's machine would boot their diarization runtime and fire
/// their configured LLM for the duration, so the test is gated on
/// `MILA_APP_CHURN_E2E=1`, which only the `unit-and-ui-tests` job sets.
@MainActor
final class AppSceneChurnTests: XCTestCase {
    private static let gate = "MILA_APP_CHURN_E2E"

    /// Seconds of fixture audio pumped, at real time — real time so a 5 Hz
    /// timer regression shows up as 5 publishes a second, not as the handful
    /// a fast pump would let through.
    private static let pumpSeconds: TimeInterval = 12

    /// Publishes any single App-level object may make per second of
    /// recording. Utterance-driven objects (`LiveTranscriber` flips
    /// `isTranscribing` twice per utterance and appends a segment) sit near
    /// 1/s on this fixture; the bug signature starts at 12/s (one per mic
    /// buffer) and a timer regression at 5/s.
    private static let publishBudgetPerSecond = 4.0

    /// Main-thread CPU fraction during the pump: the coarse backstop.
    private static let mainThreadCPUBudget = 0.5

    /// One mic tap buffer at 16 kHz — `MicrophoneRecorder` taps 4096 frames at
    /// 48 kHz, which `RecordingSession` sees as ~1365 samples every ~85 ms.
    private static let framesPerBuffer = 1_365
    private static let bufferIntervalNanos: UInt64 = 85_000_000

    /// Counts `objectWillChange` emissions per registered object.
    private final class PublishCounter {
        private(set) var counts: [String: Int] = [:]
        private var subscriptions = Set<AnyCancellable>()
        init(_ objects: [AppSceneChurnProbe.Registered]) {
            for entry in objects {
                entry.willChange
                    .sink { [weak self] _ in self?.counts[entry.name, default: 0] += 1 }
                    .store(in: &subscriptions)
            }
        }
        func stop() { subscriptions.removeAll() }
    }

    func test_live_recording_stays_within_the_app_scene_publish_budget() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment[Self.gate] == "1",
                          "Set \(Self.gate)=1 to run — drives the host app's real recording controller (CI only).")
        let probe = AppSceneChurnProbe.shared
        guard let session = probe.session, let actions = probe.actions,
              !probe.appLevelObjects.isEmpty else {
            throw XCTSkip("App-level objects are not registered — needs the app-hosted DEBUG test host")
        }
        try XCTSkipIf(actions.isRecording, "the host app is already recording")

        let fixture = try Self.loadFixture()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-churn-\(UUID().uuidString).wav")
        await actions.startFakeRecordingForTesting(outputURL: outputURL)
        XCTAssertTrue(actions.isRecording, "startFakeRecordingForTesting did not start a recording")
        addTeardownBlock { @MainActor in
            await actions.discardFakeRecordingForTesting()
        }

        // `wireLiveAIPipeline` installs `onLiveSamples` when it sees
        // `.recording`; the live pipeline is not running until it has.
        var wired = false
        for _ in 0..<60 {
            if session.onLiveSamples != nil { wired = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(wired, "the live pipeline never wired up to the fake recording")
        // Let the start-up publishes (state, activeJob, transcriber start)
        // drain before counting: the budget is for the steady state.
        try await Task.sleep(nanoseconds: 500_000_000)

        let counter = PublishCounter(probe.appLevelObjects)
        let bodyBefore = probe.bodyEvaluations
        let cpuBefore = Self.mainThreadCPUSeconds()
        let wallBefore = Date()

        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let totalBuffers = Int(Self.pumpSeconds * 16_000) / Self.framesPerBuffer
        var offset = 0
        for _ in 0..<totalBuffers {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format,
                                                        frameCapacity: AVAudioFrameCount(Self.framesPerBuffer)))
            buffer.frameLength = AVAudioFrameCount(Self.framesPerBuffer)
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            for i in 0..<Self.framesPerBuffer {
                channel[i] = fixture[(offset + i) % fixture.count]
            }
            offset += Self.framesPerBuffer
            // The real mic path: meters, live feed, VAD, transcriber — but
            // `write()` no-ops on a fake session, so nothing hits disk.
            await session.consumeMic(buffer)
            try await Task.sleep(nanoseconds: Self.bufferIntervalNanos)
        }

        let wall = Date().timeIntervalSince(wallBefore)
        let cpu = Self.mainThreadCPUSeconds() - cpuBefore
        counter.stop()
        let bodyDelta = probe.bodyEvaluations - bodyBefore
        let counts = counter.counts

        let report = counts.sorted { $0.value > $1.value }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        print("AppSceneChurn: \(String(format: "%.1f", wall))s pumped, MilaApp.body evaluated \(bodyDelta)×, "
              + "main-thread CPU \(String(format: "%.2f", cpu))s (\(String(format: "%.0f", 100 * cpu / wall))%), "
              + "publishes: \(report.isEmpty ? "none" : report)")

        // Primary: no App-level object publishes at buffer or timer cadence.
        let budget = Int(Self.publishBudgetPerSecond * Self.pumpSeconds)
        for (name, count) in counts where count > budget {
            XCTFail("`\(name)` published \(count) times during \(Int(Self.pumpSeconds))s of recording "
                    + "(budget \(budget)). It is a @StateObject on MilaApp, so each publish re-evaluated the "
                    + "App body and re-diffed every scene — move the high-frequency value onto its own "
                    + "ObservableObject, as RecordingMeters does (#280).")
        }
        XCTAssertEqual(counts["session"] ?? 0, 0,
                       "RecordingSession publishes only on state transitions; nothing changed state mid-pump")
        XCTAssertLessThanOrEqual(bodyDelta, budget,
                                 "MilaApp.body evaluated \(bodyDelta) times in \(Int(Self.pumpSeconds))s of "
                                 + "recording (budget \(budget)); publishes: \(report)")

        // Backstop: the whole point of the budget is main-thread time.
        XCTAssertLessThan(cpu / wall, Self.mainThreadCPUBudget,
                          "main thread spent \(String(format: "%.0f", 100 * cpu / wall))% of the recording busy "
                          + "(bug: 60–75%, fixed: single digits) — the publish counts above say who: \(report)")

        await actions.discardFakeRecordingForTesting()
        XCTAssertFalse(actions.isRecording, "discardFakeRecordingForTesting must leave the controller idle")
    }

    // MARK: - Helpers

    /// `Packages/TranscriptionCore/Fixtures/en_meeting_notes.wav`: 5.7 s of
    /// real English speech, Float32 mono 16 kHz — looped by the pump. Real
    /// speech (not a tone) so the VAD emits utterances and the transcriber
    /// runs its per-utterance publishes, which the budget has to leave room
    /// for. Resolved from `#filePath` like `RemoteTranscriptionE2ETests`.
    private static func loadFixture() throws -> [Float] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MilaTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Packages/TranscriptionCore/Fixtures/en_meeting_notes.wav")
        let file = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.length)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        try file.read(into: buffer)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000, "fixture is expected at 16 kHz")
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        XCTAssertGreaterThan(samples.count, 16_000, "fixture suspiciously short")
        return samples
    }

    /// CPU seconds consumed by the calling thread. The test is `@MainActor`,
    /// so this is the main thread — where SwiftUI does its updates.
    private static func mainThreadCPUSeconds() -> TimeInterval {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000
    }
}
