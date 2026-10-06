import Foundation
import MilaKit
import TranscriptionCore
import UniformTypeIdentifiers

/// The `manifest.json` inside a `.milashare` bundle — one recording, its
/// transcript, speaker names, summary and action items, plus (optionally) the
/// sender's voice profiles for the speakers in it.
///
/// ## Why a dedicated DTO and not `Recording`'s Codable
///
/// `recordings.json` is one cross-version contract (the app and mila-mcp,
/// pinned by `StoredRecordingDriftTests`). The `.milashare` wire format is a
/// *second* one: the sender's build and the receiver's build are different
/// versions of Mila, and a bundle saved today must still open next year.
/// Reusing `Recording.encode(to:)` would make every `recordings.json` schema
/// change silently a share-format change and vice versa, and would drag the
/// drift test into every share change. `RecordingPayload` below carries only
/// what travels (nothing machine-specific: no `audioFileName`, `status`,
/// `deletedAt`, `folder`, Voice Memo ids or receiver-side attribution), and
/// `ShareManifestTests.test_every_recording_key_is_shared_or_deliberately_excluded`
/// forces a decision for every new `Recording` field the same way the drift
/// test does.
///
/// ## Container
///
/// A zip (built with `ditto`, see `ZipArchiver`) with **fixed entry names**:
/// `manifest.json`, `audio.wav` or `audio.m4a`, and `transcript.txt`. The
/// importer reads those three names and nothing else, so an archive entry's
/// name is never attacker-controlled input — the receiver mints its own
/// library filename from the title. `audio.fileName` must match
/// `^audio\.(wav|m4a)$` exactly or the bundle is rejected.
///
/// Version-gated like `MilaConfig`: a `version` newer than
/// `currentVersion` is refused with a clear "update Mila" message rather than
/// half-applied; unknown keys are ignored so a newer sender's additions do
/// not break an older receiver.
struct ShareManifest: Codable, Equatable {
    /// Bump when the schema changes in a way an older app couldn't safely read.
    static let currentVersion = 1

    static let fileExtension = "milashare"
    static let manifestEntryName = "manifest.json"
    static let transcriptEntryName = "transcript.txt"
    /// The audio entry is always `audio.<ext>`; see `isAllowedAudioEntryName`.
    static let audioEntryStem = "audio"
    static let allowedAudioExtensions: Set<String> = ["wav", "m4a"]

    /// Schema version of this file. Required.
    var version: Int
    /// Minted once per export. The receiver's voice-profile import keys its
    /// idempotency tokens on it (`ImportedShareToken.bundleKey`).
    var bundleID: UUID
    var exportedAt: Date
    var exportedBy: Exporter
    var app: AppInfo?
    var recording: RecordingPayload
    var audio: Audio
    var transcript: Transcript?
    /// Present only when the sender ticked "Include voice profiles". Absent
    /// or empty means none were shared.
    var speakerProfiles: [SharedSpeakerProfile]?

    struct Exporter: Codable, Equatable {
        /// A display name, never an email: the import sheet builds
        /// "Alex (from Daniel)" out of it.
        var name: String
    }

    struct AppInfo: Codable, Equatable {
        var version: String
        var build: String
    }

    struct Audio: Codable, Equatable {
        /// Entry name inside the archive — `audio.wav` or `audio.m4a`.
        var fileName: String
        /// `wav` or `m4a`; must agree with `fileName`'s extension.
        var format: String
        var byteCount: Int64
        /// Lowercase hex SHA-256 of the audio entry. Verified on import.
        var sha256: String
    }

    struct Transcript: Codable, Equatable {
        /// Always `transcript.txt`.
        var fileName: String
    }

    /// The recording, minus everything that is about the sender's machine.
    ///
    /// Decoding is lenient everywhere except `id` and `createdAt`: a bundle
    /// without a recording id cannot be updated-in-place on re-import (the
    /// whole point of keeping the id), and a recording without a creation
    /// date has no place in a chronological library.
    struct RecordingPayload: Codable, Equatable {
        var id: UUID
        var title: String
        var createdAt: Date
        var duration: Double
        /// Raw `RecordingSource`; unknown values fall back to `.microphone`
        /// on import so a newer sender's source doesn't fail the decode.
        var source: String
        var language: String
        var modelName: String?
        var appName: String?
        var appBundleID: String?
        var segments: [Segment]
        var speakerNames: [String: String]
        var summary: String?
        var actionItems: [ActionItem]?

        /// `TranscriptSegment` without its `id`: that UUID exists to give
        /// SwiftUI lists a stable identity and is regenerated on import.
        struct Segment: Codable, Equatable {
            var start: Double
            var end: Double
            var text: String
            var speaker: String?

            init(start: Double, end: Double, text: String, speaker: String?) {
                self.start = start
                self.end = end
                self.text = text
                self.speaker = speaker
            }

            private enum CodingKeys: String, CodingKey { case start, end, text, speaker }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                start = try c.decodeIfPresent(Double.self, forKey: .start) ?? .nan
                end = try c.decodeIfPresent(Double.self, forKey: .end) ?? .nan
                text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
                speaker = try c.decodeIfPresent(String.self, forKey: .speaker)
            }

            /// Whether the timing survives arithmetic: finite, non-negative,
            /// and not inverted. `validated()` drops anything else.
            var isSound: Bool {
                start.isFinite && end.isFinite && start >= 0 && end >= start
            }
        }

        struct ActionItem: Codable, Equatable {
            var id: String
            var text: String
            var speaker: String?
            var timestampSeconds: Double
            /// Raw `ActionItem.Source` (`inferred` / `voice_command`).
            var source: String
            var addedAt: Date?

            init(id: String, text: String, speaker: String?, timestampSeconds: Double,
                 source: String, addedAt: Date?) {
                self.id = id
                self.text = text
                self.speaker = speaker
                self.timestampSeconds = timestampSeconds
                self.source = source
                self.addedAt = addedAt
            }

            private enum CodingKeys: String, CodingKey {
                case id, text, speaker, timestampSeconds, source, addedAt
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
                text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
                speaker = try c.decodeIfPresent(String.self, forKey: .speaker)
                timestampSeconds = try c.decodeIfPresent(Double.self, forKey: .timestampSeconds) ?? 0
                source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
                addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt)
            }
        }

        init(id: UUID, title: String, createdAt: Date, duration: Double, source: String,
             language: String, modelName: String?, appName: String?, appBundleID: String?,
             segments: [Segment], speakerNames: [String: String], summary: String?,
             actionItems: [ActionItem]?) {
            self.id = id
            self.title = title
            self.createdAt = createdAt
            self.duration = duration
            self.source = source
            self.language = language
            self.modelName = modelName
            self.appName = appName
            self.appBundleID = appBundleID
            self.segments = segments
            self.speakerNames = speakerNames
            self.summary = summary
            self.actionItems = actionItems
        }

        private enum CodingKeys: String, CodingKey {
            case id, title, createdAt, duration, source, language, modelName, appName,
                 appBundleID, segments, speakerNames, summary, actionItems
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            createdAt = try c.decode(Date.self, forKey: .createdAt)
            duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
            source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
            language = try c.decodeIfPresent(String.self, forKey: .language) ?? "he"
            modelName = try c.decodeIfPresent(String.self, forKey: .modelName)
            appName = try c.decodeIfPresent(String.self, forKey: .appName)
            appBundleID = try c.decodeIfPresent(String.self, forKey: .appBundleID)
            segments = try c.decodeIfPresent([Segment].self, forKey: .segments) ?? []
            speakerNames = try c.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
            summary = try c.decodeIfPresent(String.self, forKey: .summary)
            actionItems = try c.decodeIfPresent([ActionItem].self, forKey: .actionItems)
        }

        /// The names this recording's transcript actually uses, in
        /// first-spoken order — raw ids resolved through `speakerNames`,
        /// unnamed ids left raw. Drives the import sheet's "Speakers" row.
        var speakerDisplayNames: [String] {
            var seen = Set<String>()
            var names: [String] = []
            for seg in segments {
                guard let raw = seg.speaker else { continue }
                let resolved = speakerNames[raw] ?? raw
                if seen.insert(resolved).inserted { names.append(resolved) }
            }
            return names
        }
    }

    // MARK: - Errors

    enum LoadError: LocalizedError, Equatable {
        case unreadable(String)
        case malformed(String)
        case unsupportedVersion(found: Int, supported: Int)
        /// The archive's contents disagree with its manifest — size or
        /// SHA-256 mismatch, or a declared entry that is not there.
        case integrity(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let detail):
                return "Couldn't read the shared recording. \(detail)"
            case .malformed(let detail):
                return "That doesn't look like a valid Mila shared recording. \(detail)"
            case .unsupportedVersion(let found, let supported):
                return "This shared recording needs a newer version of Mila "
                    + "(file format v\(found); this app supports up to v\(supported)). "
                    + "Update Mila and try again."
            case .integrity(let detail):
                return "The shared recording appears to be damaged. \(detail)"
            }
        }

        /// The log-safe twin of `errorDescription`, same contract as
        /// `MilaConfig.LoadError.logDescription`: the three cases built from
        /// someone else's message withhold it (Cocoa quotes the filename and
        /// its folder; `JSONDecoder` quotes keys and values; an integrity
        /// detail names the entry), the one Mila composes itself passes
        /// through. (`bugbot-rules/no-user-content-in-logs.md`.)
        var logDescription: String {
            switch self {
            case .unreadable:
                return "Couldn't read the shared recording (detail withheld — it quotes the file's name and folder)"
            case .malformed:
                return "Not a valid Mila shared recording (detail withheld — decoder messages quote keys and values)"
            case .integrity:
                return "Shared recording failed its integrity check (detail withheld)"
            case .unsupportedVersion:
                return errorDescription ?? "\(self)"
            }
        }

        static func logMessage(for error: Swift.Error) -> String {
            if let loadError = error as? LoadError { return loadError.logDescription }
            let ns = error as NSError
            return "unexpected error [\(ns.domain) \(ns.code)]"
        }
    }

    // MARK: - Coding

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Parse manifest bytes, throwing a user-facing `LoadError`. Does not
    /// validate contents — call `validated()` next.
    static func decode(_ data: Data) throws -> ShareManifest {
        let manifest: ShareManifest
        do {
            manifest = try decoder().decode(ShareManifest.self, from: data)
        } catch let DecodingError.keyNotFound(key, _) where key.stringValue == "version" {
            throw LoadError.malformed("It's missing the required \"version\" field.")
        } catch {
            throw LoadError.malformed(error.localizedDescription)
        }
        guard manifest.version >= 1 else {
            throw LoadError.malformed("\"version\" must be a positive integer.")
        }
        guard manifest.version <= currentVersion else {
            throw LoadError.unsupportedVersion(found: manifest.version, supported: currentVersion)
        }
        return manifest
    }

    // MARK: - Validation

    /// Whether `name` is one of the two audio entry names a bundle may use.
    /// Exact match, case-sensitive, no path components — this is the whole
    /// of the receiver's defence against a hostile entry name, so it is a
    /// allowlist rather than a sanitiser.
    static func isAllowedAudioEntryName(_ name: String) -> Bool {
        for ext in allowedAudioExtensions where name == "\(audioEntryStem).\(ext)" {
            return true
        }
        return false
    }

    /// The manifest with every structurally impossible value either
    /// rejected (throws `.malformed`) or dropped (a bad segment), per
    /// `bugbot-rules/untrusted-persisted-data.md`: validate at the decode
    /// boundary, drop individual bad entries rather than the whole file.
    func validated() throws -> ShareManifest {
        guard Self.isAllowedAudioEntryName(audio.fileName) else {
            throw LoadError.malformed("Its audio entry has an unexpected name.")
        }
        guard audio.format == (audio.fileName as NSString).pathExtension else {
            throw LoadError.malformed("Its audio format doesn't match the audio entry.")
        }
        guard audio.byteCount > 0 else {
            throw LoadError.malformed("Its audio entry is declared empty.")
        }
        guard Self.isHexDigest(audio.sha256) else {
            throw LoadError.malformed("Its audio checksum is not a SHA-256 digest.")
        }
        if let transcript, transcript.fileName != Self.transcriptEntryName {
            throw LoadError.malformed("Its transcript entry has an unexpected name.")
        }
        guard recording.duration.isFinite, recording.duration >= 0 else {
            throw LoadError.malformed("Its recording duration is not a valid number.")
        }

        var copy = self
        copy.recording.segments = recording.segments.filter(\.isSound)
        let title = recording.title.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.recording.title = title.isEmpty ? "Shared recording" : title
        copy.exportedBy.name = exportedBy.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.exportedBy.name.isEmpty { copy.exportedBy.name = "Unknown sender" }
        if let profiles = speakerProfiles, profiles.isEmpty { copy.speakerProfiles = nil }
        return copy
    }

    private static func isHexDigest(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { $0.isHexDigit }
    }
}

// MARK: - Mapping to and from the app's Recording

extension ShareManifest.RecordingPayload {
    /// What travels from a library recording. Strips `status`,
    /// `audioFileName`, `fullText` (separate entry), `deletedAt`, `folder`,
    /// the Voice Memo ids and `sharedBy`/`sharedAt` — a re-share attributes
    /// to the re-sharer, not the original sender.
    init(sharing recording: Recording) {
        self.init(
            id: recording.id,
            title: recording.title,
            createdAt: recording.createdAt,
            duration: recording.duration,
            source: recording.source.rawValue,
            language: recording.language,
            modelName: recording.modelName,
            appName: recording.appName,
            appBundleID: recording.appBundleID,
            segments: recording.segments.map {
                Segment(start: $0.start, end: $0.end, text: $0.text, speaker: $0.speaker)
            },
            speakerNames: recording.speakerNames,
            summary: recording.summary,
            actionItems: recording.actionItems?.map {
                ActionItem(id: $0.id, text: $0.text, speaker: $0.speaker,
                           timestampSeconds: $0.timestampSeconds,
                           source: $0.source.rawValue, addedAt: $0.addedAt)
            }
        )
    }

    /// A library recording for the receiver. Always `.completed` (the
    /// exporter refuses untranscribed recordings) and never trashed.
    func makeRecording(audioFileName: String,
                       fullText: String,
                       sharedBy: String,
                       sharedAt: Date,
                       folder: String?) -> Recording {
        Recording(
            id: id,
            title: title,
            createdAt: createdAt,
            duration: duration,
            source: RecordingSource(rawValue: source) ?? .microphone,
            audioFileName: audioFileName,
            status: .completed,
            language: language,
            modelName: modelName,
            segments: segments.map {
                TranscriptSegment(start: $0.start, end: $0.end, text: $0.text, speaker: $0.speaker)
            },
            fullText: fullText,
            deletedAt: nil,
            folder: folder,
            appName: appName,
            appBundleID: appBundleID,
            summary: summary,
            // Module-qualified: inside this extension `ActionItem` is the
            // payload's nested DTO, not the app's model.
            actionItems: actionItems?.map {
                Mila.ActionItem(id: $0.id, text: $0.text, speaker: $0.speaker,
                                timestampSeconds: $0.timestampSeconds,
                                source: Mila.ActionItem.Source(rawValue: $0.source) ?? .llmInferred,
                                addedAt: $0.addedAt ?? sharedAt)
            },
            speakerNames: speakerNames,
            sharedBy: sharedBy,
            sharedAt: sharedAt
        )
    }
}

/// Lets the importer fall back to `TranscriptFormatter.joinedFullText` when a
/// bundle carries segments but no `transcript.txt`.
extension ShareManifest.RecordingPayload.Segment: SpeakerTextSegment {}

extension UTType {
    /// Registered in `project.yml` (`UTExportedTypeDeclarations`) as
    /// conforming to `public.zip-archive` with the `milashare` extension,
    /// and claimed by Mila in `CFBundleDocumentTypes` so a double-click
    /// routes through `MilaAppDelegate.application(_:open:)`.
    static let milaShare = UTType(exportedAs: "io.island.mila.share")
}
