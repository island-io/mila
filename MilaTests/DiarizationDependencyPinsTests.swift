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

    /// torch 2.2.2 has no wheels past cp312, so a 3.13 interpreter must get a
    /// clear message instead of pip's "No matching distribution found".
    func test_python_outside_the_pinned_range_is_refused_with_a_message() {
        for ok in ["3.9", "3.11", "3.12\n"] {
            XCTAssertNil(DiarizationDependencyPins.unsupportedPythonMessage(version: ok), ok)
        }
        for bad in ["3.8", "3.13", "3.14", "2.7"] {
            XCTAssertNotNil(DiarizationDependencyPins.unsupportedPythonMessage(version: bad), bad)
        }
        XCTAssertNil(DiarizationDependencyPins.unsupportedPythonMessage(version: "garbage"),
                     "an unparseable probe must fall through to pip")
    }

    /// Nothing ran, so the refusal must not read "Speaker diarization
    /// failed", and it holds only version numbers, so the log keeps it.
    func test_unsupported_python_error_is_shown_and_logged_as_is() throws {
        let message = try XCTUnwrap(DiarizationDependencyPins.unsupportedPythonMessage(version: "3.13"))
        let error = SpeakerDiarizer.Error.unsupportedPython(message)
        XCTAssertEqual(error.localizedDescription, message)
        XCTAssertEqual(error.logDescription, message)
    }

    func test_bootstrap_wheels_use_the_shared_pins() {
        XCTAssertEqual(DiarizationBootstrap.torchVersion, DiarizationDependencyPins.torch)
        XCTAssertEqual(DiarizationBootstrap.torchaudioVersion, DiarizationDependencyPins.torchaudio)
        XCTAssertTrue(DiarizationBootstrap.extraInstallSpecs.contains("numpy\(DiarizationDependencyPins.numpy)"))
        XCTAssertFalse(DiarizationBootstrap.extraInstallSpecs.contains { $0.hasPrefix("numpy") && $0 != "numpy\(DiarizationDependencyPins.numpy)" },
                       "the bootstrap's numpy constraint must come from the shared table")
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
        // The resolver constraints are literal lines in the script's heredoc.
        // numpy is the pin that has already broken a release (1.9.7).
        let lines = Set(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        XCTAssertTrue(lines.contains("numpy\(DiarizationDependencyPins.numpy)"),
                      "build-diarization-bundle.sh must constrain numpy like the app does")
        XCTAssertTrue(lines.contains("huggingface_hub\(DiarizationDependencyPins.huggingfaceHub)"),
                      "build-diarization-bundle.sh must constrain huggingface_hub like the app does")
    }
}
