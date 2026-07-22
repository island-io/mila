import SwiftUI

/// Confirmation sheet shown when the user opens a `.milaconfig` file. Lists the
/// exact settings the file will change (secrets masked) so a double-clicked
/// file can never silently reconfigure the app. Settings not named in the file
/// are left as they are.
struct MilaConfigConfirmationView: View {
    let pending: MilaConfigImporter.PendingImport
    let onApply: () -> Void
    let onCancel: () -> Void

    private var hasChanges: Bool { !pending.changes.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apply Mila configuration?")
                        .font(.headline)
                    Text(pending.sourceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if hasChanges {
                Text("The following settings will be updated:")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(pending.changes) { change in
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Text(change.label)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Text(change.value)
                                .fontWeight(.medium)
                                .multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.4))
                )
                Text("Settings not listed in the file are left unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("This configuration matches your current settings — nothing will change.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(hasChanges ? "Apply" : "OK", action: onApply)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
