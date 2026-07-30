import XCTest
@testable import Mila

/// Unit tests for the client-side pre-release guard that backs
/// `UpdaterViewModel.updater(_:shouldProceedWithUpdate:updateCheck:)`.
///
/// Context: `1.9.2-beta.1` was published to the appcast without
/// `<sparkle:channel>beta</sparkle:channel>`, so channel filtering
/// (`allowedChannels(for:)`) couldn't hide it and every user was offered a beta
/// regardless of the opt-in. The delegate now also refuses any update whose
/// version *looks* like a pre-release when the user hasn't opted in, so a
/// mis-tagged feed item can't do that again.
///
/// `UpdaterViewModel` itself is deliberately NOT instantiated here — its `init`
/// builds a real `SPUStandardUpdaterController` and starts Sparkle's scheduled
/// poll. The classification logic is a pure static function precisely so it can
/// be tested without any of that.
final class UpdaterPrereleaseGuardTests: XCTestCase {

    // MARK: - Version classification

    func test_stableVersionIsNotPrerelease() {
        XCTAssertFalse(UpdaterViewModel.isPrerelease("1.9.2"))
    }

    func test_betaVersionIsPrerelease() {
        XCTAssertTrue(UpdaterViewModel.isPrerelease("1.9.2-beta.1"))
    }

    /// Case-insensitive: the tag casing in a feed is not something the client
    /// gets to rely on.
    func test_uppercaseBetaVersionIsPrerelease() {
        XCTAssertTrue(UpdaterViewModel.isPrerelease("1.9.2-BETA.2"))
    }

    func test_releaseCandidateIsPrerelease() {
        XCTAssertTrue(UpdaterViewModel.isPrerelease("1.10.0-rc.1"))
    }

    func test_alphaIsPrerelease() {
        XCTAssertTrue(UpdaterViewModel.isPrerelease("2.0.0-Alpha"))
    }

    /// An empty / unknown version string must never be treated as a beta —
    /// failing closed here would block legitimate stable updates for everyone.
    func test_emptyVersionIsNotPrerelease() {
        XCTAssertFalse(UpdaterViewModel.isPrerelease(""))
    }

    /// The hyphen is load-bearing: a stable version that merely contains one of
    /// the marker words is not a pre-release.
    func test_stableVersionContainingMarkerWordIsNotPrerelease() {
        XCTAssertFalse(UpdaterViewModel.isPrerelease("1.0.0 Alpharetta"))
        XCTAssertFalse(UpdaterViewModel.isPrerelease("1.2.3 (arcade)"))
    }

    // MARK: - Beta opt-in default

    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "UpdaterPrereleaseGuardTests.\(name)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    /// The guard only fires for users who have NOT opted in, so the default
    /// value of the opt-in key matters: it must be false (opted out) for a
    /// user who has never touched the checkbox.
    func test_betaChannelOptInDefaultsToFalse() {
        let defaults = freshDefaults()
        XCTAssertNil(defaults.object(forKey: UpdaterViewModel.betaChannelDefaultsKey))
        XCTAssertFalse(defaults.bool(forKey: UpdaterViewModel.betaChannelDefaultsKey))
    }

    /// Sanity-check the two halves compose the way the delegate uses them:
    /// opted out + pre-release version means "refuse"; anything else means
    /// "proceed". (The delegate itself reads `.standard`, which tests must not
    /// touch, so the composition is exercised against an isolated suite here.)
    func test_refusalConditionMatchesOptInAndVersion() {
        let defaults = freshDefaults()

        func wouldRefuse(_ version: String) -> Bool {
            !defaults.bool(forKey: UpdaterViewModel.betaChannelDefaultsKey)
                && UpdaterViewModel.isPrerelease(version)
        }

        // Opted out (default): betas refused, stable allowed.
        XCTAssertTrue(wouldRefuse("1.9.2-beta.1"))
        XCTAssertFalse(wouldRefuse("1.9.2"))

        // Opted in: nothing is refused.
        defaults.set(true, forKey: UpdaterViewModel.betaChannelDefaultsKey)
        XCTAssertFalse(wouldRefuse("1.9.2-beta.1"))
        XCTAssertFalse(wouldRefuse("1.9.2"))
    }
}
