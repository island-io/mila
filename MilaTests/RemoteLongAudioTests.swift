import XCTest
import TranscriptionCore
@testable import Mila

/// Issue #376: an imported Voice Memo longer than ~25 minutes never
/// transcribed on a remote `gpt-4o(-mini)-transcribe` model. The whole file
/// went to the API in one request, which refused it (`input_too_large`);
/// the row sat in "running" for hours with 0 segments and then turned
/// `failed` with no reason anywhere.
///
/// What these pin, against a scripted server over a real `URLSession` (a
/// `URLProtocol` stub — no network, no API key):
///   * a long recording goes out as several requests, none longer than the
///     limit, and comes back as one transcript on the recording's clock;
///   * how each response format is stitched — untimed `json` spans its
///     piece, `verbose_json` times are offset and clamped, per-request
///     speaker labels survive only when one piece produced every line;
///   * the first refused piece ends the run with the SERVER's reason;
///   * silent and wordless pieces don't fail the recording;
///   * through `TranscriptionService`: the stitched result completes the
///     row, and a refusal leaves the row `failed` with the reason on it.
final class RemotePieceTranscriptionTests: XCTestCase {

    private static let sampleRate = WhisperAudioFormat.sampleRate

    private func tone(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * Self.sampleRate)).map { i in
            0.3 * Float(sin(2 * Double.pi * 220 * Double(i) / Self.sampleRate))
        }
    }

    private func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Self.sampleRate))
    }

    /// 25 s of "speech" with pauses at 8.0–8.5 s and 17.0–17.5 s. With a
    /// 10 s limit it is cut in those pauses: three pieces, the cuts at
    /// 8.3 s and 17.3 s (`AudioChunkPlannerTests` pins where exactly).
    private func threePieceAudio() -> [Float] {
        tone(8.0) + silence(0.5) + tone(8.5) + silence(0.5) + tone(7.5)
    }

    // MARK: - Pieces and offsets

    func test_long_audio_goes_out_in_pieces_and_comes_back_on_the_recording_clock() async throws {
        let fixture = PieceServerFixture(model: "gpt-4o-mini-transcribe", replies: [
            .ok(#"{"text":"one"}"#), .ok(#"{"text":"two"}"#), .ok(#"{"text":"three"}"#),
        ])
        defer { fixture.cleanUp() }
        let samples = threePieceAudio()
        let segments = try await fixture.transcribe(samples)

        XCTAssertEqual(fixture.server.requestCount, 3)
        let sent = fixture.encoded.pieceSampleCounts
        XCTAssertEqual(sent.count, 3)
        XCTAssertEqual(sent.reduce(0, +), samples.count, "every sample is sent exactly once")
        XCTAssertTrue(sent.allSatisfy { Double($0) <= 10 * Self.sampleRate }, "no piece over the limit: \(sent)")

        XCTAssertEqual(segments.map(\.text), ["one", " two", " three"])
        XCTAssertEqual(segments.map(\.text).joined(), "one two three",
                       "the transcript is the segments joined with no separator — pieces must not run together")
        // `json` has no timing, so each answer spans its piece.
        let cut1 = Double(sent[0]) / Self.sampleRate
        let cut2 = cut1 + Double(sent[1]) / Self.sampleRate
        XCTAssertEqual(segments[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(segments[0].end, cut1, accuracy: 0.001)
        XCTAssertEqual(segments[1].start, cut1, accuracy: 0.001)
        XCTAssertEqual(segments[1].end, cut2, accuracy: 0.001)
        XCTAssertEqual(segments[2].start, cut2, accuracy: 0.001)
        XCTAssertEqual(segments[2].end, 25, accuracy: 0.001)
        XCTAssertTrue((8.0...8.5).contains(cut1), "cut in the first pause, not mid-word: \(cut1)")
        XCTAssertTrue((17.0...17.5).contains(cut2), "cut in the second pause, not mid-word: \(cut2)")
    }

    func test_timed_segments_are_offset_by_their_piece_and_clamped_into_it() async throws {
        let fixture = PieceServerFixture(model: "whisper-1", replies: [
            .ok(#"{"segments":[{"start":0,"end":1.5,"text":" a"},{"start":2,"end":99,"text":" b"}]}"#),
            .ok(#"{"segments":[{"start":0.5,"end":1,"text":" c"}]}"#),
        ])
        defer { fixture.cleanUp() }
        let samples = tone(9.0) + silence(0.5) + tone(5.0)
        let segments = try await fixture.transcribe(samples)

        let cut = Double(try XCTUnwrap(fixture.encoded.pieceSampleCounts.first)) / Self.sampleRate
        XCTAssertEqual(segments.map(\.text), [" a", " b", " c"])
        XCTAssertEqual(segments[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(segments[0].end, 1.5, accuracy: 0.001)
        XCTAssertEqual(segments[1].start, 2, accuracy: 0.001)
        XCTAssertEqual(segments[1].end, cut, accuracy: 0.001,
                       "an end past the piece is clamped, so it can't overlap the next piece")
        XCTAssertEqual(segments[2].start, cut + 0.5, accuracy: 0.001)
        XCTAssertEqual(segments[2].end, cut + 1, accuracy: 0.001)
    }

    private static let diarized = #"{"segments":[{"start":0,"end":1,"text":" hi","speaker":"A"},{"start":1,"end":2,"text":" yo","speaker":"B"},{"start":2,"end":3,"text":" hi again","speaker":"A"}]}"#

    /// `gpt-4o-transcribe-diarize` labels each request's speakers from "A",
    /// so "A" in two pieces need not be the same person. With nothing else
    /// to label the recording, each piece's voices get labels of their own:
    /// one person may end up with several, but two people never share one.
    func test_server_speaker_labels_from_several_pieces_are_numbered_apart() async throws {
        let fixture = PieceServerFixture(model: "gpt-4o-transcribe-diarize",
                                         replies: [.ok(Self.diarized), .ok(Self.diarized), .ok(Self.diarized)])
        defer { fixture.cleanUp() }
        let segments = try await fixture.transcribe(threePieceAudio())
        XCTAssertEqual(segments.map(\.speaker), [
            "SPEAKER_00", "SPEAKER_01", "SPEAKER_00",
            "SPEAKER_02", "SPEAKER_03", "SPEAKER_02",
            "SPEAKER_04", "SPEAKER_05", "SPEAKER_04",
        ])
    }

    /// When pyannote will label the recording, labels from several requests
    /// are dropped: server labels win over the offline pass (#180), and
    /// pyannote's are consistent across the whole recording.
    func test_server_speaker_labels_from_several_pieces_give_way_to_the_offline_pass() async throws {
        let fixture = PieceServerFixture(model: "gpt-4o-transcribe-diarize",
                                         replies: [.ok(Self.diarized), .ok(Self.diarized), .ok(Self.diarized)],
                                         offlineDiarization: true)
        defer { fixture.cleanUp() }
        let segments = try await fixture.transcribe(threePieceAudio())
        XCTAssertEqual(segments.count, 9)
        XCTAssertTrue(segments.allSatisfy { $0.speaker == nil }, "\(segments.map(\.speaker))")
    }

    /// Only one piece had words: its labels describe the whole recording.
    func test_labels_survive_when_one_piece_produced_every_line() async throws {
        let fixture = PieceServerFixture(model: "gpt-4o-transcribe-diarize",
                                         replies: [.ok(#"{"text":""}"#), .ok(Self.diarized), .ok(#"{"text":""}"#)],
                                         offlineDiarization: true)
        defer { fixture.cleanUp() }
        let segments = try await fixture.transcribe(threePieceAudio())
        XCTAssertEqual(segments.map(\.speaker), ["SPEAKER_00", "SPEAKER_01", "SPEAKER_00"])
    }

    func test_server_speaker_labels_are_kept_when_one_request_covers_the_recording() async throws {
        let fixture = PieceServerFixture(model: "gpt-4o-transcribe-diarize", replies: [
            .ok(#"{"segments":[{"start":0,"end":1,"text":" hi","speaker":"A"},{"start":1,"end":2,"text":" yo","speaker":"B"}]}"#),
        ])
        defer { fixture.cleanUp() }
        let segments = try await fixture.transcribe(tone(5))
        XCTAssertEqual(fixture.server.requestCount, 1)
        XCTAssertEqual(segments.map(\.speaker), ["SPEAKER_00", "SPEAKER_01"])
    }

    // MARK: - Failures

    /// The bug's own response. The run stops at the refused piece (the rest
    /// would be refused too) and the error carries the server's reason.
    func test_a_refused_piece_ends_the_run_with_the_servers_reason() async throws {
        let fixture = PieceServerFixture(model: "gpt-4o-mini-transcribe", replies: [
            .ok(#"{"text":"one"}"#),
            .init(status: 400, body: Self.inputTooLarge),
            .ok(#"{"text":"three"}"#),
        ])
        defer { fixture.cleanUp() }
        do {
            _ = try await fixture.transcribe(threePieceAudio())
            XCTFail("A refused piece must fail the transcription")
        } catch let error as RemoteWhisperEngine.RemoteError {
            guard case .http(let status, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(status, 400)
            XCTAssertTrue(error.errorDescription?.contains("too large for this model") == true,
                          error.errorDescription ?? "")
        }
        XCTAssertEqual(fixture.server.requestCount, 2, "no request after the refusal")
    }

    /// One proxy hiccup among twenty requests must not throw away the
    /// pieces already transcribed.
    func test_a_transient_failure_is_retried_and_the_run_completes() async throws {
        let fixture = PieceServerFixture(model: "gpt-4o-mini-transcribe", replies: [
            .ok(#"{"text":"one"}"#),
            .init(status: 502, body: "Bad Gateway"),
            .ok(#"{"text":"two"}"#),
            .ok(#"{"text":"three"}"#),
        ])
        defer { fixture.cleanUp() }
        let segments = try await fixture.transcribe(threePieceAudio())
        XCTAssertEqual(segments.map(\.text).joined(), "one two three")
        XCTAssertEqual(fixture.server.requestCount, 4)
        XCTAssertEqual(fixture.encoded.pieceSampleCounts.count, 4, "the retry sends the same piece again")
        XCTAssertEqual(fixture.encoded.pieceSampleCounts[1], fixture.encoded.pieceSampleCounts[2])
    }

    func test_a_transient_failure_that_persists_fails_after_the_retries() async throws {
        let fixture = PieceServerFixture(model: "gpt-4o-mini-transcribe", replies: [
            .ok(#"{"text":"one"}"#),
            .init(status: 503, body: "Unavailable"),
            .init(status: 503, body: "Unavailable"),
            .init(status: 503, body: "Unavailable"),
            .ok(#"{"text":"never asked"}"#),
        ])
        defer { fixture.cleanUp() }
        do {
            _ = try await fixture.transcribe(threePieceAudio())
            XCTFail("A piece that keeps failing must fail the transcription")
        } catch RemoteWhisperEngine.RemoteError.http(let status, _) {
            XCTAssertEqual(status, 503)
        }
        XCTAssertEqual(fixture.server.requestCount, 4, "one try and two retries, then stop")
    }

    /// Out of credit is a 429 too, and no amount of waiting fixes it.
    func test_a_quota_refusal_is_not_retried() async throws {
        let fixture = PieceServerFixture(model: "gpt-4o-mini-transcribe", replies: [
            .init(status: 429, body: #"{"error":{"message":"You exceeded your current quota.","code":"insufficient_quota"}}"#),
            .ok(#"{"text":"never asked"}"#),
        ])
        defer { fixture.cleanUp() }
        do {
            _ = try await fixture.transcribe(threePieceAudio())
            XCTFail("A quota refusal must fail the transcription")
        } catch RemoteWhisperEngine.RemoteError.http(let status, _) {
            XCTAssertEqual(status, 429)
        }
        XCTAssertEqual(fixture.server.requestCount, 1)
    }

    func test_only_transient_failures_are_retried() {
        XCTAssertTrue(RemoteWhisperEngine.pieceFailureIsRetryable(
            RemoteWhisperEngine.RemoteError.http(status: 502, body: "")))
        XCTAssertTrue(RemoteWhisperEngine.pieceFailureIsRetryable(URLError(.networkConnectionLost)))
        XCTAssertFalse(RemoteWhisperEngine.pieceFailureIsRetryable(URLError(.timedOut)),
                       "a piece that already waited its full timeout would only wait as long again")
        XCTAssertFalse(RemoteWhisperEngine.pieceFailureIsRetryable(
            RemoteWhisperEngine.RemoteError.http(status: 400, body: Self.inputTooLarge)))
        XCTAssertFalse(RemoteWhisperEngine.pieceFailureIsRetryable(
            RemoteWhisperEngine.RemoteError.http(status: 401, body: "")))
        XCTAssertFalse(RemoteWhisperEngine.pieceFailureIsRetryable(CancellationError()))
    }

    /// The engine also serves live clips, and their `configure` can arrive
    /// between two pieces. Every piece of one recording still goes to the
    /// server it started with.
    func test_every_piece_goes_to_the_server_the_pass_started_with() async throws {
        let fixture = PieceServerFixture(model: "gpt-4o-mini-transcribe", replies: [
            .ok(#"{"text":"one"}"#), .ok(#"{"text":"two"}"#), .ok(#"{"text":"three"}"#),
        ])
        let elsewhere = PieceServerFixture(model: "whisper-1", replies: [])
        defer { fixture.cleanUp(); elsewhere.cleanUp() }
        let engine = fixture.engine
        let otherConfig = elsewhere.config
        fixture.server.beforeReply = { requestNumber in
            guard requestNumber == 1 else { return }
            // Reconfigure while the first piece's request is in flight. The
            // wait is bounded, and the actor is free: it is suspended on
            // this very request.
            let done = DispatchSemaphore(value: 0)
            Task {
                await engine.configure(otherConfig)
                done.signal()
            }
            XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
        }
        let segments = try await fixture.transcribe(threePieceAudio())
        XCTAssertEqual(segments.map(\.text).joined(), "one two three")
        XCTAssertEqual(fixture.server.requestCount, 3)
        XCTAssertEqual(elsewhere.server.requestCount, 0, "no piece went to the newly configured server")
    }

    /// A stretch of exact digital silence inside a real recording is not
    /// uploaded — `upload` would refuse it as "no audio was captured" and
    /// fail a perfectly good recording.
    func test_a_silent_piece_is_skipped_not_sent() async throws {
        let fixture = PieceServerFixture(model: "gpt-4o-mini-transcribe", replies: [
            .ok(#"{"text":"before"}"#), .ok(#"{"text":"after"}"#),
        ])
        defer { fixture.cleanUp() }
        let samples = tone(8) + silence(12) + tone(5)
        let segments = try await fixture.transcribe(samples)
        XCTAssertEqual(fixture.server.requestCount, 2)
        XCTAssertEqual(segments.map(\.text), ["before", " after"])
        XCTAssertGreaterThan(segments[1].start, 19, "the last piece keeps its place after the gap")
    }

    /// A piece with no speech comes back with no words. That is the piece's
    /// answer, not a failure of the recording.
    func test_a_wordless_piece_contributes_nothing() async throws {
        let fixture = PieceServerFixture(model: "gpt-4o-mini-transcribe", replies: [
            .ok(#"{"text":""}"#), .ok(#"{"text":"middle"}"#), .ok(#"{"text":"   "}"#),
        ])
        defer { fixture.cleanUp() }
        let segments = try await fixture.transcribe(threePieceAudio())
        XCTAssertEqual(segments.map(\.text), ["middle"])
        XCTAssertEqual(fixture.server.requestCount, 3)
    }

    func test_a_recording_with_no_words_anywhere_is_still_an_empty_result() async throws {
        let fixture = PieceServerFixture(model: "gpt-4o-mini-transcribe", replies: [
            .ok(#"{"text":""}"#), .ok(#"{"text":""}"#), .ok(#"{"text":""}"#),
        ])
        defer { fixture.cleanUp() }
        do {
            _ = try await fixture.transcribe(threePieceAudio())
            XCTFail("No words anywhere must still be reported")
        } catch RemoteWhisperEngine.RemoteError.emptyResult {
        }
    }

    func test_progress_climbs_once_across_the_whole_recording() async throws {
        let fixture = PieceServerFixture(model: "gpt-4o-mini-transcribe", replies: [
            .ok(#"{"text":"one"}"#), .ok(#"{"text":"two"}"#), .ok(#"{"text":"three"}"#),
        ])
        defer { fixture.cleanUp() }
        let reported = ProgressLog()
        _ = try await fixture.transcribe(threePieceAudio(), progress: { reported.append($0) })
        let values = reported.values
        XCTAssertFalse(values.isEmpty)
        XCTAssertEqual(values, values.sorted(), "progress never goes backwards between pieces")
        XCTAssertEqual(try XCTUnwrap(values.last), 1, accuracy: 0.0001)
    }

    // MARK: - Limits

    func test_request_limits_per_response_format() {
        typealias Format = RemoteWhisperEngine.ResponseFormat
        XCTAssertEqual(Format.forModel("gpt-4o-transcribe").maxRequestSeconds, 240)
        XCTAssertEqual(Format.forModel("gpt-4o-mini-transcribe").maxRequestSeconds, 240)
        XCTAssertEqual(Format.forModel("gpt-4o-transcribe-diarize").maxRequestSeconds, 240)
        XCTAssertEqual(Format.forModel("whisper-1").maxRequestSeconds, 600)
        XCTAssertEqual(Format.forModel("ivrit-ai/whisper-large-v3-turbo-ct2").maxRequestSeconds, 600)
        // The 1500 s the API refuses at, with room to spare.
        XCTAssertLessThan(Format.json.maxRequestSeconds, 1500)
    }

    /// Each piece's wait follows its own length — room for a server well
    /// below real time, but bounded, never more than the hour.
    func test_piece_request_timeout_scales_with_the_piece() {
        XCTAssertEqual(RemoteWhisperEngine.pieceRequestTimeout(audioSeconds: 10), 300)
        XCTAssertEqual(RemoteWhisperEngine.pieceRequestTimeout(audioSeconds: 240), 1200)
        XCTAssertEqual(RemoteWhisperEngine.pieceRequestTimeout(audioSeconds: 600), 3000)
        XCTAssertEqual(RemoteWhisperEngine.pieceRequestTimeout(audioSeconds: 10_000),
                       RemoteWhisperEngine.wholeRecordingTimeout)
        XCTAssertEqual(RemoteWhisperEngine.pieceRequestTimeout(audioSeconds: .nan),
                       RemoteWhisperEngine.wholeRecordingTimeout)
    }

    // MARK: - Stitching

    func test_an_untimed_answer_spans_its_piece() {
        let placed = RemoteWhisperEngine.placed([TranscriptSegment(start: 0, end: 0, text: "hello")],
                                                at: 240, length: 230, after: nil)
        XCTAssertEqual(placed.count, 1)
        XCTAssertEqual(placed[0].start, 240, accuracy: 0.001)
        XCTAssertEqual(placed[0].end, 470, accuracy: 0.001)
        XCTAssertEqual(placed[0].text, "hello", "the first line of a recording gets no leading space")
    }

    func test_pieces_are_separated_only_where_neither_side_has_whitespace() {
        let previous = TranscriptSegment(start: 0, end: 1, text: "end.")
        let joined = RemoteWhisperEngine.placed([TranscriptSegment(start: 0, end: 1, text: "Next"),
                                                 TranscriptSegment(start: 1, end: 2, text: "word")],
                                                at: 10, length: 5, after: previous)
        XCTAssertEqual(joined.map(\.text), [" Next", "word"], "only the seam is touched")
        let spaced = RemoteWhisperEngine.placed([TranscriptSegment(start: 0, end: 1, text: " Next")],
                                                at: 10, length: 5, after: previous)
        XCTAssertEqual(spaced.map(\.text), [" Next"])
    }

    func test_non_finite_server_times_cannot_poison_the_transcript() {
        let placed = RemoteWhisperEngine.placed(
            [TranscriptSegment(start: .nan, end: .infinity, text: " a"),
             TranscriptSegment(start: -3, end: 2, text: " b")],
            at: 100, length: 10, after: nil)
        XCTAssertTrue(placed.allSatisfy { $0.start.isFinite && $0.end.isFinite })
        XCTAssertTrue(placed.allSatisfy { $0.start >= 100 && $0.end <= 110 && $0.end >= $0.start })
    }

    static let inputTooLarge = #"{"error":{"message":"Total number of tokens in instructions + audio is too large for this model","type":"invalid_request_error","code":"input_too_large"}}"#
}

// MARK: - Through TranscriptionService

/// The same scripted server behind the real batch queue: what the user sees
/// on the row.
@MainActor
final class RemoteLongRecordingServiceTests: XCTestCase {

    private let label = "RemoteLongRecordingServiceTests"
    private var keychainKey: String { "\(label).apiKey" }
    private var tempRoot: URL!
    private var store: RecordingStore!
    private var manager: ModelManager!
    private var fixture: PieceServerFixture?

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: label)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = RecordingStore(rootDirectory: tempRoot)
        manager = TestSupport.isolatedModelManager(
            modelsDirectory: tempRoot.appendingPathComponent("Models"), label: label)
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
        fixture = nil
        store = nil
        manager = nil
        KeychainHelper.delete(key: keychainKey)
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        try await super.tearDown()
    }

    private func makeService(model: String, replies: [ScriptedReply]) -> TranscriptionService {
        let server = PieceServerFixture(model: model, replies: replies)
        fixture = server
        let suiteName = "\(label).remote"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        let remote = RemoteTranscriptionSettings(defaults: suite, apiKeyKeychainKey: keychainKey)
        remote.backend = .remote
        // Not an OpenAI host, so it is configured without a key and nothing
        // touches the Keychain or the network.
        remote.endpoint = server.config.endpoint.absoluteString
        remote.model = model
        let diarizationSuite = "\(label).diarization"
        UserDefaults(suiteName: diarizationSuite)!.removePersistentDomain(forName: diarizationSuite)
        return TranscriptionService(
            store: store,
            modelManager: manager,
            diarizationSettings: DiarizationSettings(defaults: .init(suiteName: diarizationSuite)!),
            remoteSettings: remote,
            engine: StubWhisperEngine(),
            remoteEngine: server.engine)
    }

    /// An imported Voice Memo: audio on disk, no transcript yet.
    private func addVoiceMemo(_ samples: [Float]) throws -> Recording {
        let url = store.freshAudioURL(suggestedName: "Long memo")
        try AudioConvert.writeWhisperWAV(samples: samples, to: url)
        let recording = Recording(title: "Long memo",
                                  duration: Double(samples.count) / WhisperAudioFormat.sampleRate,
                                  source: .voiceMemo,
                                  audioFileName: url.lastPathComponent,
                                  language: "he")
        store.add(recording)
        return recording
    }

    private func threePieceAudio() -> [Float] {
        func tone(_ s: Double) -> [Float] {
            (0..<Int(s * 16_000)).map { 0.3 * Float(sin(2 * Double.pi * 220 * Double($0) / 16_000)) }
        }
        return tone(8.0) + [Float](repeating: 0, count: 8_000) + tone(8.5)
            + [Float](repeating: 0, count: 8_000) + tone(7.5)
    }

    func test_a_long_recording_on_a_remote_model_completes_with_a_stitched_transcript() async throws {
        let service = makeService(model: "gpt-4o-mini-transcribe", replies: [
            .ok(#"{"text":"one"}"#), .ok(#"{"text":"two"}"#), .ok(#"{"text":"three"}"#),
        ])
        let recording = try addVoiceMemo(threePieceAudio())

        service.enqueue(recording)
        await service.waitForIdle()

        let row = try XCTUnwrap(store.recordings.first { $0.id == recording.id })
        XCTAssertEqual(row.status, .completed)
        XCTAssertEqual(row.fullText, "one two three")
        XCTAssertEqual(row.segments.count, 3)
        XCTAssertEqual(row.segments.map(\.start).first ?? -1, 0, accuracy: 0.001)
        XCTAssertTrue((8.0...8.5).contains(row.segments[1].start), "\(row.segments[1].start)")
        XCTAssertTrue((17.0...17.5).contains(row.segments[2].start), "\(row.segments[2].start)")
        XCTAssertEqual(row.duration, 25, accuracy: 0.01, "the last piece ends at the end of the audio")
        XCTAssertEqual(row.modelName, "Remote · gpt-4o-mini-transcribe")
        XCTAssertNil(row.transcriptionFailureReason)
        XCTAssertEqual(fixture?.server.requestCount, 3)
        XCTAssertNil(service.lastError)
    }

    /// The transcript ends at the last words; the recording does not. A
    /// last piece with nothing said in it must not shorten the recording —
    /// playback, seek and the list all read its length.
    func test_a_wordless_last_piece_keeps_the_recordings_full_length() async throws {
        let service = makeService(model: "gpt-4o-mini-transcribe", replies: [
            .ok(#"{"text":"one"}"#), .ok(#"{"text":"two"}"#), .ok(#"{"text":""}"#),
        ])
        let recording = try addVoiceMemo(threePieceAudio())

        service.enqueue(recording)
        await service.waitForIdle()

        let row = try XCTUnwrap(store.recordings.first { $0.id == recording.id })
        XCTAssertEqual(row.status, .completed)
        XCTAssertEqual(row.fullText, "one two")
        XCTAssertLessThan(try XCTUnwrap(row.segments.last?.end), 18)
        XCTAssertEqual(row.duration, 25, accuracy: 0.01)
    }

    /// The row the issue describes: `failed`, 0 segments, no reason. Now the
    /// server's refusal is on the row itself, not only in a one-time alert.
    func test_a_refusal_leaves_the_row_failed_with_the_servers_reason() async throws {
        let service = makeService(model: "gpt-4o-mini-transcribe", replies: [
            .init(status: 400, body: RemotePieceTranscriptionTests.inputTooLarge),
        ])
        let recording = try addVoiceMemo(threePieceAudio())

        service.enqueue(recording)
        await service.waitForIdle()

        let row = try XCTUnwrap(store.recordings.first { $0.id == recording.id })
        XCTAssertEqual(row.status, .failed)
        XCTAssertTrue(row.segments.isEmpty)
        let reason = try XCTUnwrap(row.visibleTranscriptionFailureReason)
        XCTAssertTrue(reason.contains("HTTP 400"), reason)
        XCTAssertTrue(reason.contains("too large for this model"), reason)
        XCTAssertEqual(fixture?.server.requestCount, 1, "nothing is sent after the refusal")
        XCTAssertNotNil(service.lastError)

        // It survives a relaunch: it is read back from recordings.json.
        let reloaded = RecordingStore(rootDirectory: tempRoot)
        let reloadedRow = try XCTUnwrap(reloaded.recordings.first { $0.id == recording.id })
        XCTAssertEqual(reloadedRow.transcriptionFailureReason, row.transcriptionFailureReason)
    }

    /// A retry that works must not keep saying it failed.
    func test_the_reason_is_cleared_when_the_next_pass_starts() async throws {
        let service = makeService(model: "gpt-4o-mini-transcribe", replies: [
            .init(status: 400, body: RemotePieceTranscriptionTests.inputTooLarge),
            .ok(#"{"text":"one"}"#), .ok(#"{"text":"two"}"#), .ok(#"{"text":"three"}"#),
        ])
        let recording = try addVoiceMemo(threePieceAudio())
        service.enqueue(recording)
        await service.waitForIdle()
        XCTAssertNotNil(store.recordings.first { $0.id == recording.id }?.transcriptionFailureReason)

        service.lastError = nil
        let retry = try XCTUnwrap(store.prepareForRetranscription(id: recording.id))
        XCTAssertNil(retry.transcriptionFailureReason, "cleared as soon as the retry is queued")
        service.enqueue(retry, isRetranscription: true)
        await service.waitForIdle()

        let row = try XCTUnwrap(store.recordings.first { $0.id == recording.id })
        XCTAssertEqual(row.status, .completed)
        XCTAssertNil(row.transcriptionFailureReason)
        XCTAssertNil(row.visibleTranscriptionFailureReason)
    }

    /// A live draft whose full pass had failed, re-run on audio too quiet to
    /// send: the re-run is undone back to the failed draft, and the draft
    /// must still say why it is not a finished transcript.
    func test_an_unusable_rerun_of_a_failed_draft_keeps_a_reason() async throws {
        let service = makeService(model: "gpt-4o-mini-transcribe", replies: [])
        let url = store.freshAudioURL(suggestedName: "Quiet draft")
        // Peak 0.001, under `TranscriptionService.minimumAudioPeak`.
        let quiet = (0..<32_000).map { 0.001 * Float(sin(2 * Double.pi * 220 * Double($0) / 16_000)) }
        try AudioConvert.writeWhisperWAV(samples: quiet, to: url)
        let draft = Recording(title: "Quiet draft", duration: 2, source: .microphone,
                              audioFileName: url.lastPathComponent, status: .failed,
                              language: "he",
                              segments: [TranscriptSegment(start: 0, end: 1, text: "live draft")],
                              fullText: "live draft",
                              transcriptionFailureReason: "Remote server returned HTTP 401.")
        store.add(draft)

        let retry = try XCTUnwrap(store.prepareForRetranscription(id: draft.id))
        service.enqueue(retry, isRetranscription: true)
        await service.waitForIdle()

        let row = try XCTUnwrap(store.recordings.first { $0.id == draft.id })
        XCTAssertEqual(row.status, .failed)
        XCTAssertEqual(row.fullText, "live draft", "the draft is kept")
        let reason = try XCTUnwrap(row.visibleTranscriptionFailureReason)
        XCTAssertTrue(reason.contains("too short or too quiet"), reason)
        XCTAssertEqual(fixture?.server.requestCount, 0, "nothing was sent")
    }
}

// MARK: - The reason on the row

final class TranscriptionFailureReasonTests: XCTestCase {

    private func row(status: TranscriptionStatus = .running) -> Recording {
        Recording(title: "Memo", source: .voiceMemo, audioFileName: "Memo.wav", status: status)
    }

    func test_a_failed_first_pass_keeps_its_reason() {
        var recording = row()
        recording.settleFailedPass(reason: "Remote server returned HTTP 400: too large.")
        XCTAssertEqual(recording.status, .failed)
        XCTAssertEqual(recording.visibleTranscriptionFailureReason, "Remote server returned HTTP 400: too large.")
    }

    /// A failed re-run is undone to the transcript it would have replaced;
    /// that row is not failed, so it has no failure to explain.
    func test_a_failed_rerun_that_restores_the_earlier_transcript_keeps_no_reason() {
        var recording = row()
        recording.segments = [TranscriptSegment(start: 0, end: 1, text: "kept")]
        recording.fullText = "kept"
        recording.retranscriptionPriorState = .init(status: .completed, language: "en", modelName: "Earlier")
        recording.settleFailedPass(reason: "refused")
        XCTAssertEqual(recording.status, .completed)
        XCTAssertNil(recording.transcriptionFailureReason)
    }

    /// A live draft whose full pass had failed, re-run and failed again: the
    /// row goes back to `.failed` with its draft, and must still say why.
    func test_a_failed_rerun_restored_to_failed_keeps_this_runs_reason() {
        var recording = row()
        recording.segments = [TranscriptSegment(start: 0, end: 1, text: "draft")]
        recording.fullText = "draft"
        recording.retranscriptionPriorState = .init(status: .failed, language: "he", modelName: nil)
        recording.settleFailedPass(reason: "Remote server returned HTTP 400.")
        XCTAssertEqual(recording.status, .failed)
        XCTAssertEqual(recording.fullText, "draft")
        XCTAssertEqual(recording.visibleTranscriptionFailureReason, "Remote server returned HTTP 400.")
    }

    func test_a_stopped_or_blank_reason_is_not_shown() {
        var recording = row(status: .failed)
        recording.transcriptionFailureReason = "   "
        XCTAssertNil(recording.visibleTranscriptionFailureReason)
        recording.transcriptionFailureReason = "refused"
        recording.transcriptionDeferredAt = Date()
        XCTAssertNil(recording.visibleTranscriptionFailureReason, "a stopped transcription says stopped")
        recording.transcriptionDeferredAt = nil
        recording.status = .completed
        XCTAssertNil(recording.visibleTranscriptionFailureReason)
    }

    func test_a_long_server_message_is_capped() {
        var recording = row()
        recording.settleFailedPass(reason: String(repeating: "x", count: 5_000))
        XCTAssertEqual(recording.transcriptionFailureReason?.count, Recording.maxFailureReasonLength)
    }

    func test_reason_round_trips_and_is_omitted_when_nil() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let plain = row(status: .completed)
        let plainJSON = try JSONSerialization.jsonObject(with: encoder.encode(plain)) as? [String: Any]
        XCTAssertNil(plainJSON?["transcriptionFailureReason"],
                     "a row that never failed encodes exactly as before")

        var failed = row(status: .failed)
        failed.transcriptionFailureReason = "refused"
        let decoded = try decoder.decode(Recording.self, from: encoder.encode(failed))
        XCTAssertEqual(decoded.transcriptionFailureReason, "refused")
    }

    /// recordings.json loads all-or-nothing, so a hand-edited value of the
    /// wrong type costs the reason, not the library.
    func test_a_malformed_reason_does_not_fail_the_row() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let json = """
        {"id":"\(UUID().uuidString)","title":"Memo","createdAt":"2026-10-19T07:31:12Z",
         "duration":10,"source":"voiceMemo","audioFileName":"Memo.wav","status":"failed",
         "language":"he","segments":[],"transcriptionFailureReason":42}
        """
        let decoded = try decoder.decode(Recording.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.status, .failed)
        XCTAssertNil(decoded.transcriptionFailureReason)
    }
}

// MARK: - Scripted server

struct ScriptedReply: Sendable {
    let status: Int
    let body: String
    static func ok(_ body: String) -> ScriptedReply { .init(status: 200, body: body) }
}

/// Answers requests in order from a script; anything past the script is a 500.
final class ScriptedTranscriptionServer: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [ScriptedReply]
    private var requests = 0
    private var hook: (@Sendable (Int) -> Void)?
    init(_ replies: [ScriptedReply]) { self.replies = replies }
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests }
    /// Runs with each request's number (from 1) before it is answered.
    var beforeReply: (@Sendable (Int) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return hook }
        set { lock.lock(); hook = newValue; lock.unlock() }
    }
    func nextReply() -> ScriptedReply {
        lock.lock()
        requests += 1
        let number = requests
        let hook = self.hook
        let reply: ScriptedReply = replies.isEmpty
            ? .init(status: 500, body: #"{"error":{"message":"script exhausted"}}"#)
            : replies.removeFirst()
        lock.unlock()
        hook?(number)
        return reply
    }
}

/// What the engine handed its encoder — one entry per piece actually sent.
final class EncodedPieces: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int] = []
    var pieceSampleCounts: [Int] { lock.lock(); defer { lock.unlock() }; return counts }
    func record(_ samples: [Float]) { lock.lock(); counts.append(samples.count); lock.unlock() }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [Float] = []
    var values: [Float] { lock.lock(); defer { lock.unlock() }; return log }
    func append(_ value: Float) { lock.lock(); log.append(value); lock.unlock() }
}

/// A `RemoteWhisperEngine` with a 10 s piece limit and two immediate
/// retries, talking to a scripted
/// server on its own `.invalid` host through a real `URLSession`.
struct PieceServerFixture {
    let config: RemoteTranscriptionConfig
    let server: ScriptedTranscriptionServer
    let encoded: EncodedPieces
    let engine: RemoteWhisperEngine
    private let session: URLSession
    private let host: String

    init(model: String, replies: [ScriptedReply], offlineDiarization: Bool = false) {
        let host = "pieces-\(UUID().uuidString.lowercased()).invalid"
        self.host = host
        config = RemoteTranscriptionConfig(endpoint: URL(string: "https://\(host)/v1")!,
                                           apiKey: "", model: model,
                                           offlineDiarization: offlineDiarization)
        let server = ScriptedTranscriptionServer(replies)
        self.server = server
        ScriptedTranscriptionURLProtocol.register(server, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedTranscriptionURLProtocol.self]
        let session = URLSession(configuration: configuration)
        self.session = session
        let encoded = EncodedPieces()
        self.encoded = encoded
        engine = RemoteWhisperEngine(session: session,
                                     encodeAudio: { samples in
                                         encoded.record(samples)
                                         return Data([1, 2, 3])
                                     },
                                     maxChunkSeconds: 10,
                                     // Retries without the production waits.
                                     pieceRetryDelays: [0, 0])
    }

    func transcribe(_ samples: [Float],
                    progress: (@Sendable (Float) -> Void)? = nil) async throws -> [TranscriptSegment] {
        await engine.configure(config)
        return try await engine.transcribe(samples: samples, language: "he", audioCtx: 0,
                                           progress: progress, isCancelled: nil)
    }

    func cleanUp() {
        session.invalidateAndCancel()
        ScriptedTranscriptionURLProtocol.remove(host: host)
    }
}

final class ScriptedTranscriptionURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var servers: [String: ScriptedTranscriptionServer] = [:]

    static func register(_ server: ScriptedTranscriptionServer, host: String) {
        lock.lock(); defer { lock.unlock() }; servers[host] = server
    }
    static func remove(host: String) {
        lock.lock(); defer { lock.unlock() }; servers[host] = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let server = Self.servers[request.url?.host ?? ""]
        Self.lock.unlock()
        guard let server, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let reply = server.nextReply()
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
