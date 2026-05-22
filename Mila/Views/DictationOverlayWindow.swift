import AppKit
import SwiftUI

/// A small floating panel shown while dictation is active.
/// Renders a blue pill with an animated white equalizer (or a spinner while busy).
@MainActor
final class DictationOverlayWindow {
    static let shared = DictationOverlayWindow()

    private var window: NSPanel?
    private let viewModel = DictationOverlayModel()

    private static let panelSize = NSSize(width: 150, height: 44)

    func show() {
        if window == nil { createWindow() }
        viewModel.busy = false
        viewModel.level = 0
        guard let window else { return }
        positionAtBottomCenter(window)
        window.orderFrontRegardless()
        window.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            window.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let window else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            window.animator().alphaValue = 0
        }, completionHandler: {
            window.orderOut(nil)
        })
    }

    func updateLevel(_ value: Float) {
        withAnimation(.easeInOut(duration: 0.08)) {
            viewModel.level = max(0, min(1, value))
        }
    }

    func setBusy(_ busy: Bool) {
        withAnimation(.easeInOut(duration: 0.15)) {
            viewModel.busy = busy
        }
    }

    private func createWindow() {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(
            rootView: DictationOverlayContent(viewModel: viewModel)
        )
        self.window = panel
    }

    private func positionAtBottomCenter(_ window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.minY + 80
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

@MainActor
final class DictationOverlayModel: ObservableObject {
    @Published var level: Float = 0
    @Published var busy: Bool = false
}

private struct DictationOverlayContent: View {
    @ObservedObject var viewModel: DictationOverlayModel

    private let pillColor = Color(red: 0.20, green: 0.55, blue: 0.95)

    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(pillColor)
                .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 2)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                )

            Group {
                if viewModel.busy {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(.white)
                        .transition(.opacity)
                } else {
                    EqualizerBars(level: viewModel.level)
                        .transition(.opacity)
                }
            }
        }
        .padding(4)
        .frame(width: 150, height: 44)
    }
}

/// White equalizer bars driven by a TimelineView so they keep a subtle
/// idle wobble even when the audio level is zero.
private struct EqualizerBars: View {
    var level: Float

    private let barCount = 12
    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 3
    private let minHeight: CGFloat = 6
    private let maxExtra: CGFloat = 22

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    Capsule(style: .continuous)
                        .fill(Color.white)
                        .frame(width: barWidth, height: barHeight(index: i, time: time))
                }
            }
            .animation(.easeInOut(duration: 0.08), value: level)
        }
    }

    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        let phase = Double(index) * 0.45
        let wobble = (sin(time * 7.0 + phase) + 1) / 2 // 0...1
        let amp = max(Double(level), 0.05)
        return minHeight + CGFloat(amp * Double(maxExtra) * wobble)
    }
}
