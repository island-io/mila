import SwiftUI
import UniformTypeIdentifiers

enum SidebarSelection: Hashable {
    case home
    case queue
    /// Lower-priority entry points (Open Files / App Audio / Subtitle
    /// Video) live behind a single "More" page so Home stays focused
    /// on the one big Record button.
    case more
    case category(HistoryCategory)
    /// Catch-all view for recordings the user hasn't filed anywhere
    /// yet — labelled "All Transcriptions" in the sidebar so users
    /// immediately know it's the place to look for transcripts.
    case defaultFolder
    case folder(String)
    case recording(Recording.ID)
}

/// Wire payload for drag-and-drop of recordings from a list row onto a
/// sidebar folder. Transferable-conforming so SwiftUI's `.draggable` /
/// `.dropDestination` can carry it without manual NSItemProvider plumbing.
struct RecordingDragPayload: Codable, Transferable, Hashable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .islandWhisperRecording)
    }
}

extension UTType {
    static let islandWhisperRecording = UTType(exportedAs: "io.island.whisper.recording")
}

struct SidebarView: View {
    @Binding var selection: SidebarSelection?
    @EnvironmentObject private var store: RecordingStore

    @State private var showingNewFolderSheet = false
    @State private var newFolderName = ""
    @State private var renameTarget: String?
    @State private var renameDraft = ""
    /// Inline error shown in the rename sheet when `store.renameFolder`
    /// rejects the new name (collision). Kept here so the sheet can stay
    /// open instead of silently no-op'ing and closing.
    @State private var renameError: String?

    /// Whether the "All Transcriptions" section is expanded to show its
    /// recordings inline. Persisted so the user's choice survives app
    /// launches (issue #28).
    @AppStorage("sidebar.allTranscriptions.expanded")
    private var allTranscriptionsExpanded = false

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("Home", systemImage: "house")
                    .tag(SidebarSelection.home)
                Label("Queue", systemImage: "list.bullet.rectangle")
                    .tag(SidebarSelection.queue)
                Label("More", systemImage: "ellipsis.circle")
                    .tag(SidebarSelection.more)
            }

            Section("Folders") {
                // "All Transcriptions" is a virtual folder for unfiled
                // recordings (folder == nil). Lives under "Folders" but is
                // labeled descriptively so first-time users know that's
                // where their transcripts show up.
                //
                // It doubles as a collapsible section (issue #28): the
                // disclosure triangle expands an inline list of the
                // recordings so the user can jump straight to one without
                // first landing on the all-recordings page. Tapping the
                // row body still navigates to that page (tag ==
                // .defaultFolder); only the triangle toggles expansion.
                let unfiled = store.unfiledRecordings()
                AllTranscriptionsRow(
                    expanded: $allTranscriptionsExpanded,
                    hasRecordings: !unfiled.isEmpty
                ) { payload in
                    if let id = payload?.id,
                       let rec = store.recordings.first(where: { $0.id == id }) {
                        store.assign(rec, toFolder: nil)
                    }
                }

                if allTranscriptionsExpanded {
                    ForEach(unfiled) { rec in
                        RecordingSubRow(recording: rec)
                    }
                }

                ForEach(store.folders, id: \.self) { name in
                    folderRow(label: name,
                              systemImage: "folder",
                              selection: .folder(name),
                              identifier: "sidebar.folder.\(name)") { payload in
                        if let id = payload?.id,
                           let rec = store.recordings.first(where: { $0.id == id }) {
                            store.assign(rec, toFolder: name)
                        }
                    }
                    .contextMenu {
                        Button("Rename Folder…") {
                            renameDraft = name
                            renameError = nil
                            renameTarget = name
                        }
                        Button("Delete Folder", role: .destructive) {
                            store.deleteFolder(name)
                            if case .folder(let sel) = selection, sel == name {
                                selection = .defaultFolder
                            }
                        }
                    }
                }

                // The new-folder trigger lives as a plain List row instead of
                // a Section-header button: SwiftUI's macOS sidebar paints
                // section headers as decorations and does not route hit-tests
                // there reliably (the XCUITest run on macos-15 could find the
                // button by identifier but the click never produced a sheet).
                Label("New Folder…", systemImage: "plus.circle")
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        newFolderName = ""
                        showingNewFolderSheet = true
                    }
                    .accessibilityIdentifier("sidebar.folders.new")
            }
        }
        .listStyle(.sidebar)
        // (The sidebar's color used to drift to match whatever was
        // behind the window because macOS draws it with a
        // `.behindWindow`-blended NSVisualEffectView. The fix is in
        // the AppDelegate's applyChrome — it walks the split view's
        // sidebar pane and switches the visual-effect view to
        // `.withinWindow` so the material no longer samples
        // cross-app content. We don't slap a solid SwiftUI background
        // here because that flattens the floating-card look that
        // macOS Tahoe gives the sidebar.)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                SidebarFooter(selection: $selection,
                              trashCount: store.recordings(in: .recentlyDeleted).count)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .background(.bar)
        }
        .sheet(isPresented: $showingNewFolderSheet) {
            FolderNameSheet(
                title: "New Folder",
                confirmLabel: "Create",
                name: $newFolderName,
                onConfirm: {
                    if let created = store.createFolder(newFolderName) {
                        selection = .folder(created)
                    }
                    showingNewFolderSheet = false
                },
                onCancel: { showingNewFolderSheet = false }
            )
        }
        .sheet(item: Binding(
            get: { renameTarget.map(FolderRenameTarget.init) },
            set: { if $0 == nil { renameTarget = nil } }
        )) { target in
            FolderNameSheet(
                title: "Rename Folder",
                confirmLabel: "Rename",
                name: $renameDraft,
                errorText: $renameError,
                onConfirm: {
                    // nil = rejected (name collides with an existing
                    // folder). Keep the sheet open with an inline error
                    // instead of silently closing as if it worked.
                    guard let renamed = store.renameFolder(target.name, to: renameDraft) else {
                        renameError = "A folder with that name already exists."
                        return
                    }
                    if case .folder(let sel) = selection, sel == target.name {
                        selection = .folder(renamed)
                    }
                    renameTarget = nil
                },
                onCancel: { renameTarget = nil }
            )
        }
    }
}

private struct FolderRenameTarget: Identifiable {
    let name: String
    var id: String { name }
}

extension SidebarView {
    /// Builds one folder row that's both selectable (drives the detail
    /// view) and a drop destination for dragged recording rows. Tagging
    /// the underlying `Label` is what lets SwiftUI's List selection
    /// recognise it; the `.dropDestination` modifier carries the assign
    /// callback so each folder knows what to do when something lands on
    /// it. The `isTargeted` parameter on `.dropDestination` is wired into
    /// a subtle background tint so the user gets feedback while dragging.
    @ViewBuilder
    func folderRow(label: String,
                   systemImage: String,
                   selection: SidebarSelection,
                   identifier: String,
                   onDrop: @escaping (RecordingDragPayload?) -> Void) -> some View {
        FolderRow(label: label,
                  systemImage: systemImage,
                  selection: selection,
                  identifier: identifier,
                  onDrop: onDrop)
    }
}

/// Stateful inner view so each row owns its own `isTargeted` flag — putting
/// the flag on `SidebarView` would make every folder light up at once.
///
/// **Layout note:** SwiftUI's `.dropDestination` on a bare `Label` inside a
/// `List` only registers a hit area the size of the icon + text glyphs,
/// which is impossible to land on with a real drag. Wrapping the label in
/// an HStack with a full-width spacer + an explicit `.contentShape` makes
/// the entire row width the drop target, which is what users expect from
/// a sidebar.
private struct FolderRow: View {
    let label: String
    let systemImage: String
    let selection: SidebarSelection
    let identifier: String
    let onDrop: (RecordingDragPayload?) -> Void

    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 6) {
            Label(label, systemImage: systemImage)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .dropDestination(for: RecordingDragPayload.self) { items, _ in
            guard let first = items.first else { return false }
            onDrop(first)
            return true
        } isTargeted: { isTargeted = $0 }
        .tag(selection)
        .accessibilityIdentifier(identifier)
        .listRowBackground(
            isTargeted
                ? Color.accentColor.opacity(0.18)
                : Color.clear
        )
    }
}

/// Header row for the collapsible "All Transcriptions" section (issue #28).
///
/// Mirrors `FolderRow` (selectable + drop destination for unfiling a dragged
/// recording) but prefixes a disclosure triangle that toggles the inline
/// recording list independently of selection. The triangle is a `.plain`
/// Button so clicking it flips `expanded` without also selecting the row;
/// clicking anywhere else on the row falls through to List selection and
/// navigates to `.defaultFolder`, exactly as the old plain row did.
private struct AllTranscriptionsRow: View {
    @Binding var expanded: Bool
    /// When there are no unfiled recordings the triangle is hidden (but its
    /// space is kept) so the label stays aligned with the sibling folders.
    let hasRecordings: Bool
    let onDrop: (RecordingDragPayload?) -> Void

    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasRecordings)
            .opacity(hasRecordings ? 1 : 0)
            .help(expanded ? "Hide recordings" : "Show recordings")
            .accessibilityIdentifier("sidebar.folder.default.disclosure")

            Label("All Transcriptions", systemImage: "tray.full")
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .dropDestination(for: RecordingDragPayload.self) { items, _ in
            guard let first = items.first else { return false }
            onDrop(first)
            return true
        } isTargeted: { isTargeted = $0 }
        .tag(SidebarSelection.defaultFolder)
        .accessibilityIdentifier("sidebar.folder.default")
        .listRowBackground(
            isTargeted
                ? Color.accentColor.opacity(0.18)
                : Color.clear
        )
    }
}

/// Inline sub-row shown under an expanded "All Transcriptions" (issue #28):
/// the recording title as primary text with a smaller, gray timestamp
/// beneath it. Tagged `.recording(id)` so List selection drives navigation
/// straight to the transcript page, and `.draggable` so it can still be
/// filed into a folder by dragging — same payload the history rows use.
private struct RecordingSubRow: View {
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(recording.title)
                .font(.callout)
                .lineLimit(1)
            Text(recording.createdAt,
                 format: .dateTime.month().day().hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // Indent so the sub-rows read as children of the section header
        // rather than peers of the folder rows.
        .padding(.leading, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .tag(SidebarSelection.recording(recording.id))
        .draggable(RecordingDragPayload(id: recording.id))
        .accessibilityIdentifier("sidebar.recording.\(recording.title)")
    }
}

/// Shared sheet for both creating and renaming folders. Title and confirm
/// button label are parameterized so the same control serves the sidebar
/// "+ New Folder" flow, the per-recording "Move to Folder → New Folder…"
/// flow, and the folder context-menu "Rename Folder…" flow.
struct FolderNameSheet: View {
    let title: String
    let confirmLabel: String
    @Binding var name: String
    /// Inline validation message (e.g. a rename collision). Owned by the
    /// presenting view — its confirm handler sets it and keeps the sheet
    /// open; the sheet clears it as soon as the user edits the name.
    /// Defaults to a constant nil so the create-folder call sites (which
    /// have no failure mode to surface) don't have to thread state through.
    @Binding var errorText: String?
    let onConfirm: () -> Void
    let onCancel: () -> Void

    init(title: String,
         confirmLabel: String,
         name: Binding<String>,
         errorText: Binding<String?> = .constant(nil),
         onConfirm: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        self.title = title
        self.confirmLabel = confirmLabel
        self._name = name
        self._errorText = errorText
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title3.weight(.semibold))
            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                // Return must behave like the confirm button below — without
                // the guard it fired onConfirm on a blank name the disabled
                // button was there to prevent.
                .onSubmit {
                    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    onConfirm()
                }
                .onChange(of: name) { _, _ in errorText = nil }
                .accessibilityIdentifier("folder.name.field")
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("folder.name.error")
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("folder.name.confirm")
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

/// Footer pinned to the bottom-left of the sidebar. Hosts the "Trash"
/// entry (moved out of the main folder list so it's never in the way) and
/// the Settings link. Trash is also a drop destination — dragging a row
/// onto it soft-deletes the recording.
private struct SidebarFooter: View {
    @Binding var selection: SidebarSelection?
    let trashCount: Int

    @EnvironmentObject private var store: RecordingStore
    @State private var trashTargeted = false

    var body: some View {
        // Settings sits ABOVE Trash now: the user expects Settings as
        // the always-available system anchor (the typical macOS
        // "left bottom" position for app settings) with Trash as a
        // less-frequently-used row beneath it. The previous order
        // (Trash on top, Settings on bottom) put the destructive row
        // higher than the system row, which felt inverted.
        VStack(alignment: .leading, spacing: 4) {
            SettingsLink {
                HStack(spacing: 8) {
                    Image(systemName: "gear")
                        .frame(width: 18)
                    Text("Settings")
                        .font(.callout)
                    Spacer()
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button {
                selection = .category(.recentlyDeleted)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "trash")
                        .frame(width: 18)
                    Text("Trash")
                        .font(.callout)
                    Spacer()
                    if trashCount > 0 {
                        Text("\(trashCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    trashTargeted
                        ? Color.red.opacity(0.18)
                        : (isSelectingTrash
                           ? Color.accentColor.opacity(0.18)
                           : Color.clear),
                    in: RoundedRectangle(cornerRadius: 6)
                )
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("sidebar.trash")
            .dropDestination(for: RecordingDragPayload.self) { items, _ in
                if let id = items.first?.id,
                   let rec = store.recordings.first(where: { $0.id == id }) {
                    store.softDelete(rec)
                    return true
                }
                return false
            } isTargeted: { trashTargeted = $0 }
        }
    }

    private var isSelectingTrash: Bool {
        if case .category(.recentlyDeleted) = selection { return true }
        return false
    }
}

func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    } else {
        return String(format: "%d:%02d", m, s)
    }
}
