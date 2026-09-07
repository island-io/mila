import XCTest
@testable import Mila

@MainActor
final class DiagnosticReporterTests: XCTestCase {

    private var tempRoot: URL!
    private var store: RecordingStore!

    override func setUp() {
        super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "DiagnosticReporterTests")
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = RecordingStore(rootDirectory: tempRoot)
    }

    override func tearDown() {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        super.tearDown()
    }

    func test_buildReport_returns_a_zip_file_that_exists() async throws {
        // Seed with a recording so the report has something to summarize.
        store.add(Recording(title: "Demo",
                            duration: 12.0,
                            source: .microphone,
                            audioFileName: "demo.wav",
                            fullText: "hello world"))
        let zip = try await DiagnosticReporter.buildReport(store: store, diarization: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path))
        XCTAssertEqual(zip.pathExtension, "zip")
        XCTAssertGreaterThan(try zip.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 0)
        // Clean up the temp staging dir + the zip.
        try? FileManager.default.removeItem(at: zip.deletingLastPathComponent())
    }

    func test_buildReport_excludes_transcript_text_from_recordings_json() async throws {
        // Important privacy check: even though Recording.fullText might
        // contain whatever the user said, the report's recordings.json
        // must only carry counts/lengths, not the actual text.
        let sensitive = "my super secret diary entry that no support person should ever see"
        store.add(Recording(title: "Secret",
                            duration: 1.0,
                            source: .microphone,
                            audioFileName: "secret.wav",
                            segments: [.init(start: 0, end: 1, text: sensitive)],
                            fullText: sensitive))
        let zip = try await DiagnosticReporter.buildReport(store: store, diarization: nil)
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }

        let unzipped = try unzip(zip)
        defer { try? FileManager.default.removeItem(at: unzipped) }
        let recordingsJSON = try locate(named: "recordings.json", under: unzipped)
        let body = try String(contentsOf: recordingsJSON, encoding: .utf8)
        XCTAssertFalse(body.contains(sensitive),
                       "recordings.json must not contain transcript text — counts/lengths only")
        XCTAssertTrue(body.contains("\"full_text_length\""),
                      "but it must record the length so the recipient can tell if there was a transcript")
    }

    func test_buildReport_includes_manifest_and_system_info() async throws {
        let zip = try await DiagnosticReporter.buildReport(store: store, diarization: nil)
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        let unzipped = try unzip(zip)
        defer { try? FileManager.default.removeItem(at: unzipped) }

        let manifestURL = try locate(named: "manifest.txt", under: unzipped)
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        XCTAssertTrue(manifest.contains("Mila Diagnostic Report"))
        XCTAssertTrue(manifest.contains("recordings.json"))

        let sysURL = try locate(named: "system-info.txt", under: unzipped)
        let sysInfo = try String(contentsOf: sysURL, encoding: .utf8)
        XCTAssertTrue(sysInfo.contains("App:"))
        XCTAssertTrue(sysInfo.contains("Version:"))
        XCTAssertTrue(sysInfo.contains("macOS:"))
    }

    func test_diarization_snapshot_provider_runs_when_passed() async throws {
        // Use a stub provider so the test doesn't have to instantiate the
        // real (Python-backed) diarization pipeline.
        let stub = StubProvider(payload: "STUB_HEALTH_OUTPUT_42")
        let zip = try await DiagnosticReporter.buildReport(store: store, diarization: stub)
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        let unzipped = try unzip(zip)
        defer { try? FileManager.default.removeItem(at: unzipped) }

        let healthURL = try locate(named: "diarization-health.txt", under: unzipped)
        let body = try String(contentsOf: healthURL, encoding: .utf8)
        XCTAssertEqual(body, "STUB_HEALTH_OUTPUT_42")
    }

    // MARK: - settings.json scoping (#281)

    /// The report's `settings.json` has to say which backend and which Live
    /// AI mode the user is in without a follow-up email — a CPU report whose
    /// remote backend had to be inferred from log lines is what #281 was.
    /// Every Mila namespace is exported; unrelated defaults are not.
    func test_scopedSettings_exports_every_mila_namespace_and_drops_the_rest() throws {
        let defaults: [String: Any] = [
            "transcription.backend": "remote",
            "remote.endpoint": "https://asr.example.internal/v1",
            "remote.model": "ivrit-ai/whisper-large-v3-turbo-ct2",
            "liveAI.enabled": true,
            "liveAI.backgroundMode": true,
            "meetingDetection.enabled": true,
            "voiceMemos.folderBookmark": Data([1, 2, 3]),
            "mcp.enabled": false,
            "updates.betaChannel": true,
            "audioInput.adaptiveGainEnabled": true,
            "coreml.compiled.openai-whisper-large-v3-turbo": true,
            "speakers.voiceRecognition.enabled": false,
            "model.declinedNames": ["ivrit-ai-whisper-large-v3"],
            "selectedModelName": "openai-whisper-large-v3-turbo",
            // Not Mila's — must not leak into the zip.
            "NSNavLastRootDirectory": "~/Desktop",
            "com.apple.trackpad.scaling": 1.5,
            "AppleLanguages": ["en"],
        ]
        let scoped = DiagnosticReporter.scopedSettings(from: defaults)

        XCTAssertEqual(scoped["transcription.backend"] as? String, "remote")
        XCTAssertEqual(scoped["remote.endpoint"] as? String, "https://asr.example.internal/v1")
        XCTAssertEqual(scoped["remote.model"] as? String, "ivrit-ai/whisper-large-v3-turbo-ct2")
        XCTAssertEqual(scoped["liveAI.backgroundMode"] as? Bool, true)
        XCTAssertEqual(scoped["meetingDetection.enabled"] as? Bool, true)
        XCTAssertEqual(scoped["voiceMemos.folderBookmark"] as? String, "<3 bytes>",
                       "security-scoped bookmarks are opaque Data — a byte count is all the report needs")
        XCTAssertEqual(scoped["mcp.enabled"] as? Bool, false)
        XCTAssertEqual(scoped["updates.betaChannel"] as? Bool, true)
        XCTAssertEqual(scoped["audioInput.adaptiveGainEnabled"] as? Bool, true)
        XCTAssertEqual(scoped["coreml.compiled.openai-whisper-large-v3-turbo"] as? Bool, true)
        XCTAssertEqual(scoped["speakers.voiceRecognition.enabled"] as? Bool, false)
        XCTAssertEqual(scoped["model.declinedNames"] as? [String], ["ivrit-ai-whisper-large-v3"])
        XCTAssertEqual(scoped["selectedModelName"] as? String, "openai-whisper-large-v3-turbo")

        XCTAssertNil(scoped["NSNavLastRootDirectory"])
        XCTAssertNil(scoped["com.apple.trackpad.scaling"])
        XCTAssertNil(scoped["AppleLanguages"])
        XCTAssertEqual(scoped.count, 14, "exactly the Mila keys, nothing else")

        // What comes out must be what `writeSettings` can serialise.
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: scoped, options: [.sortedKeys]))
    }

    /// Widening the allowlist to every Mila namespace pulls in keys that
    /// carry credentials and user-authored text. Credentials are redacted
    /// by key name; prompts are reported as a length — people paste meeting
    /// agendas into them; the Obsidian written-index is a count, because its
    /// vault paths are derived from recording titles.
    func test_scopedSettings_redacts_credentials_and_reports_prompts_as_lengths() throws {
        let agenda = "Q3 planning: budget cuts in the Berlin office, layoffs to be discussed Thursday"
        let defaults: [String: Any] = [
            "remote.apiKey": "sk-live-abc123",
            "llm.openai.apiKey": "sk-proj-xyz",
            "claudeSetup.oauthToken": "oat-secret",
            "liveAI.prompt": agenda,
            "liveAI.summaryPrompt": "Summarise the meeting.",
            "llm.action.prompt": agenda,
            "llm.name.prompt": "",
            "obsidian.writtenIndex": ["id-1": "Meetings/Berlin layoffs.md", "id-2": "Notes/x.md"],
            "llm.tool": "claude",
        ]
        let scoped = DiagnosticReporter.scopedSettings(from: defaults)

        for key in ["remote.apiKey", "llm.openai.apiKey", "claudeSetup.oauthToken"] {
            XCTAssertEqual(scoped[key] as? String, "<redacted>", key)
        }
        XCTAssertEqual(scoped["liveAI.prompt"] as? String, "<\(agenda.count) chars>")
        XCTAssertEqual(scoped["llm.action.prompt"] as? String, "<\(agenda.count) chars>")
        XCTAssertEqual(scoped["liveAI.summaryPrompt"] as? String, "<22 chars>")
        XCTAssertEqual(scoped["llm.name.prompt"] as? String, "<0 chars>",
                       "an empty prompt is still worth knowing about — as a length")
        XCTAssertEqual(scoped["obsidian.writtenIndex"] as? String, "<2 entries>")
        XCTAssertEqual(scoped["llm.tool"] as? String, "claude", "plain settings pass through")

        let json = String(decoding: try JSONSerialization.data(withJSONObject: scoped, options: [.sortedKeys]),
                          as: UTF8.self)
        XCTAssertFalse(json.contains("Berlin"), "prompt text and vault paths must not reach the zip")
        XCTAssertFalse(json.contains("sk-live"), "credentials must not reach the zip")
        XCTAssertFalse(json.contains("oat-secret"))
    }

    // MARK: - Test helpers

    /// Extract `zip` into a fresh temp directory and return its URL.
    private func unzip(_ zip: URL) throws -> URL {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("unzip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dest.path]
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw NSError(domain: "DiagnosticReporterTests", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "unzip failed"])
        }
        return dest
    }

    /// Find a file with `name` anywhere under `root`. The zip wraps the
    /// payload in a versioned folder, so absolute paths inside aren't
    /// stable across runs — finding by leaf name is fine for tests.
    private func locate(named name: String, under root: URL) throws -> URL {
        let enumerator = FileManager.default.enumerator(at: root,
                                                         includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == name { return url }
        }
        throw NSError(domain: "DiagnosticReporterTests", code: 404,
                      userInfo: [NSLocalizedDescriptionKey: "Could not find \(name) under \(root.path)"])
    }
}

/// Hand-rolled stub for the DiagnosticSnapshotProvider seam — using a
/// real DiarizationSettings here would drag in the Python bootstrap path
/// which has no business running during unit tests.
private struct StubProvider: DiagnosticSnapshotProvider {
    let payload: String
    func diagnosticSnapshot() async -> String { payload }
}
