import Foundation
import OSLog
import TranscriptionCore

private let remoteLog = Logger(subsystem: "io.island.whisper.IslandWhisper",
                               category: "RemoteWhisperEngine")

/// Injection seam for `TranscriptionService`: the two requests the service
/// makes of a remote server, each carrying the config it goes out with.
/// Pulling it behind a protocol lets tests substitute an engine that fails
/// deterministically (e.g. a simulated HTTP 401) without a real network
/// round-trip — which is exactly the failure mode that previously went
/// uncaught (a misconfigured remote key silently emptied the live
/// transcript). `RemoteWhisperEngine` is the only production conformer.
///
/// The config travels WITH each call, never as state set beforehand (#376).
/// One engine serves live clips and whole-recording passes at once, in
/// different languages and so with different model ids; a `configure` step
/// followed by a separate call let one caller's `configure` arrive between the
/// other's two steps, and send its audio to the wrong model — a Hebrew
/// utterance to an English import's model, or a long recording to a live
/// clip's, without the pass's `offlineDiarization`.
///
/// `samples` is `consuming`, as on `TranscribingEngine.transcribe` (#403):
/// the batch pass hands a whole recording over with `consume samples`, so
/// the caller keeps no second reference to it. `RemoteWhisperEngine` only
/// reads the samples, so it declares the parameter without `consuming`.
protocol RemoteTranscribing: Sendable {
    /// One short clip (a live utterance, a dictation, a missing span) with
    /// an explicit per-request idle timeout, sent as ONE request. A live
    /// clip must fail in seconds, or a connection that silently stops
    /// answering holds the live queue — and Stop's drain — for an hour
    /// (#355).
    func transcribe(samples: consuming [Float],
                    language: String,
                    config: RemoteTranscriptionConfig,
                    requestTimeout: TimeInterval,
                    isCancelled: (@Sendable () -> Bool)?) async throws -> [TranscriptSegment]

    /// A whole recording: split into several requests where it is long
    /// (#376), each with a timeout sized to its piece.
    func transcribe(samples: consuming [Float],
                    language: String,
                    config: RemoteTranscriptionConfig,
                    progress: (@Sendable (Float) -> Void)?,
                    isCancelled: (@Sendable () -> Bool)?) async throws -> [TranscriptSegment]

    func shutdown() async
}

extension RemoteTranscribing {
    /// Test doubles have no network, so the timeout means nothing to them.
    /// The config still reaches them: a double can check what it was handed.
    func transcribe(samples: consuming [Float],
                    language: String,
                    config: RemoteTranscriptionConfig,
                    requestTimeout: TimeInterval,
                    isCancelled: (@Sendable () -> Bool)?) async throws -> [TranscriptSegment] {
        try await transcribe(samples: consume samples, language: language, config: config,
                             progress: nil, isCancelled: isCancelled)
    }
}

/// Transcription on an OpenAI-compatible `/v1/audio/transcriptions` endpoint
/// instead of whisper.cpp locally.
///
/// The service hands us 16 kHz mono `Float` samples (the same buffer the
/// local engine would consume), so the recording's audio never has to be
/// re-read from disk — we encode the samples to a compact AAC/`.m4a` blob and
/// upload that. The requested `response_format` is chosen from the model
/// (see `ResponseFormat.forModel(_:)`): `verbose_json` wherever it is
/// available, so we get per-segment timestamps that map straight onto
/// `TranscriptSegment` and keep diarization / SRT-export working exactly as
/// they do for the local path.
///
/// The config (endpoint, key, model) comes with every call, and the engine
/// keeps none of its own: one engine serves live clips and whole-recording
/// passes at once (see `RemoteTranscribing`).
actor RemoteWhisperEngine: RemoteTranscribing {
    enum RemoteError: LocalizedError {
        case noAudioCaptured
        case http(status: Int, body: String)
        case badResponse
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .noAudioCaptured:
                return "No audio was captured, so there was nothing to transcribe. Check that the input in Settings ▸ Audio Input is connected and not muted."
            case .http(let status, let body):
                let detail = Self.shortMessage(from: body)
                return "Remote server returned HTTP \(status)\(detail.map { ": \($0)" } ?? "")."
            case .badResponse:
                return "Remote server returned a response Mila couldn't parse."
            case .emptyResult:
                return "Remote server returned no transcript."
            }
        }

        /// The log-safe twin of `errorDescription`, matching
        /// `LLMRunnerError.logDescription`,
        /// `SpeakerDiarizer.Error.logDescription` and
        /// `OpenAIRequestError.logDescription`.
        ///
        /// Only `.http` differs, and it is the only case that carries bytes
        /// Mila did not write. `shortMessage(from:)` prefers the endpoint's
        /// `error.message` but falls back to `String(body.prefix(200))` — an
        /// unbounded 200-character slice of whatever a configured ASR endpoint
        /// returned. A real OpenAI 401 reads "Incorrect API key provided:
        /// sk-…XYZ", so that slice can be a fragment of the user's
        /// credential, and a proxy answering 502 with the upstream payload can
        /// put transcript text there.
        ///
        /// Volume is what makes it matter: `TranscriptionService`'s live path
        /// logs this once per *utterance* for the whole recording (its own
        /// comment says a remote failure "repeats on every utterance"), so one
        /// misconfigured endpoint writes hundreds of copies into a plaintext
        /// system log.
        ///
        /// The status code stays — 401 vs 404 vs 500 is the entire first
        /// question and names nothing — and the byte count says whether the
        /// server explained itself at all. `errorDescription` is untouched:
        /// `lastError` puts it in the app's own error banner, which is the
        /// user reading their own failure on their own screen.
        /// (Issue #213, CWE-532.)
        var logDescription: String {
            switch self {
            case .http(let status, let body):
                return """
                    Remote server returned HTTP \(status) \
                    (\(body.utf8.count)B of server response withheld — it can \
                    quote your API key)
                    """
            case .noAudioCaptured, .badResponse, .emptyResult:
                return errorDescription ?? "\(self)"
            }
        }

        /// The log-safe message for any error a remote transcription can
        /// throw — applied where the concrete type is still unknown, since
        /// `TranscriptionService` catches `Error` and a `CancellationError` or
        /// a `URLError` lands there too.
        static func logMessage(for error: Swift.Error) -> String {
            if let remoteError = error as? RemoteError { return remoteError.logDescription }
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        /// Pull a human-readable `error.message` out of an OpenAI-style error
        /// body, falling back to a trimmed prefix of the raw body.
        private static func shortMessage(from body: String) -> String? {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let data = trimmed.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = obj["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message
            }
            return String(trimmed.prefix(200))
        }
    }

    /// The `response_format` to ask a remote model for.
    ///
    /// **Not every model can produce every format**, and asking for the wrong
    /// one is a hard 400, not a degraded transcript. `verbose_json` — the only
    /// format that carries per-segment timestamps — is effectively a
    /// `whisper-1` exclusive: the original Whisper decoder emits timestamp
    /// tokens natively, which is also where `srt`/`vtt` fall out of. The
    /// `gpt-*transcribe` family are audio-native models with no alignment
    /// stage, so they reject *every* timestamped format (`verbose_json`, `srt`,
    /// `vtt`) and accept only `json`/`text`:
    ///
    ///     response_format 'verbose_json' is not compatible with model
    ///     'gpt-transcribe-api-ev3'. Use 'json' or 'text' instead.
    ///
    /// `gpt-4o-transcribe-diarize` is the exception — it emits structure
    /// organised by *speaker turn* rather than decode window, under its own
    /// `diarized_json` name. (Behaviour verified against the live OpenAI API;
    /// issue #180.)
    ///
    /// Hardcoding `verbose_json` is what previously locked remote
    /// transcription to `whisper-1`.
    enum ResponseFormat: String {
        /// Timestamped segments. `whisper-1` and self-hosted Whisper servers.
        case verboseJSON = "verbose_json"
        /// Text only, no timing. The `gpt-*transcribe` models.
        case json = "json"
        /// Speaker-turn segments with timing. `gpt-4o-transcribe-diarize`.
        case diarizedJSON = "diarized_json"

        /// The format `model` can actually produce.
        ///
        /// Matched on the id's last path component, lowercased, so a
        /// vendor-prefixed mirror (`openai/gpt-4o-transcribe`) resolves the
        /// same way as the bare id — the same tolerant substring style as
        /// `RemoteTranscriptionSettings.isHebrewOnlyModel(_:)`. Anything that
        /// isn't a `gpt-` model keeps requesting `verbose_json` exactly as
        /// before, so self-hosted Whisper deployments are unaffected.
        static func forModel(_ model: String) -> ResponseFormat {
            let id = (model.split(separator: "/").last.map(String.init) ?? model)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard id.hasPrefix("gpt-") else { return .verboseJSON }
            return id.contains("diarize") ? .diarizedJSON : .json
        }

        /// What timing information a response in this format carries.
        ///
        /// A property of the *format*, so the UI can describe the tradeoff of
        /// a model without re-deriving it from the model id — the mapping from
        /// id to format lives in `forModel(_:)` and nowhere else.
        enum TimestampSupport {
            /// Per-decode-window segments (`verbose_json`). SRT export and the
            /// local pyannote pass both have something to align to.
            case perSegment
            /// Per-speaker-turn segments (`diarized_json`), already labelled.
            case perSpeakerTurn
            /// None: the whole recording arrives as one untimed segment.
            case none
        }

        var timestamps: TimestampSupport {
            switch self {
            case .verboseJSON:  return .perSegment
            case .diarizedJSON: return .perSpeakerTurn
            case .json:         return .none
            }
        }

        /// Whether the request must also carry a `chunking_strategy`.
        ///
        /// The diarization models require one explicitly for audio longer than
        /// 30s — without it the API answers "chunking_strategy is required".
        /// No other format takes the parameter.
        var needsChunkingStrategy: Bool { self == .diarizedJSON }

        /// The most audio one whole-recording request carries; longer audio
        /// is split into several requests (`AudioChunkPlanner`, #376).
        ///
        ///  * `gpt-*transcribe` (`json`, `diarized_json`): **4 minutes.** The
        ///    API refuses roughly 25 minutes or more outright
        ///    (`input_too_large` — every Voice Memo of 49 minutes or more
        ///    failed this way), and the models stop writing at 2,000 output
        ///    tokens, which is about eight minutes of English speech and less
        ///    of Hebrew — past that the transcript comes back cut short with
        ///    no error. Four minutes keeps a fast speaker well under the
        ///    output cap.
        ///  * Whisper (`verbose_json`: `whisper-1`, self-hosted servers):
        ///    **10 minutes.** Whisper decodes in 30-second windows, so it has
        ///    no output cap to stay under; the bound keeps each request's wait
        ///    short and its file small.
        ///
        /// File size follows from duration: uploads are 32 kbps AAC
        /// (`AudioCompressor`), so 10 minutes is about 2.4 MB, a tenth of
        /// OpenAI's 25 MB request limit.
        var maxRequestSeconds: TimeInterval {
            switch self {
            case .verboseJSON:           return 10 * 60
            case .json, .diarizedJSON:   return 4 * 60
            }
        }
    }

    private let session: URLSession
    private let encodeAudio: @Sendable ([Float]) async throws -> Data
    /// Replaces `ResponseFormat.maxRequestSeconds`, so tests can exercise
    /// the split with seconds of audio instead of minutes. Nil in production.
    private let maxChunkSecondsOverride: TimeInterval?
    /// How long to wait before each retry of a piece that failed
    /// transiently — one entry per retry. See `transcribeInPieces`.
    private let pieceRetryDelays: [TimeInterval]
    private var isShutDown = false

    init(session: URLSession? = nil,
         encodeAudio: @escaping @Sendable ([Float]) async throws -> Data = {
             try await RemoteWhisperEngine.encodeM4A(samples: $0)
         },
         maxChunkSeconds: TimeInterval? = nil,
         pieceRetryDelays: [TimeInterval] = RemoteWhisperEngine.defaultPieceRetryDelays) {
        let configuration = URLSessionConfiguration.default
        // A long meeting can take a while to transcribe server-side; the
        // resource timeout has to clear the whole round trip, not just the
        // upload.
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 60 * 60
        self.session = session ?? URLSession(configuration: configuration)
        self.encodeAudio = encodeAudio
        self.maxChunkSecondsOverride = maxChunkSeconds
        self.pieceRetryDelays = pieceRetryDelays
    }

    // MARK: - RemoteTranscribing

    func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        session.invalidateAndCancel()
    }

    /// The whole-recording path (imported files, Voice Memos, the batch pass
    /// after a recording): split into pieces the server accepts, sent one
    /// after another, stitched back onto the recording's clock. See
    /// `transcribeInPieces`.
    func transcribe(samples: [Float],
                    language: String,
                    config: RemoteTranscriptionConfig,
                    progress: (@Sendable (Float) -> Void)?,
                    isCancelled: (@Sendable () -> Bool)?) async throws -> [TranscriptSegment] {
        try await transcribeInPieces(samples: samples, language: language, config: config,
                                     progress: progress, isCancelled: isCancelled)
    }

    func transcribe(samples: [Float],
                    language: String,
                    config: RemoteTranscriptionConfig,
                    requestTimeout: TimeInterval,
                    isCancelled: (@Sendable () -> Bool)?) async throws -> [TranscriptSegment] {
        try checkCancellation(isCancelled)
        return try await upload(samples: samples, language: language, config: config, progress: nil,
                                isCancelled: isCancelled, requestTimeout: requestTimeout)
    }

    /// The longest any one request may sit waiting for an answer. See the
    /// per-request override in `upload`.
    static let wholeRecordingTimeout: TimeInterval = 60 * 60

    /// Idle timeout for one piece of a whole-recording transcription: five
    /// times the piece's length, at least five minutes, at most the hour. The
    /// server sends nothing while it transcribes, so this has to outlast its
    /// think time — a self-hosted CPU server can run well below real time —
    /// but no more: a piece is at most ten minutes, so a server that stopped
    /// answering fails the recording within the hour instead of holding it
    /// for as long as the whole file was allowed (#376).
    static func pieceRequestTimeout(audioSeconds: Double) -> TimeInterval {
        guard audioSeconds.isFinite else { return wholeRecordingTimeout }
        return min(wholeRecordingTimeout, max(300, audioSeconds * 5))
    }

    /// The waits before the first and the second retry of a piece that
    /// failed transiently. A 74-minute memo is about twenty requests; one
    /// proxy 502 among them must not throw away the rest and make the user
    /// pay for all of them again.
    static let defaultPieceRetryDelays: [TimeInterval] = [5, 20]

    /// Whether a piece that failed with `error` is worth sending again: the
    /// live path's notion of transient (`isTransientRemoteFailure` — a
    /// dropped connection, 408/429/502/503/504) minus a timeout. A piece that
    /// already waited `pieceRequestTimeout` for an answer would only wait as
    /// long again.
    static func pieceFailureIsRetryable(_ error: Error) -> Bool {
        if let urlError = error as? URLError, urlError.code == .timedOut { return false }
        return TranscriptionService.isTransientRemoteFailure(error)
    }

    /// Transcribe a whole recording as a series of requests, each no longer
    /// than `ResponseFormat.maxRequestSeconds` (#376).
    ///
    /// One request for the whole file was the bug: past the server's limits
    /// it was refused (`input_too_large`), or came back silently truncated.
    /// The pieces are cut at pauses (`AudioChunkPlanner`) and sent in order;
    /// each answer is moved onto the recording's clock (`placed`).
    ///
    /// * Every piece goes to the server, key and model in `config`: a
    ///   recording must not be stitched from two servers' answers.
    /// * A piece that fails transiently is retried (`pieceRetryDelays`,
    ///   `pieceFailureIsRetryable`). Any other failure — and a transient one
    ///   that outlasts the retries — ends the run, and its error is what the
    ///   caller reports. Later pieces would most likely fail the same way,
    ///   and a half-transcribed recording must not pass as finished.
    /// * A piece of pure digital silence is not sent (`upload` would refuse
    ///   it as "no audio captured"), and a piece the server answers with no
    ///   words contributes nothing. Only a recording with no words ANYWHERE
    ///   is `emptyResult`, as it was for one request.
    /// * Server-side speaker labels (`gpt-4o-transcribe-diarize`) name one
    ///   request's voices: "A" in one piece is not "A" in the next. So each
    ///   piece's speakers get numbers of their own (`speakersRenumbered`) —
    ///   one voice may then carry several labels, but two voices never share
    ///   one, and a name given to a label is learned into a voice profile.
    ///   When the offline pyannote pass will run
    ///   (`RemoteTranscriptionConfig.offlineDiarization`), labels from
    ///   several pieces are dropped instead, so that pass labels the whole
    ///   recording consistently (server labels would otherwise win over it).
    private func transcribeInPieces(samples: [Float],
                                    language: String,
                                    config: RemoteTranscriptionConfig,
                                    progress: (@Sendable (Float) -> Void)?,
                                    isCancelled: (@Sendable () -> Bool)?) async throws -> [TranscriptSegment] {
        try checkCancellation(isCancelled)
        // The guard `upload` applies per request (issue #147), applied to the
        // whole recording first: a silent piece inside a real recording is
        // skipped below, but a recording that is ALL silence is a capture
        // failure and has to say so.
        guard !AudioSignal.isSilent(samples) else {
            remoteLog.error("transcribe: REFUSING to upload \(samples.count, privacy: .public) samples with no signal — nothing was captured")
            throw RemoteError.noAudioCaptured
        }

        let limit = maxChunkSecondsOverride ?? ResponseFormat.forModel(config.model).maxRequestSeconds
        let sampleRate = WhisperAudioFormat.sampleRate
        let pieces = AudioChunkPlanner.plan(samples: samples, sampleRate: sampleRate,
                                            maxChunkSeconds: limit)
        remoteLog.log("transcribe: \(samples.count, privacy: .public) samples → \(pieces.count, privacy: .public) request(s) of ≤ \(Int(limit), privacy: .public)s")

        let total = Double(samples.count)
        var stitched: [TranscriptSegment] = []
        var piecesWithText = 0
        var speakersUsed = 0
        for (index, range) in pieces.enumerated() {
            try checkCancellation(isCancelled)
            let piece = Array(samples[range])
            let offset = Double(range.lowerBound) / sampleRate
            let length = Double(range.count) / sampleRate
            if AudioSignal.isSilent(piece) {
                remoteLog.log("transcribe: piece \(index + 1, privacy: .public)/\(pieces.count, privacy: .public) is digital silence — not sent")
                continue
            }
            // This piece's share of the bar, so progress climbs once across
            // the whole recording instead of restarting with every request.
            let base = Double(range.lowerBound) / total
            let share = Double(range.count) / total
            let pieceProgress: (@Sendable (Float) -> Void)? = progress.map { report in
                { @Sendable fraction in report(Float(base + Double(fraction) * share)) }
            }
            var segments: [TranscriptSegment] = []
            var retries = 0
            while true {
                do {
                    segments = try await upload(samples: piece, language: language, config: config,
                                                progress: pieceProgress, isCancelled: isCancelled,
                                                requestTimeout: Self.pieceRequestTimeout(audioSeconds: length))
                    break
                } catch RemoteError.emptyResult where pieces.count > 1 {
                    // A stretch with no speech in it — music, a break. That
                    // is this piece's answer, not the recording's.
                    segments = []
                    break
                } catch let error where retries < pieceRetryDelays.count
                            && Self.pieceFailureIsRetryable(error) {
                    let delay = pieceRetryDelays[retries]
                    retries += 1
                    remoteLog.log("""
                        transcribe: piece \(index + 1, privacy: .public)/\(pieces.count, privacy: .public) \
                        failed transiently (\(RemoteError.logMessage(for: error), privacy: .public)) — \
                        retry \(retries, privacy: .public) in \(Int(delay), privacy: .public)s
                        """)
                    try await pauseBeforeRetry(seconds: delay, isCancelled: isCancelled)
                } catch {
                    if !(error is CancellationError) {
                        remoteLog.error("""
                            transcribe: piece \(index + 1, privacy: .public)/\(pieces.count, privacy: .public) \
                            at \(Int(offset), privacy: .public)s FAILED — \
                            \(RemoteError.logMessage(for: error), privacy: .public)
                            """)
                    }
                    throw error
                }
            }
            let placed = Self.placed(segments, at: offset, length: length, after: stitched.last)
            if !placed.isEmpty { piecesWithText += 1 }
            stitched.append(contentsOf: Self.speakersRenumbered(placed, after: &speakersUsed))
        }

        guard !stitched.isEmpty else { throw RemoteError.emptyResult }
        if piecesWithText > 1, stitched.contains(where: { $0.speaker != nil }) {
            if config.offlineDiarization {
                remoteLog.log("transcribe: dropping the per-request speaker labels of \(piecesWithText, privacy: .public) pieces — the offline pass labels the whole recording")
                for i in stitched.indices { stitched[i].speaker = nil }
            } else {
                remoteLog.log("transcribe: keeping \(speakersUsed, privacy: .public) per-request speaker labels from \(piecesWithText, privacy: .public) pieces — numbered apart, since requests don't share voices")
            }
        }
        progress?(1.0)
        remoteLog.log("transcribe: ok segs=\(stitched.count, privacy: .public) pieces=\(pieces.count, privacy: .public)")
        return stitched
    }

    /// Wait `seconds` before a retry, looking every 200 ms at the batch
    /// Cancel flag and at shutdown, so a stop is not held up by the wait.
    private func pauseBeforeRetry(seconds: TimeInterval,
                                  isCancelled: (@Sendable () -> Bool)?) async throws {
        var remaining = seconds
        while remaining > 0 {
            try checkCancellation(isCancelled)
            let step = min(remaining, 0.2)
            try await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
            remaining -= step
        }
        try checkCancellation(isCancelled)
    }

    /// One piece's speaker labels, renumbered to follow the `used` labels
    /// earlier pieces took, in order of first appearance (`used` is advanced
    /// past them). A label from one request never collides with another
    /// request's: each request diarizes on its own. The first piece with
    /// labels keeps `SPEAKER_00`, `SPEAKER_01`, … — a recording sent as one
    /// request is labelled exactly as before.
    static func speakersRenumbered(_ segments: [TranscriptSegment],
                                   after used: inout Int) -> [TranscriptSegment] {
        var mapping: [String: String] = [:]
        var output = segments
        for i in output.indices {
            guard let label = output[i].speaker, !label.isEmpty else { continue }
            if let renumbered = mapping[label] {
                output[i].speaker = renumbered
            } else {
                let renumbered = String(format: "SPEAKER_%02d", used)
                used += 1
                mapping[label] = renumbered
                output[i].speaker = renumbered
            }
        }
        return output
    }

    /// `segments` — one piece's answer, timed from the start of the piece —
    /// moved onto the recording's clock.
    ///
    /// Times are clamped into the piece, so a server that reports a little
    /// past the end of its audio can't overlap the next piece. A response
    /// with no timing at all (`json`: a single segment with no end) spans its
    /// whole piece rather than collapsing to a point at the piece's start.
    /// The first line of a piece gets a leading space when neither it nor
    /// the previous piece's last line has whitespace at the seam, because
    /// the transcript text is the segments joined with no separator.
    static func placed(_ segments: [TranscriptSegment], at offset: Double, length: Double,
                       after previous: TranscriptSegment?) -> [TranscriptSegment] {
        let length = length.isFinite ? max(0, length) : 0
        func clamped(_ t: Double) -> Double { t.isFinite ? min(max(0, t), length) : 0 }
        let untimed = segments.count == 1 && !(segments[0].end > segments[0].start)
        var placed: [TranscriptSegment] = []
        placed.reserveCapacity(segments.count)
        for segment in segments {
            var start = clamped(segment.start)
            var end = max(start, clamped(segment.end))
            if untimed { start = 0; end = length }
            var text = segment.text
            if placed.isEmpty, let previous,
               let last = previous.text.last, !last.isWhitespace,
               let first = text.first, !first.isWhitespace {
                text = " " + text
            }
            placed.append(TranscriptSegment(start: offset + start, end: offset + end,
                                            text: text, speaker: segment.speaker))
        }
        return placed
    }

    /// One request, to the server `config` names.
    private func upload(samples: [Float],
                        language: String,
                        config: RemoteTranscriptionConfig,
                        progress: (@Sendable (Float) -> Void)?,
                        isCancelled: (@Sendable () -> Bool)?,
                        requestTimeout: TimeInterval) async throws -> [TranscriptSegment] {
        try checkCancellation(isCancelled)

        // Never POST audio with nothing in it. A capture session that
        // delivered zero frames encodes to a header-only file, and the server
        // answers — correctly — `HTTP 500: {"detail":"Failed to decode
        // audio."}`, which reads to the user as a server outage and is
        // completely unactionable. The failure belongs to the microphone, so
        // say so here rather than letting the network report it. (issue #147)
        guard !AudioSignal.isSilent(samples) else {
            remoteLog.error("transcribe: REFUSING to upload \(samples.count, privacy: .public) samples with no signal — nothing was captured")
            throw RemoteError.noAudioCaptured
        }

        progress?(0.05)
        let audioData = try await encodeAudio(samples)
        try checkCancellation(isCancelled)
        progress?(0.2)

        let boundary = "MilaBoundary-\(UUID().uuidString)"
        var request = URLRequest(url: config.endpoint.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        // The session's 120s request timeout is an INACTIVITY timer, and an
        // OpenAI-compatible server sends zero bytes while it transcribes —
        // after the upload finishes, a long recording routinely stays silent
        // well past 120s of server-side processing, which failed the whole
        // transcription with "The request timed out". Override per-request
        // with a bound sized to the audio: a piece of a whole recording gets
        // `pieceRequestTimeout` (minutes, #376), and a short clip
        // (`transcribe(…requestTimeout:)`) a much shorter one — a live
        // utterance is answered in seconds or not at all. The short idle
        // timeout still applies to everything else on this session.
        request.timeoutInterval = requestTimeout
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body = Self.multipartBody(boundary: boundary,
                                      audio: audioData,
                                      model: config.model,
                                      language: language)

        // Endpoint kept .private — a user-configured URL can carry private
        // hostnames or credentials/query tokens we must not leak to the log.
        remoteLog.log("transcribe: POST \(request.url?.absoluteString ?? "?", privacy: .private) model=\(config.model, privacy: .public) format=\(Self.ResponseFormat.forModel(config.model).rawValue, privacy: .public) lang=\(language, privacy: .public) bytes=\(body.count, privacy: .public)")

        // Task creation and session invalidation must share this actor turn.
        // A check before Task { session.upload(...) } still lets shutdown
        // invalidate the session before that task creates its upload (#301).
        let (responses, continuation) = AsyncThrowingStream<(Data, URLResponse), Error>.makeStream()
        let upload = session.uploadTask(with: request, from: body) { data, response, error in
            if let error {
                continuation.finish(throwing: error)
            } else if let data, let response {
                continuation.yield((data, response))
                continuation.finish()
            } else {
                continuation.finish(throwing: RemoteError.badResponse)
            }
        }
        upload.resume()

        // Preserve the batch Cancel button's polled flag, as well as Swift
        // cancellation. The handler also covers cancellation before registration.
        let watchdog = Task {
            while !Task.isCancelled {
                if isCancelled?() == true { upload.cancel(); return }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { watchdog.cancel() }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await withTaskCancellationHandler {
                var iterator = responses.makeAsyncIterator()
                guard let result = try await iterator.next() else { throw CancellationError() }
                return result
            } onCancel: {
                upload.cancel()
            }
            try checkCancellation(isCancelled)
        } catch {
            // Foundation reports URLError.cancelled for invalidated uploads;
            // normalize shutdown and ignore a completion that raced it.
            try checkCancellation(isCancelled)
            throw error
        }

        guard let http = response as? HTTPURLResponse else { throw RemoteError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw RemoteError.http(status: http.statusCode,
                                   body: String(data: data, encoding: .utf8) ?? "")
        }

        progress?(0.95)
        let segments = try Self.parseSegments(data: data)
        progress?(1.0)
        remoteLog.log("transcribe: ok segs=\(segments.count, privacy: .public)")
        return segments
    }

    private func checkCancellation(_ isCancelled: (@Sendable () -> Bool)?) throws {
        if isShutDown || Task.isCancelled || isCancelled?() == true {
            throw CancellationError()
        }
    }

    // MARK: - Encoding

    /// Encode 16 kHz mono float samples to an in-memory AAC/`.m4a` blob via the
    /// app's existing WAV → m4a path (~14 MB/hour vs ~230 MB/hour for raw WAV),
    /// keeping uploads well under typical API size limits. Temp files are
    /// cleaned up before returning.
    static func encodeM4A(samples: [Float]) async throws -> Data {
        let tmp = FileManager.default.temporaryDirectory
        let token = UUID().uuidString
        let wavURL = tmp.appendingPathComponent("mila-remote-\(token).wav")
        let m4aURL = tmp.appendingPathComponent("mila-remote-\(token).m4a")
        defer {
            try? FileManager.default.removeItem(at: wavURL)
            try? FileManager.default.removeItem(at: m4aURL)
        }
        try AudioConvert.writeWhisperWAV(samples: samples, to: wavURL)
        try await AudioCompressor.compress(wavURL: wavURL, toM4A: m4aURL)
        return try Data(contentsOf: m4aURL)
    }

    /// Build a `multipart/form-data` body for the transcription request.
    /// Fields: `file` (the m4a), `model`, `response_format` (chosen from the
    /// model — see `ResponseFormat.forModel(_:)`), `chunking_strategy` where
    /// the format requires it, and `language` (omitted when "auto" so the
    /// server detects it).
    static func multipartBody(boundary: String,
                              audio: Data,
                              model: String,
                              language: String) -> Data {
        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }

        appendField("model", model)
        let format = ResponseFormat.forModel(model)
        appendField("response_format", format.rawValue)
        if format.needsChunkingStrategy {
            appendField("chunking_strategy", "auto")
        }
        let lang = language.lowercased()
        if !lang.isEmpty && lang != "auto" {
            // OpenAI expects ISO-639-1; Mila already uses "he"/"en".
            appendField("language", lang)
        }

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n")
        body.append("Content-Type: audio/mp4\r\n\r\n")
        body.append(audio)
        body.append("\r\n")
        body.append("--\(boundary)--\r\n")
        return body
    }

    // MARK: - Parsing

    /// The shape shared by every transcription response Mila asks for.
    ///
    /// `verbose_json` and `diarized_json` differ only in the extra keys they
    /// add (decoder internals like `seek`/`avg_logprob` for the former, a
    /// `speaker` per turn for the latter), and `json` simply omits `segments`.
    /// `Decodable` ignores unknown keys, so one struct decodes all three.
    private struct VerboseResponse: Decodable {
        struct Segment: Decodable {
            let start: Double
            let end: Double
            let text: String
            /// Present only in `diarized_json` — the server's own turn label
            /// ("A", "B", …) from `gpt-4o-transcribe-diarize`.
            let speaker: String?
        }
        let text: String?
        let duration: Double?
        let segments: [Segment]?
    }

    /// Parse a `verbose_json` / `diarized_json` (preferred) or plain `json`
    /// transcription response into `TranscriptSegment`s. Static + pure so it
    /// can be unit tested without a server.
    static func parseSegments(data: Data) throws -> [TranscriptSegment] {
        let decoder = JSONDecoder()
        guard let parsed = try? decoder.decode(VerboseResponse.self, from: data) else {
            throw RemoteError.badResponse
        }

        if let segments = parsed.segments, !segments.isEmpty {
            let mapped = segments.compactMap { seg -> TranscriptSegment? in
                let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return TranscriptSegment(start: seg.start, end: seg.end,
                                         text: seg.text, speaker: seg.speaker)
            }
            if !mapped.isEmpty {
                // A `diarized_json` body labels turns "A", "B", … — a
                // different label space from the one the rest of the app
                // speaks (`SPEAKER_00`, which is what `friendlySpeakerLabel`
                // renders as "Speaker A" / "דובר א׳", what `speakerNames` is
                // keyed by, and what the exporters emit). Re-key at the
                // boundary where the foreign labels enter, so server-side
                // diarization is indistinguishable downstream from the local
                // pyannote pass. No-op for an unlabelled response.
                return SpeakerLabels.normalized(in: mapped)
            }
        }

        // No segment array (server returned `response_format=json`, or an empty
        // segment list with a top-level transcript). Fall back to one segment
        // spanning the whole clip.
        if let text = parsed.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return [TranscriptSegment(start: 0, end: parsed.duration ?? 0, text: text)]
        }

        throw RemoteError.emptyResult
    }
}

private extension Data {
    /// Append UTF-8 bytes of a string. Used to assemble multipart bodies.
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}
