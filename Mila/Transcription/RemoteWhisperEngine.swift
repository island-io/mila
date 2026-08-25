import Foundation
import OSLog
import TranscriptionCore

private let remoteLog = Logger(subsystem: "io.island.whisper.IslandWhisper",
                               category: "RemoteWhisperEngine")

/// Injection seam for `TranscriptionService`: the remote engine refines
/// `TranscribingEngine` with the remote-specific `configure(_:)` step the
/// service calls before each run. Pulling it behind a protocol lets tests
/// substitute an engine that fails deterministically (e.g. a simulated HTTP
/// 401) without a real network round-trip — which is exactly the failure mode
/// that previously went uncaught (a misconfigured remote key silently emptied
/// the live transcript). `RemoteWhisperEngine` is the only production conformer.
protocol RemoteTranscribing: TranscribingEngine {
    func configure(_ config: RemoteTranscriptionConfig) async
}

/// A `TranscribingEngine` that offloads transcription to an OpenAI-compatible
/// `/v1/audio/transcriptions` endpoint instead of running whisper.cpp locally.
///
/// The protocol hands us 16 kHz mono `Float` samples (the same buffer the
/// local engine would consume), so the recording's audio never has to be
/// re-read from disk — we encode the samples to a compact AAC/`.m4a` blob and
/// upload that. The requested `response_format` is chosen from the model
/// (see `ResponseFormat.forModel(_:)`): `verbose_json` wherever it is
/// available, so we get per-segment timestamps that map straight onto
/// `TranscriptSegment` and keep diarization / SRT-export working exactly as
/// they do for the local path.
///
/// Config (endpoint, key, model) is injected via `configure(_:)` before each
/// transcription — the protocol's `transcribe` signature is fixed by the local
/// engine, so the remote-specific bits ride alongside on the actor's state.
actor RemoteWhisperEngine: RemoteTranscribing {
    enum RemoteError: LocalizedError {
        case notConfigured
        case noAudioCaptured
        case http(status: Int, body: String)
        case badResponse
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Remote transcription endpoint is not configured."
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
    }

    private var config: RemoteTranscriptionConfig?
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        // A long meeting can take a while to transcribe server-side; the
        // resource timeout has to clear the whole round trip, not just the
        // upload.
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 60 * 60
        self.session = URLSession(configuration: configuration)
    }

    func configure(_ config: RemoteTranscriptionConfig) {
        self.config = config
    }

    // MARK: - TranscribingEngine

    /// No local weights to load. The connectivity check lives in
    /// `RemoteTranscriptionSettings.testConnection()`; here we just confirm
    /// the engine was configured.
    func loadIfNeeded(modelURL: URL, displayName: String) async throws {
        guard config != nil else { throw RemoteError.notConfigured }
    }

    func shutdown() async {
        session.invalidateAndCancel()
    }

    func transcribe(samples: [Float],
                    language: String,
                    audioCtx: Int32?,
                    progress: (@Sendable (Float) -> Void)?,
                    isCancelled: (@Sendable () -> Bool)?) async throws -> [TranscriptSegment] {
        guard let config else { throw RemoteError.notConfigured }
        if isCancelled?() == true { throw CancellationError() }

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
        let audioData = try await Self.encodeM4A(samples: samples)
        progress?(0.2)

        let boundary = "MilaBoundary-\(UUID().uuidString)"
        var request = URLRequest(url: config.endpoint.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        // The session's 120s request timeout is an INACTIVITY timer, and an
        // OpenAI-compatible server sends zero bytes while it transcribes —
        // after the upload finishes, a long recording routinely stays silent
        // well past 120s of server-side processing, which failed the whole
        // transcription with "The request timed out". Override per-request so
        // only the 1-hour resource timeout bounds the wait; the short idle
        // timeout still applies to everything else on this session.
        request.timeoutInterval = 60 * 60
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

        // The protocol's `isCancelled` is a polled flag (the batch Cancel
        // button), not Swift task cancellation. Bridge it: run the upload in a
        // child task and a watchdog that cancels it the moment the flag flips.
        let netTask = Task { try await session.upload(for: request, from: body) }
        let watchdog = Task {
            while !Task.isCancelled {
                if isCancelled?() == true { netTask.cancel(); return }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { watchdog.cancel() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await netTask.value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if isCancelled?() == true { throw CancellationError() }
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
