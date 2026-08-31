import Foundation

/// A `.milaconfig` file — a shareable, partial snapshot of Mila settings.
///
/// **Partial-override semantics.** Every field is optional. When a config is
/// applied (see `MilaConfigImporter`), a field that is *present* overrides the
/// current setting; a field that is *absent* leaves the current setting
/// untouched. This lets someone hand out a file that configures, say, just the
/// remote transcription server without disturbing the recipient's hotkeys,
/// language, or anything else.
///
/// The on-disk format is JSON. `version` gates forward-compatibility: a file
/// whose `version` is newer than `MilaConfig.currentVersion` is rejected with a
/// clear message rather than silently half-applied. Absent/older-but-valid
/// versions are accepted.
///
/// Deliberately *not* representable here: machine-specific settings that can't
/// travel between Macs — the selected audio input device UID and the
/// recordings-directory security-scoped bookmark — and per-key hotkey bindings.
/// See `MilaConfigImporter` for the rationale.
struct MilaConfig: Codable, Equatable {
    /// Bump when the schema changes in a way older apps couldn't safely apply.
    static let currentVersion = 1

    /// Schema version of this file. Required.
    var version: Int

    var remoteTranscription: RemoteTranscription?
    /// ISO-style language code for new recordings: `"he"` or `"en"`. Anything
    /// else — including the retired `"auto"` — is read as Hebrew.
    var recordingLanguage: String?
    var liveAI: LiveAI?
    var diarization: Toggle?
    var meetingDetection: Toggle?

    /// OpenAI-compatible remote transcription backend (e.g. a self-hosted
    /// `speaches` server running an ivrit.ai model).
    struct RemoteTranscription: Codable, Equatable {
        /// `true` switches Mila to the remote backend; `false` reverts to
        /// on-device whisper.cpp.
        var enabled: Bool?
        /// Base URL, e.g. `https://mila-asr.internal.island.io/v1`. The engine
        /// appends `audio/transcriptions`.
        var endpoint: String?
        /// Model id the server expects, e.g. `ivrit-ai/whisper-large-v3-turbo-ct2`.
        var model: String?
        /// Optional model id for English and auto-detect recordings, for servers
        /// whose main model is language-specific (the ivrit.ai finetune is
        /// Hebrew-only). Absent or empty means `model` handles every language.
        var englishModel: String?
        /// Bearer token. Stored in the Keychain on apply, never in UserDefaults.
        var apiKey: String?
    }

    struct LiveAI: Codable, Equatable {
        var enabled: Bool?
        var model: String?
    }

    /// A single on/off feature toggle.
    struct Toggle: Codable, Equatable {
        var enabled: Bool?
    }
}

extension MilaConfig {
    /// The file extension (without the dot) and the UTI registered in
    /// `Info.plist` for double-click-to-open.
    static let fileExtension = "milaconfig"

    enum LoadError: LocalizedError, Equatable {
        case unreadable(String)
        case malformed(String)
        case unsupportedVersion(found: Int, supported: Int)

        var errorDescription: String? {
            switch self {
            case .unreadable(let detail):
                return "Couldn't read the configuration file. \(detail)"
            case .malformed(let detail):
                return "That doesn't look like a valid Mila configuration file. \(detail)"
            case .unsupportedVersion(let found, let supported):
                return "This configuration needs a newer version of Mila "
                    + "(file format v\(found); this app supports up to v\(supported)). "
                    + "Update Mila and try again."
            }
        }

        /// The log-safe twin of `errorDescription`, matching
        /// `LLMRunnerError.logDescription` and
        /// `SpeakerDiarizer.Error.logDescription`.
        ///
        /// `MilaConfigImporter` logs the staged filename `.private` because a
        /// `.milaconfig` passed round a team is commonly named for the org or
        /// the server it configures — and then its `catch` published the same
        /// name straight back, because these two cases are built from someone
        /// else's message:
        ///
        ///   * `.unreadable` wraps `Data(contentsOf:).localizedDescription`
        ///     for a file the user double-clicked, and Cocoa quotes both the
        ///     filename and its containing folder in that sentence.
        ///   * `.malformed` wraps `JSONDecoder`'s message, which quotes coding
        ///     keys and — for a type/value mismatch — the offending value,
        ///     e.g. the endpoint URL or model name in the config.
        ///
        /// `.unsupportedVersion` is the opposite case and passes through: two
        /// integers Mila composed itself, which are the entire diagnostic
        /// ("update Mila") and name nothing. Redacting it would be the
        /// over-redaction `bugbot-rules/no-user-content-in-logs.md` warns
        /// about. (Issue #213, CWE-532.)
        var logDescription: String {
            switch self {
            case .unreadable:
                return "Couldn't read the configuration file (detail withheld — it quotes the file's name and folder)"
            case .malformed:
                return "Not a valid Mila configuration file (detail withheld — decoder messages quote keys and values)"
            case .unsupportedVersion:
                return errorDescription ?? "\(self)"
            }
        }

        /// The log-safe message for any error a config load can throw, applied
        /// where the concrete type is still unknown — `MilaConfigImporter`
        /// catches `Error`.
        ///
        /// The fallback is deliberately **not** `localizedDescription`, unlike
        /// the LLM and diarizer helpers. `load(from:)` only ever throws
        /// `LoadError`, so anything else arriving here came from the
        /// surrounding file-open path (the security-scope dance, a future
        /// caller) — which is exactly the shape that quotes the user's path.
        /// Domain + code keep it diagnosable without guessing.
        static func logMessage(for error: Swift.Error) -> String {
            if let loadError = error as? LoadError { return loadError.logDescription }
            let ns = error as NSError
            return "unexpected error [\(ns.domain) \(ns.code)]"
        }
    }

    /// Parse a `.milaconfig` file, throwing a user-facing `LoadError`.
    static func load(from url: URL) throws -> MilaConfig {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LoadError.unreadable(error.localizedDescription)
        }
        return try decode(data)
    }

    /// Parse config bytes. Split out from `load(from:)` so tests don't need a
    /// file on disk.
    static func decode(_ data: Data) throws -> MilaConfig {
        let config: MilaConfig
        do {
            config = try JSONDecoder().decode(MilaConfig.self, from: data)
        } catch let DecodingError.keyNotFound(key, _) where key.stringValue == "version" {
            throw LoadError.malformed("It's missing the required \"version\" field.")
        } catch {
            throw LoadError.malformed(error.localizedDescription)
        }
        guard config.version >= 1 else {
            throw LoadError.malformed("\"version\" must be a positive integer.")
        }
        guard config.version <= currentVersion else {
            throw LoadError.unsupportedVersion(found: config.version, supported: currentVersion)
        }
        return config
    }
}
