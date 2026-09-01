import SwiftUI

/// One of the *other* speakers in the same transcript, offered as a target
/// for moving a single line or for merging a whole speaker.
struct SpeakerChoice: Identifiable, Equatable {
    /// The raw `SPEAKER_NN` id the store writes.
    let rawID: String
    /// What the transcript shows for them — a user-assigned name, or the
    /// localized "Speaker A" fallback.
    let displayName: String
    var id: String { rawID }
}

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
    /// Split this segment into a new speaker. Nil when not applicable
    /// (live transcript, or segment has no speaker).
    var onSplit: (() -> Void)?
    /// The other speakers in this transcript, as targets for the two
    /// correction actions below. Empty in the live pane.
    var otherSpeakers: [SpeakerChoice] = []
    /// Move just this line to another speaker — the diarizer mis-tagged one
    /// utterance. Receives the target's raw id.
    var onMoveLine: ((String) -> Void)?
    /// **Request** a merge of this speaker into another — the diarizer split
    /// one person in two. Receives the target's raw id.
    ///
    /// A request, not the merge: it is destructive and has no undo, so it is
    /// confirmed by the view that owns the transcript. Confirming here would
    /// mean presenting an alert from inside a popover that the same tap
    /// dismisses, which is what made the previous attempt at this feature
    /// drop the action (island-io/mila#237).
    var onRequestMerge: ((String) -> Void)?

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

            if currentName != nil || onSplit != nil {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    if currentName != nil {
                        row {
                            onAssign(nil)
                            dismiss()
                        } label: {
                            Label("Use default (\(defaultLabel))", systemImage: "arrow.uturn.backward")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    if onSplit != nil {
                        row {
                            onSplit?()
                            dismiss()
                        } label: {
                            Label("Split this line", systemImage: "arrow.triangle.branch")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            if !otherSpeakers.isEmpty, onMoveLine != nil || onRequestMerge != nil {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    if let onMoveLine {
                        speakerTargetMenu(
                            title: "Move this line to…",
                            systemImage: "arrow.turn.down.right"
                        ) { target in
                            onMoveLine(target)
                            dismiss()
                        }
                    }
                    if let onRequestMerge {
                        speakerTargetMenu(
                            title: "Merge all these lines into…",
                            systemImage: "arrow.triangle.merge"
                        ) { target in
                            onRequestMerge(target)
                            dismiss()
                        }
                    }
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

    /// A submenu of the other speakers. A `Menu` rather than a flat list of
    /// rows so a recording with six speakers doesn't push the naming UI —
    /// what the popover is actually for — off the bottom.
    private func speakerTargetMenu(title: String,
                                   systemImage: String,
                                   pick: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(otherSpeakers) { choice in
                Button(choice.displayName) { pick(choice.rawID) }
            }
        } label: {
            Label(title, systemImage: systemImage)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        // `.borderlessButton` is the obvious spelling and is deprecated as of
        // macOS 13 in favour of exactly this pair.
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
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
    /// Split this segment into a new speaker.
    var onSplit: (() -> Void)?
    /// Other speakers in the same transcript, and the two correction actions
    /// they are targets for. All empty/nil in the live pane, which has no
    /// stable segment identity to move around.
    var otherSpeakers: [SpeakerChoice] = []
    var onMoveLine: ((String) -> Void)?
    var onRequestMerge: ((String) -> Void)?

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
                    onAssign: onAssign,
                    onSplit: onSplit,
                    otherSpeakers: otherSpeakers,
                    onMoveLine: onMoveLine,
                    onRequestMerge: onRequestMerge
                )
            }
            .help("Rename speaker")
    }
}
