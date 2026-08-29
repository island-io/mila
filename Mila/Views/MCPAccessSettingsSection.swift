import SwiftUI
import AppKit

/// MCP access section, embedded in the Storage settings tab beneath the
/// Obsidian card — both are "where your transcripts can go" settings.
///
/// **Visibility contract**, same as `ObsidianSettingsSection`: when the
/// feature is off, its entire footprint is one toggle and one caption. The
/// registration command only appears once the user has opted in.
struct MCPAccessSettingsSection: View {
    @EnvironmentObject private var settings: MCPAccessSettings

    @State private var copied = false

    /// Path the user registers with their MCP client. Resolved from the
    /// running bundle so a local dev build or a relocated Mila.app prints
    /// the path that actually exists rather than a hardcoded /Applications.
    private var helperPath: String {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/mila-mcp")
        return url.path
    }

    /// The command we tell the user to paste into a terminal.
    ///
    /// The path is single-quoted, not double-quoted: inside double quotes a
    /// shell still expands `$(…)`, backticks and `$VAR`, so an app living
    /// under a directory someone named `$(rm -rf ~)` would produce a command
    /// that runs that when pasted. Single quotes suppress all expansion; the
    /// only character needing care is `'` itself, closed and reopened around
    /// an escaped copy in the standard POSIX way.
    private var registerCommand: String {
        "claude mcp add mila -- \(singleQuoted(helperPath))"
    }

    private func singleQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            enableCard
            if settings.enabled {
                registrationCard
            }
            // Turning access OFF didn't take. The toggle has been put back to
            // on, because it is still on in fact — saying so is the only
            // honest option, and it tells the user to act rather than
            // assuming they're covered.
            if settings.revocationFailed {
                Text("Mila couldn't turn MCP access off — the permission file can't be written or removed, so the helper still has access. Check that \(settings.gateFilePath) is writable, then try again.")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let error = settings.mirrorError {
                Text("Mila couldn't save this preference (\(error)). The MCP helper will keep refusing access until it can be written.")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Access is on, saved fine, and still refused — because
            // `store-location.json` doesn't describe the store Mila is
            // using, so the helper would read a stale one. Without this line
            // the refusal is invisible from inside the app and the toggle
            // looks like it's working.
            if settings.storeUnreachable {
                Text("MCP access is paused: Mila couldn't record where your recordings live, so the helper would read an out-of-date copy. Reopening Mila usually fixes it; if it persists, set the storage location again in Storage above.")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var enableCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(.tint)
                Toggle("Allow MCP access to transcriptions", isOn: $settings.enabled)
                    .accessibilityIdentifier("mcp.enabled.toggle")
                Spacer()
            }
            if settings.enabled {
                Text("An MCP client on this Mac — Claude Code or Claude Desktop — can list your recordings, read their transcripts, search them, and follow a recording as it happens. Nothing is sent anywhere by Mila; the client you register decides what it does with the text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Off. Turn this on to let an MCP client on this Mac read your transcriptions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var registrationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "link")
                    .foregroundStyle(.tint)
                Text("Register with Claude Code")
                    .font(.callout.weight(.medium))
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(registerCommand, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                }
                .accessibilityIdentifier("mcp.copyCommand.button")
            }
            Text(registerCommand)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            Text("Run this once in a terminal. The helper ships inside Mila.app and updates with it, so you won't need to re-register after an update.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
