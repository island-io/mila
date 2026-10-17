import XCTest
import TranscriptionCore
@testable import Mila

/// Issue #355: a short network drop during a recording on the REMOTE backend
/// used to pop the blocking "Transcription error" alert ("The network
/// connection was lost") — and, on the default VAD path, silently drop every
/// utterance spoken during the outage from the saved transcript, because the
/// live transcript is saved as final and no batch pass runs over the WAV.
///
/// What these pin:
///   * the transient-vs-hard classification (`isTransientConnectivityError`):
///     only "could not reach the server" is transient; anything the server
///     ANSWERED with stays a loud error;
///   * the live path reports a transient failure as an outcome, not an alert,
///     while dictation (which cannot retry) still alerts;
///   * the live transcriber keeps a failed utterance, shows the non-blocking
///     warning, retries, and clears the warning by itself once the connection
///     is back — with the utterance in the transcript;
///   * Stop does not hang on an outage, and audio still untranscribed at Stop
///     sends the recording to the batch pass (unless the user deleted lines).
@MainActor
final class RemoteConnectionDropTests: XCTestCase {

    private var tempRoot: URL!
    private var store: RecordingStore!
    private var manager: ModelManager!
    private var engine: FlakyRemoteEngine!
    private var service: TranscriptionService!
    private var transcriber: LiveTranscriber!
    private let label = "RemoteConnectionDropTests"
    private var keychainKey: String { "\(label).apiKey" }

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: label)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = RecordingStore(rootDirectory: tempRoot)
        manager = TestSupport.isolatedModelManager(
            modelsDirectory: tempRoot.appendingPathComponent("Models"), label: label)
        try TestSupport.installFakeModel(into: manager)

        let suiteName = "\(label).remote"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        let remote = RemoteTranscriptionSettings(defaults: suite, apiKeyKeychainKey: keychainKey)
        remote.backend = .remote
        // Self-hosted endpoint → configured without a key, so routing reaches
        // the injected engine and never the network or the Keychain.
        remote.endpoint = "http://localhost:8080/v1"

        engine = FlakyRemoteEngine()
        service = TranscriptionService(
            store: store,
            modelManager: manager,
            diarizationSettings: DiarizationSettings(defaults: .init(suiteName: "\(label).diarization")!),
            remoteSettings: remote,
            engine: StubWhisperEngine(),
            remoteEngine: engine)
        transcriber = LiveTranscriber(transcription: service)
        // Fast backoff so the retry loop runs in milliseconds.
        transcriber.connectionRetryBaseDelay = 0.01
        transcriber.connectionRetryMaxDelay = 0.02
    }

    override func tearDown() async throws {
        _ = transcriber?.stop()
        transcriber = nil
        service = nil
        engine = nil
        manager = nil
        store = nil
        KeychainHelper.delete(key: keychainKey)
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        try await super.tearDown()
    }

    // MARK: - Classification

    func test_unreachable_server_errors_are_transient() {
        let codes: [URLError.Code] = [
            .notConnectedToInternet,
            .networkConnectionLost,
            .timedOut,
            .cannotConnectToHost,
            .cannotFindHost,
            .dnsLookupFailed,
        ]
        for code in codes {
            XCTAssertTrue(TranscriptionService.isTransientConnectivityError(URLError(code)),
                          "URLError \(code.rawValue) means the server could not be reached")
        }
        // URLSession's completion handler hands over a bridged NSError.
        let bridged = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        XCTAssertTrue(TranscriptionService.isTransientConnectivityError(bridged))
    }

    func test_server_refusals_and_configuration_errors_are_not_transient() {
        let hard: [any Error] = [
            RemoteWhisperEngine.RemoteError.http(status: 401, body: #"{"error":{"message":"bad key"}}"#),
            RemoteWhisperEngine.RemoteError.http(status: 404, body: ""),
            RemoteWhisperEngine.RemoteError.http(status: 429, body: ""),
            RemoteWhisperEngine.RemoteError.http(status: 500, body: ""),
            RemoteWhisperEngine.RemoteError.notConfigured,
            RemoteWhisperEngine.RemoteError.badResponse,
            RemoteWhisperEngine.RemoteError.emptyResult,
            RemoteWhisperEngine.RemoteError.noAudioCaptured,
            URLError(.badURL),
            URLError(.unsupportedURL),
            URLError(.userAuthenticationRequired),
            URLError(.serverCertificateUntrusted),
            URLError(.cancelled),
            CancellationError(),
        ]
        for error in hard {
            XCTAssertFalse(TranscriptionService.isTransientConnectivityError(error),
                           "\(error) must stay a hard, visible error")
        }
    }

    func test_retry_backoff_doubles_and_is_capped() {
        XCTAssertEqual(LiveTranscriber.connectionRetryDelay(attempt: 1, base: 2, max: 10), 2)
        XCTAssertEqual(LiveTranscriber.connectionRetryDelay(attempt: 2, base: 2, max: 10), 4)
        XCTAssertEqual(LiveTranscriber.connectionRetryDelay(attempt: 3, base: 2, max: 10), 8)
        XCTAssertEqual(LiveTranscriber.connectionRetryDelay(attempt: 4, base: 2, max: 10), 10)
        XCTAssertEqual(LiveTranscriber.connectionRetryDelay(attempt: 40, base: 2, max: 10), 10)
    }

    // MARK: - Service outcome

    func test_live_path_reports_a_dropped_connection_without_an_alert() async {
        await engine.setFailure(URLError(.networkConnectionLost))
        let outcome = await service.transcribeLiveSegments(
            samples: Self.speech(seconds: 1), language: "en", audioCtx: nil)
        guard case .connectionUnavailable = outcome else {
            return XCTFail("expected .connectionUnavailable, got \(outcome)")
        }
        XCTAssertNil(service.lastError,
                     "a transient network drop must not raise the blocking Transcription error alert")
    }

    func test_live_path_still_alerts_on_a_server_refusal() async {
        await engine.setFailure(RemoteWhisperEngine.RemoteError.http(
            status: 401, body: #"{"error":{"message":"Incorrect API key provided"}}"#))
        let outcome = await service.transcribeLiveSegments(
            samples: Self.speech(seconds: 1), language: "en", audioCtx: nil)
        guard case .skipped = outcome else {
            return XCTFail("a refusal is not retryable, got \(outcome)")
        }
        XCTAssertNotNil(service.lastError, "a bad key must still be surfaced")
    }

    func test_one_shot_dictation_still_alerts_on_a_dropped_connection() async {
        // Dictation has no retry: its audio is gone once the call returns, so
        // the user must still be told the transcription did not happen.
        await engine.setFailure(URLError(.notConnectedToInternet))
        let segments = await service.transcribeOnceSegments(
            samples: Self.speech(seconds: 1), language: "en", audioCtx: 0)
        XCTAssertTrue(segments.isEmpty)
        XCTAssertNotNil(service.lastError)
    }

    // MARK: - Live transcriber: warning, retry, recovery

    func test_vad_utterance_is_retried_and_warning_clears_when_connection_returns() async {
        await engine.setFailure(URLError(.networkConnectionLost))
        transcriber.useVAD = true
        transcriber.start(language: "en")
        transcriber.ingest(ArraySlice(Self.speech(seconds: 1.2)))
        transcriber.pauseBoundary()   // emit the utterance now

        let warned = await waitUntil { self.transcriber.isConnectionInterrupted }
        XCTAssertTrue(warned, "a dropped connection must raise the non-blocking warning")
        XCTAssertNil(service.lastError, "…and not the blocking alert")
        XCTAssertTrue(transcriber.segments.isEmpty)
        XCTAssertFalse(transcriber.hasUntranscribedAudio,
                       "the utterance is still being retried, not given up on")

        await engine.setFailure(nil)
        let recovered = await waitUntil { !self.transcriber.segments.isEmpty }
        XCTAssertTrue(recovered, "the utterance spoken during the outage must reach the transcript")
        XCTAssertEqual(transcriber.segments.map(\.text), ["back online"])
        XCTAssertFalse(transcriber.isConnectionInterrupted,
                       "the warning must clear by itself once an upload gets through")
        XCTAssertFalse(transcriber.hasUntranscribedAudio)
        XCTAssertNil(service.lastError)
        let calls = await engine.transcribeCalls
        XCTAssertGreaterThanOrEqual(calls, 2, "the failed utterance must have been re-sent")
    }

    func test_stop_drain_does_not_wait_out_an_outage_and_flags_the_gap() async {
        await engine.setFailure(URLError(.notConnectedToInternet))
        // A long backoff: the drain has to cut it short, not sleep through it.
        transcriber.connectionRetryBaseDelay = 30
        transcriber.connectionRetryMaxDelay = 30
        transcriber.useVAD = true
        transcriber.start(language: "en")
        transcriber.ingest(ArraySlice(Self.speech(seconds: 1.2)))
        transcriber.pauseBoundary()
        let warned = await waitUntil { self.transcriber.isConnectionInterrupted }
        XCTAssertTrue(warned)

        let startedAt = Date()
        await transcriber.transcribeNow()   // what stopRecording awaits
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 10,
                          "Stop must not hang for the length of the outage")
        XCTAssertTrue(transcriber.hasUntranscribedAudio,
                      "an utterance still unsent at Stop must be reported, so the batch pass covers it")
        XCTAssertNil(service.lastError)

        _ = transcriber.stop()
        XCTAssertFalse(transcriber.isConnectionInterrupted, "the warning ends with the recording")
        XCTAssertTrue(transcriber.hasUntranscribedAudio,
                      "Stop reads the gap after its drain; stop() must not erase it first")
        transcriber.reset()
        XCTAssertFalse(transcriber.hasUntranscribedAudio, "the next recording starts clean")
    }

    func test_fixed_window_tick_warns_and_recovers_on_the_next_tick() async {
        await engine.setFailure(URLError(.timedOut))
        transcriber.start(language: "en")
        transcriber.ingest(ArraySlice(Self.speech(seconds: 2)))
        await transcriber.transcribeNow()
        XCTAssertTrue(transcriber.isConnectionInterrupted)
        XCTAssertNil(service.lastError)

        await engine.setFailure(nil)
        await transcriber.transcribeNow()
        XCTAssertFalse(transcriber.isConnectionInterrupted)
        XCTAssertEqual(transcriber.segments.map(\.text), ["back online"])
    }

    // MARK: - Stop: is the live transcript final?

    func test_untranscribed_audio_sends_the_recording_to_the_batch_pass() {
        XCTAssertTrue(QuickActionsController.isLiveTranscriptAuthoritative(
            vadActive: true, hasLiveSegments: true,
            userDeletedLiveLines: false, hasUntranscribedAudio: false),
            "baseline: a complete VAD transcript is final")
        XCTAssertFalse(QuickActionsController.isLiveTranscriptAuthoritative(
            vadActive: true, hasLiveSegments: true,
            userDeletedLiveLines: false, hasUntranscribedAudio: true),
            "a transcript with an outage-shaped hole must not be saved as final")
        XCTAssertFalse(QuickActionsController.isLiveTranscriptAuthoritative(
            vadActive: true, hasLiveSegments: false,
            userDeletedLiveLines: false, hasUntranscribedAudio: true))
    }

    func test_user_deletions_win_over_the_gap_fallback() {
        // The batch pass re-transcribes the whole WAV and would write every
        // deleted line back (bugbot-rules/deleted-data-stays-deleted.md).
        XCTAssertTrue(QuickActionsController.isLiveTranscriptAuthoritative(
            vadActive: true, hasLiveSegments: true,
            userDeletedLiveLines: true, hasUntranscribedAudio: true))
        XCTAssertTrue(QuickActionsController.isLiveTranscriptAuthoritative(
            vadActive: true, hasLiveSegments: false,
            userDeletedLiveLines: true, hasUntranscribedAudio: true),
            "an emptied transcript stays empty")
    }

    func test_fixed_window_mode_is_never_authoritative() {
        for gap in [false, true] {
            XCTAssertFalse(QuickActionsController.isLiveTranscriptAuthoritative(
                vadActive: false, hasLiveSegments: true,
                userDeletedLiveLines: false, hasUntranscribedAudio: gap))
        }
    }

    // MARK: - Helpers

    /// Audio well above the VAD threshold, so the detector emits it and the
    /// silence guard lets it through.
    private static func speech(seconds: Double) -> [Float] {
        Array(repeating: Float(0.05), count: Int(16_000 * seconds))
    }

    private func waitUntil(timeout: TimeInterval = 5,
                           _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }
}

/// A remote engine whose "network" the test switches off and on. While a
/// failure is set every call throws it; otherwise it answers with one segment.
private actor FlakyRemoteEngine: RemoteTranscribing {
    private var failure: (any Error)?
    private(set) var transcribeCalls = 0

    func setFailure(_ error: (any Error)?) { failure = error }

    func configure(_ config: RemoteTranscriptionConfig) async {}
    func loadIfNeeded(modelURL: URL, displayName: String) async throws {}
    func shutdown() async {}
    func transcribe(samples: [Float],
                    language: String,
                    audioCtx: Int32?,
                    progress: (@Sendable (Float) -> Void)?,
                    isCancelled: (@Sendable () -> Bool)?) async throws -> [TranscriptSegment] {
        transcribeCalls += 1
        if let failure { throw failure }
        return [TranscriptSegment(start: 0, end: 1, text: "back online")]
    }
}
