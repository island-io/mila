import XCTest
@testable import Mila

final class RemoteShutdownTests: XCTestCase {
    private let samples = Array(repeating: Float(0.2), count: 16_000)

    func test_normal_upload_returns_transcript() async throws {
        let fixture = RemoteShutdownFixture(hold: false)
        defer { fixture.cleanUp() }
        let engine = fixture.engine()
        await engine.configure(fixture.config)
        let result = try await engine.transcribe(samples: samples, language: "en", audioCtx: 0,
                                                 progress: nil, isCancelled: nil)
        XCTAssertEqual(result.first?.text, "Synthetic transcript.")
        XCTAssertEqual(fixture.probe.startCount, 1)
        await engine.shutdown()
    }

    func test_shutdown_rejects_new_uploads_and_is_idempotent() async {
        let fixture = RemoteShutdownFixture(hold: false)
        defer { fixture.cleanUp() }
        let engine = fixture.engine(encode: { _ in
            XCTFail("An engine shut down before entry must not encode audio")
            return Data()
        })
        await engine.configure(fixture.config)
        await engine.shutdown()
        await engine.shutdown()
        do {
            _ = try await engine.transcribe(samples: samples, language: "en", audioCtx: 0,
                                             progress: nil, isCancelled: nil)
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(fixture.probe.startCount, 0)
    }

    func test_shutdown_while_encoding_never_starts_upload() async {
        let fixture = RemoteShutdownFixture(hold: false)
        defer { fixture.cleanUp() }
        let entered = expectation(description: "encoder entered")
        let finished = expectation(description: "transcription returned")
        let gate = ShutdownEncodingGate(entered: entered)
        let engine = fixture.engine(encode: { _ in await gate.wait() })
        await engine.configure(fixture.config)
        let input = samples
        let call = Task {
            defer { finished.fulfill() }
            do {
                _ = try await engine.transcribe(samples: input, language: "en", audioCtx: 0,
                                                 progress: nil, isCancelled: nil)
                XCTFail("Expected shutdown cancellation")
            } catch is CancellationError {
            } catch { XCTFail("Unexpected error: \(error)") }
        }
        await fulfillment(of: [entered], timeout: 10)
        await engine.shutdown()
        await gate.release()
        await fulfillment(of: [finished], timeout: 10)
        call.cancel()
        XCTAssertEqual(fixture.probe.startCount, 0)
    }

    func test_shutdown_cancels_active_upload() async {
        await assertActiveUploadCancelled(by: .shutdown)
    }

    func test_swift_task_cancellation_cancels_active_upload() async {
        await assertActiveUploadCancelled(by: .swiftTask)
    }

    func test_polled_cancellation_cancels_active_upload() async {
        await assertActiveUploadCancelled(by: .polledFlag)
    }

    private enum CancelMethod { case shutdown, swiftTask, polledFlag }

    private func assertActiveUploadCancelled(by method: CancelMethod) async {
        let fixture = RemoteShutdownFixture(hold: true)
        defer { fixture.cleanUp() }
        let finished = expectation(description: "cancelled call returned")
        let engine = fixture.engine()
        await engine.configure(fixture.config)
        let cancelled = ShutdownTestFlag()
        let input = samples
        let call = Task {
            defer { finished.fulfill() }
            do {
                _ = try await engine.transcribe(samples: input, language: "en", audioCtx: 0,
                                                 progress: nil, isCancelled: { cancelled.value })
                XCTFail("Expected cancellation")
            } catch is CancellationError {
            } catch { XCTFail("Unexpected error: \(error)") }
        }
        await fulfillment(of: [fixture.probe.started], timeout: 10)
        switch method {
        case .shutdown: await engine.shutdown()
        case .swiftTask: call.cancel()
        case .polledFlag: cancelled.set()
        }
        // Check the requested cancellation mechanism BEFORE the cleanup shutdown.
        await fulfillment(of: [fixture.probe.stopped, finished], timeout: 10)
        call.cancel()
        await engine.shutdown()
        XCTAssertEqual(fixture.probe.startCount, 1)
    }
}

private actor ShutdownEncodingGate {
    private let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Data, Never>?
    private var released = false
    init(entered: XCTestExpectation) { self.entered = entered }
    func wait() async -> Data {
        if released { return Data([1, 2, 3]) }
        return await withCheckedContinuation {
            continuation = $0
            entered.fulfill()
        }
    }
    func release() {
        released = true
        continuation?.resume(returning: Data([1, 2, 3]))
        continuation = nil
    }
}

private final class ShutdownTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func set() { lock.lock(); defer { lock.unlock() }; cancelled = true }
}

private final class ShutdownRequestProbe: @unchecked Sendable {
    let started = XCTestExpectation(description: "upload started")
    let stopped = XCTestExpectation(description: "upload stopped")
    let hold: Bool
    private let lock = NSLock()
    private var starts = 0
    init(hold: Bool) { self.hold = hold }
    var startCount: Int { lock.lock(); defer { lock.unlock() }; return starts }
    func start() { lock.lock(); starts += 1; lock.unlock(); started.fulfill() }
}

private struct RemoteShutdownFixture {
    let config: RemoteTranscriptionConfig
    let session: URLSession
    let probe: ShutdownRequestProbe
    private let host: String
    init(hold: Bool) {
        host = "shutdown-\(UUID().uuidString.lowercased()).invalid"
        config = RemoteTranscriptionConfig(endpoint: URL(string: "https://\(host)/v1")!,
                                           apiKey: "", model: "whisper-1")
        probe = ShutdownRequestProbe(hold: hold)
        ShutdownURLProtocol.register(probe, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShutdownURLProtocol.self]
        session = URLSession(configuration: configuration)
    }
    func engine(encode: @escaping @Sendable ([Float]) async throws -> Data = { _ in Data([1, 2, 3]) }) -> RemoteWhisperEngine {
        RemoteWhisperEngine(session: session, encodeAudio: encode)
    }
    func cleanUp() {
        session.invalidateAndCancel()
        ShutdownURLProtocol.remove(host: host)
    }
}

private final class ShutdownURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var probes: [String: ShutdownRequestProbe] = [:]
    private var probe: ShutdownRequestProbe?
    static func register(_ probe: ShutdownRequestProbe, host: String) {
        lock.lock(); defer { lock.unlock() }; probes[host] = probe
    }
    static func remove(host: String) {
        lock.lock(); defer { lock.unlock() }; probes[host] = nil
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let current = Self.probes[request.url?.host ?? ""]
        Self.lock.unlock()
        guard let current, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        probe = current
        current.start()
        guard !current.hold else { return }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"segments":[{"start":0,"end":1,"text":"Synthetic transcript."}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { probe?.stopped.fulfill() }
}
