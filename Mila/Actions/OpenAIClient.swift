import Foundation

/// Typed errors surfaced by `OpenAIClient.parse` (HTTP-status-driven) and
/// mapped from transport failures by `runOpenAICompatible`. Conforms to
/// `LocalizedError` so the Settings sheet can render `errorDescription`
/// directly. (Top-level so callers — including tests — reference it
/// unqualified, matching the plan's flat layout.)
enum OpenAIRequestError: LocalizedError, Equatable {
    case auth(String)
    case notFound(String)
    case server(status: Int, message: String)
    case emptyOutput
    /// The configured base URL couldn't be turned into a valid request URL
    /// (e.g. it contains a space or other character `URL(string:)` rejects).
    /// Raised by `OpenAIClient.makeRequest` instead of force-unwrapping — a
    /// malformed base URL is user input and must surface as a readable error,
    /// not crash the app (issue celarent7/mila#1).
    case invalidEndpoint(String)

    var errorDescription: String? {
        switch self {
        case .auth(let m):
            return "Authentication failed (401). \(m)"
        case .notFound(let m):
            return "Model or endpoint not found (404). \(m)"
        case .server(let status, let m):
            return "Server returned HTTP \(status). \(m)"
        case .emptyOutput:
            return "The model returned no content."
        case .invalidEndpoint(let baseURL):
            return "“\(baseURL)” is not a valid endpoint URL. Check the Base URL in Settings → AI (it must look like https://api.openai.com/v1)."
        }
    }
}

/// Host-locality classification for an OpenAI-compatible base URL, used by
/// the Settings UI to decide whether to show the "your transcript is sent to
/// a remote server" privacy disclaimer (AC-UI-03). `localhost`, the loopback
/// addresses, and Bonjour `.local` hosts count as local — everything else is
/// remote. Unparseable input is treated as remote (non-local) so the disclaimer
/// errs toward showing.
enum OpenAILocality {
    static func isLocal(baseURL: String) -> Bool {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let comps = URLComponents(string: trimmed),
              let rawHost = comps.host?.lowercased(),
              !rawHost.isEmpty
        else { return false }
        // URLComponents may return an IPv6 host bracketed ("[::1]"); strip them
        // so the loopback comparison matches.
        let host = rawHost
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
        if host == "localhost" || host == "127.0.0.1"
            || host == "0.0.0.0" || host == "::1" {
            return true
        }
        // Bonjour / mDNS local hosts, e.g. "myllama.local".
        if host.hasSuffix(".local") { return true }
        return false
    }
}

/// Performs the actual HTTP send for an OpenAI-compatible request.
///
/// Injected (rather than `URLSession`-inlined) so `LLMRunner.run`'s
/// `.openaiCompatible` branch is unit-testable without a network: production
/// wires `URLSessionTransport(URLSession.shared)`, tests wire a stub that
/// records the `URLRequest` and returns a canned response. `Sendable` so the
/// transport can cross the async boundary from the static, non-isolated
/// `LLMRunner`. Only `transport` is caller-transparent — `baseURL`/`apiKey`/
/// `jsonMode` are threaded explicitly at every call site (see the plan's
/// Phase 6.0).
protocol OpenAITransport: Sendable {
    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data)
}

/// Production `OpenAITransport`: a thin `URLSession` wrapper. `URLSession.data`
/// throws `URLError.cancelled` when the driving Task is cancelled and
/// `URLError.timedOut` when the request exceeds its timeout — both mapped by
/// `LLMRunner.runOpenAICompatible`.
struct URLSessionTransport: OpenAITransport {
    let session: URLSession
    init(_ session: URLSession) { self.session = session }

    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (http, data)
    }
}

/// Pure, testable OpenAI-compatible `/v1/chat/completions` client.
///
/// Split into three layers so the bulk of behaviour is covered without a
/// network: `makeRequest` builds a `URLRequest` (pure), `parse` decodes a
/// `(Data, HTTPURLResponse)` into content or a typed error (pure), and an
/// injectable `OpenAITransport` performs the actual send. `LLMRunner.run` /
/// `diagnose` compose the three layers; the transport defaults to a real
/// `URLSession` in production and to a test stub in tests.
///
/// Only `transport` is caller-transparent — `baseURL`/`apiKey`/`jsonMode` are
/// threaded explicitly at every `LLMRunner.run`/`diagnose` call site (see the
/// implementation plan's Phase 6.0).
enum OpenAIClient {

    // MARK: - Wire types

    struct OpenAIChatMessage: Codable {
        let role: String
        let content: String
    }

    struct OpenAIResponseFormat: Codable {
        let type: String
    }

    struct OpenAIChatRequest: Codable {
        let model: String
        let messages: [OpenAIChatMessage]
        let temperature: Double?
        let response_format: OpenAIResponseFormat?
        let max_tokens: Int?
        let stream: Bool
    }

    struct OpenAIChatResponse: Codable {
        struct Choice: Codable { let message: OpenAIChatMessage }
        let choices: [Choice]
    }

    struct OpenAIErrorResponse: Codable {
        struct ErrorBody: Codable {
            let message: String
            let type: String?
            let code: String?
        }
        let error: ErrorBody?
    }

    // MARK: - Request builder (pure)

    /// Build the `/chat/completions` `URLRequest` for a single composed
    /// `user` message. `baseURL` is trimmed of trailing slashes and joined
    /// with `chat/completions`; `Authorization` is set iff `apiKey` is
    /// non-empty; `response_format` is included iff `jsonMode`; `stream` is
    /// always `false`. `temperature` is included iff non-nil.
    ///
    /// Throws `OpenAIRequestError.invalidEndpoint` if the trimmed base URL
    /// can't be parsed into an *absolute* `http`/`https` URL with a host —
    /// e.g. it contains a space (`URL(string:)` returns nil), omits the scheme
    /// (`api.openai.com/v1` parses as a relative path with no host and would
    /// fail deep inside `URLSession` with an opaque "unsupported URL"), or uses
    /// a scheme `URLSession` can't POST to. `baseURL` is free-text user input —
    /// the builder must not assume it's well-formed (issue celarent7/mila#1).
    static func makeRequest(baseURL: String,
                            model: String,
                            prompt: String,
                            transcript: String,
                            summary: String,
                            apiKey: String,
                            jsonMode: Bool,
                            temperature: Double?) throws -> URLRequest {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmedBase)/chat/completions"),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else {
            throw OpenAIRequestError.invalidEndpoint(trimmedBase)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }

        let body = OpenAIChatRequest(
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            messages: [OpenAIChatMessage(
                role: "user",
                content: LLMRunner.composedPrompt(prompt, transcript: transcript, summary: summary)
            )],
            temperature: temperature,
            response_format: jsonMode ? OpenAIResponseFormat(type: "json_object") : nil,
            max_tokens: nil,
            stream: false
        )
        // `try`, not `try?`: silently dropping the body would POST an empty
        // request that the endpoint rejects with an unhelpful 400. The function
        // already throws, so let the encoding error surface.
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    // MARK: - Response / error parser (pure)

    /// Decode an OpenAI-compatible response body into the trimmed first-choice
    /// content, or a typed `OpenAIRequestError`. Pure: takes the data + HTTP
    /// status, performs no network. Transport-level failures (`URLError`) are
    /// not seen here — they are mapped in `runOpenAICompatible`.
    static func parse(data: Data, response: HTTPURLResponse) -> Result<String, Error> {
        let status = response.statusCode
        if (200..<300).contains(status) {
            if let parsed = try? JSONDecoder().decode(OpenAIChatResponse.self, from: data) {
                if let content = parsed.choices.first?.message.content
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !content.isEmpty {
                    return .success(content)
                }
                return .failure(OpenAIRequestError.emptyOutput)
            }
            // 2xx but unparseable body — treat as no usable content.
            return .failure(OpenAIRequestError.emptyOutput)
        }

        // 4xx / 5xx: pull a message out of an OpenAI-style error body, with a
        // status-only fallback when the body is missing or undecodable.
        var serverMessage = "HTTP \(status)"
        if let body = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data),
           let msg = body.error?.message, !msg.isEmpty {
            serverMessage = msg
        }

        switch status {
        case 401, 403:
            return .failure(OpenAIRequestError.auth(serverMessage))
        case 404:
            // A 404 with model-not-found wording is a distinct, common case.
            if serverMessage.lowercased().contains("model") {
                return .failure(OpenAIRequestError.notFound(serverMessage))
            }
            return .failure(OpenAIRequestError.server(status: status, message: serverMessage))
        default:
            return .failure(OpenAIRequestError.server(status: status, message: serverMessage))
        }
    }
}