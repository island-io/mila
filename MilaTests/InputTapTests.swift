import AVFoundation
import XCTest
@testable import Mila

/// #385: AirPods switched from 48 kHz to their 24 kHz call profile between
/// `inputFormat(forBus:)` and `installTap`, the tap raised, and the uncaught
/// exception aborted Mila. The real switch can't be staged without the
/// hardware, so these drive `installFollowingFormatChange`'s decision with a
/// scripted install and format source. (That `InputTap.install` really turns
/// an AVFAudio raise into a Swift error is pinned in the ObjCExceptionCatcher
/// package's own tests, against a real `AVAudioEngine`.)
final class InputTapTests: XCTestCase {

    private struct Refused: Error {}

    private func mono(_ rate: Double) throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
    }

    func test_a_tap_that_installs_first_time_uses_the_format_it_was_given() throws {
        let initial = try mono(48_000)
        var attempts: [Double] = []
        var formatReads = 0
        let used = try InputTap.installFollowingFormatChange(
            initial: initial,
            currentFormat: { formatReads += 1; return initial },
            install: { attempts.append($0.sampleRate) })
        XCTAssertEqual(used, initial)
        XCTAssertEqual(attempts, [48_000])
        XCTAssertEqual(formatReads, 0, "a tap that installed must not re-read the format")
    }

    /// The crash case: the format the bring-up read is stale by the time the
    /// tap goes in. The retry must use what the device reports NOW, and hand
    /// that format back so the converter is built for it.
    func test_a_refused_tap_is_retried_at_the_format_the_device_switched_to() throws {
        let stale = try mono(48_000)
        let switched = try mono(24_000)
        var attempts: [Double] = []
        let used = try InputTap.installFollowingFormatChange(
            initial: stale,
            currentFormat: { switched },
            install: { format in
                attempts.append(format.sampleRate)
                if format == stale { throw Refused() }
            })
        XCTAssertEqual(used, switched)
        XCTAssertEqual(attempts, [48_000, 24_000])
    }

    /// Retrying the same format cannot succeed where it just failed; the
    /// original error must come back so the bring-up fails cleanly.
    func test_a_refused_tap_whose_format_did_not_change_is_not_retried() throws {
        let initial = try mono(48_000)
        var attempts = 0
        XCTAssertThrowsError(try InputTap.installFollowingFormatChange(
            initial: initial,
            currentFormat: { initial },
            install: { _ in attempts += 1; throw Refused() })) { error in
            XCTAssertTrue(error is Refused)
        }
        XCTAssertEqual(attempts, 1)
    }

    /// Mid-switch the node can report "0 ch, 0 Hz" (#147); installing that
    /// would be refused too, or worse, accepted and never deliver a buffer.
    func test_a_refused_tap_is_not_retried_at_an_unusable_format() throws {
        let initial = try mono(48_000)
        let dead = AVAudioFormat()
        XCTAssertEqual(dead.sampleRate, 0)
        var attempts = 0
        XCTAssertThrowsError(try InputTap.installFollowingFormatChange(
            initial: initial,
            currentFormat: { dead },
            install: { _ in attempts += 1; throw Refused() }))
        XCTAssertEqual(attempts, 1)
    }

    /// One retry, not a loop: a format that keeps moving is left to the
    /// caller's failure path (start banner / watchdog rebuild).
    func test_a_retry_that_is_also_refused_throws_after_exactly_two_attempts() throws {
        var rates: [Double] = [24_000, 16_000]
        var attempts = 0
        XCTAssertThrowsError(try InputTap.installFollowingFormatChange(
            initial: try mono(48_000),
            currentFormat: { (try? self.mono(rates.removeFirst())) ?? AVAudioFormat() },
            install: { _ in attempts += 1; throw Refused() }))
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(rates, [16_000], "the format was re-read once, for the single retry")
    }

    /// The banner shows `localizedDescription` verbatim.
    func test_tap_install_error_names_the_device_and_where_to_change_it() {
        let text = MicrophoneError.tapInstallFailed(device: "AirPods Pro").localizedDescription
        XCTAssertTrue(text.hasPrefix("The microphone “AirPods Pro” couldn't be opened."), text)
        XCTAssertTrue(text.contains("Settings → Audio"), text)
        XCTAssertFalse(text.contains("MicrophoneError"), "fell back to Foundation's generic text: \(text)")
    }

    func test_tap_install_error_without_a_chosen_device_still_reads_as_a_sentence() {
        let text = MicrophoneError.tapInstallFailed(device: nil).localizedDescription
        XCTAssertTrue(text.hasPrefix("The microphone couldn't be opened."), text)
    }
}
