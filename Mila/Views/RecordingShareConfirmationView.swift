import SwiftUI

/// Confirmation sheet shown when the user opens a `.milashare` file. Says
/// exactly what will land in the library — and whether that replaces a copy
/// already here — so a double-clicked file can never silently change it.
struct RecordingShareConfirmationView: View {
    @ObservedObject var importer: RecordingShareImporter
    let pending: RecordingShareImporter.PendingImport
    let onImport: () -> Void
    let onCancel: () -> Void

    private var recording: ShareManifest.RecordingPayload { pending.manifest.recording }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down.on.square.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import shared recording?")
                        .font(.headline)
                    Text(pending.sourceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                row("Title", recording.title)
                row("Shared by", sharedBy)
                row("Recorded", recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                row("Duration", formatDuration(recording.duration))
                if !speakers.isEmpty { row("Speakers", speakers) }
                row("Transcript", transcriptSummary)
                row("Size", ByteCountFormatter.string(fromByteCount: pending.bundleByteCount,
                                                      countStyle: .file))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.4))
            )

            Text(dispositionText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("share.import.disposition")

            if pending.wouldExceedStorageCap {
                Text("Importing this would exceed your storage limit. Free up space or raise the limit in Settings ▸ Storage.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !pending.speakerPlan.isEmpty {
                Divider()
                SharedSpeakersImportSection(plan: Binding(
                    get: { importer.pending?.speakerPlan ?? pending.speakerPlan },
                    set: { importer.pending?.speakerPlan = $0 }
                ))
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(pending.isUpdate ? "Replace" : "Import", action: onImport)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(pending.wouldExceedStorageCap)
                    .accessibilityIdentifier("share.import.confirm")
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value)
                .fontWeight(.medium)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private var sharedBy: String {
        let when = pending.manifest.exportedAt.formatted(date: .abbreviated, time: .omitted)
        return "\(pending.manifest.exportedBy.name) · \(when)"
    }

    private var speakers: String {
        recording.speakerDisplayNames
            .map { $0.displaySpeakerName(names: [:], language: recording.language) }
            .joined(separator: ", ")
    }

    private var transcriptSummary: String {
        let n = recording.segments.count
        if n == 0 { return "Plain text" }
        return n == 1 ? "1 line" : "\(n) lines"
    }

    private var dispositionText: String {
        switch pending.disposition {
        case .add:
            return "Will be added to your library."
        case .update(let existing):
            var text = "Will replace your existing copy of “\(existing.title)”. Your local transcript edits are overwritten; the folder it is filed in is kept."
            if existing.isTrashed {
                text += " It is in Recently Deleted and will be restored."
            }
            return text
        }
    }
}
