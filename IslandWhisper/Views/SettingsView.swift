import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Standard `Settings` scene. Opened via `Cmd+,` from the menu bar.
struct SettingsView: View {
    var body: some View {
        TabView {
            HotkeysSettingsTab()
                .tabItem { Label("Hotkeys", systemImage: "command") }
            ModelsSettingsTab()
                .tabItem { Label("Models", systemImage: "cube.box") }
        }
        .frame(width: 520, height: 420)
        .padding(20)
    }
}

// MARK: - Hotkeys

private struct HotkeysSettingsTab: View {
    @EnvironmentObject private var hotkeys: HotkeySettings

    /// The action whose hotkey the user is currently re-recording. Nil when
    /// no row is in capture mode.
    @State private var recordingAction: HotkeyAction?
    @State private var lastError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dictation hotkeys")
                .font(.title3.weight(.semibold))
            Text("Press the hotkey anywhere in macOS to start dictating. Press it again to stop, transcribe, and paste at the cursor. Click a binding to record a new one; press Esc to cancel.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                ForEach(HotkeyAction.allCases) { action in
                    HotkeyRow(action: action,
                              isRecording: recordingAction == action,
                              onStartRecording: { recordingAction = action },
                              onCaptured: { applyCapture($0, for: action) },
                              onCancel: { recordingAction = nil },
                              onReset: { resetToDefault(action) })
                }
            }

            if let lastError {
                Text(lastError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func applyCapture(_ binding: HotkeyBinding, for action: HotkeyAction) {
        recordingAction = nil

        // Reject empty / modifier-only combos: Carbon will accept them but
        // Apple shortcut conventions require at least one of ⌘ ⌃ ⌥.
        let needsModifier = UInt32(cmdKey | controlKey | optionKey)
        guard binding.modifiers & needsModifier != 0 else {
            lastError = "Please include at least one modifier (⌘, ⌃, or ⌥)."
            return
        }

        // Reject collisions with the *other* action so the user doesn't
        // shoot themselves in the foot.
        for other in HotkeyAction.allCases where other != action {
            let existing = hotkeys.binding(for: other)
            if existing == binding {
                lastError = "\(binding.displayName) is already used for \(other.displayLabel)."
                return
            }
        }

        lastError = nil
        hotkeys.setBinding(binding, for: action)
    }

    private func resetToDefault(_ action: HotkeyAction) {
        hotkeys.resetToDefault(action)
        lastError = nil
    }
}

private struct HotkeyRow: View {
    @EnvironmentObject private var hotkeys: HotkeySettings

    let action: HotkeyAction
    let isRecording: Bool
    let onStartRecording: () -> Void
    let onCaptured: (HotkeyBinding) -> Void
    let onCancel: () -> Void
    let onReset: () -> Void

    var body: some View {
        HStack {
            Text(action.displayLabel)
                .font(.body)
                .frame(width: 160, alignment: .leading)

            Spacer()

            HotkeyCaptureField(currentDisplay: hotkeys.binding(for: action).displayName,
                               isRecording: isRecording,
                               onStartRecording: onStartRecording,
                               onCaptured: onCaptured,
                               onCancel: onCancel)
                .frame(width: 160)

            Button("Reset") { onReset() }
                .buttonStyle(.borderless)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A click-to-record hotkey field. When activated it becomes first responder
/// and captures the next non-modifier keyDown event into a `HotkeyBinding`.
/// Hosted via `NSViewRepresentable` because SwiftUI's focus / key event APIs
/// don't expose the raw virtual key code we need to register through Carbon.
private struct HotkeyCaptureField: NSViewRepresentable {
    let currentDisplay: String
    let isRecording: Bool
    let onStartRecording: () -> Void
    let onCaptured: (HotkeyBinding) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> HotkeyCaptureNSView {
        let view = HotkeyCaptureNSView()
        view.onStartRecording = onStartRecording
        view.onCaptured = onCaptured
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: HotkeyCaptureNSView, context: Context) {
        nsView.label = isRecording ? "Press a hotkey…" : currentDisplay
        nsView.recording = isRecording
        nsView.onStartRecording = onStartRecording
        nsView.onCaptured = onCaptured
        nsView.onCancel = onCancel
        if isRecording {
            nsView.window?.makeFirstResponder(nsView)
        } else if nsView.window?.firstResponder === nsView {
            nsView.window?.makeFirstResponder(nil)
        }
    }
}

final class HotkeyCaptureNSView: NSView {
    var label: String = "" { didSet { needsDisplay = true } }
    var recording: Bool = false { didSet { needsDisplay = true } }
    var onStartRecording: (() -> Void)?
    var onCaptured: ((HotkeyBinding) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard !recording else { return }
        onStartRecording?()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }

        // Esc cancels the capture without saving.
        if event.keyCode == kVK_Escape {
            onCancel?()
            return
        }

        // Carbon expects its own modifier flags, not NSEvent's. Translate.
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.command)  { modifiers |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.shift)    { modifiers |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.option)   { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control)  { modifiers |= UInt32(controlKey) }

        let binding = HotkeyBinding(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        onCaptured?(binding)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        if recording {
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            NSColor.controlAccentColor.setStroke()
        } else {
            NSColor.controlBackgroundColor.setFill()
            NSColor.separatorColor.setStroke()
        }
        path.lineWidth = 1
        path.fill()
        path.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: recording ? NSColor.controlAccentColor : NSColor.labelColor
        ]
        let string = NSAttributedString(string: label, attributes: attrs)
        let size = string.size()
        let origin = NSPoint(x: rect.midX - size.width / 2,
                             y: rect.midY - size.height / 2)
        string.draw(at: origin)
    }
}

// MARK: - Models

private struct ModelsSettingsTab: View {
    @EnvironmentObject private var manager: ModelManager
    @EnvironmentObject private var transcription: TranscriptionService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Whisper models")
                .font(.title3.weight(.semibold))
            Text("English dictation uses the OpenAI turbo model; Hebrew uses ivrit.ai. Both download automatically on first launch (~1.6 GB each). The optional ivrit.ai large model is higher accuracy but ~2× slower.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                ForEach(WhisperModel.all) { model in
                    ModelRow(model: model)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ModelRow: View {
    @EnvironmentObject private var manager: ModelManager
    let model: WhisperModel

    var body: some View {
        let progress = manager.downloads[model.name]
        let installed = manager.isInstalled(model)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(.body)
                Text(byteCountString(model.sizeBytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let progress {
                ProgressView(value: progress).frame(width: 80)
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if installed {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.iconOnly)
                Button("Delete", role: .destructive) {
                    try? manager.delete(model)
                }
                .buttonStyle(.borderless)
            } else {
                Button("Download") { manager.download(model) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func byteCountString(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        f.allowedUnits = [.useGB, .useMB]
        return f.string(fromByteCount: bytes)
    }
}
