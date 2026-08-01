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
        XCTAssertFalse(UpdaterViewModel.isPrerelease("1.0.0-superbeta"))
    }

    /// …and so is the *trailing* boundary. A label that merely starts with a
    /// marker is a different, unknown token — and unknown must fail OPEN, not
    /// get refused as a beta. Regression guard for the substring matcher that
    /// classified `-betamax` as a pre-release.
    func test_unknownLabelStartingWithMarkerIsNotPrerelease() {
        XCTAssertFalse(UpdaterViewModel.isPrerelease("1.0.0-betamax"))
        XCTAssertFalse(UpdaterViewModel.isPrerelease("1.0.0-alphabet"))
        XCTAssertFalse(UpdaterViewModel.isPrerelease("1.0.0-rcon"))
        XCTAssertFalse(UpdaterViewModel.isPrerelease("2.0.0-BETAMAX"))
    }

    /// The trailing guard must not cost us real spellings: any non-letter
    /// (including a digit) terminates the marker token.
    func test_markerTokenTerminatorsStillMatch() {
        for version in [
            "1.9.2-beta",     // end of string
            "1.9.2-beta1",    // digit
            "1.9.2-beta.1",   // dot
            "1.9.2-beta-1",   // hyphen
            "1.9.2-beta+42",  // build metadata
            "1.10.0-rc",
            "1.10.0-rc2",
            "2.0.0-alpha.3",
        ] {
            XCTAssertTrue(
                UpdaterViewModel.isPrerelease(version),
                "\(version) should be classified as a pre-release"
            )
        }
    }

    /// A string can hold both an unknown marker-prefixed label and a real
    /// marker token; the scan must keep looking past the first near-miss.
    func test_markerFoundAfterANearMissStillMatches() {
        XCTAssertTrue(UpdaterViewModel.isPrerelease("1.0.0-betamax-beta.2"))
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
