import SwiftUI

/// The voice-profile part of the import sheet: one row per speaker the
/// sender shared, with what Mila suggests and a menu to change it.
///
/// The menu is always complete — every local profile, "Add as new", "Skip" —
/// so the user can merge an unmatched speaker into whoever they really are,
/// or keep a matched one separate. Only a hard blocker (voice recognition
/// off, an incompatible model) removes the menu, because nothing a choice
/// could do would be honoured.
struct SharedSpeakersImportSection: View {
    @Binding var plan: SpeakerProfileImportPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Voice profiles")
                .font(.callout.weight(.semibold))
            Text(headline)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Scrolls past a few speakers so the sheet never outgrows a small
            // window — a sheet taller than its window is clipped, not shrunk.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach($plan.rows) { $row in
                        SharedSpeakerImportRow(row: $row, threshold: plan.similarityThreshold)
                        if row.id != plan.rows.last?.id { Divider() }
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: 240, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.4))
            )

            Text("Merging folds the sender's voice samples into your profile. Skip keeps the name on the transcript and changes nothing on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headline: String {
        // Every row shares the same gate, so one sentence covers it.
        if let blocker = plan.rows.first?.blocker,
           plan.rows.allSatisfy({ $0.blocker == blocker }),
           blocker == .voiceRecognitionOff || blocker == .voiceRecognitionNotReady {
            let n = plan.rows.count
            return "This file includes voice fingerprints for \(n) speaker\(n == 1 ? "" : "s"). "
                + blocker.message
        }
        return "This file includes voice fingerprints for the speakers below. Choose what to do with each; nothing is written until you click Import."
    }
}

private struct SharedSpeakerImportRow: View {
    @Binding var row: SpeakerProfileImportPlan.Row
    let threshold: Double

    @State private var showingPicker = false

    var body: some View {
        // Name and sample line take the full width; the control sits on its
        // own line below, so a long speaker name or a long profile name can
        // never squeeze the other into a one-character column.
        VStack(alignment: .leading, spacing: 4) {
            Text(row.incoming.name)
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(statusLine)
                .font(.caption)
                .foregroundStyle(warns ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)

            if row.isBlocked {
                Text("Can't import")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                // A button that opens a searchable popover, not a `Menu`: a
                // library with dozens of voice profiles needs type-to-filter,
                // which a menu cannot offer. Same shape as `SpeakerNamePicker`.
                Button {
                    showingPicker = true
                } label: {
                    HStack(spacing: 6) {
                        Text(currentChoiceLabel)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: 320, alignment: .leading)
                .padding(.top, 2)
                .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
                    SharedSpeakerTargetPicker(row: $row)
                }
                .accessibilityIdentifier("share.import.voiceProfiles.action.\(row.incoming.name)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("share.import.voiceProfiles.row.\(row.incoming.name)")
    }

    /// What the button reads when closed: the choice in effect.
    private var currentChoiceLabel: String {
        switch row.target {
        case .merge:
            if let c = row.selectedCandidate {
                return "Merge into “\(c.profile.name)” (\(c.percent)%)"
            }
            return "Merge"
        case .addAsNew(let name):
            return "Add as “\(name)”"
        case .skip:
            return "Skip"
        }
    }

    private var detail: String {
        let samples = row.incoming.sampleCount == 1 ? "1 sample" : "\(row.incoming.sampleCount) samples"
        if row.rawIDs.isEmpty { return "\(samples) · not in this transcript" }
        return "\(samples) · \(row.rawIDs.joined(separator: ", "))"
    }

    /// The suggestion while the user hasn't touched the row; once they pick
    /// something else, describe what THAT will do.
    private var statusLine: String {
        if row.isBlocked { return row.suggestionReason }
        if row.target == row.suggested { return row.suggestionReason }
        switch row.target {
        case .merge:
            if let c = row.selectedCandidate {
                return "Will merge into your “\(c.profile.name)” (\(c.percent)% match)."
            }
            return "Will merge."
        case .addAsNew(let name):
            return "Will add a new voice profile called “\(name)”."
        case .skip:
            return "Will skip — the transcript keeps the name, nothing is stored."
        }
    }

    /// Orange when the merge in effect is below the user's own threshold:
    /// the resolver's name-only suggestion, or a manual pick of a weak match.
    private var warns: Bool {
        guard case .merge = row.target, let c = row.selectedCandidate else { return false }
        return c.similarity < threshold
    }
}

/// Popover for choosing what happens to one shared voice profile:
/// type-to-filter over every local profile (best voice match first, with
/// its percentage), plus "add as new" and "skip". Mirrors
/// `SpeakerNamePicker`, so the two pickers feel like one control.
private struct SharedSpeakerTargetPicker: View {
    @Binding var row: SpeakerProfileImportPlan.Row

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var filtered: [SpeakerProfileImportPlan.Candidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return row.candidates }
        return row.candidates.filter { $0.profile.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search your voice profiles…", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit(submitQuery)
                .padding(10)
                .accessibilityIdentifier("share.import.voiceProfiles.search")

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { candidate in
                        pickerRow(selected: row.target == .merge(into: candidate.id)) {
                            choose(.merge(into: candidate.id))
                        } label: {
                            HStack(spacing: 8) {
                                Text(candidate.profile.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 4)
                                Text("\(candidate.percent)%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(candidate.nameMatches ? .primary : .secondary)
                            }
                        }
                    }
                    if filtered.isEmpty {
                        Text(row.candidates.isEmpty
                             ? "You have no voice profiles yet."
                             : "No profile matches “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 220)

            Divider()
            VStack(alignment: .leading, spacing: 0) {
                pickerRow(selected: row.target == .addAsNew(name: row.suggestedNewName)) {
                    choose(.addAsNew(name: row.suggestedNewName))
                } label: {
                    Label("Add as “\(row.suggestedNewName)”", systemImage: "plus.circle.fill")
                        .lineLimit(1)
                }
                pickerRow(selected: row.target == .skip) {
                    choose(.skip)
                } label: {
                    Label("Skip — keep the name on the transcript only", systemImage: "forward.end")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 320)
        .onAppear { searchFocused = true }
    }

    /// Enter picks the top filtered profile, if any.
    private func submitQuery() {
        if let top = filtered.first { choose(.merge(into: top.id)) }
    }

    private func choose(_ target: SpeakerProfileImportPlan.Target) {
        row.target = target
        dismiss()
    }

    private func pickerRow<L: View>(selected: Bool,
                                    action: @escaping () -> Void,
                                    @ViewBuilder label: () -> L) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                label()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
