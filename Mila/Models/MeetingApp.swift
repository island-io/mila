import SwiftUI

/// Identifies a well-known meeting app so a saved `Recording` can show an
/// app-specific badge/label. Kept separate from `MeetingDetector.App`
/// (which drives *live* meeting detection via Core Audio bundle IDs)
/// because this type answers a different question — "which app does this
/// already-saved recording look like it came from?" — derived from a
/// recording's `appName`/`title` strings, not from a live process.
enum MeetingApp: String, CaseIterable {
    case zoom
    case teams

    struct Info {
        let displayName: String
        let badgeColor: Color
        /// Lowercased substring checked against a recording's `appName`
        /// (falling back to its `title`) to decide whether this app
        /// produced the recording.
        let matchSubstring: String
    }

    var info: Info {
        switch self {
        case .zoom:
            return Info(
                displayName: "Zoom",
                badgeColor: Color(red: 0.176, green: 0.549, blue: 1.0), // #2D8CFF
                matchSubstring: "zoom"
            )
        case .teams:
            return Info(
                displayName: "Microsoft Teams",
                badgeColor: Color(red: 0.384, green: 0.388, blue: 0.651), // #6264A7
                matchSubstring: "teams"
            )
        }
    }
}
