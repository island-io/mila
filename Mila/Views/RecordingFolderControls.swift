import SwiftUI

/// Isolated leaf views for the recording folder / meeting-name controls.
///
/// These deliberately observe ONLY `RecordingStore` (for the folder list) and
/// `QuickActionsController` (for the bindings) — never the high-frequency
/// `LiveTranscriber` / `TranscriptionService` / `LiveAISession`. That isolation
/// is the whole point: on the live recording screen, the detail view during an
/// active transcription, and the post-stop rename sheet, those objects
/// `@Publish` many times per second. When an interactive `Menu` (backed by a
/// native NSMenu that runs a nested modal event-tracking runloop while open)
/// lives in a body that re-renders at that cadence, the menu host gets
/// reconciled mid-tracking and the whole app beachballs.
///
/// By pulling the controls into leaves whose inputs are constant/stable, the
/// parent body can churn as much as it likes without ever re-invoking these
/// bodies — so the open menu stays untouched. Same rationale as
/// `RecordingElapsedLabel` isolating `RecordingSession`.

/// Folder picker for the NEXT recording (Home + live recording screen). Binds
/// to `QuickActionsController.nextRecordingFolder`, applied when the recording
/// is saved.
struct NextRecordingFolderPicker: View {
    @EnvironmentObject private var store: RecordingStore
    @EnvironmentObject private var actions: QuickActionsController
    let accessibilityID: String

    var body: some View {
        Menu {
            Button(actions.nextRecordingFolder == nil ? "✓ All Transcriptions" : "All Transcriptions") {
                actions.nextRecordingFolder = nil
            }
            if !store.folders.isEmpty {
                Divider()
                ForEach(store.folders, id: \.self) { folder in
                    Button(actions.nextRecordingFolder == folder ? "✓ \(folder)" : folder) {
                        actions.nextRecordingFolder = folder
                    }
                }
            }
        } label: {
            Text(actions.nextRecordingFolder ?? "All Transcriptions")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier(accessibilityID)
    }
}

/// Optional meeting-name field for the NEXT recording (Home + live recording
/// screen). Isolated so typing stays responsive even while the surrounding
/// screen re-renders at transcript cadence. Callers apply `.textFieldStyle` /
/// `.font` via modifiers (both propagate into the inner `TextField` through the
/// environment).
struct NextRecordingMeetingNameField: View {
    @EnvironmentObject private var actions: QuickActionsController
    let placeholder: String
    let accessibilityID: String

    var body: some View {
        TextField(placeholder, text: $actions.nextRecordingTitle)
            .accessibilityIdentifier(accessibilityID)
    }
}

/// Inline folder picker for an EXISTING recording (recording detail view).
/// Files the recording via `store.assign` and offers a "New Folder…" flow. Takes
/// the recording id + its current folder as stable inputs (both only change when
/// the folder actually changes), so an active transcription's progress flood
/// never re-invokes this body.
struct RecordingFolderMenu: View {
    @EnvironmentObject private var store: RecordingStore
    let recordingID: UUID
    let currentFolder: String?

    @State private var showingNewFolderAlert = false
    @State private var newFolderName = ""

    var body: some View {
        Menu {
            Button(currentFolder == nil ? "✓ None" : "None") {
                assign(nil)
            }
            if !store.folders.isEmpty {
                Divider()
                ForEach(store.folders, id: \.self) { folder in
                    Button(currentFolder == folder ? "✓ \(folder)" : folder) {
                        assign(folder)
                    }
                }
            }
            Divider()
            Button("New Folder…") {
                newFolderName = ""
                showingNewFolderAlert = true
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                Text(currentFolder ?? "No folder")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose the folder this recording is filed under")
        .accessibilityIdentifier("detail.folder.menu")
        .alert("New Folder", isPresented: $showingNewFolderAlert) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { assign(name) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("File this recording into a new folder.")
        }
    }

    private func assign(_ folder: String?) {
        guard let rec = store.recordings.first(where: { $0.id == recordingID }) else { return }
        store.assign(rec, toFolder: folder)
    }
}
