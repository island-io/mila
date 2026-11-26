import Foundation
import XCTest
import AVFoundation
import ObjCExceptionCatcher

final class ObjCExceptionTests: XCTestCase {

    func test_a_block_that_returns_normally_runs_once_and_does_not_throw() throws {
        var runs = 0
        try ObjCException.catching { runs += 1 }
        XCTAssertEqual(runs, 1)
    }

    /// The whole point: without the shim this exception terminates the
    /// test process instead of failing anything.
    func test_a_raised_NSException_becomes_a_Swift_error_carrying_its_name_and_reason() {
        XCTAssertThrowsError(try ObjCException.catching {
            NSException(name: NSExceptionName("com.apple.coreaudio.avfaudio"),
                        reason: "Failed to create tap due to format mismatch",
                        userInfo: nil).raise()
        }) { error in
            let ns = error as NSError
            XCTAssertEqual(ns.domain, ObjCExceptionErrorDomain)
            XCTAssertEqual(ns.localizedDescription, "Failed to create tap due to format mismatch")
            XCTAssertEqual(ns.userInfo[ObjCExceptionNameKey] as? String, "com.apple.coreaudio.avfaudio")
        }
    }

    func test_an_exception_without_a_reason_is_described_by_its_name() {
        XCTAssertThrowsError(try ObjCException.catching {
            NSException(name: .internalInconsistencyException, reason: nil, userInfo: nil).raise()
        }) { error in
            XCTAssertEqual((error as NSError).localizedDescription,
                           NSExceptionName.internalInconsistencyException.rawValue)
        }
    }

    /// A Foundation call that really raises (out-of-range index), so the
    /// shim is exercised against a framework throw, not just `raise()`.
    func test_a_framework_raise_is_caught() {
        let array = NSArray()
        XCTAssertThrowsError(try ObjCException.catching { _ = array.object(at: 3) }) { error in
            XCTAssertEqual((error as NSError).userInfo[ObjCExceptionNameKey] as? String,
                           NSExceptionName.rangeException.rawValue)
        }
    }

    /// The call #385 is about: `installTap` raising from inside AVFAudio's
    /// C++ graph code, where the exception has to unwind through C++ frames
    /// before the `@catch` sees it. A second tap on the same bus is the
    /// raise that needs no audio hardware (the format-mismatch raise needs a
    /// device that re-negotiates); nothing here touches the input or output
    /// node, so no CoreAudio device is opened.
    func test_an_AVAudioEngine_installTap_raise_is_caught_and_the_node_stays_usable() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        try ObjCException.catching {
            player.installTap(onBus: 0, bufferSize: 4800, format: format) { _, _ in }
        }
        XCTAssertThrowsError(try ObjCException.catching {
            player.installTap(onBus: 0, bufferSize: 4800, format: format) { _, _ in }
        }) { error in
            XCTAssertEqual((error as NSError).domain, ObjCExceptionErrorDomain)
        }
        // The raise left AVFAudio's graph consistent: the first tap can still
        // be removed and a fresh one installed.
        player.removeTap(onBus: 0)
        try ObjCException.catching {
            player.installTap(onBus: 0, bufferSize: 4800, format: format) { _, _ in }
        }
        player.removeTap(onBus: 0)
    }
}
