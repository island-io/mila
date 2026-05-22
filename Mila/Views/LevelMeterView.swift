import SwiftUI

/// 12-segment LED-style VU meter. Renders the leading N segments based on
/// `level` (0…1), color-graded so the user gets quick visual feedback:
/// green for normal speech, yellow climbing into the upper third, red at
/// the top to warn of clipping.
///
/// Reused by Settings → Audio so the user can verify the chosen input
/// device is actually hearing them before they ever record. Previously
/// lived on the Home screen but cluttered the main page — moving it to
/// Settings keeps Home focused on actions.
struct LevelMeterView: View {
    let level: Float
    /// When false, the meter is dimmed and shows no live bars — used while
    /// the level monitor is paused (e.g. during an active recording, when
    /// the real `MicrophoneRecorder` owns the device).
    let isLive: Bool

    private static let segmentCount = 12

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 3) {
                ForEach(0..<Self.segmentCount, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(for: i))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: geo.size.height)
            .accessibilityElement()
            .accessibilityLabel("Microphone level")
            .accessibilityValue(isLive ? "\(Int(level * 100)) percent" : "off")
        }
        .frame(height: 14)
        .opacity(isLive ? 1.0 : 0.45)
        .animation(.linear(duration: 0.08), value: level)
    }

    private func color(for index: Int) -> Color {
        let active = Int(Float(Self.segmentCount) * level + 0.0001)
        let isActive = index < active
        guard isActive else {
            return Color.primary.opacity(0.08)
        }
        // Color buckets — bottom 8 green, next 2 yellow, top 2 red.
        switch index {
        case 0..<8:  return Color.green.opacity(0.85)
        case 8..<10: return Color.yellow.opacity(0.9)
        default:     return Color.red.opacity(0.9)
        }
    }
}
