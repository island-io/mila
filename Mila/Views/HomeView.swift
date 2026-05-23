import SwiftUI

/// Home is intentionally bare: the wordmark, a one-line tagline, and a
/// single big Record button with an "also record app audio" toggle
/// underneath. Everything else (file import, app audio picker, video
/// subtitling) moved to the sidebar's More page; the Recent list and
/// the dictation-hotkeys card both moved off Home — hotkeys live in
/// the toolbar now, recordings live in the All Transcriptions folder.
struct HomeView: View {
    @EnvironmentObject private var actions: QuickActionsController
    @EnvironmentObject private var languageSettings: RecordingLanguageSettings

    @Binding var selection: SidebarSelection?
    let search: String

    /// User's preference for capturing the system's audio mix alongside
    /// the mic. Defaults to ON because the main use case is meeting /
    /// content transcription; mic-only dictation users untick it once
    /// and the choice sticks across launches.
    @AppStorage("home.record.withSystemAudio") private var withSystemAudio: Bool = true

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            VStack(spacing: 28) {
                header
                heroAction
                appAudioToggle
            }
            .padding(.horizontal, 24)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Wordmark: "Mila" + a small "by Island" credit to the right at the
    /// .lastTextBaseline so the small caps sit flush with the bottom of
    /// the big wordmark. One-liner tagline below.
    private var header: some View {
        VStack(spacing: 6) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text("Mila")
                    .font(.system(size: 36, weight: .semibold))
                Text("by Island")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text("Record, dictate, and transcribe locally on your Mac.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    /// The single primary CTA. Hands off to QuickActionsController
    /// which chooses mic-only vs mic+system based on the checkbox.
    private var heroAction: some View {
        HeroRecordButton(
            isRecording: isRecording,
            languageFlag: languageSettings.current.flagEmoji,
            languageName: languageSettings.current.displayName,
            withSystemAudio: withSystemAudio
        ) {
            Task { await actions.toggleRecord(withSystemAudio: withSystemAudio) }
        }
        .frame(maxWidth: 460)
    }

    /// Small toggle below the Record button. Default-on. Disabled while
    /// a recording is in flight so the user can't change the mode
    /// mid-capture (the engine is already running against the chosen
    /// source pair).
    private var appAudioToggle: some View {
        Toggle(isOn: $withSystemAudio) {
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.callout)
                    .foregroundStyle(.tint)
                Text("Also record app audio")
                    .font(.callout)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(isRecording)
        .frame(maxWidth: 460, alignment: .center)
        .help("Capture audio from any app playing on this Mac alongside your microphone. Required for meeting / video transcription.")
        .accessibilityIdentifier("home.record.appaudio.toggle")
    }

    private var isRecording: Bool {
        actions.isRecording
    }
}

/// Big primary "Record" CTA. Idle state uses the system accent; the
/// active state flips to red with a pulsing ring so it's obvious at a
/// glance whether you're recording. Includes a small badge in the
/// caption line indicating whether app audio is part of this capture.
private struct HeroRecordButton: View {
    let isRecording: Bool
    let languageFlag: String
    let languageName: String
    let withSystemAudio: Bool
    let action: () -> Void

    @State private var hovering = false
    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.18))
                        .frame(width: 56, height: 56)
                    if isRecording {
                        Circle()
                            .stroke(Color.white.opacity(0.5), lineWidth: 2)
                            .frame(width: 56, height: 56)
                            .scaleEffect(pulse ? 1.6 : 1.0)
                            .opacity(pulse ? 0 : 0.9)
                    }
                    Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(isRecording ? "Recording…" : "Record")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                    HStack(spacing: 6) {
                        Text(languageFlag)
                            .font(.callout)
                        Text(captionText)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: backgroundColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(hovering ? 0.25 : 0.12), lineWidth: 1)
            )
            .shadow(color: shadowColor, radius: hovering ? 14 : 8, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.record.hero")
        .onHover { hovering = $0 }
        .onAppear { startPulseIfNeeded() }
        .onChange(of: isRecording) { _, _ in startPulseIfNeeded() }
    }

    private var captionText: String {
        if isRecording {
            return "Tap to stop"
        }
        let mode = withSystemAudio ? "Mic + app audio" : "Mic only"
        return "\(mode) · \(languageName)"
    }

    private var backgroundColors: [Color] {
        if isRecording {
            return [Color(red: 0.93, green: 0.27, blue: 0.27),
                    Color(red: 0.78, green: 0.18, blue: 0.18)]
        }
        return [Color.accentColor,
                Color.accentColor.opacity(0.78)]
    }

    private var shadowColor: Color {
        isRecording ? Color.red.opacity(0.35) : Color.accentColor.opacity(0.35)
    }

    private func startPulseIfNeeded() {
        guard isRecording else { pulse = false; return }
        pulse = false
        withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
            pulse = true
        }
    }
}
