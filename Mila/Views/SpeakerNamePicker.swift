import SwiftUI

/// Popover content for renaming a diarized speaker: type-to-filter over
/// the persistent `SpeakerDirectory`, an "Add" row for new names, and a
/// reset row back to the default "Speaker A" label. Shared by the
/// completed-recording detail view and the live transcript pane — the
/// caller decides where the assignment lands via `onAssign`.
struct SpeakerNamePicker: View {
    /// Resolved default label ("Speaker A" / "דובר א׳") shown in the
    /// reset row when a custom name is currently assigned.
    let defaultLabel: String
    /// Name currently assigned to this speaker, nil when unnamed.
    let currentName: String?
    /// Called with the chosen name, or nil to reset to the default label.
    let onAssign: (String?) -> Void

    @EnvironmentObject private var directory: SpeakerDirectory
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var filtered: [String] {
        directory.matches(for: query)
    }

    /// The typed query has no exact (case-insensitive) match in the
    /// directory yet — offer to add it as a brand-new name.
    private var canAddQuery: Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !directory.names.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Name this speaker…", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit(submitQuery)
                .padding(10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered, id: \.self) { name in
                        row {
                            assign(name)
                        } label: {
                            HStack {
                                Text(name).lineLimit(1)
                                Spacer()
                                if name == currentName {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                    if canAddQuery {
                        row {
                            assign(query)
                        } label: {
                            Label("Add \"\(query.trimmingCharacters(in: .whitespacesAndNewlines))\"",
                                  systemImage: "plus.circle.fill")
                                .lineLimit(1)
                        }
                    }
                    if filtered.isEmpty && !canAddQuery {
                        Text("Type a name to add it")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 180)

            if currentName != nil {
                Divider()
                row {
                    onAssign(nil)
                    dismiss()
                } label: {
                    Label("Use default (\(defaultLabel))", systemImage: "arrow.uturn.backward")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 260)
        .onAppear { searchFocused = true }
    }

    /// Enter in the search field: exact match wins, otherwise the top
    /// filtered suggestion, otherwise add the typed name.
    private func submitQuery() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let exact = directory.names.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            assign(exact)
        } else if let top = filtered.first {
            assign(top)
        } else {
            assign(trimmed)
        }
    }

    /// Route every assignment through the directory so names typed here
    /// (not just ones picked from the list) persist for future recordings.
    private func assign(_ name: String) {
        guard let canonical = directory.add(name) else { return }
        onAssign(canonical)
        dismiss()
    }

    private func row<L: View>(action: @escaping () -> Void,
                              @ViewBuilder label: () -> L) -> some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Clickable speaker label used by both transcript panes (recording
/// detail + live). Shows the resolved display name, underlines on hover,
/// and opens `SpeakerNamePicker` in an anchored popover on click. Its
/// own tap gesture takes precedence over any enclosing row gesture
/// (e.g. the detail view's seek-on-tap), so clicking the label never
/// scrubs playback.
struct SpeakerLabelButton: View {
    let rawID: String
    let names: [String: String]
    let language: String
    let color: Color
    /// Text appended after the name — the detail view's tight-prefix
    /// layout uses ":", the live pane's fixed column uses nothing.
    var suffix: String = ""
    var font: Font = .body.weight(.semibold)
    /// Receives the chosen name (nil = reset to the default label);
    /// the caller persists it wherever this transcript's names live.
    let onAssign: (String?) -> Void

    @State private var showingPicker = false
    @State private var hovering = false

    var body: some View {
        Text(rawID.displaySpeakerName(names: names, language: language) + suffix)
            .font(font)
            .foregroundStyle(color)
            .underline(hovering)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { showingPicker = true }
            .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
                SpeakerNamePicker(
                    defaultLabel: rawID.friendlySpeakerLabel(language: language),
                    currentName: names[rawID],
                    onAssign: onAssign
                )
            }
            .help("Rename speaker")
    }
}
