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
}
