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
///   * the transient-vs-hard classification (`isTransientRemoteFailure`):
///     "could not reach the server" and "temporarily unavailable" are
///     retryable; any other answer from the server stays a loud error;
///   * the live path reports a transient failure as an outcome, not an alert,
///     while dictation (which cannot retry) still alerts;
///   * the live transcriber keeps a failed utterance, shows the non-blocking
///     warning, retries, and clears the warning by itself once the server
///     answers again — with the utterance in the transcript;
///   * Stop's drain makes ONE upload attempt for a whole backlog when the
///     server is still unreachable, and records the rest as missing spans;
///   * missing spans are filled from the recorded audio and inserted in time
///     order — at finalize and by "Retry missing parts" — and kept on the
///     recording when they still fail.
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

    func test_unreachable_or_temporarily_unavailable_server_is_transient() {
        let codes: [URLError.Code] = [
            .notConnectedToInternet,
            .networkConnectionLost,
            .timedOut,
            .cannotConnectToHost,
            .cannotFindHost,
            .dnsLookupFailed,
            .secureConnectionFailed,
            .cannotLoadFromNetwork,
            .resourceUnavailable,
            .dataNotAllowed,
            .internationalRoamingOff,
            .callIsActive,
        ]
        for code in codes {
            XCTAssertTrue(TranscriptionService.isTransientRemoteFailure(URLError(code)),
                          "URLError \(code.rawValue) means the server could not be reached")
        }
        // URLSession's completion handler hands over a bridged NSError.
        let bridged = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        XCTAssertTrue(TranscriptionService.isTransientRemoteFailure(bridged))

        for status in [408, 429, 502, 503, 504] {
            XCTAssertTrue(TranscriptionService.isTransientRemoteFailure(
                RemoteWhisperEngine.RemoteError.http(status: status, body: "")),
                "HTTP \(status) says 'try again shortly'")
        }
    }

    func test_server_refusals_and_configuration_errors_are_not_transient() {
        let hard: [any Error] = [
            RemoteWhisperEngine.RemoteError.http(status: 401, body: #"{"error":{"message":"bad key"}}"#),
            RemoteWhisperEngine.RemoteError.http(status: 403, body: ""),
            RemoteWhisperEngine.RemoteError.http(status: 404, body: ""),
            RemoteWhisperEngine.RemoteError.http(status: 400, body: ""),
            RemoteWhisperEngine.RemoteError.http(status: 500, body: #"{"detail":"Failed to decode audio."}"#),
            // Out of credit is a 429 too, and no amount of waiting fixes it.
            RemoteWhisperEngine.RemoteError.http(
                status: 429, body: #"{"error":{"code":"insufficient_quota","type":"insufficient_quota"}}"#),
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
            XCTAssertFalse(TranscriptionService.isTransientRemoteFailure(error),
                           "\(error) must stay a hard, visible error")
        }
    }

    func test_short_clips_get_a_short_request_timeout() {
        let rate = Int(WhisperAudioFormat.sampleRate)
        XCTAssertEqual(TranscriptionService.shortClipRequestTimeout(sampleCount: rate * 5), 30,
                       "a padded live utterance must fail in seconds, not in an hour")
        XCTAssertEqual(TranscriptionService.shortClipRequestTimeout(sampleCount: rate * 25), 50)
        XCTAssertEqual(TranscriptionService.shortClipRequestTimeout(sampleCount: rate * 60 * 60 * 3),
                       RemoteWhisperEngine.wholeRecordingTimeout)
    }

    func test_retry_backoff_doubles_and_is_capped() {
        XCTAssertEqual(LiveTranscriber.connectionRetryDelay(attempt: 1, base: 2, max: 10), 2)
        XCTAssertEqual(LiveTranscriber.connectionRetryDelay(attempt: 2, base: 2, max: 10), 4)
        XCTAssertEqual(LiveTranscriber.connectionRetryDelay(attempt: 3, base: 2, max: 10), 8)
        XCTAssertEqual(LiveTranscriber.connectionRetryDelay(attempt: 4, base: 2, max: 10), 10)
        XCTAssertEqual(LiveTranscriber.connectionRetryDelay(attempt: 40, base: 2, max: 10), 10)
    }

    func test_insertion_keeps_time_order_and_existing_lines_first_on_ties() {
        let merged = TranscriptionService.insertedInTimeOrder(
            [TranscriptSegment(start: 1, end: 2, text: "recovered"),
             TranscriptSegment(start: 5, end: 6, text: "tie")],
            into: [TranscriptSegment(start: 0, end: 1, text: "a"),
                   TranscriptSegment(start: 5, end: 6, text: "existing"),
                   TranscriptSegment(start: 9, end: 10, text: "z")]) { $0.start }
        XCTAssertEqual(merged.map(\.text), ["a", "recovered", "existing", "tie", "z"])
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

    func test_live_path_treats_service_unavailable_as_transient() async {
        await engine.setFailure(RemoteWhisperEngine.RemoteError.http(status: 503, body: "busy"))
        let outcome = await service.transcribeLiveSegments(
            samples: Self.speech(seconds: 1), language: "en", audioCtx: nil)
        guard case .connectionUnavailable = outcome else {
            return XCTFail("expected .connectionUnavailable, got \(outcome)")
        }
        XCTAssertNil(service.lastError)
    }

    func test_live_path_still_alerts_on_a_server_refusal() async {
        await engine.setFailure(RemoteWhisperEngine.RemoteError.http(
            status: 401, body: #"{"error":{"message":"Incorrect API key provided"}}"#))
        let outcome = await service.transcribeLiveSegments(
            samples: Self.speech(seconds: 1), language: "en", audioCtx: nil)
        guard case .failed = outcome else {
            return XCTFail("a refusal is a failure, not a skip and not retryable, got \(outcome)")
        }
        XCTAssertNotNil(service.lastError, "a bad key must still be surfaced")
    }

    func test_live_requests_carry_the_short_timeout() async {
        _ = await service.transcribeLiveSegments(
            samples: Self.speech(seconds: 1), language: "en", audioCtx: nil)
        let timeouts = await engine.requestTimeouts
        XCTAssertEqual(timeouts, [30], "live clips must not inherit the whole-recording hour")
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
        transcriber.connectionRetryBaseDelay = 0.05
        transcriber.connectionRetryMaxDelay = 0.05
        transcriber.useVAD = true
        transcriber.start(language: "en")
        transcriber.ingest(ArraySlice(Self.speech(seconds: 1.2)))
        transcriber.pauseBoundary()   // emit the utterance now

        let warned = await waitUntil { self.transcriber.isConnectionInterrupted }
        XCTAssertTrue(warned, "a dropped connection must raise the non-blocking warning")
        XCTAssertNil(service.lastError, "…and not the blocking alert")
        XCTAssertTrue(transcriber.segments.isEmpty)
        XCTAssertTrue(transcriber.untranscribedSpans.isEmpty,
                      "the utterance is still being retried, not given up on")

        await engine.setFailure(nil)
        let recovered = await waitUntil { !self.transcriber.segments.isEmpty }
        XCTAssertTrue(recovered, "the utterance spoken during the outage must reach the transcript")
        XCTAssertEqual(transcriber.segments.count, 1)
        XCTAssertFalse(transcriber.isConnectionInterrupted,
                       "the warning must clear by itself once an upload gets through")
        XCTAssertTrue(transcriber.untranscribedSpans.isEmpty)
        XCTAssertNil(service.lastError)
        let calls = await engine.transcribeCalls
        XCTAssertGreaterThanOrEqual(calls, 2, "the failed utterance must have been re-sent")
    }

    func test_warning_clears_when_the_server_answers_even_with_a_refusal() async {
        await engine.setFailure(URLError(.notConnectedToInternet))
        transcriber.useVAD = true
        transcriber.start(language: "en")
        transcriber.ingest(ArraySlice(Self.speech(seconds: 1.2)))
        transcriber.pauseBoundary()
        let warned = await waitUntil { self.transcriber.isConnectionInterrupted }
        XCTAssertTrue(warned)

        // The server is reachable again — it just refuses this request.
        await engine.setFailure(RemoteWhisperEngine.RemoteError.http(status: 401, body: ""))
        let cleared = await waitUntil { !self.transcriber.isConnectionInterrupted }
        XCTAssertTrue(cleared, "a refusal is still an answer: the connection banner must go")
        let marked = await waitUntil { !self.transcriber.untranscribedSpans.isEmpty }
        XCTAssertTrue(marked, "a refused utterance must be recorded as missing, not dropped")
        XCTAssertNotNil(service.lastError, "the refusal itself stays loud")
    }

    func test_stop_drain_makes_one_attempt_for_a_whole_backlog() async throws {
        await engine.setFailure(URLError(.notConnectedToInternet))
        // A long backoff: the drain has to cut it short, not sleep through it.
        transcriber.connectionRetryBaseDelay = 30
        transcriber.connectionRetryMaxDelay = 30
        transcriber.useVAD = true
        transcriber.start(language: "en")
        // Two utterances: the second queues behind the first, which is stuck
        // in its backoff.
        transcriber.ingest(ArraySlice(Self.speech(seconds: 1.2) + Self.silence(seconds: 1)
                                      + Self.speech(seconds: 1.2)))
        transcriber.pauseBoundary()
        let warned = await waitUntil { self.transcriber.isConnectionInterrupted }
        XCTAssertTrue(warned)
        XCTAssertFalse(transcriber.isTranscribing,
                       "nothing is being transcribed during the backoff, so no spinner")
        let callsBeforeStop = await engine.transcribeCalls

        let startedAt = Date()
        await transcriber.transcribeNow()   // what stopRecording awaits
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 10,
                          "Stop must not wait out the backoff")
        let callsDuringDrain = await engine.transcribeCalls - callsBeforeStop
        XCTAssertEqual(callsDuringDrain, 1,
                       "once the drain finds the server unreachable, the rest of the backlog must not each pay a timeout")
        XCTAssertEqual(transcriber.untranscribedSpans.count, 2,
                       "both utterances are kept as missing spans, not dropped")
        XCTAssertNil(service.lastError)

        // Stop's span pass right after: no second upload, so no second
        // request timeout at Stop.
        let audio = try writeAudio(Self.speech(seconds: 3.4))
        await transcriber.recoverUntranscribedAudio(from: audio)
        let callsAfterRecover = await engine.transcribeCalls - callsBeforeStop
        XCTAssertEqual(callsAfterRecover, 1)

        _ = transcriber.stop()
        XCTAssertFalse(transcriber.isConnectionInterrupted, "the warning ends with the recording")
        XCTAssertEqual(transcriber.untranscribedSpans.count, 2,
                       "Stop reads the spans after its drain; stop() must not erase them first")
        transcriber.reset()
        XCTAssertTrue(transcriber.untranscribedSpans.isEmpty, "the next recording starts clean")
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
        XCTAssertEqual(transcriber.segments.count, 1)
    }

    // MARK: - Filling the gaps from the recorded audio

    func test_finalize_fills_a_missing_span_from_the_audio_in_time_order() async throws {
        let audio = Self.speech(seconds: 1.2) + Self.silence(seconds: 1) + Self.speech(seconds: 1.2)
        let audioURL = try writeAudio(audio)
        transcriber.useVAD = true
        transcriber.start(language: "en")

        // The first utterance is refused; the second goes through.
        await engine.setFailure(RemoteWhisperEngine.RemoteError.http(status: 500, body: "hiccup"))
        transcriber.ingest(ArraySlice(Self.speech(seconds: 1.2) + Self.silence(seconds: 1)))
        let marked = await waitUntil { self.transcriber.untranscribedSpans.count == 1 }
        XCTAssertTrue(marked)
        service.lastError = nil
        await engine.setFailure(nil)
        transcriber.ingest(ArraySlice(Self.speech(seconds: 1.2)))
        transcriber.pauseBoundary()
        await transcriber.transcribeNow()
        XCTAssertEqual(transcriber.segments.map(\.text), ["reply 2"])
        let liveLine = try XCTUnwrap(transcriber.segments.first)

        await transcriber.recoverUntranscribedAudio(from: audioURL)

        XCTAssertEqual(transcriber.segments.count, 2, "the missing utterance is back")
        XCTAssertEqual(transcriber.segments.last?.id, liveLine.id,
                       "the recovered line goes BEFORE the later live line, and the live line is untouched")
        XCTAssertEqual(transcriber.segments.first?.text, "reply 3")
        XCTAssertLessThan(transcriber.segments[0].startSeconds, transcriber.segments[1].startSeconds)
        XCTAssertTrue(transcriber.untranscribedSpans.isEmpty)
        XCTAssertEqual(transcriber.fullText, "reply 3 reply 2")
        XCTAssertNil(service.lastError)
    }

    func test_finalize_keeps_spans_that_still_fail() async throws {
        let audioURL = try writeAudio(Self.speech(seconds: 1.2) + Self.silence(seconds: 1)
                                      + Self.speech(seconds: 1.2))
        transcriber.useVAD = true
        transcriber.start(language: "en")
        await engine.setFailure(RemoteWhisperEngine.RemoteError.http(status: 500, body: "hiccup"))
        transcriber.ingest(ArraySlice(Self.speech(seconds: 1.2) + Self.silence(seconds: 1)))
        let marked = await waitUntil { self.transcriber.untranscribedSpans.count == 1 }
        XCTAssertTrue(marked)
        await engine.setFailure(nil)
        transcriber.ingest(ArraySlice(Self.speech(seconds: 1.2)))
        transcriber.pauseBoundary()
        await transcriber.transcribeNow()

        await engine.setFailure(URLError(.notConnectedToInternet))
        await transcriber.recoverUntranscribedAudio(from: audioURL)
        XCTAssertEqual(transcriber.segments.count, 1, "nothing invented, nothing lost")
        XCTAssertEqual(transcriber.untranscribedSpans.count, 1,
                       "a span that still fails stays recorded, so Stop saves it on the recording")
    }

    func test_retry_missing_parts_fills_the_stored_recording_and_keeps_names() async throws {
        let audioURL = store.freshAudioURL(suggestedName: "Gap")
        try TestSupport.writeSineWav(at: audioURL, durationSeconds: 4)
        let recording = Recording(
            title: "Gap", duration: 4, source: .meeting,
            audioFileName: audioURL.lastPathComponent, status: .completed, language: "en",
            segments: [TranscriptSegment(start: 3, end: 4, text: "later", speaker: "SPEAKER_00")],
            fullText: "later",
            speakerNames: ["SPEAKER_00": "Dana"],
            untranscribedSpans: [UntranscribedSpan(start: 0.5, end: 1.5)])
        store.add(recording)

        await service.retryUntranscribedSpans(of: recording.id)

        let row = try XCTUnwrap(store.recordings.first { $0.id == recording.id })
        XCTAssertNil(row.untranscribedSpans, "the gap is filled")
        XCTAssertEqual(row.segments.map(\.text), ["reply 1", "later"])
        XCTAssertEqual(row.segments.first?.start ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(row.speakerNames, ["SPEAKER_00": "Dana"],
                       "filling a gap must not re-key speakers the way a full pass does")
        XCTAssertEqual(row.segments.last?.speaker, "SPEAKER_00")
        XCTAssertEqual(row.fullText, "reply 1 later")
        XCTAssertEqual(row.status, .completed)
    }

    func test_retry_missing_parts_while_offline_keeps_the_gap_and_says_so() async throws {
        let audioURL = store.freshAudioURL(suggestedName: "Offline")
        try TestSupport.writeSineWav(at: audioURL, durationSeconds: 4)
        let spans = [UntranscribedSpan(start: 0.5, end: 1.5), UntranscribedSpan(start: 2, end: 2.8)]
        let recording = Recording(
            title: "Offline", duration: 4, source: .meeting,
            audioFileName: audioURL.lastPathComponent, status: .completed, language: "en",
            segments: [TranscriptSegment(start: 3, end: 4, text: "later")],
            fullText: "later",
            untranscribedSpans: spans)
        store.add(recording)
        await engine.setFailure(URLError(.notConnectedToInternet))

        await service.retryUntranscribedSpans(of: recording.id)

        let row = try XCTUnwrap(store.recordings.first { $0.id == recording.id })
        XCTAssertEqual(row.untranscribedSpans, spans)
        XCTAssertEqual(row.segments.map(\.text), ["later"])
        let calls = await engine.transcribeCalls
        XCTAssertEqual(calls, 1, "the first unreachable span ends the attempt")
        XCTAssertNotNil(service.lastError, "a retry the user asked for must say it did nothing")
        XCTAssertTrue(service.spanRetryIDs.isEmpty)
    }

    func test_a_refused_span_does_not_block_the_ones_after_it() async throws {
        let audioURL = store.freshAudioURL(suggestedName: "Refused")
        try TestSupport.writeSineWav(at: audioURL, durationSeconds: 4)
        let first = UntranscribedSpan(start: 0.5, end: 1.5)
        let second = UntranscribedSpan(start: 2, end: 2.8)
        let recording = Recording(
            title: "Refused", duration: 4, source: .meeting,
            audioFileName: audioURL.lastPathComponent, status: .completed, language: "en",
            segments: [TranscriptSegment(start: 3, end: 4, text: "later")],
            fullText: "later",
            untranscribedSpans: [first, second])
        store.add(recording)
        await engine.failNextCall(with: RemoteWhisperEngine.RemoteError.http(status: 500, body: "bad slice"))

        await service.retryUntranscribedSpans(of: recording.id)

        let row = try XCTUnwrap(store.recordings.first { $0.id == recording.id })
        XCTAssertEqual(row.untranscribedSpans, [first], "only the refused span is still missing")
        XCTAssertEqual(row.segments.map(\.text), ["reply 2", "later"],
                       "a refusal of one span must not stop the next from being filled")
        let calls = await engine.transcribeCalls
        XCTAssertEqual(calls, 2)
    }

    func test_a_span_with_no_audio_on_disk_stays_missing() async throws {
        let audioURL = store.freshAudioURL(suggestedName: "Short")
        try TestSupport.writeSineWav(at: audioURL, durationSeconds: 1)
        // Past the end of the file: nothing can be read for it.
        let beyond = UntranscribedSpan(start: 2, end: 3)
        let recording = Recording(
            title: "Short", duration: 1, source: .meeting,
            audioFileName: audioURL.lastPathComponent, status: .completed, language: "en",
            segments: [TranscriptSegment(start: 0, end: 1, text: "only")],
            fullText: "only",
            untranscribedSpans: [beyond])
        store.add(recording)

        await service.retryUntranscribedSpans(of: recording.id)

        let row = try XCTUnwrap(store.recordings.first { $0.id == recording.id })
        XCTAssertEqual(row.untranscribedSpans, [UntranscribedSpan(start: 2, end: 3, unreadable: true)],
                       "an unreadable slice is not proof of silence — the gap must stay visible")
        XCTAssertEqual(row.retryableUntranscribedSeconds, 0, "…but no retry can fix it")
        XCTAssertEqual(row.untranscribedSeconds, 1, accuracy: 0.0001)
        let calls = await engine.transcribeCalls
        XCTAssertEqual(calls, 0, "nothing to send")
        XCTAssertNil(service.lastError,
                     "unreadable audio is not a server failure and must not raise the server alert")

        // A second retry has nothing retryable left and changes nothing.
        await service.retryUntranscribedSpans(of: recording.id)
        let again = try XCTUnwrap(store.recordings.first { $0.id == recording.id })
        XCTAssertEqual(again.untranscribedSpans, row.untranscribedSpans)
        XCTAssertNil(service.lastError)
    }

    func test_invalid_spans_are_dropped_at_decode() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"R","createdAt":0,"duration":1,"source":"microphone",
         "audioFileName":"r.wav","status":"completed","language":"en","segments":[],
         "untranscribedSpans":[{"start":2,"end":1},{"start":-1,"end":1},{"start":1,"end":2}]}
        """
        let decoded = try JSONDecoder().decode(Recording.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.untranscribedSpans, [UntranscribedSpan(start: 1, end: 2)],
                       "inverted or negative spans would trap later; they must not survive decode")
        XCTAssertFalse(UntranscribedSpan(start: .nan, end: 1).isValid)
        XCTAssertFalse(UntranscribedSpan(start: 0, end: .infinity).isValid)
        XCTAssertEqual(UntranscribedSpan(start: 0, end: .infinity).duration, 0)

        let samples = try AudioConvert.loadAsWhisperSamples(
            url: tempRoot.appendingPathComponent("missing.wav"), from: .nan, to: 1)
        XCTAssertTrue(samples.isEmpty, "a non-finite bound is refused before touching the file")

        XCTAssertFalse(UntranscribedSpan(start: 0, end: 1e300).isValid, "past a day is a corrupt row")
        // Huge but finite bounds must clamp to the file, not trap converting
        // seconds × sample rate to a frame index.
        let wav = store.freshAudioURL(suggestedName: "Huge")
        try TestSupport.writeSineWav(at: wav, durationSeconds: 1)
        let tail = try AudioConvert.loadAsWhisperSamples(url: wav, from: 0.5, to: 1e300)
        XCTAssertEqual(tail.count, 8_000, "clamped to the end of the 1 s file")
        let beyond = try AudioConvert.loadAsWhisperSamples(url: wav, from: 1e300, to: 2e300)
        XCTAssertTrue(beyond.isEmpty)
    }

    func test_untranscribed_spans_round_trip_and_are_omitted_when_empty() throws {
        var recording = Recording(title: "R", source: .microphone, audioFileName: "r.wav")
        let encoder = JSONEncoder()
        let bare = try JSONSerialization.jsonObject(with: encoder.encode(recording)) as? [String: Any]
        XCTAssertNil(bare?["untranscribedSpans"], "a complete transcript encodes exactly as before")

        recording.untranscribedSpans = [UntranscribedSpan(start: 1, end: 2.5)]
        let decoded = try JSONDecoder().decode(Recording.self, from: encoder.encode(recording))
        XCTAssertEqual(decoded.untranscribedSpans, [UntranscribedSpan(start: 1, end: 2.5)])
        XCTAssertEqual(decoded.untranscribedSeconds, 1.5, accuracy: 0.0001)
    }

    // MARK: - Helpers

    /// Audio well above the VAD threshold, so the detector emits it and the
    /// silence guard lets it through.
    private static func speech(seconds: Double) -> [Float] {
        Array(repeating: Float(0.05), count: Int(16_000 * seconds))
    }

    private static func silence(seconds: Double) -> [Float] {
        Array(repeating: Float(0), count: Int(16_000 * seconds))
    }

    /// The "recorded WAV": live time and file time are the same clock,
    /// because the session feeds the live transcriber exactly what it writes.
    private func writeAudio(_ samples: [Float]) throws -> URL {
        let url = tempRoot.appendingPathComponent("recorded-\(UUID().uuidString).wav")
        try AudioConvert.writeWhisperWAV(samples: samples, to: url)
        return url
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
/// failure is set every call throws it; otherwise it answers with one segment
/// whose text names the call ("reply N"), so a test can tell which upload
/// produced which line.
private actor FlakyRemoteEngine: RemoteTranscribing {
    private var failure: (any Error)?
    /// Thrown by the next call only, then cleared — a refusal of one clip.
    private var nextCallFailure: (any Error)?
    private(set) var transcribeCalls = 0
    private(set) var requestTimeouts: [TimeInterval] = []

    func setFailure(_ error: (any Error)?) { failure = error }
    func failNextCall(with error: any Error) { nextCallFailure = error }

    func configure(_ config: RemoteTranscriptionConfig) async {}
    func loadIfNeeded(modelURL: URL, displayName: String) async throws {}
    func shutdown() async {}

    func transcribe(samples: [Float],
                    language: String,
                    audioCtx: Int32?,
                    requestTimeout: TimeInterval,
                    isCancelled: (@Sendable () -> Bool)?) async throws -> [TranscriptSegment] {
        requestTimeouts.append(requestTimeout)
        return try await transcribe(samples: samples, language: language, audioCtx: audioCtx,
                                    progress: nil, isCancelled: isCancelled)
    }

    func transcribe(samples: [Float],
                    language: String,
                    audioCtx: Int32?,
                    progress: (@Sendable (Float) -> Void)?,
                    isCancelled: (@Sendable () -> Bool)?) async throws -> [TranscriptSegment] {
        transcribeCalls += 1
        if let nextCallFailure {
            self.nextCallFailure = nil
            throw nextCallFailure
        }
        if let failure { throw failure }
        return [TranscriptSegment(start: 0, end: 1, text: "reply \(transcribeCalls)")]
    }
}
