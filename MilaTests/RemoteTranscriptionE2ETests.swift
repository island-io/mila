import XCTest
import TranscriptionCore
@testable import Mila

/// End-to-end test of the remote transcription client against a live HTTP
/// server. The server is the stdlib mock in
/// `scripts/mock-openai-transcription-server.py`, spawned by the
/// `e2e-remote-transcription` CI workflow, which passes its base URL in
/// `MILA_REMOTE_TEST_ENDPOINT`.
///
/// When that env var is absent (every normal `MilaTests` run, local or in the
/// regular CI jobs) the whole suite XCTSkips — so it only does real work in the
/// dedicated workflow, while still being a first-class test there.
///
/// What it proves, over a real socket:
///   * `RemoteWhisperEngine` encodes samples to m4a and uploads a well-formed
///     multipart request with the right `model` / `language` fields + Bearer
///     auth (the mock rejects the request otherwise),
///   * it parses `verbose_json` segments + timestamps back correctly,
///   * `RemoteTranscriptionSettings.testConnection()` reaches `/models`.
final class RemoteTranscriptionE2ETests: XCTestCase {

    private var endpoint: URL!

    override func setUpWithError() throws {
        guard let raw = ProcessInfo.processInfo.environment["MILA_REMOTE_TEST_ENDPOINT"],
              let url = URL(string: raw) else {
            throw XCTSkip("MILA_REMOTE_TEST_ENDPOINT not set — remote E2E runs only in the e2e-remote-transcription workflow.")
        }
        endpoint = url
    }

    /// 1 second of a 220 Hz sine at 16 kHz — real, non-silent audio for the
    /// engine to encode and upload.
    private func sineSamples(seconds: Double = 1.0) -> [Float] {
        let rate = WhisperAudioFormat.sampleRate
        let count = Int(rate * seconds)
        return (0..<count).map { i in
            0.3 * Float(sin(2.0 * Double.pi * 220.0 * Double(i) / rate))
        }
    }

    func test_roundTrip_uploadsAndParsesSegments() async throws {
        let engine = RemoteWhisperEngine()
        await engine.configure(RemoteTranscriptionConfig(
            endpoint: endpoint,
            apiKey: "test-key-123",
            model: "mila-echo-model"
        ))

        let segments = try await engine.transcribe(
            samples: sineSamples(),
            language: "he",
            audioCtx: 0,
            progress: nil,
            isCancelled: nil
        )

        // The mock echoes the received model + language into the segments, so
        // these assertions prove the client transmitted them and parsed the
        // verbose_json (segments + timestamps) back.
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.first?.text, "model=mila-echo-model")
        XCTAssertEqual(segments.last?.text, "lang=he")
        XCTAssertEqual(try XCTUnwrap(segments.last?.end), 1.0, accuracy: 0.0001)
    }

    func test_autoLanguage_isOmitted() async throws {
        let engine = RemoteWhisperEngine()
        await engine.configure(RemoteTranscriptionConfig(
            endpoint: endpoint,
            apiKey: "test-key-123",
            model: "m"
        ))

        let segments = try await engine.transcribe(
            samples: sineSamples(),
            language: "auto",
            audioCtx: 0,
            progress: nil,
            isCancelled: nil
        )

        // "auto" must NOT send a language field; the mock reports "none" then.
        XCTAssertEqual(segments.last?.text, "lang=none")
    }

    @MainActor
    func test_testConnection_reachesModelsEndpoint() async {
        let suite = UserDefaults(suiteName: "RemoteTranscriptionE2ETests.conn")!
        suite.removePersistentDomain(forName: "RemoteTranscriptionE2ETests.conn")
        let settings = RemoteTranscriptionSettings(
            defaults: suite,
            apiKeyKeychainKey: "RemoteTranscriptionE2ETests.conn.apiKey")
        settings.backend = .remote
        settings.endpoint = endpoint.absoluteString
        settings.apiKey = "test-key-123"

        await settings.testConnection()

        guard case .ok = settings.testStatus else {
            return XCTFail("Expected .ok, got \(settings.testStatus)")
        }
    }
}
