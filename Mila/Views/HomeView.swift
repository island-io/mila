import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var actions: QuickActionsController
    @EnvironmentObject private var store: RecordingStore
    @EnvironmentObject private var hotkeySettings: HotkeySettings
    @EnvironmentObject private var languageSettings: RecordingLanguageSettings

    @Binding var selection: SidebarSelection?
    let search: String

    /// Persisted across launches so the user's privacy choice (hide the
    /// Recent list while screen-sharing) sticks.
    @AppStorage("home.hideRecent") private var hideRecent: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                tiles
                hotkeysCard
                recent
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("Mila")
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
                isActive: isRecordingMic,
                badge: languageSettings.current.flagEmoji
            ) {
                Task { await actions.toggleVoiceMemo() }
            }

            HomeTile(icon: "folder", label: "Open Files") {
                Task { await actions.openFiles() }
            }

            HomeTile(icon: "speaker.wave.3.fill", label: "App Audio") {
                Task { await actions.presentAppPicker() }
            }

            HomeTile(icon: "captions.bubble", label: "Subtitle Video…") {
                Task { await actions.subtitleVideo() }
            }
        }
    }

    /// Always-visible card that documents the two dictation hotkeys so the
    /// user doesn't have to open Settings to remember which ⌘ combo does
    /// what. The bindings stay live — if a user rebinds in Settings the
    /// glyphs here update immediately.
    private var hotkeysCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "command.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("Dictation hotkeys")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("Press anywhere in macOS")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                HotkeyChip(flag: "🇬🇧",
                           label: "English dictation",
                           binding: hotkeySettings.binding(for: .dictateEnglish).displayName)
                HotkeyChip(flag: "🇮🇱",
                           label: "Hebrew dictation",
                           binding: hotkeySettings.binding(for: .dictateHebrew).displayName)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        hideRecent.toggle()
                    }
                } label: {
                    Label(hideRecent ? "Show" : "Hide",
                          systemImage: hideRecent ? "eye.slash" : "eye")
                        .labelStyle(.titleAndIcon)
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .help(hideRecent
                      ? "Show recent recordings"
                      : "Hide recent recordings (useful when sharing your screen)")
            }

            if hideRecent {
                hiddenPlaceholder
            } else {
                BucketedRecordingsView(
                    recordings: recentRecordings,
                    search: search,
                    selection: $selection
                )
            }
        }
    }

    /// Empty-state replacement when the user has hidden the Recent list.
    /// Keeps a visible affordance so it's obvious the list is hidden, not
    /// just empty.
    private var hiddenPlaceholder: some View {
        HStack(spacing: 10) {
            Image(systemName: "eye.slash.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Recent recordings hidden")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
        )
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
    /// Optional emoji shown in the upper-right of the tile (we use it to
    /// expose the active recording language flag on the Voice Memo tile).
    var badge: String? = nil
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
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Text(badge)
                        .font(.system(size: 16))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.thinMaterial, in: Capsule())
                        .padding(8)
                }
            }
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

/// Visual chip used inside `hotkeysCard` to show one (flag, label, hotkey)
/// triple in a compact row.
private struct HotkeyChip: View {
    let flag: String
    let label: String
    let binding: String

    var body: some View {
        HStack(spacing: 10) {
            Text(flag)
                .font(.system(size: 22))
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.callout.weight(.medium))
                Text(binding)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.tint)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}
