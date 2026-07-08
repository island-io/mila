import SwiftUI
import AppKit

/// The per-recording context menu (Rename / Move to Folder / Re-transcribe /
/// Send to LLM / Export / Reveal / Delete) shared by the "All Transcripts"
/// list rows (`HistoryListView`'s `HistoryRow`) and the sidebar's inline
/// recording sub-rows (`SidebarView`'s `RecordingSubRow`).
///
/// Extracted into a single modifier so the two lists can't drift: the sidebar
/// sub-rows previously carried no context menu at all (issue #62 — a
/// right-click regression), which was only possible because each list built
/// its own menu independently. Both now call
/// `.recordingContextMenu(recording:selection:)`.
///
/// The modifier owns the sheet/dialog state each row needs (rename, new
/// folder, send-to-LLM, permanent-delete confirmation), so callers only pass
/// the recording and the shared `selection` binding (used to navigate away
/// when the currently-selected recording is deleted).
extension View {
    func recordingContextMenu(recording: Recording,
                              selection: Binding<SidebarSelection?>) -> some View {
        modifier(RecordingContextMenu(recording: recording, selection: selection))
    }
}

private struct RecordingContextMenu: ViewModifier {
    let recording: Recording
    @Binding var selection: SidebarSelection?

    @EnvironmentObject private var store: RecordingStore
    @EnvironmentObject private var transcription: TranscriptionService
    @EnvironmentObject private var llm: LLMSettings

    @State private var renameRequest: String?
    @State private var promptForNewFolder = false
    @State private var newFolderDraft = ""
    @State private var showingSendSheet = false
    /// Confirmation gate before "Delete Permanently" actually removes the
    /// files — unlike soft-delete there's no Trash to restore from, and
    /// accidental loss of recordings was the #1 user complaint (same
    /// rationale as the rename sheet's Discard confirm).
    @State private var confirmingPermanentDelete = false

    func body(content: Content) -> some View {
        content
            .contextMenu { menuItems }
            .sheet(item: Binding(
                get: { renameRequest.map(RenameDraft.init) },
                set: { if $0 == nil { renameRequest = nil } }
            )) { draft in
                RenameSheet(
                    initialTitle: draft.title,
                    onConfirm: { newTitle in
                        store.rename(recording, to: newTitle)
                        renameRequest = nil
                    },
                    onCancel: { renameRequest = nil }
                )
            }
            .sheet(isPresented: $promptForNewFolder) {
                FolderNameSheet(
                    title: "New Folder",
                    confirmLabel: "Create",
                    name: $newFolderDraft,
                    onConfirm: {
                        if let created = store.createFolder(newFolderDraft) {
                            store.assign(recording, toFolder: created)
                        }
                        promptForNewFolder = false
                    },
                    onCancel: { promptForNewFolder = false }
                )
            }
            .sheet(isPresented: $showingSendSheet) {
                SendToLLMSheet(recording: recording)
            }
            .confirmationDialog("Delete “\(recording.title)” permanently?",
                                isPresented: $confirmingPermanentDelete,
                                titleVisibility: .visible) {
                Button("Delete Permanently", role: .destructive) {
                    store.permanentlyDelete(recording)
                    if case .recording(let id) = selection, id == recording.id {
                        selection = .home
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("The audio file and any transcript will be permanently deleted. This can't be undone.")
            }
    }

    @ViewBuilder
    private var menuItems: some View {
        if recording.isTrashed {
            Button("Restore") { store.restore(recording) }
            Divider()
            Button("Delete Permanently", role: .destructive) {
                confirmingPermanentDelete = true
            }
        } else {
            Button("Rename…") {
                renameRequest = recording.title
            }
            Menu("Move to Folder") {
                Button(recording.folder == nil ? "✓ None" : "None") {
                    store.assign(recording, toFolder: nil)
                }
                if !store.folders.isEmpty {
                    Divider()
                    ForEach(store.folders, id: \.self) { folder in
                        Button(recording.folder == folder ? "✓ \(folder)" : folder) {
                            store.assign(recording, toFolder: folder)
                        }
                    }
                }
                Divider()
                Button("New Folder…") {
                    newFolderDraft = ""
                    promptForNewFolder = true
                }
            }
            Divider()
            let currentLang = RecordingLanguage.fromCode(recording.language)
            // Busy = this recording is already transcribing or queued. We gate
            // BEFORE mutating the store: `enqueue` drops active/queued ids, but
            // `prepareForRetranscription` persists `.pending`/language first, so
            // without this guard a re-transcribe on a busy row would clobber its
            // status even though the enqueue itself no-ops.
            let isBusy = transcription.activeRecordingID == recording.id
                || transcription.pendingIDs.contains(recording.id)
            Button("Re-transcribe (\(currentLang.flagEmoji) \(currentLang.displayName))") {
                // Route through the live-store chokepoint (same as the
                // language-switch action) so we never enqueue a stale snapshot
                // whose `.wav` a since-run compression already deleted.
                guard !isBusy,
                      let prepared = store.prepareForRetranscription(id: recording.id)
                else { return }
                transcription.enqueue(prepared)
            }
            .disabled(isBusy)
            Button("Re-transcribe in \(currentLang.other.flagEmoji) \(currentLang.other.displayName)") {
                retranscribe(recording, in: currentLang.other)
            }
            .disabled(isBusy)
            if llm.isConfigured {
                Divider()
                Button("Send to \(llm.tool.displayName)…") {
                    showingSendSheet = true
                }
                .disabled(recording.fullText.isEmpty && recording.segments.isEmpty)
            }
            Divider()
            Button("Export Subtitles (.srt)…") {
                exportSRT()
            }
            .disabled(recording.segments.isEmpty)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([store.audioURL(for: recording)])
            }
            Divider()
            Button("Delete", role: .destructive) {
                store.softDelete(recording)
                if case .recording(let id) = selection, id == recording.id {
                    selection = .home
                }
            }
        }
    }

    /// Switch the recording's stored language and re-enqueue it. The
    /// `TranscriptionService` reads `recording.language` to pick the right
    /// model (ivrit.ai for Hebrew, OpenAI for English), so updating the
    /// store before enqueueing is enough to re-run with the other model.
    private func retranscribe(_ recording: Recording, in language: RecordingLanguage) {
        // Gate before mutating the store: a busy (active/queued) recording must
        // not have its status/language flipped under an in-flight pass, because
        // `enqueue` would then no-op the re-run while the store mutation stuck.
        guard transcription.activeRecordingID != recording.id,
              !transcription.pendingIDs.contains(recording.id)
        else { return }
        // Mutate only language+status on the LIVE record so we don't clobber a
        // since-compressed `.m4a` audioFileName back to a deleted `.wav`.
        guard let prepared = store.prepareForRetranscription(id: recording.id,
                                                             language: language.rawValue)
        else { return }
        transcription.enqueue(prepared)
    }

    /// Save the recording's SRT to a user-chosen location. NSSavePanel lets
    /// the user place subtitles next to the original video file (the main
    /// "video → SRT" use case) or anywhere else they like. We use the
    /// title as the suggested filename so dragging a video produces
    /// `MyVideo.srt` next to `MyVideo.mp4` by default.
    private func exportSRT() {
        let panel = NSSavePanel()
        panel.title = "Export Subtitles"
        panel.allowedContentTypes = [.init(filenameExtension: "srt") ?? .data]
        panel.nameFieldStringValue = recording.title + ".srt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try TranscriptExporter.writeSRT(for: recording, to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

private struct RenameDraft: Identifiable {
    let title: String
    var id: String { title }
}
