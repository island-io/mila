import Foundation
import TranscriptionCore

enum RecordingSource: String, Codable, CaseIterable, Identifiable {
    case microphone
    case systemAudio
    case meeting
    /// Imported from the iPhone's Voice Memos app via the iCloud-synced
    /// folder on this Mac. Distinct from Mila's own mic capture (which is
    /// `.microphone`) so the origin is visible in the UI and so the sync
    /// importer can dedup these against `Recording.voiceMemoUniqueID`.
    case voiceMemo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .systemAudio: return "System audio"
        case .meeting: return "Meeting (mic + system)"
        case .voiceMemo: return "Voice Memo"
        }
    }

    var sfSymbol: String {
        switch self {
        case .microphone: return "mic.fill"
        case .systemAudio: return "speaker.wave.3.fill"
        case .meeting: return "person.2.wave.2.fill"
        case .voiceMemo: return "waveform"
        }
    }
}

enum TranscriptionStatus: String, Codable {
    case pending
    case running
    case completed
    case failed
}

struct Recording: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var createdAt: Date
    var duration: Double
    var source: RecordingSource
    /// File name (relative to recordings directory) of the .wav file.
    var audioFileName: String
    var status: TranscriptionStatus
    var language: String
    var modelName: String?
    var segments: [TranscriptSegment]
    /// Plain-text transcript. Persisted to a sidecar `.txt` file on disk
    /// (RecordingStore handles I/O); NOT encoded into recordings.json so the
    /// metadata blob stays small as the user accumulates recordings.
    var fullText: String
    /// When non-nil the recording is in the "Recently Deleted" trash.
    var deletedAt: Date?
    /// User-assigned folder. nil = unfiled. Flat namespace (no nesting).
    var folder: String?
    /// The captured app's name when the recording came from an app-audio
    /// (or meeting) capture — used to surface an app-specific badge (Zoom,
    /// Microsoft Teams, …) without re-deriving from the title. nil for
    /// microphone-only or system-wide system-audio captures.
    var appName: String?

    /// The captured app's bundle identifier, recorded alongside `appName`
    /// for app-audio (and meeting) captures. This — not the display name —
    /// is the authoritative signal for `detectedMeetingApp`: it's the same
    /// key Core Audio uses for live meeting detection, it isn't localized,
    /// and it can't be mangled by a rename. nil for microphone-only or
    /// system-wide captures, and for recordings saved before this field
    /// existed (those fall back to the `appName`/`title` substrings).
    var appBundleID: String?

    /// Rolling Live-AI summary captured at the moment recording stopped.
    /// nil for any recording that ran without Live AI mode active.
    var summary: String?

    /// Action items surfaced by Live AI during the recording. nil when
    /// Live AI wasn't running; an empty array means it ran but produced
    /// nothing (rare — usually means the LLM CLI returned an error).
    var actionItems: [ActionItem]?

    /// Stable per-recording identifier from the iPhone Voice Memos library
    /// (`ZCLOUDRECORDING.ZUNIQUEID`) when `source == .voiceMemo`. The sync
    /// importer keys on this to skip recordings it already imported, so a
    /// rescan or app restart never re-imports the same memo. nil for every
    /// non-Voice-Memo recording.
    var voiceMemoUniqueID: String?

    /// The Voice Memos folder this memo was imported from, keyed by the
    /// stable `ZFOLDER.ZUUID`, or `Recording.voiceMemoUnfiledFolderID` for
    /// the unfiled bucket. Set only on `source == .voiceMemo` imports. Lets
    /// "un-selecting a folder removes its recordings" (issue #57) find every
    /// recording that came from a given folder without guessing.
    ///
    /// nil means "origin not recorded" — either a non-Voice-Memo recording or
    /// a memo imported before this field existed. Legacy nil is deliberately
    /// treated as unknown and never swept up by the un-select cleanup, so an
    /// upgrade can't mass-delete a user's older imports.
    var voiceMemoFolderUUID: String?

    /// User-assigned display names for diarized speakers, keyed by the raw
    /// diarizer ID (`SPEAKER_00` → "Daniel"). Segments keep their raw IDs —
    /// this map is a display overlay resolved at render/export time, so
    /// re-clustering tooling and the color palette stay keyed on stable IDs.
    /// Empty for recordings whose speakers were never renamed.
    var speakerNames: [String: String]

    /// Per-recording override of the language the AI summary and action
    /// items are written in — a `RecordingLanguage` raw value (`"he"` /
    /// `"en"`). nil means "follow Settings → AI Features → Output language",
    /// which is what every recording has until the user picks a language
    /// for it from the Summary language menu. Independent of `language`
    /// (the whisper model): a Hebrew meeting can carry an English summary.
    /// Survives re-transcription on purpose — it records what the user
    /// asked for, not what the transcript happened to be in.
    ///
    /// Read through `summaryLanguageOverride`, which refuses anything that
    /// is not one of the two known codes.
    var summaryLanguage: String?

    /// `summaryLanguage` as a `RecordingLanguage`, or nil when unset OR
    /// unrecognised. Deliberately `init(rawValue:)` rather than
    /// `RecordingLanguage.fromCode`: `fromCode` falls back to Hebrew for any
    /// unknown string, which would turn a hand-edited `"fr"` in
    /// recordings.json into a silent Hebrew override. Unknown → nil → the
    /// global setting applies (`bugbot-rules/untrusted-persisted-data.md`).
    var summaryLanguageOverride: RecordingLanguage? {
        summaryLanguage.flatMap(RecordingLanguage.init(rawValue:))
    }

    /// Display name of the person who shared this recording, when it arrived
    /// as a `.milashare` bundle rather than being recorded or imported here.
    /// nil for everything Mila captured itself. Attribution only — it does
    /// not change `source`, so a shared Zoom meeting is still a meeting.
    var sharedBy: String?

    /// When the bundle that brought this recording was exported (the
    /// sender's clock). Set together with `sharedBy`, nil otherwise.
    var sharedAt: Date?
    /// When the user stopped this recording's transcription to run it later
    /// ("Stop Transcribing"), before a full pass had finished — the row has no
    /// transcript, or only a live draft. Set only
    /// alongside `status == .failed`, which is what keeps the launch recovery
    /// sweep from restarting the run; this marker is what lets the UI say
    /// "stopped" instead of "failed". Cleared the moment a new pass starts.
    ///
    /// A field rather than a new `TranscriptionStatus` case on purpose: older
    /// builds decode `status` strictly and load recordings.json all-or-nothing,
    /// so one unknown status value would empty their whole library. An unknown
    /// KEY is ignored instead — an older build just reads the row as `.failed`.
    var transcriptionDeferredAt: Date?

    /// What a recording that already held a transcript looked like before
    /// the user started a re-transcription of it — the status, language and
    /// model that describe the transcript still on the row. Captured by
    /// `RecordingStore.prepareForRetranscription`, consumed by
    /// `markTranscriptionDeferred` when the user stops the re-run (the row
    /// goes back to exactly this, not to the language and model of the run
    /// that never finished), and cleared when a pass settles the row.
    ///
    /// Persisted on the row, not held in memory, because the re-run can
    /// outlive the process: "Re-transcribe in Hebrew" on an English
    /// recording, quit, relaunch — the recovery sweep hands the `.pending`
    /// row straight back to the worker, nothing calls
    /// `prepareForRetranscription` again — and a Stop after that must still
    /// know the transcript is English. In memory it didn't (island-io/mila#320).
    ///
    /// Non-nil only while the row is `.pending`/`.running` — a stop or a
    /// finished pass clears it. A stale value, should one survive (a crash
    /// between the status write and the clear), is harmless: nothing but a
    /// stop reads it, and a stop needs a `.pending`/`.running` row, which
    /// only `prepareForRetranscription` (which overwrites it) or the launch
    /// sweep (for which it is exactly right) produces.
    struct RetranscriptionPriorState: Codable, Hashable {
        var status: TranscriptionStatus
        var language: String
        var modelName: String?
        var transcriptionDeferredAt: Date?
    }

    /// See `RetranscriptionPriorState`. Omitted from recordings.json when nil,
    /// so a row that was never re-transcribed encodes byte-identically to
    /// before the field existed; an older build ignores the key and reads the
    /// row as it always did. Mirrored in MilaKit's `StoredRecording`.
    var retranscriptionPriorState: RetranscriptionPriorState?

    /// Sentinel stored in `voiceMemoFolderUUID` for memos imported from the
    /// Voice Memos "Unfiled" bucket, which has no real folder UUID. Keeps
    /// "imported from Unfiled" distinguishable from a legacy import whose
    /// origin was never recorded (nil) — the former is cleaned up when the
    /// user turns Unfiled off, the latter is left alone.
    static let voiceMemoUnfiledFolderID = "__voicememos.unfiled__"

    init(id: UUID = UUID(),
         title: String,
         createdAt: Date = Date(),
         duration: Double = 0,
         source: RecordingSource,
         audioFileName: String,
         status: TranscriptionStatus = .pending,
         language: String = "he",
         modelName: String? = nil,
         segments: [TranscriptSegment] = [],
         fullText: String = "",
         deletedAt: Date? = nil,
         folder: String? = nil,
         appName: String? = nil,
         appBundleID: String? = nil,
         summary: String? = nil,
         actionItems: [ActionItem]? = nil,
         voiceMemoUniqueID: String? = nil,
         voiceMemoFolderUUID: String? = nil,
         speakerNames: [String: String] = [:],
         summaryLanguage: String? = nil,
         sharedBy: String? = nil,
         sharedAt: Date? = nil,
         transcriptionDeferredAt: Date? = nil,
         retranscriptionPriorState: RetranscriptionPriorState? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.source = source
        self.audioFileName = audioFileName
        self.status = status
        self.language = language
        self.modelName = modelName
        self.segments = segments
        self.fullText = fullText
        self.deletedAt = deletedAt
        self.folder = folder
        self.appName = appName
        self.appBundleID = appBundleID
        self.summary = summary
        self.actionItems = actionItems
        self.voiceMemoUniqueID = voiceMemoUniqueID
        self.voiceMemoFolderUUID = voiceMemoFolderUUID
        self.speakerNames = speakerNames
        self.summaryLanguage = summaryLanguage
        self.sharedBy = sharedBy
        self.sharedAt = sharedAt
        self.transcriptionDeferredAt = transcriptionDeferredAt
        self.retranscriptionPriorState = retranscriptionPriorState
    }

    var isTrashed: Bool { deletedAt != nil }

    /// Whether this recording arrived from another Mila user's `.milashare`.
    var isShared: Bool { sharedBy != nil }
    /// The user stopped this recording's transcription and it has not run
    /// since — see `transcriptionDeferredAt`.
    var isTranscriptionDeferred: Bool { transcriptionDeferredAt != nil }

    /// File name (relative to recordings directory) of the sidecar `.txt`
    /// holding the plain-text transcript. Derived from `audioFileName` so a
    /// recording + its transcript stay side by side and survive a rename.
    var transcriptFileName: String {
        (audioFileName as NSString).deletingPathExtension + ".txt"
    }

    /// File name (relative to recordings directory) of the sidecar
    /// `.summary.txt` holding the LLM-generated meeting summary. Same
    /// derive-from-audio convention as `transcriptFileName` so a user
    /// browsing the recordings directory sees `Foo.wav` + `Foo.txt` +
    /// `Foo.summary.txt` clustered together. Absent on disk whenever
    /// `summary` is nil/empty — the store deletes the sidecar in that
    /// case so we never leave a stale summary around.
    var summaryFileName: String {
        (audioFileName as NSString).deletingPathExtension + ".summary.txt"
    }

    /// File name (relative to recordings directory) of the sidecar `.srt`
    /// subtitle file auto-written after transcription (see
    /// `TranscriptExporter.writeSRT(for:in:)`). Same derive-from-audio
    /// convention as the other sidecars so deleting a recording can clean
    /// up `Foo.srt` alongside `Foo.wav`/`Foo.txt`/`Foo.summary.txt`.
    var subtitleFileName: String {
        (audioFileName as NSString).deletingPathExtension + ".srt"
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, duration, source, audioFileName,
             status, language, modelName, segments, deletedAt, folder, appName,
             appBundleID,
             summary, actionItems, voiceMemoUniqueID, voiceMemoFolderUUID,
             speakerNames, summaryLanguage, sharedBy, sharedAt, transcriptionDeferredAt,
             retranscriptionPriorState
        // `fullText` deliberately excluded — lives in a sidecar .txt file.
        // Legacy records that had it inline are decoded via the custom init.
        case fullText
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.duration = try c.decode(Double.self, forKey: .duration)
        self.source = try c.decode(RecordingSource.self, forKey: .source)
        self.audioFileName = try c.decode(String.self, forKey: .audioFileName)
        self.status = try c.decode(TranscriptionStatus.self, forKey: .status)
        self.language = try c.decode(String.self, forKey: .language)
        self.modelName = try c.decodeIfPresent(String.self, forKey: .modelName)
        self.segments = try c.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
        self.deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        self.folder = try c.decodeIfPresent(String.self, forKey: .folder)
        self.appName = try c.decodeIfPresent(String.self, forKey: .appName)
        self.appBundleID = try c.decodeIfPresent(String.self, forKey: .appBundleID)
        self.summary = try c.decodeIfPresent(String.self, forKey: .summary)
        self.actionItems = try c.decodeIfPresent([ActionItem].self, forKey: .actionItems)
        self.voiceMemoUniqueID = try c.decodeIfPresent(String.self, forKey: .voiceMemoUniqueID)
        self.voiceMemoFolderUUID = try c.decodeIfPresent(String.self, forKey: .voiceMemoFolderUUID)
        self.speakerNames = try c.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
        self.summaryLanguage = try c.decodeIfPresent(String.self, forKey: .summaryLanguage)
        self.sharedBy = try c.decodeIfPresent(String.self, forKey: .sharedBy)
        self.sharedAt = try c.decodeIfPresent(Date.self, forKey: .sharedAt)
        self.transcriptionDeferredAt = try c.decodeIfPresent(Date.self, forKey: .transcriptionDeferredAt)
        // `try?`, not `try`: recordings.json loads all-or-nothing, so a prior
        // state this build cannot read (a `status` value a newer build added,
        // say) must not empty the whole library. Dropping it costs only what
        // a relaunch used to cost — a stop parks the row as an ordinary
        // stopped transcription instead of restoring it.
        self.retranscriptionPriorState = try? c.decodeIfPresent(RetranscriptionPriorState.self,
                                                                forKey: .retranscriptionPriorState)
        // Legacy records still have fullText inline; new records leave it
        // empty here and RecordingStore loads it from the sidecar .txt.
        self.fullText = try c.decodeIfPresent(String.self, forKey: .fullText) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(duration, forKey: .duration)
        try c.encode(source, forKey: .source)
        try c.encode(audioFileName, forKey: .audioFileName)
        try c.encode(status, forKey: .status)
        try c.encode(language, forKey: .language)
        try c.encodeIfPresent(modelName, forKey: .modelName)
        try c.encode(segments, forKey: .segments)
        try c.encodeIfPresent(deletedAt, forKey: .deletedAt)
        try c.encodeIfPresent(folder, forKey: .folder)
        try c.encodeIfPresent(appName, forKey: .appName)
        try c.encodeIfPresent(appBundleID, forKey: .appBundleID)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encodeIfPresent(actionItems, forKey: .actionItems)
        try c.encodeIfPresent(voiceMemoUniqueID, forKey: .voiceMemoUniqueID)
        try c.encodeIfPresent(voiceMemoFolderUUID, forKey: .voiceMemoFolderUUID)
        if !speakerNames.isEmpty {
            try c.encode(speakerNames, forKey: .speakerNames)
        }
        // Omitted when nil so a recordings.json nobody has set an override
        // in is byte-identical to what the previous release wrote.
        try c.encodeIfPresent(summaryLanguage, forKey: .summaryLanguage)
        // Omitted when nil so every recording Mila captured itself encodes
        // byte-for-byte as before. Mirrored in MilaKit's `StoredRecording`.
        try c.encodeIfPresent(sharedBy, forKey: .sharedBy)
        try c.encodeIfPresent(sharedAt, forKey: .sharedAt)
        try c.encodeIfPresent(transcriptionDeferredAt, forKey: .transcriptionDeferredAt)
        try c.encodeIfPresent(retranscriptionPriorState, forKey: .retranscriptionPriorState)
        // fullText intentionally omitted — sidecar .txt is the source of truth.
    }

    /// Sources whose recordings can plausibly have come from a meeting app:
    /// only captures that actually pulled another app's audio. A
    /// `.microphone` or `.voiceMemo` recording never did, so its (freely
    /// user-editable) title must not be scanned for app names — otherwise
    /// renaming a dictation to "teams sync" badges it as a Teams meeting.
    static let meetingAppSources: Set<RecordingSource> = [.systemAudio, .meeting]

    /// The known meeting app this recording came from, if any. Used by list
    /// rows to surface an app-specific badge (Zoom-blue, Teams-purple)
    /// instead of the generic source icon.
    ///
    /// Three passes, strongest signal first, each tried against EVERY app
    /// before the next one runs for any of them — they must not be
    /// interleaved. A single pass that checks "bundle ID or appName or
    /// title" per app lets an earlier case win on a weaker signal: a Teams
    /// recording whose title happens to mention Zoom would be badged Zoom
    /// purely because `.zoom` is declared first.
    ///
    /// 1. `appBundleID` — authoritative. Same key Core Audio uses for live
    ///    detection, not localized, not user-editable.
    /// 2. `appName` — the captured app's (localized) display name, for
    ///    recordings saved before `appBundleID` existed.
    /// 3. `title` — a legacy guess for recordings saved before `appName`
    ///    existed, whose title was auto-derived from the app name. Gated on
    ///    `meetingAppSources` because the title is user-editable and means
    ///    nothing on a mic or Voice Memo recording.
    ///
    /// Passes 2 and 3 are substring matches, so `MeetingApp.matchSubstring`
    /// has to stay specific enough not to collide with unrelated apps.
    var detectedMeetingApp: MeetingApp? {
        if let appBundleID, let byBundleID = MeetingApp.matching(bundleID: appBundleID) {
            return byBundleID
        }
        if let appName, let byAppName = MeetingApp.matching(text: appName) {
            return byAppName
        }
        guard Recording.meetingAppSources.contains(source) else { return nil }
        return MeetingApp.matching(text: title)
    }
}

/// Categories used by the sidebar.
enum HistoryCategory: String, CaseIterable, Identifiable, Hashable {
    case transcriptions   // any non-deleted recording with a transcript
    case meetings         // source == .meeting
    case dictations       // source == .microphone, marked as dictation
    case recentlyDeleted

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .transcriptions:   return "Transcriptions"
        case .meetings:         return "Meetings"
        case .dictations:       return "Dictations"
        case .recentlyDeleted:  return "Recently Deleted"
        }
    }
    var sfSymbol: String {
        switch self {
        case .transcriptions:   return "text.alignleft"
        case .meetings:         return "person.2.wave.2"
        case .dictations:       return "mic"
        case .recentlyDeleted:  return "trash"
        }
    }
}
