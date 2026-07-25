import SwiftUI

/// Directory of all named speakers across the user's recordings.
/// Shows each speaker with their recording count and most recent
/// appearance, and lets the user drill into a speaker's recordings.
struct SpeakersView: View {
    @Binding var selection: SidebarSelection?
    @EnvironmentObject private var store: RecordingStore

    var body: some View {
        Group {
            let speakers = store.allSpeakerNames
            if speakers.isEmpty {
                ContentUnavailableView(
                    "No named speakers",
                    systemImage: "person.3",
                    description: Text("Click a speaker label in any transcription to assign a name. Named speakers will appear here.")
                )
            } else {
                List {
                    ForEach(speakers, id: \.self) { name in
                        let recs = store.recordings(forSpeaker: name)
                        SpeakerRow(
                            name: name,
                            recordingCount: recs.count,
                            lastRecordingDate: recs.map(\.createdAt).max(),
                            recordings: recs,
                            selection: $selection
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Speakers")
    }
}

private struct SpeakerRow: View {
    let name: String
    let recordingCount: Int
    let lastRecordingDate: Date?
    let recordings: [Recording]
    @Binding var selection: SidebarSelection?

    @EnvironmentObject private var store: RecordingStore
    @EnvironmentObject private var profileStore: SpeakerProfileStore
    @State private var isExpanded = false
    @State private var isEditing = false
    @EnvironmentObject private var diarizationSettings: DiarizationSettings
    @State private var nameDraft = ""
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(recordings) { rec in
                Button {
                    selection = .recording(rec.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rec.title)
                                .font(.callout)
                                .lineLimit(1)
                            Text(rec.createdAt,
                                 format: .dateTime.month().day().year().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(formatDuration(rec.duration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } label: {
            HStack {
                Image(systemName: "person.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    if isEditing {
                        TextField("Speaker name", text: $nameDraft)
                            .font(.body.weight(.medium))
                            .textFieldStyle(.roundedBorder)
                            .focused($nameFieldFocused)
                            .onSubmit { commitName() }
                            .onExitCommand { cancelEdit() }
                            .onChange(of: nameFieldFocused) { _, focused in
                                if !focused { commitName() }
                            }
                            .accessibilityIdentifier("speakers.rename.field")
                    } else {
                        Text(name)
                            .font(.body.weight(.medium))
                            .contentShape(Rectangle())
                            .onTapGesture { beginEdit() }
                            .help("Click to rename speaker")
                    }
                    HStack(spacing: 12) {
                        if let state = profileStore.updatingProfiles[name], state.isRunning {
                            VStack(alignment: .leading, spacing: 4) {
                                ProgressView(value: state.progress) {
                                    Text("Extracting voice data…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .progressViewStyle(.linear)
                                Text("\(Int(state.progress * 100))%")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: 200)
                        } else if let state = profileStore.updatingProfiles[name], let status = state.status {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(status.contains("No") ? .orange : .teal)
                                .onAppear {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                                        profileStore.updatingProfiles.removeValue(forKey: name)
                                    }
                                }
                        } else {
                            if profileStore.profileExists(name: name) {
                                Label("Voice profile", systemImage: "waveform.badge.person.crop")
                                    .font(.caption)
                                    .foregroundStyle(.teal)
                            }
                            Text("\(recordingCount) recording\(recordingCount == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let date = lastRecordingDate {
                                Text("Last: \(date, format: .dateTime.month().day())")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .contextMenu {
                Button("Update Voice Profile") {
                    profileStore.updateVoiceProfile(
                        speakerName: name,
                        store: store,
                        pythonPath: diarizationSettings.pythonPath
                    )
                }
                .disabled(profileStore.updatingProfiles[name]?.isRunning == true)
                if profileStore.profileExists(name: name) {
                    Button("Delete Voice Profile", role: .destructive) {
                        profileStore.deleteProfile(name: name)
                    }
                }
            }
        }
    }

    private func beginEdit() {
        nameDraft = name
        isEditing = true
        DispatchQueue.main.async { nameFieldFocused = true }
    }

    private func commitName() {
        guard isEditing else { return }
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reject a rename onto a name another speaker already uses. Both
        // RecordingStore and SpeakerProfileStore key merges/lookups on exact
        // name equality, so renaming onto an existing name would silently fold
        // two different people's recordings together and leave two profiles
        // sharing one name (breaking updateProfile's name-uniqueness). Merging
        // speakers is a deliberate action, not a side effect of a typo'd rename.
        if !trimmed.isEmpty, trimmed != name, !store.allSpeakerNames.contains(trimmed) {
            store.renameSpeakerGlobally(from: name, to: trimmed)
            profileStore.renameProfile(from: name, to: trimmed)
        }
        isEditing = false
    }

    private func cancelEdit() {
        isEditing = false
        nameDraft = name
    }

}
