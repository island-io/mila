import SwiftUI

enum SidebarSelection: Hashable {
    case home
    case queue
    case category(HistoryCategory)
    case folder(String)
    case recording(Recording.ID)
}

struct SidebarView: View {
    @Binding var selection: SidebarSelection?
    @EnvironmentObject private var store: RecordingStore

    @State private var showingNewFolderSheet = false
    @State private var newFolderName = ""
    @State private var renameTarget: String?
    @State private var renameDraft = ""

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("Home", systemImage: "house")
                    .tag(SidebarSelection.home)
                Label("Queue", systemImage: "list.bullet.rectangle")
                    .tag(SidebarSelection.queue)
            }

            Section("History") {
                ForEach(HistoryCategory.allCases) { cat in
                    Label(cat.displayName, systemImage: cat.sfSymbol)
                        .tag(SidebarSelection.category(cat))
                        .accessibilityIdentifier("sidebar.category.\(cat.rawValue)")
                }
            }

            Section("Folders") {
                ForEach(store.folders, id: \.self) { name in
                    Label(name, systemImage: "folder")
                        .tag(SidebarSelection.folder(name))
                        .contextMenu {
                            Button("Rename Folder…") {
                                renameDraft = name
                                renameTarget = name
                            }
                            Button("Delete Folder", role: .destructive) {
                                store.deleteFolder(name)
                                if case .folder(let sel) = selection, sel == name {
                                    selection = .home
                                }
                            }
                        }
                        .accessibilityIdentifier("sidebar.folder.\(name)")
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                SidebarFooter()
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
                onConfirm: {
                    if let renamed = store.renameFolder(target.name, to: renameDraft) {
                        if case .folder(let sel) = selection, sel == target.name {
                            selection = .folder(renamed)
                        }
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

/// Shared sheet for both creating and renaming folders. Title and confirm
/// button label are parameterized so the same control serves the sidebar
/// "+ New Folder" flow, the per-recording "Move to Folder → New Folder…"
/// flow, and the folder context-menu "Rename Folder…" flow.
struct FolderNameSheet: View {
    let title: String
    let confirmLabel: String
    @Binding var name: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title3.weight(.semibold))
            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onConfirm() }
                .accessibilityIdentifier("folder.name.field")
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

private struct SidebarFooter: View {
    var body: some View {
        SettingsLink {
            Label("Settings…", systemImage: "gear")
                .font(.callout)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
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
