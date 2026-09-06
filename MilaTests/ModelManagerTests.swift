import XCTest
import CryptoKit
@testable import Mila

@MainActor
final class ModelManagerTests: XCTestCase {

    private var tempRoot: URL!
    private var defaults: UserDefaults!
    private let suite = "ModelManagerTests"

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelManagerTests-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func makeManager(sessionProtocolClasses: [AnyClass]? = nil) -> ModelManager {
        ModelManager(modelsDirectory: tempRoot, defaults: defaults,
                     sessionProtocolClasses: sessionProtocolClasses)
    }

    func test_catalog_contains_ivrit_large_as_default_selected_model() {
        let mgr = makeManager()
        XCTAssertNotNil(mgr.selectedModel())
        XCTAssertEqual(mgr.selectedModelName, WhisperModel.ivritLarge.name,
                       "Default selection should be the ivrit.ai large-v3 Hebrew model")
        XCTAssertEqual(WhisperModel.all.contains { $0.name.contains("ivrit") },
                       true,
                       "Expected at least one ivrit.ai model in the catalog")
    }

    func test_models_have_consistent_metadata() {
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        for model in WhisperModel.all {
            XCTAssertFalse(model.name.isEmpty)
            XCTAssertFalse(model.displayName.isEmpty)
            XCTAssertGreaterThan(model.sizeBytes, 100_000_000, "\(model.name) size implausibly small")
            XCTAssertEqual(model.url.scheme, "https")
            XCTAssertTrue(model.url.host?.contains("huggingface.co") == true,
                          "Expected HuggingFace URL for \(model.name)")
            XCTAssertEqual(model.sha256.count, 64,
                           "\(model.name) sha256 must be a 64-char hex string")
            XCTAssertEqual(model.sha256, model.sha256.lowercased(),
                           "\(model.name) sha256 should be lowercase hex")
            XCTAssertTrue(CharacterSet(charactersIn: model.sha256).isSubset(of: hex),
                          "\(model.name) sha256 must be hex-only")
        }
    }

    func test_verify_sha256_accepts_known_good_file() throws {
        let path = tempRoot.appendingPathComponent("good.bin")
        let payload = Data("hello island whisper\n".utf8)
        try payload.write(to: path)
        try ModelManager.verifySHA256(at: path, expected: Self.sha256Hex(of: payload))
    }

    func test_verify_sha256_accepts_multi_chunk_file() throws {
        // Force the streaming loop to iterate more than once (chunk size is 1 MiB).
        let path = tempRoot.appendingPathComponent("large.bin")
        let payload = Data(repeating: 0x5A, count: 3 * (1 << 20) + 17)
        try payload.write(to: path)
        try ModelManager.verifySHA256(at: path, expected: Self.sha256Hex(of: payload))
    }

    func test_verify_sha256_rejects_tampered_file() throws {
        let path = tempRoot.appendingPathComponent("bad.bin")
        try Data("the real bytes".utf8).write(to: path)
        let tamperedExpected = Self.sha256Hex(of: Data("different bytes".utf8))
        XCTAssertThrowsError(
            try ModelManager.verifySHA256(at: path, expected: tamperedExpected)
        ) { error in
            guard case ModelManager.VerifyError.sha256Mismatch = error else {
                XCTFail("Expected sha256Mismatch, got \(error)")
                return
            }
        }
    }

    private static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func test_url_for_model_lives_under_models_directory() {
        let mgr = makeManager()
        let url = mgr.url(for: WhisperModel.ivritLarge)
        XCTAssertEqual(url.deletingLastPathComponent().path, tempRoot.path)
        XCTAssertEqual(url.lastPathComponent, "ivrit-ai-whisper-large-v3.bin")
    }

    func test_install_state_reflects_files_in_directory() throws {
        let mgr = makeManager()
        XCTAssertFalse(mgr.isInstalled(.ivritLarge))

        let path = mgr.url(for: .ivritLarge)
        try Data("not-a-real-model".utf8).write(to: path)
        mgr.refreshInstalled()
        XCTAssertTrue(mgr.isInstalled(.ivritLarge))

        try mgr.delete(.ivritLarge)
        XCTAssertFalse(mgr.isInstalled(.ivritLarge))
    }

    func test_set_selected_persists_choice() {
        let mgr = makeManager()
        mgr.setSelected(.openaiTurbo)
        XCTAssertEqual(mgr.selectedModelName, WhisperModel.openaiTurbo.name)

        let reloaded = makeManager()
        XCTAssertEqual(reloaded.selectedModelName, WhisperModel.openaiTurbo.name)
    }

    func test_best_model_for_language_routes_hebrew_to_ivrit() {
        XCTAssertEqual(WhisperModel.bestModel(for: "he"), .ivritLarge)
        XCTAssertEqual(WhisperModel.bestModel(for: "iw"), .ivritLarge)
        XCTAssertEqual(WhisperModel.bestModel(for: "en"), .openaiTurbo)
        XCTAssertEqual(WhisperModel.bestModel(for: "auto"), .openaiTurbo)
    }

    func test_model_for_language_falls_back_to_selected_when_best_not_installed() throws {
        let mgr = makeManager()
        // Install only the OpenAI turbo, then ask for the Hebrew best model.
        let openaiPath = mgr.url(for: .openaiTurbo)
        try Data("not-a-real-model".utf8).write(to: openaiPath)
        mgr.refreshInstalled()
        mgr.setSelected(.openaiTurbo)

        // Hebrew best is ivritLarge (not installed) so we should fall back.
        let resolved = mgr.model(for: "he")
        XCTAssertEqual(resolved, .openaiTurbo)
    }

    func test_delete_marks_model_declined() throws {
        let mgr = makeManager()
        let path = mgr.url(for: .ivritLarge)
        try Data("not-a-real-model".utf8).write(to: path)
        mgr.refreshInstalled()
        XCTAssertFalse(mgr.isDeclined(.ivritLarge))

        try mgr.delete(.ivritLarge)

        XCTAssertTrue(mgr.isDeclined(.ivritLarge),
                      "Deleting a model must mark it declined so launch-time auto-download skips it")
    }

    func test_declined_status_persists_across_reload() throws {
        let mgr = makeManager()
        let path = mgr.url(for: .ivritLarge)
        try Data("not-a-real-model".utf8).write(to: path)
        mgr.refreshInstalled()
        try mgr.delete(.ivritLarge)

        let reloaded = makeManager()

        XCTAssertTrue(reloaded.isDeclined(.ivritLarge),
                      "Declined status must survive process relaunch, same as selectedModelName")
    }

    func test_download_clears_declined_status() throws {
        let mgr = makeManager(sessionProtocolClasses: [StubModelDownloadURLProtocol.self])
        let path = mgr.url(for: .ivritLarge)
        try Data("not-a-real-model".utf8).write(to: path)
        mgr.refreshInstalled()
        try mgr.delete(.ivritLarge)
        XCTAssertTrue(mgr.isDeclined(.ivritLarge))

        mgr.download(.ivritLarge)
        mgr.shutdown() // stop the stubbed task; we only care about the declined-set side effect

        XCTAssertFalse(mgr.isDeclined(.ivritLarge),
                       "An explicit download request means the user wants the model again")
    }

    func test_declining_one_model_does_not_affect_another() throws {
        let mgr = makeManager()
        let path = mgr.url(for: .ivritLarge)
        try Data("not-a-real-model".utf8).write(to: path)
        mgr.refreshInstalled()

        try mgr.delete(.ivritLarge)

        XCTAssertTrue(mgr.isDeclined(.ivritLarge))
        XCTAssertFalse(mgr.isDeclined(.openaiTurbo))
    }

    // MARK: - CoreML encoder is deleted with the model (#265)

    /// Installs a stand-in `<name>-encoder.mlmodelc` next to the `.bin`, the
    /// way a finished CoreML download would.
    private func installFakeCoreMLEncoder(_ mgr: ModelManager,
                                          for model: WhisperModel) throws -> URL {
        let dir = try XCTUnwrap(mgr.coreMLDirectory(for: model))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not-a-real-encoder".utf8)
            .write(to: dir.appendingPathComponent("model.espresso.net"))
        XCTAssertTrue(mgr.isCoreMLInstalled(model))
        return dir
    }

    func test_delete_also_removes_the_coreml_encoder() throws {
        let mgr = makeManager()
        try Data("not-a-real-model".utf8).write(to: mgr.url(for: .ivritLarge))
        mgr.refreshInstalled()
        let encoder = try installFakeCoreMLEncoder(mgr, for: .ivritLarge)

        try mgr.delete(.ivritLarge)

        XCTAssertFalse(FileManager.default.fileExists(atPath: encoder.path),
                       "Deleting a model must reclaim its ~1.1GB CoreML encoder too — "
                       + "the confirmation dialog quotes the size of both")
        XCTAssertFalse(mgr.isCoreMLInstalled(.ivritLarge))
        XCTAssertFalse(mgr.isInstalled(.ivritLarge))
        XCTAssertTrue(mgr.isDeclined(.ivritLarge))
    }

    func test_delete_leaves_another_models_coreml_encoder_alone() throws {
        let mgr = makeManager()
        try Data("not-a-real-model".utf8).write(to: mgr.url(for: .ivritLarge))
        try Data("not-a-real-model".utf8).write(to: mgr.url(for: .openaiTurbo))
        mgr.refreshInstalled()
        let deleted = try installFakeCoreMLEncoder(mgr, for: .ivritLarge)
        let kept = try installFakeCoreMLEncoder(mgr, for: .openaiTurbo)

        try mgr.delete(.ivritLarge)

        XCTAssertFalse(FileManager.default.fileExists(atPath: deleted.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path),
                      "Deleting one model must not touch the other's encoder")
        XCTAssertTrue(mgr.isCoreMLInstalled(.openaiTurbo))
    }

    func test_delete_succeeds_when_the_model_has_no_coreml_encoder_on_disk() throws {
        let mgr = makeManager()
        try Data("not-a-real-model".utf8).write(to: mgr.url(for: .ivritLarge))
        mgr.refreshInstalled()
        XCTAssertFalse(mgr.isCoreMLInstalled(.ivritLarge))

        XCTAssertNoThrow(try mgr.delete(.ivritLarge))
        XCTAssertTrue(mgr.isDeclined(.ivritLarge))
    }

    // MARK: - Default selection is established once, not re-asserted (#264, #266)

    func test_fresh_install_has_no_persisted_selection() {
        let mgr = makeManager()
        XCTAssertFalse(mgr.hasPersistedSelection,
                       "A catalog default is not a user choice — launch-time bootstrap "
                       + "uses this to tell 'never picked' from 'picked this'")
        XCTAssertEqual(mgr.selectedModelName, WhisperModel.ivritLarge.name)
    }

    func test_persisted_selection_is_remembered_across_reload() {
        let mgr = makeManager()
        mgr.setSelected(.openaiTurbo)
        XCTAssertTrue(mgr.hasPersistedSelection)

        let reloaded = makeManager()

        XCTAssertTrue(reloaded.hasPersistedSelection,
                      "Once the user has chosen a model, every later launch must see "
                      + "that choice rather than re-establishing the default over it")
        XCTAssertEqual(reloaded.selectedModelName, WhisperModel.openaiTurbo.name)
    }

    func test_deleting_a_model_does_not_invent_a_persisted_selection() throws {
        let mgr = makeManager()
        try Data("not-a-real-model".utf8).write(to: mgr.url(for: .ivritLarge))
        mgr.refreshInstalled()

        try mgr.delete(.ivritLarge)

        XCTAssertFalse(mgr.hasPersistedSelection,
                       "Deleting is not choosing — a user who never picked a model "
                       + "must still get the fresh-install default path")
    }
}

/// Returns a tiny 200 response for any request — lets `ModelManager.download(_:)`
/// exercise its declined-status side effect without a real network fetch.
private final class StubModelDownloadURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("stub-model-bytes".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
