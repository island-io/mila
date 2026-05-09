import SwiftUI
import AppKit

struct HistoryListView: View {
    let category: HistoryCategory
    let search: String
    @Binding var selection: SidebarSelection?

    @EnvironmentObject private var store: RecordingStore

    init(category: HistoryCategory,
         search: String = "",
         selection: Binding<SidebarSelection?>) {
        self.category = category
        self.search = search
        self._selection = selection
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(category.displayName)
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.top, 16)

                BucketedRecordingsView(
                    recordings: store.recordings(in: category),
                    search: search,
                    selection: $selection
                )
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct BucketedRecordingsView: View {
    let recordings: [Recording]
    let search: String
    @Binding var selection: SidebarSelection?

    var body: some View {
        let filtered = filterRecordings(recordings, search: search)
        let buckets = bucketByDate(filtered)

        if filtered.isEmpty {
            HStack {
                Spacer()
                emptyState
                Spacer()
            }
            .padding(.top, 60)
        } else {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(buckets, id: \.label) { bucket in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(bucket.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)

                        VStack(spacing: 0) {
                            ForEach(Array(bucket.items.enumerated()), id: \.element.id) { idx, rec in
                                HistoryRow(recording: rec, selection: $selection)
                                if idx < bucket.items.count - 1 {
                                    Divider().padding(.leading, 36)
                                }
                            }
                        }
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if search.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView(
                "Nothing here yet",
                systemImage: "tray",
                description: Text("New recordings will appear in this list.")
            )
        } else {
            ContentUnavailableView.search(text: search)
        }
    }
}

private struct HistoryRow: View {
    let recording: Recording
    @Binding var selection: SidebarSelection?

    @EnvironmentObject private var store: RecordingStore
    @EnvironmentObject private var transcription: TranscriptionService

    @State private var hovering = false

    var body: some View {
        let isSelected: Bool = {
            if case .recording(let id) = selection, id == recording.id { return true }
            return false
        }()

        HStack(alignment: .top, spacing: 12) {
            Image(systemName: recording.source.sfSymbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 22, height: 22)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(recording.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(formatDuration(recording.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if !preview.isEmpty {
                    Text(preview)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                HStack(spacing: 6) {
                    Text(recording.createdAt, format: .dateTime.hour().minute())
                    Text("·")
                    Text(recording.source.displayName)
                    if transcription.activeRecordingID == recording.id {
                        Text("·")
                        ProgressView(value: transcription.progress)
                            .progressViewStyle(.linear)
                            .frame(width: 80)
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.18)
                : (hovering ? Color.primary.opacity(0.04) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { selection = .recording(recording.id) }
        .contextMenu { contextMenu }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if recording.isTrashed {
            Button("Restore") { store.restore(recording) }
            Divider()
            Button("Delete Permanently", role: .destructive) {
                store.permanentlyDelete(recording)
                if case .recording(let id) = selection, id == recording.id {
                    selection = .home
                }
            }
        } else {
            let currentLang = RecordingLanguage.fromCode(recording.language)
            Button("Re-transcribe (\(currentLang.flagEmoji) \(currentLang.displayName))") {
                transcription.enqueue(recording)
            }
            Button("Re-transcribe in \(currentLang.other.flagEmoji) \(currentLang.other.displayName)") {
                retranscribe(recording, in: currentLang.other)
            }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([store.audioURL(for: recording)])
            }
            Divider()
            Button("Delete", role: .destructive) {
                store.softDelete(recording)
                if case .recording(let id) = selection, id == recording.id {
                    selection = .home
                }
            }
        }
    }

    /// Switch the recording's stored language and re-enqueue it. The
    /// `TranscriptionService` reads `recording.language` to pick the right
    /// model (ivrit.ai for Hebrew, OpenAI for English), so updating the
    /// store before enqueueing is enough to re-run with the other model.
    private func retranscribe(_ recording: Recording, in language: RecordingLanguage) {
        var copy = recording
        copy.language = language.rawValue
        copy.status = .pending
        store.update(copy)
        transcription.enqueue(copy)
    }

    private var preview: String {
        let t = recording.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= 140 { return t }
        let end = t.index(t.startIndex, offsetBy: 140)
        return String(t[..<end]) + "…"
    }
}

func filterRecordings(_ recs: [Recording], search: String) -> [Recording] {
    let q = search.trimmingCharacters(in: .whitespaces).lowercased()
    guard !q.isEmpty else { return recs }
    return recs.filter { r in
        r.title.lowercased().contains(q) || r.fullText.lowercased().contains(q)
    }
}

struct DateBucket {
    let label: String
    let items: [Recording]
}

func bucketByDate(_ recs: [Recording]) -> [DateBucket] {
    let cal = Calendar.current
    let now = Date()

    let weekdayFmt = DateFormatter()
    weekdayFmt.dateFormat = "EEEE"
    let dateFmt = DateFormatter()
    dateFmt.dateStyle = .long

    var todayItems: [Recording] = []
    var yesterdayItems: [Recording] = []
    var weekItems: [(key: String, recs: [Recording])] = []
    var olderItems: [(key: String, recs: [Recording])] = []

    func appendInto(_ list: inout [(key: String, recs: [Recording])], key: String, rec: Recording) {
        if let idx = list.firstIndex(where: { $0.key == key }) {
            list[idx].recs.append(rec)
        } else {
            list.append((key: key, recs: [rec]))
        }
    }

    for r in recs {
        let date = r.createdAt
        if cal.isDateInToday(date) {
            todayItems.append(r)
        } else if cal.isDateInYesterday(date) {
            yesterdayItems.append(r)
        } else if let days = cal.dateComponents([.day],
                                                from: cal.startOfDay(for: date),
                                                to: cal.startOfDay(for: now)).day,
                  days >= 0, days < 7 {
            appendInto(&weekItems, key: weekdayFmt.string(from: date), rec: r)
        } else {
            appendInto(&olderItems, key: dateFmt.string(from: date), rec: r)
        }
    }

    var buckets: [DateBucket] = []
    if !todayItems.isEmpty { buckets.append(DateBucket(label: "Today", items: todayItems)) }
    if !yesterdayItems.isEmpty { buckets.append(DateBucket(label: "Yesterday", items: yesterdayItems)) }
    for w in weekItems { buckets.append(DateBucket(label: w.key, items: w.recs)) }
    for o in olderItems { buckets.append(DateBucket(label: o.key, items: o.recs)) }
    return buckets
}
