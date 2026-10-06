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

            VStack(alignment: .leading, spacing: 10) {
                ForEach($plan.rows) { $row in
                    SharedSpeakerImportRow(row: $row, threshold: plan.similarityThreshold)
                    if row.id != plan.rows.last?.id { Divider() }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.incoming.name)
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(warns ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if row.isBlocked {
                Text("Can't import")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Picker("", selection: $row.target) {
                    ForEach(row.candidates) { candidate in
                        Text("Merge into “\(candidate.profile.name)” (\(candidate.percent)%)")
                            .tag(SpeakerProfileImportPlan.Target.merge(into: candidate.id))
                    }
                    if !row.candidates.isEmpty { Divider() }
                    Text("Add as “\(row.suggestedNewName)”")
                        .tag(SpeakerProfileImportPlan.Target.addAsNew(name: row.suggestedNewName))
                    Text("Skip")
                        .tag(SpeakerProfileImportPlan.Target.skip)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("share.import.voiceProfiles.action.\(row.incoming.name)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("share.import.voiceProfiles.row.\(row.incoming.name)")
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
