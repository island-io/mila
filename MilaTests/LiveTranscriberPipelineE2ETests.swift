import XCTest
import TranscriptionCore
@testable import Mila

/// Unit-level E2E for the live-recording pipeline. Loads the fixture WAV
/// + drives real `LiveTranscriber` with real `WhisperEngine` (the
/// production models on disk) — no XCUITest, no SwiftUI rendering,
/// no a11y queries. Asserts the segments collection grows over time
/// + has expected language tokens.
///
/// Gated on env `MILA_PIPELINE_E2E=1` so a casual local `make test`
/// run doesn't spend 5 minutes loading whisper. CI provisions
/// the models + sets the flag.
@MainActor
final class LiveTranscriberPipelineE2ETests: XCTestCase {

    func test_english_fixture_produces_segments() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MILA_PIPELINE_E2E"] == "1",
            "Set MILA_PIPELINE_E2E=1 to run; needs real whisper models on disk."
        )
        try await runFixturePipeline(
            language: "en",
            fixtureEnvVar: "MILA_FIXTURE_WAV_EN",
            longTokens: ["search", "auth", "billing", "thursday"],
            shortTokens: ["hi", "yes", "ok", "done", "great"]
        )
    }

    func test_hebrew_fixture_produces_segments() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MILA_PIPELINE_E2E"] == "1",
            "Set MILA_PIPELINE_E2E=1 to run; needs real whisper models on disk."
        )
        try await runFixturePipeline(
            language: "he",
            fixtureEnvVar: "MILA_FIXTURE_WAV_HE",
            longTokens: ["חיפוש", "מערכת", "חמישי"],
            shortTokens: ["היי", "כן", "בסדר", "סיימנו", "מצוין"]
        )
    }

    // MARK: - Driver

    private func runFixturePipeline(
        language: String,
        fixtureEnvVar: String,
        longTokens: [String],
        shortTokens: [String]
    ) async throws {
        guard let wavPath = ProcessInfo.processInfo.environment[fixtureEnvVar] else {
            throw XCTSkip("\(fixtureEnvVar) not set — workflow should point to the generated fixture WAV")
        }
        let samples = try loadFixtureWAV(path: wavPath)
        XCTAssertGreaterThan(samples.count, 16_000 * 30, "[\(language)] fixture suspiciously short")

        // Real models on disk — same path Mila itself uses.
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveTranscriberPipelineE2E-\(UUID().uuidString)")
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let modelsDir = appSupport.appendingPathComponent("Mila/Models", isDirectory: true)
        let manager = ModelManager(modelsDirectory: modelsDir)
        let store = RecordingStore(rootDirectory: tempRoot)
        let diarSettings = DiarizationSettings(
            defaults: .init(suiteName: "LiveTranscriberPipelineE2ETests.diar")!
        )
        let service = TranscriptionService(
            store: store,
            modelManager: manager,
            diarizationSettings: diarSettings,
            engine: WhisperEngine()
        )
        let transcriber = LiveTranscriber(transcription: service)
        transcriber.useVAD = true
        transcriber.start(language: language)
        // Pump samples in 30ms chunks. Speed doesn't matter (no UI,
        // no real-time pacing); the slow part is whisper's transcribe
        // call, which serializes on the actor anyway.
        let chunkSize = 480
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunkSize, samples.count)
            transcriber.ingest(samples[offset..<end])
            offset = end
        }
        // Force the detector to flush its trailing in-progress
        // utterance, then await every queued transcribe via
        // transcribeNow's idempotent path.
        await transcriber.transcribeNow()

        let segments = transcriber.segments
        let transcript = segments.map(\.text).joined(separator: " ").lowercased()
        print("PipelineE2E[\(language)]: \(segments.count) segments, \(transcript.count) chars")
        print("PipelineE2E[\(language)]: ===TRANSCRIPT===\n\(transcript)\n===END===")

        XCTAssertGreaterThanOrEqual(
            segments.count, 5,
            "[\(language)] Only \(segments.count) segments from a 60s+ fixture — VAD or whisper not progressing"
        )
        let foundLong = longTokens.filter { transcript.contains($0.lowercased()) }
        XCTAssertGreaterThanOrEqual(
            foundLong.count, 2,
            "[\(language)] Missing long tokens (found \(foundLong) of \(longTokens))"
        )
        let foundShort = shortTokens.filter { transcript.contains($0.lowercased()) }
        XCTAssertGreaterThanOrEqual(
            foundShort.count, 2,
            "[\(language)] Missing short tokens (found \(foundShort) of \(shortTokens))"
        )

        _ = transcriber.stop()
    }

    // MARK: - WAV loader

    /// Minimal RIFF/WAVE decoder — supports 16-bit PCM mono and 32-bit
    /// float mono, the two shapes our fixture generator + production
    /// recording paths emit. Stereo input is collapsed to mono.
    private func loadFixtureWAV(path: String) throws -> [Float] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count > 44,
              data.prefix(4) == Data("RIFF".utf8),
              data[8..<12] == Data("WAVE".utf8) else {
            throw NSError(domain: "loadFixtureWAV", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "not a RIFF WAVE: \(path)"])
        }
        var idx = 12
        var fmtTag: UInt16 = 0
        var channels: UInt16 = 1
        var bitsPerSample: UInt16 = 16
        var dataStart = -1
        var dataLen = 0
        while idx + 8 <= data.count {
            let id = String(data: data[idx..<idx+4], encoding: .ascii) ?? ""
            let size = Int(data[idx+4..<idx+8].withUnsafeBytes {
                $0.load(as: UInt32.self).littleEndian
            })
            let payloadStart = idx + 8
            switch id {
            case "fmt ":
                fmtTag = data[payloadStart..<payloadStart+2].withUnsafeBytes {
                    $0.load(as: UInt16.self).littleEndian
                }
                channels = data[payloadStart+2..<payloadStart+4].withUnsafeBytes {
                    $0.load(as: UInt16.self).littleEndian
                }
                bitsPerSample = data[payloadStart+14..<payloadStart+16].withUnsafeBytes {
                    $0.load(as: UInt16.self).littleEndian
                }
            case "data":
                dataStart = payloadStart
                dataLen = size
            default: break
            }
            idx = payloadStart + size
            if dataStart >= 0 { break }
        }
        guard dataStart >= 0, dataStart + dataLen <= data.count else {
            throw NSError(domain: "loadFixtureWAV", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "missing data chunk"])
        }
        let payload = data[dataStart..<dataStart+dataLen]
        var samples: [Float] = []
        if fmtTag == 1 && bitsPerSample == 16 {
            let count = dataLen / 2
            payload.withUnsafeBytes { raw in
                let i16 = raw.bindMemory(to: Int16.self)
                if channels == 1 {
                    for i in 0..<count {
                        samples.append(Float(i16[i]) / 32768.0)
                    }
                } else {
                    let frames = count / Int(channels)
                    for f in 0..<frames {
                        var sum: Float = 0
                        for c in 0..<Int(channels) {
                            sum += Float(i16[f * Int(channels) + c]) / 32768.0
                        }
                        samples.append(sum / Float(channels))
                    }
                }
            }
        } else if fmtTag == 3 && bitsPerSample == 32 {
            let count = dataLen / 4
            payload.withUnsafeBytes { raw in
                let f32 = raw.bindMemory(to: Float.self)
                if channels == 1 {
                    for i in 0..<count { samples.append(f32[i]) }
                } else {
                    let frames = count / Int(channels)
                    for f in 0..<frames {
                        var sum: Float = 0
                        for c in 0..<Int(channels) {
                            sum += f32[f * Int(channels) + c]
                        }
                        samples.append(sum / Float(channels))
                    }
                }
            }
        } else {
            throw NSError(domain: "loadFixtureWAV", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "unsupported WAV format \(fmtTag)/\(bitsPerSample)"])
        }
        return samples
    }
}
