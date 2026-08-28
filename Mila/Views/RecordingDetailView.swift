import SwiftUI
import AVKit
import AppKit
import TranscriptionCore
import UniformTypeIdentifiers
import MilaKit

struct RecordingDetailView: View {
    let recording: Recording
    @EnvironmentObject private var store: RecordingStore
    @EnvironmentObject private var transcription: TranscriptionService
    @EnvironmentObject private var modelManager: ModelManager
    @EnvironmentObject private var llmSettings: LLMSettings
    @EnvironmentObject private var summarizer: RecordingSummarizer

    @State private var player: AVPlayer?
    @State private var currentTime: Double = 0
    @State private var timeObserver: Any?
    /// Persisted so a chosen speed carries across recordings and app launches
    /// (the menu in `playbackBar`). Stored as a plain `Double`; the menu reads
    /// it back through `PlaybackSpeed.nearest(to:)`, which snaps anything that
    /// isn't a supported rate.
    @AppStorage("detail.playback.speed") private var playbackSpeed: Double = 1.0
    /// Whether the transcript auto-scrolls to keep the highlighted segment in
    /// view. Deliberately NOT persisted: ContentView applies `.id(rec.id)`, so
    /// every recording opens following, and a manual scroll only disengages it
    /// for that visit.
    @State private var isFollowing = true
    /// Reference type on purpose. The scroll probe and the active-row preference
    /// both write here on every scrolled frame; holding this in `@State` would
    /// re-lay out the whole transcript each time.
    @State private var follow = FollowCoordinator()
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    /// Set when the user picks a merge target in the speaker popover; drives
    /// the confirmation alert, which is what actually performs the merge.
    @State private var pendingMerge: PendingSpeakerMerge?

    @FocusState private var titleFieldFocused: Bool

    /// Every raw speaker id the transcript uses, in first-appearance order.
    private var distinctSpeakerIDs: [String] {
        var seen = Set<String>()
        return recording.segments.compactMap(\.speaker).filter { seen.insert($0).inserted }
    }

    /// How many lines each raw speaker id carries. Drives whether "Split this
    /// line" is offered at all: `RecordingStore.splitSegmentSpeaker` no-ops on
    /// a speaker's only line (splitting it would just rename the id and
    /// strand the old one), so offering it there is an enabled menu item that
    /// does nothing.
    private var lineCountsBySpeaker: [String: Int] {
        recording.segments.reduce(into: [:]) { counts, seg in
            guard let raw = seg.speaker else { return }
            counts[raw, default: 0] += 1
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            AIOverviewBanner(
                summary: recording.summary,
                items: recording.actionItems ?? [],
                recordingLanguage: recording.language,
                isSummarizing: summarizer.isSummarizing(recording.id),
                onRegenerateSummary: canRegenerateSummary
                    ? { summarizer.regenerate(recording) }
                    : nil
            )
            transcriptArea
                // Force the transcript area to take the remaining
                // vertical space and scroll its OWN content rather than
                // expanding to the segments' intrinsic height. Without
                // this, a transcript with many segments made the VStack
                // grow to ~1500 px in a 700 px window and the content
                // overflowed upward past the title bar, leaving the
                // user with a blank window. Reproduced via accessibility
                // tree inspection.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            playbackBar
        }
        // ContentView applies .id(rec.id) at the call site, so SwiftUI
        // rebuilds this view on navigation between recordings and we don't
        // need a separate onChange handler to reconfigure the player.
        .onAppear { configurePlayer() }
        .onDisappear { teardownPlayer() }
        .onChange(of: playbackSpeed) { _, newValue in
            let rate = Float(PlaybackSpeed.nearest(to: newValue).rawValue)
            player?.defaultRate = rate
            // Only touch `rate` while playback is actually running: assigning a
            // non-zero rate to a paused player STARTS it, so without this guard
            // picking a speed from the menu would begin playing on its own.
            if player?.timeControlStatus == .playing {
                player?.rate = rate
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                titleEditor
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        RecordingSourceBadge(recording: recording, size: 18)
                        Text(recording.detectedMeetingApp?.info.displayName
                             ?? recording.source.displayName)
                    }
                    Text("·")
                    Text(recording.createdAt, format: .dateTime)
                    Text("·")
                    Text(formatDuration(recording.duration))
                    Text("·")
                    RecordingFolderMenu(recordingID: recording.id,
                                        currentFolder: recording.folder)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            actionButtons
        }
        .padding()
    }

    /// Click-to-edit title. Pressing Return or losing focus commits the new
    /// title via `store.rename`. Escape reverts without saving. The display
    /// state intentionally does not look like a TextField until the user
    /// clicks it — we don't want a 20pt input bar dominating the header.
    @ViewBuilder
    private var titleEditor: some View {
        if isEditingTitle {
            TextField("Title", text: $titleDraft)
                .font(.title2.weight(.semibold))
                .textFieldStyle(.roundedBorder)
                .focused($titleFieldFocused)
                .onSubmit { commitTitle() }
                .onExitCommand { cancelTitleEdit() }
                .onChange(of: titleFieldFocused) { _, focused in
                    if !focused { commitTitle() }
                }
                .accessibilityIdentifier("detail.title.field")
        } else {
            Text(recording.title)
                .font(.title2.weight(.semibold))
                .contentShape(Rectangle())
                .onTapGesture { beginTitleEdit() }
                .help("Click to rename")
                .accessibilityIdentifier("detail.title.label")
        }
    }

    private func beginTitleEdit() {
        titleDraft = recording.title
        isEditingTitle = true
        // Defer focus to next runloop tick so the TextField is actually in
        // the view hierarchy before we ask it to grab keyboard focus.
        DispatchQueue.main.async { titleFieldFocused = true }
    }

    private func commitTitle() {
        guard isEditingTitle else { return }
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != recording.title {
            store.rename(recording, to: trimmed)
        }
        isEditingTitle = false
    }

    private func cancelTitleEdit() {
        isEditingTitle = false
        titleDraft = recording.title
    }

    private var actionButtons: some View {
        let currentLang = RecordingLanguage.fromCode(recording.language)
        let busy = transcription.activeRecordingID == recording.id
                   || transcription.pendingIDs.contains(recording.id)
        // Icon-only buttons with hover tooltips. Labeled buttons here
        // competed with the title for header width and truncated ("Copy
        // tra…"); icons keep all four actions visible at any window size.
        // The Re-transcribe MENU keeps its full text labels in the dropdown.
        return HStack(spacing: 10) {
            Menu {
                Button {
                    // Route through the live-store chokepoint (same as the
                    // language-switch action) so status + audioFileName handling
                    // stays consistent and we never enqueue a stale snapshot
                    // whose `.wav` a since-run compression already deleted.
                    guard let prepared = store.prepareForRetranscription(id: recording.id) else { return }
                    transcription.enqueue(prepared, isRetranscription: true)
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
                Image(systemName: "text.badge.checkmark")
            }
            .fixedSize()
            .disabled(busy)
            .help(recording.status == .completed ? "Re-transcribe" : "Transcribe")

            ShareLink(item: store.audioURL(for: recording)) {
                Image(systemName: "square.and.arrow.up")
            }
            .help("Share audio")

            Button {
                copyOverview()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .disabled(!hasOverviewToCopy)
            .help("Copy summary + action items")

            Button {
                exportSRT()
            } label: {
                Image(systemName: "captions.bubble")
            }
            .disabled(recording.segments.isEmpty)
            .help("Export subtitles (.srt) for the original video/audio")
        }
    }

    /// Save the SRT file to a user-chosen location. Defaulting the filename
    /// to the recording title makes the common case (drag video in → save
    /// `MyVideo.srt` next to `MyVideo.mp4`) one click.
    private func exportSRT() {
        let panel = NSSavePanel()
        panel.title = "Export Subtitles"
        panel.allowedContentTypes = [.init(filenameExtension: "srt") ?? .data]
        panel.nameFieldStringValue = recording.title + ".srt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try TranscriptExporter.writeSRT(for: recording, to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Re-run the transcription pipeline with a different language model.
    /// Updates the persisted `Recording.language` so the downstream
    /// `TranscriptionService` picks the right model on its own.
    private func retranscribe(in language: RecordingLanguage) {
        // Mutate only language+status on the LIVE record so we don't clobber a
        // since-compressed `.m4a` audioFileName back to a deleted `.wav`.
        guard let prepared = store.prepareForRetranscription(id: recording.id,
                                                             language: language.rawValue)
        else { return }
        transcription.enqueue(prepared, isRetranscription: true)
    }


    /// Whether the user can ask for a fresh summary right now. Gates the
    /// "Regenerate summary" context-menu entry in `AIOverviewBanner` so
    /// it never shows up for recordings without an LLM CLI configured
    /// or without anything to summarise. Mirrors `RecordingSummarizer`'s
    /// own predicate but adds the "force-allowed even if a summary
    /// exists" piece — that's the whole point of the affordance.
    private var canRegenerateSummary: Bool {
        guard llmSettings.isConfigured else { return false }
        return !recording.fullText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    /// Human-readable name of the whisper model that will run for the
    /// recording's CURRENT language. Prefers `recording.modelName` once
    /// transcription has started writing it back to the store (that's
    /// what the engine actually used), otherwise falls back to the
    /// model selected for the recording's language.
    private var activeTranscriptionModelName: String {
        if let name = recording.modelName, !name.isEmpty { return name }
        if let model = modelManager.model(for: recording.language) {
            return model.displayName
        }
        return modelManager.selectedModel()?.displayName ?? ""
    }

    /// What the transcript area shows while a recording has no segments.
    /// `nil` means no placeholder — the active-transcription progress view
    /// owns that state.
    enum EmptyTranscriptPlaceholder: Equatable {
        /// Queued behind the active transcription — the Transcribe menu is
        /// disabled (see `busy` in `actionButtons`), so pointing the user
        /// at it would be a dead end.
        case waitingInQueue
        /// Idle: invite the user to start a transcription themselves.
        case clickTranscribe
    }

    /// Decision for the empty-segments placeholder, split out as a pure
    /// function so RecordingDetailPlaceholderTests can pin the queued
    /// case without building the view.
    static func emptyTranscriptPlaceholder(isActive: Bool,
                                           isQueued: Bool) -> EmptyTranscriptPlaceholder? {
        if isActive { return nil }
        return isQueued ? .waitingInQueue : .clickTranscribe
    }

    @ViewBuilder
    private var transcriptArea: some View {
        if transcription.activeRecordingID == recording.id {
            VStack(spacing: 12) {
                Spacer()
                ProgressView(value: transcription.progress) {
                    // Use the model for THIS recording's language, not
                    // `modelManager.selectedModel()` (the user's
                    // global default). Otherwise re-transcribing a
                    // recording in English while the user has Hebrew
                    // pinned globally still says "Transcribing with
                    // ivrit-ai…" while actually running OpenAI Turbo,
                    // which was the bug reported.
                    Text("Transcribing with \(activeTranscriptionModelName)…")
                }
                .progressViewStyle(.linear)
                .frame(maxWidth: 360)
                Text("\(Int(transcription.progress * 100))%")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if recording.segments.isEmpty {
            let placeholder = Self.emptyTranscriptPlaceholder(
                isActive: transcription.activeRecordingID == recording.id,
                isQueued: transcription.pendingIDs.contains(recording.id)
            )
            if placeholder == .waitingInQueue {
                ContentUnavailableView {
                    Label("Waiting in queue", systemImage: "clock")
                } description: {
                    Text("Transcription will start when the recording ahead of it finishes.")
                }
            } else {
                ContentUnavailableView(
                    "No transcript yet",
                    systemImage: "text.alignleft",
                    description: Text("Click \(Image(systemName: "text.badge.checkmark")) Transcribe to start.")
                )
            }
        } else {
            VStack(spacing: 0) {
                // Transcript-area copy button, on the right just below the
                // AI-overview banner's divider. Mirrors the consolidated
                // copy model: this grabs the transcript; the header button
                // grabs the summary + action items.
                HStack {
                    Spacer()
                    Button {
                        copyTranscript()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .disabled(recording.fullText.isEmpty)
                    .help("Copy transcript")
                }
                .padding(.horizontal)
                .padding(.top, 8)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            // Show the speaker column whenever ANY segment has a
                            // speaker label — that's how the user knows
                            // diarization actually ran for this recording.
                            // Dictation segments have nil speakers, so they
                            // naturally hide the column; a meeting where
                            // pyannote found only 1 speaker still shows
                            // "Speaker A" so the user gets feedback that the
                            // detection ran (vs. silently failing to detect).
                            let hasSpeakers = recording.segments.contains { $0.speaker != nil }
                            // Only color speaker labels once there's more than
                            // one distinct speaker to tell apart — a single-
                            // speaker recording keeps the plain tint color.
                            let hasMultipleSpeakers = recording.segments.hasMultipleSpeakers
                            // Distinct raw ids in transcript order — the targets
                            // offered for "move this line" and "merge into".
                            // Hoisted out of the row so it is computed once, not
                            // once per segment.
                            let distinctSpeakers = distinctSpeakerIDs
                            let lineCounts = lineCountsBySpeaker
                            // One active id per render drives BOTH the highlight and
                            // the scroll target, so they can never disagree.
                            let activeID = activeSegmentID
                            ForEach(recording.segments) { seg in
                                SegmentRow(segment: seg,
                                           isActive: seg.id == activeID,
                                           showSpeaker: hasSpeakers,
                                           useSpeakerColor: hasMultipleSpeakers,
                                           language: recording.language,
                                           speakerNames: recording.speakerNames,
                                           allSpeakers: distinctSpeakers,
                                           onTap: {
                                               // Tapping a line is an explicit "go
                                               // here", so it re-engages following.
                                               isFollowing = true
                                               seek(to: seg.start)
                                           },
                                           onAssignName: { raw, name in
                                               store.setSpeakerName(name, forSpeaker: raw,
                                                                    recordingID: recording.id)
                                           },
                                           // Only when the speaker has another
                                           // line to keep — see `lineCountsBySpeaker`.
                                           onSplit: (seg.speaker.map { lineCounts[$0] ?? 0 } ?? 0) > 1
                                               ? {
                                                   store.splitSegmentSpeaker(segmentID: seg.id,
                                                                             recordingID: recording.id)
                                               }
                                               : nil,
                                           onMoveLine: { target in
                                               store.reassignSegmentSpeaker(segmentID: seg.id,
                                                                            toSpeaker: target,
                                                                            recordingID: recording.id)
                                           },
                                           onRequestMerge: { source, target in
                                               pendingMerge = PendingSpeakerMerge(
                                                   source: source,
                                                   target: target,
                                                   sourceName: source.displaySpeakerName(
                                                       names: recording.speakerNames,
                                                       language: recording.language),
                                                   targetName: target.displaySpeakerName(
                                                       names: recording.speakerNames,
                                                       language: recording.language))
                                           })
                                .background {
                                    // Only the ACTIVE row publishes its frame: one
                                    // GeometryReader for the whole transcript rather
                                    // than one per segment. Used to decide whether a
                                    // manual scroll ended with the highlight back on
                                    // screen. A row the LazyVStack has unloaded
                                    // publishes nothing -- correctly "not visible".
                                    if seg.id == activeID {
                                        GeometryReader { geo in
                                            Color.clear.preference(
                                                key: ActiveRowFrameKey.self,
                                                value: geo.frame(in: .named(Self.transcriptSpace)))
                                        }
                                    }
                                }
                            }
                        }
                        .padding()
                        .background {
                            // Must live INSIDE the ScrollView: the probe locates its
                            // NSScrollView via `enclosingScrollView`, which only
                            // resolves from a descendant of the clip view.
                            ScrollActivityProbe(onUserScroll: userDidScroll,
                                                onScrollEnded: userScrollEnded,
                                                follow: follow)
                                .frame(width: 0, height: 0)
                                .allowsHitTesting(false)
                        }
                        // RTL from the actual transcript text, not just the
                        // language field: a recording made on "auto"/English
                        // while the speaker talked Hebrew still has `language`
                        // != "he", which left Hebrew transcripts LEFT-aligned.
                        // SegmentRow uses `.leading`, so layoutDirection mirrors
                        // it to the right exactly once.
                        .environment(\.layoutDirection,
                                     (recording.language == "he" || recording.fullText.isPredominantlyHebrew)
                                     ? .rightToLeft : .leftToRight)
                    }
                    .contextMenu {
                        let other = RecordingLanguage.fromCode(recording.language).other
                        Button("Re-transcribe in \(other.flagEmoji) \(other.displayName)") {
                            retranscribe(in: other)
                        }
                        Button("Copy transcript") { copyTranscript() }
                            .disabled(recording.fullText.isEmpty)
                    }
                    .coordinateSpace(name: Self.transcriptSpace)
                    .onPreferenceChange(ActiveRowFrameKey.self) { rect in
                        // Written to the coordinator, not @State: this fires on
                        // every scrolled frame and a @State write would re-lay out
                        // the transcript each time.
                        follow.activeRowFrame = rect
                    }
                    // Keyed on the segment ID, NOT on currentTime: the periodic
                    // time observer ticks 30x/sec, so keying on time would start
                    // 30 scroll animations a second.
                    .onChange(of: activeSegmentID) { _, id in
                        guard isFollowing, let id else { return }
                        scrollToActive(proxy, id: id)
                    }
                    .overlay(alignment: .bottom) { followPill(proxy) }
                    .animation(.easeOut(duration: 0.2), value: isFollowing)
                }
            }
            // Presented HERE, not inside the speaker popover: the tap that
            // asks for a merge also dismisses that popover, and an alert
            // attached to a disappearing view is how the previous attempt at
            // this action ended up doing nothing. Merging is destructive and
            // has no undo, so it is always confirmed.
            .alert("Merge speakers?",
                   isPresented: Binding(get: { pendingMerge != nil },
                                        set: { if !$0 { pendingMerge = nil } }),
                   presenting: pendingMerge) { merge in
                Button("Merge", role: .destructive) {
                    store.mergeSpeakers(from: merge.source, into: merge.target,
                                        recordingID: recording.id)
                    pendingMerge = nil
                }
                Button("Cancel", role: .cancel) { pendingMerge = nil }
            } message: { merge in
                Text("Every line from \(merge.sourceName) becomes \(merge.targetName). This can't be undone.")
            }
        }
    }

    /// A merge the user asked for and has not yet confirmed.
    struct PendingSpeakerMerge: Identifiable {
        let source: String
        let target: String
        let sourceName: String
        let targetName: String
        var id: String { "\(source)->\(target)" }
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
                speedMenu
            }
            .padding()
        }
    }

    /// Playback speed picker. Borderless menu labelled with the current rate,
    /// matching `LanguagePickerToolbarItem` in ContentView.
    private var speedMenu: some View {
        Menu {
            Picker("Playback speed", selection: $playbackSpeed) {
                ForEach(PlaybackSpeed.allCases) { speed in
                    Text(speed.label).tag(speed.rawValue)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            // Fixed width so switching between "1×" and "1.25×" doesn't resize
            // the seek slider next to it.
            Text(PlaybackSpeed.nearest(to: playbackSpeed).label)
                .monospacedDigit()
                .frame(width: 46, alignment: .trailing)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Playback speed")
        .accessibilityIdentifier("detail.playback.speed")
    }

    /// Active line sits 35% down the viewport — close enough to centre to feel
    /// stable, high enough that most of the screen shows what's coming next.
    private static let followAnchor = UnitPoint(x: 0.5, y: 0.35)
    private static let transcriptSpace = "detail.transcript.scroll"

    /// The segment covering `time`, as a pure function so TranscriptFollowTests
    /// can pin the boundary and silence-gap cases without building the view.
    /// Intervals are half-open — `start` inclusive, `end` exclusive — so a pause
    /// between segments correctly yields nil.
    static func activeSegmentID(segments: [TranscriptSegment],
                                at time: Double) -> TranscriptSegment.ID? {
        segments.first { time >= $0.start && time < $0.end }?.id
    }

    private var activeSegmentID: TranscriptSegment.ID? {
        Self.activeSegmentID(segments: recording.segments, at: currentTime)
    }

    private func scrollToActive(_ proxy: ScrollViewProxy, id: TranscriptSegment.ID) {
        follow.suppress()
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(id, anchor: Self.followAnchor)
        }
    }

    private func userDidScroll() {
        guard !follow.isSuppressed, isFollowing else { return }
        isFollowing = false
    }

    private func userScrollEnded() {
        guard !follow.isSuppressed, !isFollowing else { return }
        // A small nudge that left the highlight on screen resumes following;
        // scrolling properly away leaves the pill up. No scroll is issued here —
        // letting the next segment change re-centre is gentler than yanking the
        // view the instant the user lets go.
        if follow.activeRowIsVisible { isFollowing = true }
    }

    /// Floating "Follow playback" affordance, shown only while following is off
    /// AND playback has actually moved. Without the `currentTime` gate, scrolling
    /// a transcript you never played would pop a button with nothing to follow.
    @ViewBuilder
    private func followPill(_ proxy: ScrollViewProxy) -> some View {
        if !isFollowing, currentTime > 0 {
            Button {
                isFollowing = true
                if let id = activeSegmentID { scrollToActive(proxy, id: id) }
            } label: {
                Label("Follow playback", systemImage: "arrow.down.circle.fill")
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08),
                                                    lineWidth: 1))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 16)
            .help("Resume following playback in the transcript")
            .accessibilityIdentifier("detail.transcript.followPlayback")
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func configurePlayer() {
        teardownPlayer()
        let url = store.audioURL(for: recording)
        let item = AVPlayerItem(url: url)
        // `.timeDomain` is Apple's recommended algorithm for voice — it keeps
        // pitch natural at 0.5×/2× and costs less than AVPlayer's `.spectral`
        // default, which smears speech at the higher rates.
        item.audioTimePitchAlgorithm = .timeDomain
        let p = AVPlayer(playerItem: item)
        // `defaultRate` (macOS 13+) is what a bare `play()` resumes at, so
        // PlayPauseButton needs no knowledge of the speed setting.
        p.defaultRate = Float(PlaybackSpeed.nearest(to: playbackSpeed).rawValue)
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
        let text = TranscriptFormatter.plainText(segments: recording.segments,
                                                 fallback: recording.fullText,
                                                 names: recording.speakerNames)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Whether there's any AI overview content (summary or action items)
    /// to copy. Gates the header's "Copy summary + action items" button.
    private var hasOverviewToCopy: Bool {
        let hasSummary = recording.summary?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let hasItems = !(recording.actionItems ?? []).isEmpty
        return hasSummary || hasItems
    }

    /// Copy the AI overview (summary + action items) as plain text: the
    /// summary first, then — separated by a blank line — the action items
    /// as `•\u{00A0}…` lines. Only the parts that actually exist are
    /// included, so a summary-only or items-only recording copies cleanly.
    private func copyOverview() {
        var parts: [String] = []
        if let summary = recording.summary?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            parts.append(summary)
        }
        let items = recording.actionItems ?? []
        if !items.isEmpty {
            parts.append(items.map { "•\u{00A0}\($0.text)" }.joined(separator: "\n"))
        }
        guard !parts.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(parts.joined(separator: "\n\n"), forType: .string)
    }
}

private struct PlayPauseButton: View {
    let player: AVPlayer
    /// Stable local state. The previous design wrapped the player in a
    /// `PlayerBridge` ObservableObject and used `@ObservedObject`,
    /// which RE-INSTANTIATED the bridge (and a fresh KVO observer)
    /// on every parent re-render. As soon as playback started, the
    /// time observer in `configurePlayer` fired ~30×/sec and forced
    /// re-renders of the playback bar — each one tore down the old
    /// bridge, briefly read `timeControlStatus == .paused` while the
    /// new bridge was warming up, and flipped the icon back to "play"
    /// for one frame before the KVO callback caught up. Hence the
    /// flicker. Owning a plain @State Bool + a single long-lived
    /// observer in onAppear is enough.
    @State private var isPlaying: Bool = false
    @State private var observer: NSKeyValueObservation?

    var body: some View {
        Button {
            if player.timeControlStatus == .playing {
                player.pause()
            } else {
                // AVPlayer parks at end-of-item when playback finishes and
                // a bare play() there is a no-op — the button looked dead
                // after a memo played to the end until the user dragged the
                // slider back. Rewind first in that case.
                if let item = player.currentItem, item.duration.isNumeric,
                   item.duration.seconds - player.currentTime().seconds <= 0.1 {
                    player.seek(to: .zero)
                }
                player.play()
            }
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderedProminent)
        .onAppear {
            isPlaying = (player.timeControlStatus == .playing)
            // KVO on timeControlStatus is enough — fires on every
            // transition between paused / waiting / playing.
            observer = player.observe(\.timeControlStatus, options: [.new]) { p, _ in
                DispatchQueue.main.async {
                    isPlaying = (p.timeControlStatus == .playing)
                }
            }
        }
        .onDisappear {
            observer?.invalidate()
            observer = nil
        }
    }
}

/// Live-AI summary + action items, captured at recording stop time and
/// persisted onto the Recording. Extracted into its own `View` rather
/// than a `@ViewBuilder` var on the parent so the body's type inference
/// is contained: a SwiftUI hiccup inside this section never silently
/// blanks the rest of the detail screen, which is the symptom the user
/// was hitting when both the sidebar and the detail pane went empty
/// after transcription completed.
/// Detail-screen wrapper around the shared `AIOverviewSection` (which
/// renders Summary + Action items). The wrapper caps the section at
/// 240 pt inside a `ScrollView` and adds a trailing `Divider` so a
/// recording with many action items or a long summary can NEVER push
/// the transcript / playback bar off-screen.
private struct AIOverviewBanner: View {
    let summary: String?
    let items: [ActionItem]
    let recordingLanguage: String
    /// Forwarded to `AIOverviewSection` so the summary block shows a
    /// "Summarizing…" spinner while a regenerate / backfill call is in
    /// flight.
    var isSummarizing: Bool = false
    /// Forwarded to `AIOverviewSection`'s context-menu wiring. nil
    /// hides the "Regenerate summary" item (e.g. when no LLM is
    /// configured or the transcript is empty).
    var onRegenerateSummary: (() -> Void)? = nil

    var body: some View {
        let section = AIOverviewSection(
            summary: summary,
            items: items,
            recordingLanguage: recordingLanguage,
            onRegenerateSummary: onRegenerateSummary,
            isSummarizing: isSummarizing,
            // The detail view consolidates copy into two location-based
            // buttons (Summary+Action-items up top, transcript in the
            // transcript area), so the per-block header copy buttons are
            // hidden here. The block's native right-click "Copy" stays.
            showsBlockCopyButtons: false
        )
        if section.hasContent {
            VStack(spacing: 0) {
                ScrollView {
                    section
                        .padding(.horizontal)
                        .padding(.vertical, 12)
                }
                // Hard cap so a recording with many action items or a
                // long summary can NEVER push the transcript /
                // playback bar off-screen. The inner content scrolls
                // independently inside this slot if it exceeds 240 pt.
                .frame(maxHeight: 240)
                Divider()
            }
        }
    }
}

private struct SegmentRow: View {
    let segment: TranscriptSegment
    let isActive: Bool
    let showSpeaker: Bool
    /// Whether to color the speaker label per-speaker rather than the
    /// default tint — set by the caller once it's seen more than one
    /// distinct speaker across the recording.
    let useSpeakerColor: Bool
    /// Recording's language so we can render the raw `SPEAKER_00`
    /// label from pyannote as `Speaker A` / `דובר א׳` in the user's
    /// language — matching the labels the live view + post-recording
    /// action items already show.
    let language: String
    /// User-assigned speaker names for this recording (raw ID → name).
    let speakerNames: [String: String]
    /// Every distinct raw speaker id in the recording, in transcript order.
    /// The popover offers the ones that aren't this row's as move/merge
    /// targets.
    let allSpeakers: [String]
    let onTap: () -> Void
    /// Persists a rename picked from the label's popover:
    /// (raw speaker ID, chosen name or nil-to-reset).
    let onAssignName: (String, String?) -> Void
    /// Split this segment into a new unnamed speaker.
    var onSplit: (() -> Void)?
    /// Move just this segment to the given raw speaker id.
    var onMoveLine: ((String) -> Void)?
    /// Ask to merge this row's speaker (first argument) into another raw id.
    /// The caller confirms before anything happens.
    var onRequestMerge: ((_ from: String, _ into: String) -> Void)?

    /// The other speakers, resolved to what the transcript shows for them.
    private func otherSpeakers(besides raw: String) -> [SpeakerChoice] {
        allSpeakers.filter { $0 != raw }.map {
            SpeakerChoice(rawID: $0,
                          displayName: $0.displaySpeakerName(names: speakerNames,
                                                             language: language))
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Speaker prefix sits TIGHT against the text — fixed-width
            // columns introduced a gap (~30 pt) between the friendly
            // label "Speaker A" / "דובר א׳" and the actual content.
            // `fixedSize` keeps the label at its natural width.
            if showSpeaker, let raw = segment.speaker, !raw.isEmpty {
                SpeakerLabelButton(
                    rawID: raw,
                    names: speakerNames,
                    language: language,
                    color: useSpeakerColor ? raw.speakerColor(names: speakerNames) : Color.accentColor,
                    suffix: ":",
                    onAssign: { name in onAssignName(raw, name) },
                    onSplit: onSplit,
                    otherSpeakers: otherSpeakers(besides: raw),
                    onMoveLine: onMoveLine,
                    // Bind this row's speaker as the merge SOURCE; the picker
                    // only supplies the target.
                    onRequestMerge: onRequestMerge == nil ? nil : { target in
                        onRequestMerge?(raw, target)
                    }
                )
                .fixedSize(horizontal: true, vertical: false)
            }
            Text(segment.text)
                .font(.body)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(formatDuration(segment.start))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(8)
        .background(isActive ? Color.accentColor.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}

/// Mutable scroll-following state that must NOT drive view updates.
///
/// The scroll probe and the active-row preference write here on every scrolled
/// frame; routing that through `@State` would re-lay out the whole transcript
/// each time. All access is on the main thread, hence `@unchecked Sendable`.
private final class FollowCoordinator: @unchecked Sendable {
    /// Frame of the highlighted row in the ScrollView's own coordinate space,
    /// or nil when no segment is active or the LazyVStack has unloaded it.
    var activeRowFrame: CGRect?
    var viewportHeight: CGFloat = 0

    private var suppressUntil = Date.distantPast

    /// True while a scroll WE started may still be moving the clip view, so its
    /// bounds changes aren't mistaken for the user scrolling.
    var isSuppressed: Bool { Date() < suppressUntil }

    /// Slightly longer than the 0.25s scroll animation.
    func suppress(for interval: TimeInterval = 0.45) {
        suppressUntil = Date().addingTimeInterval(interval)
    }

    /// Frames are relative to the viewport, so a row scrolled off the top has a
    /// negative maxY and one below the fold has minY past the viewport height.
    var activeRowIsVisible: Bool {
        guard let frame = activeRowFrame, viewportHeight > 0 else { return false }
        return frame.maxY > 0 && frame.minY < viewportHeight
    }
}

/// Carries the highlighted row's frame out of the transcript. Only the active
/// row ever publishes a value, so `reduce` just keeps the non-nil one.
private struct ActiveRowFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

/// Detects user-driven scrolling in the enclosing `NSScrollView`.
///
/// macOS 14 is the deployment target, so `onScrollGeometryChange` (macOS 15+)
/// is unavailable, and SwiftUI on 14 gives no way to tell our own animated
/// `scrollTo` from a trackpad flick. AppKit does: live-scroll notifications are
/// posted only for user gestures, never for programmatic scrolls.
private struct ScrollActivityProbe: NSViewRepresentable {
    let onUserScroll: () -> Void
    let onScrollEnded: () -> Void
    let follow: FollowCoordinator

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.configure(onUserScroll: onUserScroll, onScrollEnded: onScrollEnded, follow: follow)
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.configure(onUserScroll: onUserScroll, onScrollEnded: onScrollEnded, follow: follow)
    }

    final class ProbeView: NSView {
        private var onUserScroll: (() -> Void)?
        private var onScrollEnded: (() -> Void)?
        private var follow: FollowCoordinator?
        private var observers: [NSObjectProtocol] = []
        private var lastOriginY: CGFloat = .nan

        func configure(onUserScroll: @escaping () -> Void,
                       onScrollEnded: @escaping () -> Void,
                       follow: FollowCoordinator) {
            self.onUserScroll = onUserScroll
            self.onScrollEnded = onScrollEnded
            self.follow = follow
        }

        /// Zero-sized and transparent to clicks — it must never intercept a tap
        /// meant for a transcript row.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }

        private func attach() {
            guard observers.isEmpty else { return }
            guard let scrollView = enclosingScrollView else {
                // The NSScrollView isn't in the hierarchy on the first pass;
                // retry once SwiftUI has finished mounting.
                if window != nil {
                    DispatchQueue.main.async { [weak self] in self?.attach() }
                }
                return
            }
            let center = NotificationCenter.default
            let clip = scrollView.contentView
            clip.postsBoundsChangedNotifications = true
            follow?.viewportHeight = clip.bounds.height
            lastOriginY = clip.bounds.origin.y

            observers.append(center.addObserver(forName: NSScrollView.didLiveScrollNotification,
                                                object: scrollView, queue: .main) { [weak self] _ in
                self?.onUserScroll?()
            })
            observers.append(center.addObserver(forName: NSScrollView.didEndLiveScrollNotification,
                                                object: scrollView, queue: .main) { [weak self] _ in
                self?.onScrollEnded?()
            })
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification,
                                                object: clip, queue: .main) { [weak self] _ in
                self?.boundsChanged(clip)
            })
        }

        private func boundsChanged(_ clip: NSClipView) {
            follow?.viewportHeight = clip.bounds.height
            let originY = clip.bounds.origin.y
            defer { lastOriginY = originY }
            guard abs(originY - lastOriginY) > 0.5 else { return }
            // Fallback for the paths that post no live-scroll notification —
            // scroller drags, Page Up/Down. Gated on a user input event being in
            // flight so layout-driven bounds changes (window resize, the
            // LazyVStack loading more rows) don't read as a manual scroll.
            guard Self.isUserInputInFlight else { return }
            onUserScroll?()
            onScrollEnded?()
        }

        private static var isUserInputInFlight: Bool {
            guard let type = NSApp?.currentEvent?.type else { return false }
            switch type {
            case .scrollWheel, .leftMouseDown, .leftMouseDragged, .leftMouseUp,
                 .otherMouseDragged, .keyDown:
                return true
            default:
                return false
            }
        }
    }
}
