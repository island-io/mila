import SwiftUI

/// The small "Managed by your organization" caption shown beside a Settings
/// control whose value a configuration profile locks (see `ManagedSettings`).
/// The control itself is disabled by its caller; this only explains why.
struct ManagedSettingNote: View {
    var body: some View {
        Label(ManagedSettings.note, systemImage: "building.2")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Set by a configuration profile your organization installed. Ask your IT administrator to change it.")
            .accessibilityIdentifier("settings.managedNote")
    }
}
