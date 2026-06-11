import Foundation
import TranscriptionCore

@main
enum CLI {
    static func main() async {
        let args = CommandLine.arguments
        guard let modelPath = flag("--model", in: args),
              let fixturesPath = flag("--fixtures", in: args) else {
            print("Usage: whisper-e2e --model <path> --fixtures <dir> [--max-wer <0.3>]")
            exit(1)
        }
        let maxWER = Double(flag("--max-wer", in: args) ?? "0.3") ?? 0.3

        let fixturesURL = URL(fileURLWithPath: fixturesPath)
        let modelURL = URL(fileURLWithPath: modelPath)

        guard FileManager.default.fileExists(atPath: modelPath) else {
            print("ERROR: model not found at \(modelPath)")
            exit(1)
        }

        let engine = WhisperEngine()
        do {
            try await engine.loadIfNeeded(modelURL: modelURL, displayName: "e2e-test")
        } catch {
            print("ERROR: failed to load model: \(error)")
            exit(1)
        }

        let fixtures: [Fixture]
        do {
            fixtures = try discoverFixtures(in: fixturesURL)
        } catch {
            print("ERROR: failed to discover fixtures: \(error)")
            exit(1)
        }

        guard !fixtures.isEmpty else {
            print("ERROR: no fixtures found in \(fixturesPath)")
            exit(1)
        }

        var passed = 0
        var failed = 0

        for fixture in fixtures {
            do {
                let samples = try WAVReader.loadSamples(url: fixture.wavURL)
                // Use the full-context path (audio_ctx = 0), matching how
                // production batch transcription runs (TranscriptionService.process
                // passes `audioCtx: 0`). Without this, `transcribe`'s default
                // `audioCtx: nil` falls through to `computeAudioCtx` → 750 (the
                // live-VAD speed truncation), which is NOT the path these batch
                // fixtures are meant to validate and degrades harder clips
                // (e.g. en_numbers_and_dates: WER 0.36 at 750 vs the threshold 0.3).
                let segments = try await engine.transcribe(
                    samples: samples,
                    language: fixture.language,
                    audioCtx: 0,
                    progress: nil,
                    isCancelled: nil
                )
                let transcript = segments.map(\.text).joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let wer = WERCalculator.calculate(
                    reference: fixture.expectedText,
                    hypothesis: transcript
                )

                let threshold = fixture.maxWER ?? maxWER
                let pass = wer <= threshold
                let symbol = pass ? "✓" : "✗"
                print("[\(fixture.language)] \(fixture.name): WER \(String(format: "%.2f", wer)) \(symbol)")
                if !pass {
                    print("  expected: \"\(fixture.expectedText)\"")
                    print("  got:      \"\(transcript)\"")
                    print("  threshold: \(threshold)")
                }
                if pass { passed += 1 } else { failed += 1 }
            } catch {
                print("[\(fixture.language)] \(fixture.name): ERROR \(error)")
                failed += 1
            }
        }

        print("\n\(passed + failed) fixtures: \(passed) passed, \(failed) failed")
        await engine.shutdown()
        exit(failed > 0 ? 1 : 0)
    }

    private static func flag(_ name: String, in args: [String]) -> String? {
        guard let idx = args.firstIndex(of: name), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }
}

struct Fixture {
    let name: String
    let wavURL: URL
    let language: String
    let expectedText: String
    let maxWER: Double?
}

func discoverFixtures(in dir: URL) throws -> [Fixture] {
    let fm = FileManager.default
    let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    let wavFiles = files.filter { $0.pathExtension == "wav" }

    return try wavFiles.compactMap { wavURL in
        let name = wavURL.deletingPathExtension().lastPathComponent
        let expectedURL = dir.appendingPathComponent("\(name).expected.txt")
        guard fm.fileExists(atPath: expectedURL.path) else {
            print("WARN: no expected.txt for \(name).wav, skipping")
            return nil
        }

        let lines = try String(contentsOf: expectedURL, encoding: .utf8)
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else {
            print("WARN: \(name).expected.txt needs at least 2 lines (language + text), skipping")
            return nil
        }

        let language = lines[0].trimmingCharacters(in: .whitespaces)
        let expectedText = lines.dropFirst().joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        var maxWER: Double?
        let werOverrideURL = dir.appendingPathComponent("\(name).max-wer")
        if let overrideStr = try? String(contentsOf: werOverrideURL, encoding: .utf8) {
            maxWER = Double(overrideStr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return Fixture(
            name: name,
            wavURL: wavURL,
            language: language,
            expectedText: expectedText,
            maxWER: maxWER
        )
    }.sorted(by: { $0.name < $1.name })
}
