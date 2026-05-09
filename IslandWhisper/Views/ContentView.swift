import SwiftUI
import ScreenCaptureKit

struct ContentView: View {
    @EnvironmentObject private var store: RecordingStore
    @EnvironmentObject private var transcription: TranscriptionService
    @EnvironmentObject private var actions: QuickActionsController
    @EnvironmentObject private var session: RecordingSession
    @EnvironmentObject private var dictation: DictationController
    @EnvironmentObject private var modelManager: ModelManager

    @State private var selection: SidebarSelection? = .home
    @State private var search: String = ""

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            ZStack(alignment: .top) {
                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let progress = activeDownloadProgress() {
                    ModelDownloadBanner(progress: progress)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if actions.isRecording {
                    HStack {
                        Spacer()
                        RecordingChip()
                            .padding(.top, 12)
                            .padding(.trailing, 16)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    DictationToolbarButton(action: .dictateEnglish)
                    DictationToolbarButton(action: .dictateHebrew)
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search")
        .alert(
            "Transcription error",
            isPresented: Binding(
                get: { transcription.lastError != nil },
                set: { if !$0 { transcription.lastError = nil } }
            ),
            actions: { Button("OK") { transcription.lastError = nil } },
            message: { Text(transcription.lastError ?? "") }
        )
        .alert(
            "Screen & System Audio Recording permission needed",
            isPresented: $actions.screenRecordingPermissionMissing,
            actions: {
                Button("Open Privacy Settings") {
                    actions.openScreenRecordingSettings()
                    actions.screenRecordingPermissionMissing = false
                }
                Button("Cancel", role: .cancel) {
                    actions.screenRecordingPermissionMissing = false
                }
            },
            message: {
                Text("macOS hasn't granted IslandWhisper access to system audio. In System Settings → Privacy & Security → Screen & System Audio Recording, remove any existing IslandWhisper entry, then check the box for this build. (Stale entries from previous builds can look granted but are no longer valid.)")
            }
        )
        .sheet(isPresented: $actions.isAppPickerShown) {
            AppPickerSheet()
        }
    }

    private func activeDownloadProgress() -> Double? {
        guard let model = modelManager.selectedModel(),
              let value = modelManager.downloads[model.name] else { return nil }
        return value
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection ?? .home {
        case .home:
            HomeView(selection: $selection, search: search)
        case .queue:
            QueueView(selection: $selection)
        case .category(let cat):
            HistoryListView(category: cat, search: search, selection: $selection)
        case .recording(let id):
            if let rec = store.recordings.first(where: { $0.id == id }) {
                RecordingDetailView(recording: rec)
            } else {
                ContentUnavailableView(
                    "Recording not found",
                    systemImage: "questionmark.folder",
                    description: Text("The recording may have been deleted.")
                )
            }
        }
    }
}

private struct ModelDownloadBanner: View {
    let progress: Double
    @EnvironmentObject private var modelManager: ModelManager

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text("Downloading \(modelManager.selectedModel()?.displayName ?? "model")…")
                    .font(.callout.weight(.semibold))
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 280)
            }
            Text("\(Int(progress * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }
}

private struct DictationToolbarButton: View {
    @EnvironmentObject private var dictation: DictationController
    @EnvironmentObject private var hotkeySettings: HotkeySettings

    let action: HotkeyAction

    var body: some View {
        Button {
            Task { await dictation.toggle(action: action) }
        } label: {
            switch dictation.state {
            case .recording(let active) where active == action:
                Label("Stop", systemImage: "stop.circle.fill")
                    .foregroundStyle(.red)
            case .transcribing(let active) where active == action:
                ProgressView().controlSize(.small)
            default:
                Label(label, systemImage: "mic.circle")
            }
        }
        .help("\(action.displayLabel) (\(hotkeySettings.binding(for: action).displayName))")
    }

    private var label: String {
        switch action {
        case .dictateEnglish: return "EN"
        case .dictateHebrew:  return "HE"
        }
    }
}

private struct RecordingChip: View {
    @EnvironmentObject private var actions: QuickActionsController
    @EnvironmentObject private var session: RecordingSession

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
            Text(formatDuration(session.elapsed))
                .font(.callout.monospacedDigit())
            Button {
                Task { await actions.stopRecording() }
            } label: {
                Image(systemName: "stop.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Stop recording")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule().strokeBorder(Color.red.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
    }
}

private struct QueueView: View {
    @EnvironmentObject private var store: RecordingStore
    @EnvironmentObject private var transcription: TranscriptionService
    @Binding var selection: SidebarSelection?

    /// Active job first (if any), then queued items in FIFO order, then any
    /// other pending recordings (e.g. queued before app launch).
    private var queue: [Recording] {
        var seen = Set<UUID>()
        var ordered: [Recording] = []
        if let activeID = transcription.activeRecordingID,
           let active = store.recordings.first(where: { $0.id == activeID }) {
            ordered.append(active)
            seen.insert(activeID)
        }
        for id in transcription.pendingIDs {
            if !seen.contains(id),
               let rec = store.recordings.first(where: { $0.id == id }) {
                ordered.append(rec)
                seen.insert(id)
            }
        }
        for rec in store.recordings where !rec.isTrashed
            && (rec.status == .running || rec.status == .pending)
            && !seen.contains(rec.id) {
            ordered.append(rec)
        }
        return ordered
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Queue")
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.top, 16)

                if queue.isEmpty {
                    HStack {
                        Spacer()
                        ContentUnavailableView(
                            "Queue is empty",
                            systemImage: "list.bullet.rectangle",
                            description: Text("Active and pending transcriptions will show up here.")
                        )
                        Spacer()
                    }
                    .padding(.top, 60)
                } else {
                    VStack(spacing: 8) {
                        ForEach(Array(queue.enumerated()), id: \.element.id) { index, rec in
                            QueueRow(recording: rec, position: index)
                                .contentShape(Rectangle())
                                .onTapGesture { selection = .recording(rec.id) }
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 24)
        }
    }
}

private struct QueueRow: View {
    let recording: Recording
    /// 0 = currently transcribing, 1+ = number of jobs ahead in the queue
    let position: Int
    @EnvironmentObject private var transcription: TranscriptionService

    private var isActive: Bool {
        transcription.activeRecordingID == recording.id
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: recording.source.sfSymbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(recording.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text(statusLabel)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(statusColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(statusColor)
                }

                if isActive {
                    ProgressView(value: transcription.progress)
                        .progressViewStyle(.linear)
                } else {
                    HStack(spacing: 6) {
                        ProgressView(value: 0)
                            .progressViewStyle(.linear)
                            .opacity(0.4)
                        if position > 0 {
                            Text("#\(position) in line")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var statusLabel: String {
        if isActive { return "Transcribing" }
        switch recording.status {
        case .running: return "Transcribing"
        case .pending: return position == 0 ? "Starting…" : "Queued"
        case .completed: return "Done"
        case .failed: return "Failed"
        }
    }

    private var statusColor: Color {
        if isActive { return .blue }
        switch recording.status {
        case .running: return .blue
        case .pending: return .orange
        case .completed: return .green
        case .failed: return .red
        }
    }
}

private struct AppPickerSheet: View {
    @EnvironmentObject private var actions: QuickActionsController

    @State private var pickedAppID: pid_t? = nil
    @State private var includeMic: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Record app audio")
                .font(.title3.weight(.semibold))
            Text("Pick an app to capture, or record everything playing on this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Picker("App", selection: $pickedAppID) {
                Text("Entire system").tag(pid_t?(nil))
                ForEach(actions.availableApps, id: \.processID) { app in
                    Text(app.applicationName).tag(pid_t?(app.processID))
                }
            }
            .pickerStyle(.menu)

            Toggle("Also record microphone", isOn: $includeMic)

            HStack {
                Spacer()
                Button("Cancel") {
                    actions.isAppPickerShown = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Start recording") {
                    let app = actions.availableApps.first { $0.processID == pickedAppID }
                    Task { await actions.startAppRecording(app: app, includeMic: includeMic) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 460)
    }
}
