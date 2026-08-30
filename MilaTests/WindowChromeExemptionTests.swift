import XCTest
import AppKit
@testable import Mila

/// Unit tests for `MilaAppDelegate.isChromeExempt(identifier:isPanel:)` — the
/// pure decision behind `applyChrome`'s early return.
///
/// The bug this pins (#207): the original guard was
///
/// ```swift
/// if let id = window.identifier?.rawValue,
///    id.contains("settings") || id.contains("alert") { return }
/// ```
///
/// `String.contains` is case-sensitive and SwiftUI names its Settings window
/// `com_apple_SwiftUI_Settings_window` with a capital `S`, so neither arm ever
/// fired. Both `_expectations` below are negative controls that reproduce the
/// old shape and assert it fails, so the passing cases are provably
/// discriminating rather than vacuous.
final class WindowChromeExemptionTests: XCTestCase {

    /// The exact identifier SwiftUI gives the Settings scene, as read from an
    /// XCUITest accessibility dump of the running app:
    ///
    ///     identifier: 'com_apple_SwiftUI_Settings_window', title: 'General'
    private static let settingsIdentifier = "com_apple_SwiftUI_Settings_window"

    // MARK: - Settings

    func test_the_real_swiftui_settings_identifier_is_exempt() {
        XCTAssertTrue(
            MilaAppDelegate.isChromeExempt(identifier: Self.settingsIdentifier, isPanel: false),
            "The Settings window must be left alone — this is the regression in #207."
        )
    }

    /// Negative control: the shape the code used to have. If this ever starts
    /// returning `true`, the case-sensitivity trap has stopped existing and the
    /// test above no longer proves anything.
    func test_the_old_case_sensitive_check_would_have_missed_settings() {
        XCTAssertFalse(
            Self.settingsIdentifier.contains("settings"),
            "A case-sensitive contains(\"settings\") does not match the real identifier; that was the bug."
        )
        XCTAssertTrue(
            Self.settingsIdentifier.lowercased().contains("settings"),
            "Lowercasing first is what makes the guard fire."
        )
    }

    func test_settings_is_matched_regardless_of_case() {
        for id in ["settings", "Settings", "SETTINGS", "com_apple_SwiftUI_Settings_window"] {
            XCTAssertTrue(
                MilaAppDelegate.isChromeExempt(identifier: id, isPanel: false),
                "\(id) should be exempt"
            )
        }
    }

    // MARK: - Panels (the old "alert" arm)

    /// An `NSAlert`'s window is an `_NSAlertPanel` carrying an opaque AppKit
    /// identifier, so it is exempted by class. Asserted against a real
    /// `NSAlert` rather than a hard-coded string, because the identifier is an
    /// AppKit implementation detail that may change between OS versions —
    /// which is precisely why the code no longer matches on it.
    func test_a_real_alert_window_is_exempt_by_being_a_panel() {
        let alert = NSAlert()
        alert.messageText = "probe"
        let window = alert.window

        XCTAssertTrue(window is NSPanel, "NSAlert's window is expected to be an NSPanel")
        XCTAssertTrue(
            MilaAppDelegate.isChromeExempt(identifier: window.identifier?.rawValue,
                                           isPanel: window is NSPanel)
        )
    }

    // Why there is no test asserting that an alert's identifier lacks an
    // "alert" substring, even though that is what killed the old
    // `id.contains("alert")` arm:
    //
    // When this was written, `NSAlert().window.identifier` was `_NS:87` — an
    // opaque AppKit nib id with no recognisable substring in any casing. That
    // observation is why the guard now matches on the panel *class* instead of
    // the identifier. But asserting it in CI would pin an AppKit implementation
    // detail we neither control nor rely on: a macOS update could start
    // including "alert" in that identifier and turn the suite red while
    // `isChromeExempt(identifier:isPanel:)` remained perfectly correct.
    //
    // `test_a_real_alert_window_is_exempt_by_being_a_panel` covers the contract
    // that actually matters — an alert is exempt because it is an `NSPanel` —
    // and it keeps holding whatever AppKit does to the identifier.

    func test_open_and_save_panels_are_exempt() {
        // Typed as NSWindow deliberately: `NSOpenPanel is NSPanel` is
        // statically true and the compiler warns on the tautology, but the
        // production call site only ever has an `NSWindow`, so this exercises
        // the same runtime check that `applyChrome` performs.
        let open: NSWindow = NSOpenPanel()
        XCTAssertTrue(open is NSPanel)
        XCTAssertNil(open.identifier?.rawValue,
                     "Open panels carry no identifier, which is why the old `if let id` guard fell through and restyled them.")
        XCTAssertTrue(
            MilaAppDelegate.isChromeExempt(identifier: open.identifier?.rawValue,
                                           isPanel: open is NSPanel)
        )
    }

    func test_a_panel_with_no_identifier_is_still_exempt() {
        XCTAssertTrue(MilaAppDelegate.isChromeExempt(identifier: nil, isPanel: true))
    }

    // MARK: - The main window must still be styled

    func test_the_main_window_is_not_exempt() {
        // A plain NSWindow with no identifier is the shape the app's own
        // WindowGroup produces; chrome must still be applied to it or the
        // half-divider this method exists to remove comes back.
        XCTAssertFalse(MilaAppDelegate.isChromeExempt(identifier: nil, isPanel: false))
        XCTAssertFalse(MilaAppDelegate.isChromeExempt(identifier: "Mila", isPanel: false))
    }

    /// An opaque AppKit identifier on a non-panel window must not be exempted:
    /// the class check is what identifies panels, and the identifier alone
    /// carries no such signal.
    func test_an_opaque_appkit_identifier_alone_does_not_exempt() {
        XCTAssertFalse(MilaAppDelegate.isChromeExempt(identifier: "_NS:87", isPanel: false))
    }
}
