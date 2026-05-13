import Foundation

struct SpeakerTurn: Codable {
    let start: Double
    let end: Double
    let speaker: String
}

enum SpeakerDiarizer {

    enum Error: Swift.Error, LocalizedError {
        case pythonNotFound(String)
        case diarizationFailed(String)

        var errorDescription: String? {
            switch self {
            case .pythonNotFound(let path):
                return "Python not found at \(path). Install Python 3 with pyannote.audio."
            case .diarizationFailed(let msg):
                return "Speaker diarization failed: \(msg)"
            }
        }
    }

    static func installDependencies(pythonPath: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            guard fm.fileExists(atPath: pythonPath) else {
                throw Error.pythonNotFound(pythonPath)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: pythonPath)
            process.arguments = ["-m", "pip", "install", "--upgrade", "pyannote.audio", "torch", "huggingface_hub<1.0"]
            process.environment = ProcessInfo.processInfo.environment

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            process.waitUntilExit()

            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outData, encoding: .utf8) ?? ""
            let errOutput = String(data: errData, encoding: .utf8) ?? ""

            guard process.terminationStatus == 0 else {
                throw Error.diarizationFailed(errOutput.isEmpty ? output : errOutput)
            }

            return output
        }.value
    }

    static func diarize(wavURL: URL, hfToken: String, pythonPath: String) async throws -> [SpeakerTurn] {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            guard fm.fileExists(atPath: pythonPath) else {
                throw Error.pythonNotFound(pythonPath)
            }

            let diarizeScript = """
            import json, sys, os, types

            # speechbrain uses LazyModule for optional integrations. When
            # pytorch_lightning inspects the call stack, it triggers these
            # lazy imports and crashes if the optional packages aren't
            # installed. Patch LazyModule.__getattr__ to return a dummy
            # instead of raising ImportError.
            try:
                import speechbrain.utils.importutils as _sbiu
                _orig_ensure = _sbiu.LazyModule.ensure_module
                def _safe_ensure(self, *a, **kw):
                    try:
                        return _orig_ensure(self, *a, **kw)
                    except ImportError:
                        self.lazy_module = types.ModuleType(self.target)
                        return self.lazy_module
                _sbiu.LazyModule.ensure_module = _safe_ensure
            except Exception:
                pass

            import torch
            _orig_torch_load = torch.load
            def _patched_torch_load(*args, **kwargs):
                kwargs["weights_only"] = False
                return _orig_torch_load(*args, **kwargs)
            torch.load = _patched_torch_load

            from pyannote.audio import Pipeline

            wav_path = sys.argv[1]
            print(f"diarize: loading pipeline...", file=sys.stderr)
            pipeline = Pipeline.from_pretrained("pyannote/speaker-diarization-3.1")
            if torch.backends.mps.is_available():
                pipeline.to(torch.device("mps"))
                print(f"diarize: using MPS", file=sys.stderr)

            print(f"diarize: running on {wav_path}", file=sys.stderr)
            diar = pipeline(wav_path)
            annotation = getattr(diar, "speaker_diarization", diar)

            turns = []
            for turn, _, speaker in annotation.itertracks(yield_label=True):
                turns.append({
                    "start": round(turn.start, 3),
                    "end": round(turn.end, 3),
                    "speaker": speaker,
                })

            print(f"diarize: found {len(set(t['speaker'] for t in turns))} speakers, {len(turns)} turns", file=sys.stderr)
            json.dump(turns, sys.stdout)
            """

            let process = Process()
            process.executableURL = URL(fileURLWithPath: pythonPath)
            process.arguments = ["-c", diarizeScript, wavURL.path]
            process.environment = ProcessInfo.processInfo.environment
            process.environment?["HF_TOKEN"] = hfToken

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            process.waitUntilExit()

            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()

            guard process.terminationStatus == 0 else {
                let errMsg = String(data: errData, encoding: .utf8) ?? "exit code \(process.terminationStatus)"
                throw Error.diarizationFailed(errMsg)
            }

            return try JSONDecoder().decode([SpeakerTurn].self, from: outData)
        }.value
    }

    struct VerifyResult: Codable {
        let pyannoteInstalled: Bool
        let torchInstalled: Bool
        let models: [ModelCheck]

        struct ModelCheck: Codable {
            let name: String
            let accessible: Bool
            let error: String?
        }

        var allGood: Bool {
            pyannoteInstalled && torchInstalled && models.allSatisfy(\.accessible)
        }
    }

    static func verifySetup(pythonPath: String, hfToken: String) async throws -> VerifyResult {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            guard fm.fileExists(atPath: pythonPath) else {
                throw Error.pythonNotFound(pythonPath)
            }

            let checkScript = """
            import json, sys, os

            result = {
                "pyannoteInstalled": False,
                "torchInstalled": False,
                "models": [],
            }

            try:
                import pyannote.audio
                result["pyannoteInstalled"] = True
            except ImportError:
                pass

            try:
                import torch
                result["torchInstalled"] = True
            except ImportError:
                pass

            if result["pyannoteInstalled"]:
                from huggingface_hub import HfApi
                token = os.environ.get("HF_TOKEN", "")
                api = HfApi(token=token)
                for model_id in ["pyannote/speaker-diarization-3.1", "pyannote/segmentation-3.0"]:
                    check = {"name": model_id, "accessible": False, "error": None}
                    try:
                        api.model_info(model_id)
                        check["accessible"] = True
                    except Exception as e:
                        msg = str(e)
                        if "403" in msg or "gated" in msg.lower() or "Access" in msg:
                            check["error"] = "terms_not_accepted"
                        elif "401" in msg or "unauthorized" in msg.lower():
                            check["error"] = "invalid_token"
                        else:
                            check["error"] = msg[:200]
                    result["models"].append(check)

            json.dump(result, sys.stdout)
            """

            let process = Process()
            process.executableURL = URL(fileURLWithPath: pythonPath)
            process.arguments = ["-c", checkScript]
            process.environment = ProcessInfo.processInfo.environment
            process.environment?["HF_TOKEN"] = hfToken

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            process.waitUntilExit()

            let outData = stdout.fileHandleForReading.readDataToEndOfFile()

            guard !outData.isEmpty else {
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                let errMsg = String(data: errData, encoding: .utf8) ?? "no output"
                throw Error.diarizationFailed(errMsg)
            }

            return try JSONDecoder().decode(VerifyResult.self, from: outData)
        }.value
    }

    static func assignSpeaker(segmentStart: Double, segmentEnd: Double, turns: [SpeakerTurn]) -> String? {
        guard !turns.isEmpty else { return nil }
        let mid = (segmentStart + segmentEnd) / 2.0
        var best: String?
        var bestOverlap: Double = 0.0
        for turn in turns {
            let overlap = max(0.0, min(segmentEnd, turn.end) - max(segmentStart, turn.start))
            if overlap > bestOverlap {
                bestOverlap = overlap
                best = turn.speaker
            }
            if best == nil && turn.start <= mid && mid <= turn.end {
                best = turn.speaker
            }
        }
        return best
    }
}
