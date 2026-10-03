import Foundation

/// The playback rates offered by the recording detail screen's speed menu:
/// 0.5× to 2×, in 0.25 steps.
///
/// Modelled as an enum (rather than a bare `Double`) so the menu can only ever
/// offer supported values, and so the label formatting and the snapping in
/// `nearest(to:)` are pure functions that `PlaybackSpeedTests` can pin without
/// building a view or an `AVPlayer`.
enum PlaybackSpeed: Double, CaseIterable, Identifiable {
    case half = 0.5
    case threeQuarters = 0.75
    case normal = 1.0
    case oneAndAQuarter = 1.25
    case oneAndAHalf = 1.5
    case oneAndThreeQuarters = 1.75
    case double = 2.0

    var id: Double { rawValue }

    /// "0.5×", "1×", "1.25×" — whole rates drop the fractional part so the
    /// default reads "1×" rather than "1.0×". Deliberately locale-independent
    /// (`%g` always emits a "." separator) so the menu label and the tests
    /// agree regardless of the user's region.
    var label: String {
        "\(String(format: "%g", rawValue))×"
    }

    /// Snap an arbitrary value to the nearest supported rate, clamping anything
    /// outside 0.5…2.0. The persisted `detail.playback.speed` default is a plain
    /// `Double`, so this guards the menu against a stale or hand-edited value
    /// that no longer matches a case (which would render an empty selection).
    static func nearest(to value: Double) -> PlaybackSpeed {
        guard value.isFinite else { return .normal }
        return allCases.min {
            abs($0.rawValue - value) < abs($1.rawValue - value)
        } ?? .normal
    }
}
