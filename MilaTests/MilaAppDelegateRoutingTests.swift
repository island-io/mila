import XCTest
@testable import Mila

/// `MilaAppDelegate.application(_:open:)` routes by document type. The
/// routing is a pure function so it can be pinned without AppKit.
final class MilaAppDelegateRoutingTests: XCTestCase {

    func test_partition_routes_by_extension_case_insensitively_and_drops_the_rest() {
        let config = URL(fileURLWithPath: "/tmp/team.milaconfig")
        let configUpper = URL(fileURLWithPath: "/tmp/TEAM.MILACONFIG")
        let share = URL(fileURLWithPath: "/tmp/Weekly sync.milashare")
        let other = URL(fileURLWithPath: "/tmp/notes.txt")
        let audio = URL(fileURLWithPath: "/tmp/memo.wav")

        let (configs, shares) = MilaAppDelegate.partition([config, share, other, configUpper, audio])
        XCTAssertEqual(configs, [config, configUpper])
        XCTAssertEqual(shares, [share])
    }

    func test_partition_of_nothing_relevant_is_empty() {
        let (configs, shares) = MilaAppDelegate.partition([URL(fileURLWithPath: "/tmp/x.zip")])
        XCTAssertTrue(configs.isEmpty)
        XCTAssertTrue(shares.isEmpty)
    }
}
