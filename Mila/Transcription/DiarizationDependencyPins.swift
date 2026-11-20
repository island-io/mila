import Foundation

/// The one table of diarization dependency versions, shared by both install
/// paths: `DiarizationBootstrap` (bundled runtime + downloaded torch wheels)
/// and `SpeakerDiarizer.installDependencies` (a user-supplied Python).
///
/// The inline diarize scripts carry two monkey-patches written against
/// pyannote.audio 3.x and a specific torch, and reach into the private
/// `pipeline._embedding`. An unpinned `pip install --upgrade` lets an upstream
/// release break diarization for whoever runs setup that day with no change on
/// Mila's side (improvement plan item 8). Keep these in step with
/// `scripts/build-diarization-bundle.sh` (`PYANNOTE_VERSION`, `TORCH_VERSION`,
/// `TORCHAUDIO_VERSION`) — `DiarizationDependencyPinsTests` checks that.
enum DiarizationDependencyPins {
    static let pyannoteAudio = "3.3.2"
    static let torch = "2.2.2"
    static let torchaudio = "2.2.2"
    /// torch 2.2.x was built against the numpy 1.x C ABI.
    static let numpy = "<2"
    static let huggingfaceHub = "<1.0"

    /// pip requirement specs for the user-Python install path.
    static var userPythonRequirements: [String] {
        [
            "pyannote.audio==\(pyannoteAudio)",
            "torch==\(torch)",
            "torchaudio==\(torchaudio)",
            "numpy\(numpy)",
            "soundfile",
            "huggingface_hub\(huggingfaceHub)",
        ]
    }

    /// Python 3 minor versions the pins can install on: torch 2.2.2 publishes
    /// macOS wheels for cp38–cp312 only, and pyannote.audio 3.3.2 needs 3.9+.
    /// A newer interpreter (Homebrew's default is 3.13+) would otherwise fail
    /// deep inside pip with "No matching distribution found for torch==2.2.2".
    static let supportedPythonMinors: ClosedRange<Int> = 9...12

    /// `nil` when `version` (`"3.11"`, as `sys.version_info[:2]` prints it) can
    /// take the pinned stack, else a message saying which Python to pick.
    /// An unparseable version returns `nil` so pip gets to report instead.
    static func unsupportedPythonMessage(version: String) -> String? {
        let parts = version.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        if parts[0] == 3 && supportedPythonMinors.contains(parts[1]) { return nil }
        return "Python \(parts[0]).\(parts[1]) can't install the pinned speaker-detection stack "
            + "(torch \(torch) ships wheels for Python 3.\(supportedPythonMinors.lowerBound)–"
            + "3.\(supportedPythonMinors.upperBound) only). Choose a Python 3."
            + "\(supportedPythonMinors.lowerBound)–3.\(supportedPythonMinors.upperBound) interpreter."
    }
}
