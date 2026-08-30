import SwiftUI

/// Identifies a well-known meeting app so a saved `Recording` can show an
/// app-specific badge/label. Kept separate from `MeetingDetector.App`
/// (which drives *live* meeting detection via Core Audio bundle IDs)
/// because this type answers a different question — "which app does this
/// already-saved recording look like it came from?" — derived from what the
/// recording persisted at capture time, not from a live process.
enum MeetingApp: String, CaseIterable {
    case zoom
    case teams
    case googleMeet

    struct Info {
        let displayName: String
        let badgeColor: Color
        /// Lowercased bundle-ID prefixes identifying this app. This is the
        /// authoritative signal: it is what Core Audio keys live meeting
        /// detection on (`MeetingDetector.App.captureBundlePrefixes`), it
        /// is not localized, and the user cannot edit it. A prefix rather
        /// than an exact ID because an app may capture under a helper
        /// bundle ID (`us.zoom.*` rather than `us.zoom.xos`).
        let bundleIDPrefixes: [String]
        /// Lowercased substring checked against a recording's `appName`,
        /// and — for capture sources only — its `title`, when no bundle ID
        /// was recorded. A *last-resort* fallback for recordings saved
        /// before `appBundleID` existed, so it must be specific enough that
        /// an unrelated app can't collide with it: `"teams"` alone also
        /// matches "TeamSpeak" and "Dream Teams".
        let matchSubstring: String
    }

    var info: Info {
        switch self {
        case .zoom:
            return Info(
                displayName: "Zoom",
                badgeColor: Color(red: 0.176, green: 0.549, blue: 1.0), // #2D8CFF
                bundleIDPrefixes: ["us.zoom"],
                matchSubstring: "zoom"
            )
        case .teams:
            return Info(
                displayName: "Microsoft Teams",
                badgeColor: Color(red: 0.384, green: 0.388, blue: 0.651), // #6264A7
                bundleIDPrefixes: ["com.microsoft.teams"],
                matchSubstring: "microsoft teams"
            )
        case .googleMeet:
            return Info(
                displayName: "Google Meet",
                badgeColor: Color(red: 0.0, green: 0.682, blue: 0.478), // #00AE7A
                bundleIDPrefixes: [
                    "meet.google.com",
                    "com.google.chrome", "com.apple.safari",
                    "company.thebrowser", "io.island"
                ],
                matchSubstring: "meet.google.com"
            )
        }
    }

    /// The app owning `bundleID`, if any. Matched by prefix, case-
    /// insensitively — bundle IDs are conventionally lowercase but nothing
    /// enforces it.
    static func matching(bundleID: String) -> MeetingApp? {
        let lowered = bundleID.lowercased()
        return allCases.first { app in
            app.info.bundleIDPrefixes.contains { lowered.hasPrefix($0) }
        }
    }

    /// The app whose `matchSubstring` appears in `text`, if any. Only for
    /// the string fallbacks — prefer `matching(bundleID:)` whenever a
    /// bundle ID was recorded.
    static func matching(text: String) -> MeetingApp? {
        let lowered = text.lowercased()
        return allCases.first { lowered.contains($0.info.matchSubstring) }
    }
}
