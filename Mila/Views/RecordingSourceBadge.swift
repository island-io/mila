import SwiftUI

/// Standardised "source" glyph for a recording row. Encapsulates the
/// special-case for known meeting apps (Zoom, Microsoft Teams) so every
/// view that lists a recording (history rows, queue rows, detail header,
/// etc.) renders a consistent app-colored camera tile instead of the
/// generic system-audio speaker icon. Plain microphone / system-audio
/// recordings keep their existing tinted SF Symbol.
struct RecordingSourceBadge: View {
    let recording: Recording
    var size: CGFloat = 22

    var body: some View {
        if let app = recording.detectedMeetingApp {
            appBadge(app)
        } else {
            sourceIcon
        }
    }

    private func appBadge(_ app: MeetingApp) -> some View {
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(app.info.badgeColor)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "video.fill")
                    .font(.system(size: size * 0.55, weight: .bold))
                    .foregroundStyle(.white)
            )
            .accessibilityLabel("\(app.info.displayName) recording")
            .help("Recorded from \(app.info.displayName)")
    }

    private var sourceIcon: some View {
        Image(systemName: recording.source.sfSymbol)
            .font(.system(size: size * 0.64, weight: .semibold))
            .foregroundStyle(.tint)
            .frame(width: size, height: size)
    }
}
