import XCTest
@testable import Mila

final class DiarizationDependencyPinsTests: XCTestCase {

    func test_user_python_install_pins_the_fragile_packages() {
        let args = SpeakerDiarizer.installDependencyArguments
        XCTAssertEqual(Array(args.prefix(3)), ["-m", "pip", "install"])
        XCTAssertFalse(args.contains("--upgrade"))
        XCTAssertTrue(args.contains("pyannote.audio==\(DiarizationDependencyPins.pyannoteAudio)"))
        XCTAssertTrue(args.contains("torch==\(DiarizationDependencyPins.torch)"))
        XCTAssertTrue(args.contains("torchaudio==\(DiarizationDependencyPins.torchaudio)"))
        XCTAssertTrue(args.contains("numpy<2"))
        XCTAssertTrue(args.contains("huggingface_hub<1.0"))
        for bare in ["pyannote.audio", "torch", "torchaudio"] {
            XCTAssertFalse(args.contains(bare), "\(bare) must not be installed unpinned")
        }
    }

    func test_bootstrap_wheels_use_the_shared_pins() {
        XCTAssertEqual(DiarizationBootstrap.torchVersion, DiarizationDependencyPins.torch)
        XCTAssertEqual(DiarizationBootstrap.torchaudioVersion, DiarizationDependencyPins.torchaudio)
    }

    /// The bundle script resolves the shipped site-packages under its own
    /// pins; if they drift from the app's, the runtime install and the bundle
    /// disagree about which pyannote/torch is in play.
    func test_pins_match_the_bundle_build_script() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/build-diarization-bundle.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        func value(_ key: String) -> String? {
            text.split(separator: "\n").first { $0.hasPrefix("\(key)=") }
                .flatMap { $0.split(separator: "=", maxSplits: 1).last }
                .flatMap { $0.split(separator: "#").first }
                .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        XCTAssertEqual(value("PYANNOTE_VERSION"), DiarizationDependencyPins.pyannoteAudio)
        XCTAssertEqual(value("TORCH_VERSION"), DiarizationDependencyPins.torch)
        XCTAssertEqual(value("TORCHAUDIO_VERSION"), DiarizationDependencyPins.torchaudio)
    }
}
