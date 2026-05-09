import SwiftUI
import AVKit

struct RecordingDetailView: View {
    let recording: Recording
    @EnvironmentObject private var store: RecordingStore
    @EnvironmentObject private var transcription: TranscriptionService
    @EnvironmentObject private var modelManager: ModelManager

    @State private var player: AVPlayer?
    @State private var currentTime: Double = 0
    @State private var timeObserver: Any?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcriptArea
            Divider()
            playbackBar
        }
        .onAppear { configurePlayer() }
        .onChange(of: recording.id) { _, _ in configurePlayer() }
        .onDisappear { teardownPlayer() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(recording.title)
                    .font(.title2.weight(.semibold))
                HStack(spacing: 8) {
                    Label(recording.source.displayName,
                          systemImage: recording.source.sfSymbol)
                    Text("·")
                    Text(recording.createdAt, format: .dateTime)
                    Text("·")
                    Text(formatDuration(recording.duration))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            actionButtons
        }
        .padding()
    }

    private var actionButtons: some View {
        let currentLang = RecordingLanguage.fromCode(recording.language)
        let busy = transcription.activeRecordingID == recording.id
                   || transcription.pendingIDs.contains(recording.id)
        return HStack {
            Menu {
                Button {
                    transcription.enqueue(recording)
                } label: {
                    Label("\(currentLang.flagEmoji) \(currentLang.displayName) (current)",
                          systemImage: "arrow.clockwise")
                }
                Button {
                    retranscribe(in: currentLang.other)
                } label: {
                    Label("\(currentLang.other.flagEmoji) \(currentLang.other.displayName)",
                          systemImage: "arrow.triangle.2.circlepath")
                }
            } label: {
                Label(recording.status == .completed ? "Re-transcribe" : "Transcribe",
                      systemImage: "text.badge.checkmark")
            }
            .disabled(busy)

            ShareLink(item: store.audioURL(for: recording)) {
                Label("Share audio", systemImage: "square.and.arrow.up")
            }

            Button {
                copyTranscript()
            } label: {
                Label("Copy transcript", systemImage: "doc.on.doc")
            }
            .disabled(recording.fullText.isEmpty)
        }
    }

    /// Re-run the transcription pipeline with a different language model.
    /// Updates the persisted `Recording.language` so the downstream
    /// `TranscriptionService` picks the right model on its own.
    private func retranscribe(in language: RecordingLanguage) {
        var copy = recording
        copy.language = language.rawValue
        copy.status = .pending
        store.update(copy)
        transcription.enqueue(copy)
    }

    @ViewBuilder
    private var transcriptArea: some View {
        if transcription.activeRecordingID == recording.id {
            VStack(spacing: 12) {
                Spacer()
                ProgressView(value: transcription.progress) {
                    Text("Transcribing with \(modelManager.selectedModel()?.displayName ?? "")…")
                }
                .progressViewStyle(.linear)
                .frame(maxWidth: 360)
                Text("\(Int(transcription.progress * 100))%")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if recording.segments.isEmpty {
            ContentUnavailableView(
                "No transcript yet",
                systemImage: "text.alignleft",
                description: Text("Click \(Image(systemName: "text.badge.checkmark")) Transcribe to start.")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(recording.segments) { seg in
                        SegmentRow(segment: seg,
                                   isActive: currentTime >= seg.start && currentTime < seg.end,
                                   onTap: { seek(to: seg.start) })
                    }
                }
                .padding()
                .environment(\.layoutDirection, recording.language == "he" ? .rightToLeft : .leftToRight)
            }
            .contextMenu {
                let other = RecordingLanguage.fromCode(recording.language).other
                Button("Re-transcribe in \(other.flagEmoji) \(other.displayName)") {
                    retranscribe(in: other)
                }
                Button("Copy transcript") { copyTranscript() }
                    .disabled(recording.fullText.isEmpty)
            }
        }
    }

    @ViewBuilder
    private var playbackBar: some View {
        if let player {
            HStack {
                PlayPauseButton(player: player)
                Slider(value: Binding(get: { currentTime },
                                      set: { seek(to: $0) }),
                       in: 0...max(recording.duration, 0.1))
                Text(formatDuration(currentTime))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
            }
            .padding()
        }
    }

    private func configurePlayer() {
        teardownPlayer()
        let url = store.audioURL(for: recording)
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30),
                                                  queue: .main) { time in
            currentTime = time.seconds.isFinite ? time.seconds : 0
        }
        player = p
    }

    private func teardownPlayer() {
        if let player, let observer = timeObserver {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
        player?.pause()
        player = nil
    }

    private func seek(to seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }

    private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recording.fullText, forType: .string)
    }
}

private struct PlayPauseButton: View {
    @ObservedObject private var bridge: PlayerBridge

    init(player: AVPlayer) {
        _bridge = ObservedObject(wrappedValue: PlayerBridge(player: player))
    }

    var body: some View {
        Button {
            bridge.toggle()
        } label: {
            Image(systemName: bridge.isPlaying ? "pause.fill" : "play.fill")
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderedProminent)
    }
}

@MainActor
private final class PlayerBridge: ObservableObject {
    @Published var isPlaying = false
    let player: AVPlayer
    private var token: NSKeyValueObservation?

    init(player: AVPlayer) {
        self.player = player
        token = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] p, _ in
            DispatchQueue.main.async {
                self?.isPlaying = (p.timeControlStatus == .playing)
            }
        }
    }
    func toggle() {
        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
    }
}

private struct SegmentRow: View {
    let segment: TranscriptSegment
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(formatDuration(segment.start))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            Text(segment.text)
                .font(.body)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(isActive ? Color.accentColor.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}
