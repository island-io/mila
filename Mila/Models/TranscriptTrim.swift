import Foundation
import TranscriptionCore
import MilaKit

/// Pure transcript edits behind the detail view's "Delete Segment(s)" and
/// "End Conversation Here" (island-io/mila#357). Kept free of the store and of
/// SwiftUI so the rules — what is removed, what the `.txt` text becomes, where
/// the audio is cut — are pinned by `TranscriptTrimTests` without a window.
///
/// Every edit is expressed against the transcript ORDER the user sees
/// (`Recording.segments`), not against timestamps: "everything after this
/// line" means the lines below it on screen.
enum TranscriptTrim {

    /// Audio kept past the last kept line's `end` when the conversation is
    /// ended there. whisper's segment ends land on the last word's onset as
    /// often as on its tail, so cutting exactly at `end` can clip the final
    /// syllable. Never reaches into the first removed line (see
    /// `audioCutTime`).
    static let audioTailPadding: Double = 0.5

    /// Where the audio should end when the conversation ends at `segmentID`,
    /// or nil when there is nothing after it (or the id is unknown) — the
    /// same cases in which `Recording.endingConversation(at:)` declines.
    ///
    /// The cut is the latest `end` among the KEPT lines (an earlier line can
    /// overlap a later one), padded by `audioTailPadding` but never past the
    /// first removed line's `start`: the padding exists to keep the tail of
    /// the last kept word, not to keep the head of the first deleted one.
    static func audioCutTime(endingAt segmentID: TranscriptSegment.ID,
                             in segments: [TranscriptSegment]) -> Double? {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }),
              index < segments.count - 1 else { return nil }
        let keptEnd = segments[...index].map(\.end).max() ?? 0
        let nextStart = segments[index + 1].start
        let padding = max(0, min(audioTailPadding, nextStart - keptEnd))
        let cut = keptEnd + padding
        // Persisted data is user-editable; a NaN or negative time must not
        // reach the audio rewrite as a frame count.
        guard cut.isFinite, cut > 0 else { return nil }
        return cut
    }

    /// How many lines "End Conversation Here" on `segmentID` would remove.
    /// Zero for the last line or an unknown id, which is what disables the
    /// menu item.
    static func linesAfter(_ segmentID: TranscriptSegment.ID,
                           in segments: [TranscriptSegment]) -> Int {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else { return 0 }
        return segments.count - index - 1
    }
}

extension Recording {

    /// This recording with the lines in `ids` removed, or nil when the edit
    /// would remove nothing (no id matches) or EVERYTHING. Emptying a
    /// transcript line by line is not a trim — it leaves a `.completed` row
    /// that reads as "No transcript yet" — so that is left to deleting the
    /// recording itself.
    ///
    /// `fullText` (the `.txt` sidecar, and what mila-mcp serves) is rebuilt
    /// from the remaining segments with `TranscriptFormatter.joinedFullText`,
    /// the same reconstruction `RecordingStore.load` and `MilaStoreReader`
    /// fall back to, so every reader agrees on what the trimmed text is.
    ///
    /// Speaker names are left alone even when a speaker loses every line: a
    /// name is a display overlay and a voice-profile contribution, and
    /// dropping it here would quietly subtract a voice the user still wants
    /// recognised. `duration` is untouched — the audio still runs to the end.
    func removingSegments(_ ids: Set<TranscriptSegment.ID>) -> Recording? {
        let kept = segments.filter { !ids.contains($0.id) }
        guard kept.count < segments.count, !kept.isEmpty else { return nil }
        var copy = self
        copy.segments = kept
        copy.fullText = TranscriptFormatter.joinedFullText(segments: kept)
        return copy
    }

    /// This recording with every line AFTER `segmentID` removed — "Mila kept
    /// recording by mistake". nil when `segmentID` is unknown or is already
    /// the last line.
    ///
    /// Action items the Live AI loop stamped later than the audio cut
    /// (`TranscriptTrim.audioCutTime`) are dropped with the lines: they were
    /// surfaced from talk the user has just said is not part of this meeting.
    /// An item with no usable timestamp decodes as 0 and is kept, so the rule
    /// can only ever under-delete. The list stays non-nil (possibly empty)
    /// when it was non-nil, which keeps "Live AI ran" distinguishable.
    ///
    /// `duration` is NOT changed here: it describes the audio file, and only
    /// `RecordingStore.trimAudio` — after the file really is shorter — may
    /// shorten it.
    func endingConversation(at segmentID: TranscriptSegment.ID) -> Recording? {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }),
              index < segments.count - 1 else { return nil }
        let kept = Array(segments[...index])
        var copy = self
        copy.segments = kept
        copy.fullText = TranscriptFormatter.joinedFullText(segments: kept)
        if let cut = TranscriptTrim.audioCutTime(endingAt: segmentID, in: segments),
           let items = actionItems {
            copy.actionItems = items.filter { !($0.timestampSeconds > cut) }
        }
        return copy
    }
}

/// Click-to-select state for the transcript rows: a plain click selects one
/// line, shift-click extends from the anchor to the clicked line (Finder's
/// list semantics), command-click toggles one line. A pure value so the
/// range arithmetic is tested without a view.
struct TranscriptSelection: Equatable {
    enum Click: Equatable {
        case plain
        case extend
        case toggle
    }

    private(set) var ids: Set<TranscriptSegment.ID> = []
    /// The line a shift-click extends FROM. Set by plain and command clicks,
    /// kept across shift-clicks so repeated shift-clicks re-span from the
    /// same origin rather than accumulating.
    private(set) var anchor: TranscriptSegment.ID?

    var isEmpty: Bool { ids.isEmpty }

    func contains(_ id: TranscriptSegment.ID) -> Bool { ids.contains(id) }

    /// The selection after `kind` of click on `id`, given the transcript's
    /// display `order`. An id not in `order` (a line deleted since the view
    /// rendered) leaves the selection unchanged.
    func clicking(_ id: TranscriptSegment.ID,
                  kind: Click,
                  order: [TranscriptSegment.ID]) -> TranscriptSelection {
        guard let clickedIndex = order.firstIndex(of: id) else { return self }
        var next = self
        switch kind {
        case .plain:
            next.ids = [id]
            next.anchor = id
        case .toggle:
            if next.ids.contains(id) {
                next.ids.remove(id)
            } else {
                next.ids.insert(id)
            }
            next.anchor = id
        case .extend:
            guard let anchor, let anchorIndex = order.firstIndex(of: anchor) else {
                // No usable anchor (nothing selected yet, or the anchor line
                // is gone): behave as a plain click.
                next.ids = [id]
                next.anchor = id
                return next
            }
            let range = min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)
            next.ids = Set(order[range])
        }
        return next
    }

    /// Drop ids that no longer name a line (after a delete, or a
    /// re-transcription that minted new segment ids).
    func pruned(to order: [TranscriptSegment.ID]) -> TranscriptSelection {
        let live = Set(order)
        var next = self
        next.ids = ids.intersection(live)
        if let anchor, !live.contains(anchor) { next.anchor = nil }
        return next
    }

    /// What a "Delete" picked from the context menu of `clickedID` applies
    /// to: the whole selection when the clicked line is part of it, otherwise
    /// just that line (right-clicking an unselected line acts on that line,
    /// as in Finder).
    func deletionTarget(forContextClickOn clickedID: TranscriptSegment.ID) -> Set<TranscriptSegment.ID> {
        ids.contains(clickedID) ? ids : [clickedID]
    }
}
