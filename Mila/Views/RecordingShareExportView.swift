import AppKit
import SwiftUI

/// Export sheet shown before the save panel when the recording's named
/// speakers have voice profiles to offer. Without any, callers skip the
/// sheet and go straight to the save panel (see `RecordingShareExporter
/// .exportSelection`).
struct RecordingShareExportView: View {
    let recording: Recording
    @Binding var selection: SharedSpeakersExportSelection
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.up.on.square.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share recording")
                        .font(.headline)
                    Text(recording.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Text("The file includes the audio, the transcript with speaker names, and the summary and action items. Anyone with Mila can open it; share it the way you'd share any confidential attachment.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SharedSpeakersExportSection(selection: $selection)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save…", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("share.export.save")
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

/// The opt-in for voice profiles. Default off, never persisted — every
/// share starts from the privacy default Settings promised.
struct SharedSpeakersExportSection: View {
    @Binding var selection: SharedSpeakersExportSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Include voice profiles for the speakers in this recording",
                   isOn: $selection.includeProfiles)
                .accessibilityIdentifier("share.export.voiceProfiles.toggle")

            Text("Mila keeps a voice fingerprint for each speaker you've named — 256 numbers describing how their voice sounds. Normally these stay on this Mac. Ticking this copies the fingerprints for the speakers below into the share file, so the recipient's Mila can recognise them in their own recordings. A fingerprint can't be played back, but it does identify a person — share it only where that's yours to decide.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if selection.includeProfiles {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(selection.available) { profile in
                        Toggle(isOn: Binding(
                            get: { selection.isIncluded(profile) },
                            set: { selection.setIncluded($0, for: profile) }
                        )) {
                            HStack(spacing: 6) {
                                Text(profile.name)
                                Text(profile.sampleCount == 1 ? "1 sample" : "\(profile.sampleCount) samples")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("share.export.voiceProfiles.row.\(profile.name)")
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.4))
                )
            }
        }
    }
}

extension RecordingShareExporter {
    /// Begin the share flow for a recording. Returns a selection to show in
    /// `RecordingShareExportView` when there are voice profiles to offer;
    /// nil means go straight to the save panel. Nothing is offered unless
    /// voice recognition is on AND a named speaker in this recording has a
    /// profile — a feature with nothing to ship should not advertise itself.
    static func exportSelection(for recording: Recording,
                                profiles: SpeakerProfileStore,
                                voiceRecognition: VoiceRecognitionSettings) -> SharedSpeakersExportSelection? {
        guard voiceRecognition.isEnabled else { return nil }
        let available = SharedSpeakerProfileExporter.availableProfiles(for: recording, store: profiles)
        guard !available.isEmpty else { return nil }
        return SharedSpeakersExportSelection(available: available)
    }

    /// Run the save-panel export and show any failure in an alert. The
    /// one-stop call for a menu item or button.
    static func saveInteractively(_ recording: Recording,
                                  store: RecordingStore,
                                  profiles: [SharedSpeakerProfile]) async {
        do {
            _ = try await exportInteractively(recording, store: store, profiles: profiles)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't share the recording"
            alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}

extension View {
    /// Attach the export sheet. `selection` non-nil shows it; Save dismisses
    /// it and runs the save panel with the chosen profiles.
    func recordingShareSheet(selection: Binding<SharedSpeakersExportSelection?>,
                             recording: Recording,
                             store: RecordingStore) -> some View {
        sheet(isPresented: Binding(
            get: { selection.wrappedValue != nil },
            set: { if !$0 { selection.wrappedValue = nil } }
        )) {
            if let current = selection.wrappedValue {
                RecordingShareExportView(
                    recording: recording,
                    selection: Binding(
                        get: { selection.wrappedValue ?? current },
                        set: { selection.wrappedValue = $0 }
                    ),
                    onSave: {
                        let profiles = SharedSpeakerProfileExporter.manifestEntries(
                            selection.wrappedValue ?? current)
                        selection.wrappedValue = nil
                        Task { @MainActor in
                            await RecordingShareExporter.saveInteractively(
                                recording, store: store, profiles: profiles)
                        }
                    },
                    onCancel: { selection.wrappedValue = nil }
                )
            }
        }
    }
}
