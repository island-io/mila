#if DEBUG
import AppKit
import SwiftUI
import Combine

/// Native presentation tests use the real coordinator and settings, with only
/// the detector and capture boundary replaced. Never enabled in release builds.
@MainActor
final class MeetingAutoRecordingTestHarness: ObservableObject, MeetingRecordingActions {
    static var retained: MeetingAutoRecordingTestHarness?
    @Published var meetingRecordingURL: URL?
    @Published var starts = 0
    @Published var stops = 0
    var canStartMeetingRecording: Bool { meetingRecordingURL == nil }
    var meetingRecordingChanges: AnyPublisher<Void, Never> {
        $meetingRecordingURL.map { _ in () }.eraseToAnyPublisher()
    }
    private let detector: MeetingDetector
    private let settings: MeetingDetectionSettings
    private var window: NSWindow?
    private var app: MeetingDetector.App { MeetingDetector.supportedApps[0] }
    init(detector: MeetingDetector, settings: MeetingDetectionSettings) {
        self.detector = detector
        self.settings = settings
    }
    func startMeetingRecording(isStillValid: @escaping () -> Bool) async -> URL? {
        guard isStillValid(), canStartMeetingRecording else { return nil }
        starts += 1
        meetingRecordingURL = URL(fileURLWithPath: "/tmp/mila-ui-meeting-\(UUID()).wav")
        return meetingRecordingURL
    }
    func stopMeetingRecording(expectedURL: URL) async {
        guard meetingRecordingURL == expectedURL else { return }
        stops += 1
        meetingRecordingURL = nil
    }
    func show() {
        let panel = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 360, height: 240),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Meeting test controls"
        panel.contentView = NSHostingView(rootView: Controls(harness: self))
        panel.isReleasedWhenClosed = false
        window = panel
        panel.makeKeyAndOrderFront(nil)
    }
    private struct Controls: View {
        @ObservedObject var harness: MeetingAutoRecordingTestHarness
        var body: some View {
            VStack(spacing: 12) {
                Text(harness.meetingRecordingURL == nil ? "Idle" : "Recording")
                    .accessibilityIdentifier("meetingTest.state")
                Text("Starts: \(harness.starts), stops: \(harness.stops)")
                    .accessibilityIdentifier("meetingTest.counts")
                Button("Detect meeting") { harness.detector.meetingStarted.send(harness.app) }
                    .accessibilityIdentifier("meetingTest.start")
                Button("End meeting") { harness.detector.meetingEnded.send(harness.app) }
                    .accessibilityIdentifier("meetingTest.end")
                Button("Auto mode") { harness.settings.setMode(.auto, forBundleID: harness.app.bundleID) }
                    .accessibilityIdentifier("meetingTest.auto")
                Button("Ask mode") { harness.settings.setMode(.ask, forBundleID: harness.app.bundleID) }
                    .accessibilityIdentifier("meetingTest.ask")
            }.padding()
        }
    }
}
#endif
