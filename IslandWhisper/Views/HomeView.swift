import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var actions: QuickActionsController
    @EnvironmentObject private var store: RecordingStore

    @Binding var selection: SidebarSelection?
    let search: String

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                tiles
                recent
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("Island Whisper")
                .font(.system(size: 32, weight: .semibold))
            Text("Record, dictate, and transcribe locally on your Mac.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private var tiles: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 16)],
            spacing: 16
        ) {
            HomeTile(
                icon: "mic.fill",
                label: isRecordingMic ? "Recording…" : "Voice Memo",
                isActive: isRecordingMic
            ) {
                Task { await actions.toggleVoiceMemo() }
            }

            HomeTile(icon: "folder", label: "Open Files") {
                Task { await actions.openFiles() }
            }

            HomeTile(icon: "speaker.wave.3.fill", label: "App Audio") {
                Task { await actions.presentAppPicker() }
            }
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent")
                    .font(.title3.weight(.semibold))
                Spacer()
            }

            BucketedRecordingsView(
                recordings: recentRecordings,
                search: search,
                selection: $selection
            )
        }
    }

    private var isRecordingMic: Bool {
        actions.activeJob == .recordingMic
    }

    private var recentRecordings: [Recording] {
        Array(store.recordings.filter { !$0.isTrashed }.prefix(30))
    }
}

private struct HomeTile: View {
    let icon: String
    let label: String
    var isActive: Bool = false
    let action: () -> Void

    @State private var hovering = false
    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(isActive ? Color.red : Color.primary.opacity(0.85))
                        .frame(width: 48, height: 38)

                    if isActive {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                            .scaleEffect(pulse ? 1.6 : 1.0)
                            .opacity(pulse ? 0 : 1)
                            .offset(x: 8, y: -2)
                    }
                }

                Text(label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 100)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onAppear { startPulseIfNeeded() }
        .onChange(of: isActive) { _, _ in startPulseIfNeeded() }
    }

    private var borderColor: Color {
        if isActive { return Color.red.opacity(0.6) }
        if hovering { return Color.accentColor.opacity(0.7) }
        return Color.primary.opacity(0.07)
    }

    private func startPulseIfNeeded() {
        guard isActive else { pulse = false; return }
        pulse = false
        withAnimation(.easeOut(duration: 0.9).repeatForever(autoreverses: false)) {
            pulse = true
        }
    }
}
