import Foundation
import Combine
import TranscriptionCore

/// One language a recording can be transcribed in: an entry in the user's
/// editable list (Settings → Languages), seeded with Hebrew and English.
///
/// The language is always an explicit choice — there is deliberately no
/// auto-detect option. Detection sounds free but isn't: it can only be as good
/// as the model behind it, and the model itself is picked *from* this setting
/// (Hebrew → the ivrit.ai finetune, everything else → the multilingual one,
/// and the same split for a remote endpoint's two model ids). "Let the model
/// decide" therefore meant "guess which specialist to ask before knowing the
/// language", which produced worse transcripts than simply saying which
/// language you're about to speak. Legacy `"auto"` values are read as Hebrew.
///
/// `Recording.language` stores only the code, so this type is a UI and
/// routing layer over that string — never part of recordings.json.
struct RecordingLanguage: Identifiable, Hashable, Codable {
    /// A whisper language code (`"he"`, `"ru"`), lowercased. The id.
    var code: String
    /// Regional flag shown in pickers. Empty means none — a language is not a
    /// country, so there is no flag to derive (English → 🇬🇧 or 🇺🇸 is a
    /// preference).
    var flagEmoji: String
    /// `WhisperModel.name` to transcribe with locally; nil = the multilingual
    /// default.
    var modelName: String?
    /// Removed by the user. Kept rather than deleted so recordings already in
    /// this language still resolve to its flag, direction and model — and so
    /// adding it back restores its settings.
    var isHidden: Bool

    var id: String { code }

    init(code: String, flagEmoji: String = "", modelName: String? = nil, isHidden: Bool = false) {
        self.code = code.lowercased()
        self.flagEmoji = flagEmoji
        self.modelName = modelName
        self.isHidden = isHidden
    }

    /// English name from CLDR, matching Mila's English-only chrome.
    var displayName: String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code.uppercased()
    }

    /// Flag and name for menus ("🇮🇱 Hebrew"), or just the name when the
    /// entry has no flag — a user-added language starts without one.
    var label: String {
        flagEmoji.isEmpty ? displayName : "\(flagEmoji) \(displayName)"
    }

    /// Script direction from CLDR, so Arabic, Farsi, Urdu and Yiddish lay out
    /// right-to-left without anyone having to know to tick a box.
    var isRTL: Bool {
        Locale.Language(identifier: code).characterDirection == .rightToLeft
    }

    /// Script direction for a STORED code — legacy aliases and regional
    /// forms included (`iw`, `auto`, `he-IL`). Direction comes from the code
    /// alone, so it needs no list: a recording in a removed or never-added
    /// language still lays out correctly.
    nonisolated static func isRTL(code: String) -> Bool {
        resolve(code, in: seeds).isRTL
    }

    // Lenient decode: a list written by a newer build may lack or add fields,
    // and a failed decode would throw away the user's whole list.
    private enum CodingKeys: String, CodingKey { case code, flagEmoji, modelName, isHidden }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(code: try c.decode(String.self, forKey: .code),
                  flagEmoji: try c.decodeIfPresent(String.self, forKey: .flagEmoji) ?? "",
                  modelName: try c.decodeIfPresent(String.self, forKey: .modelName),
                  isHidden: try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false)
    }

    // MARK: - Seeds

    static let hebrew = RecordingLanguage(code: "he", flagEmoji: "🇮🇱",
                                          modelName: "ivrit-ai-whisper-large-v3")
    /// British flag matches the user's "Israel and UK" mental model.
    static let english = RecordingLanguage(code: "en", flagEmoji: "🇬🇧",
                                           modelName: "openai-whisper-large-v3-turbo")

    /// The list a fresh install starts with, in picker order.
    static let seeds: [RecordingLanguage] = [.hebrew, .english]

    /// A recording's stored per-recording summary language
    /// (`Recording.summaryLanguage`), or nil for "no override". Strict: only
    /// a whisper code exactly as the app writes it. recordings.json and
    /// .milashare files are untrusted, and a guessed language would be a
    /// silent override (`bugbot-rules/untrusted-persisted-data.md`). Any
    /// whisper language is accepted, not only the user's list, so a
    /// colleague's Russian summary language survives sharing.
    nonisolated static func summaryLanguage(stored code: String) -> RecordingLanguage? {
        guard WhisperEngine.supportedLanguageCodes.contains(code) else { return nil }
        return resolve(code, in: seeds)
    }

    // MARK: - Resolution

    /// The entry a stored code means — for displaying and re-transcribing a
    /// recording. Never nil, and deliberately looks at HIDDEN entries too:
    /// removing a language only stops offering it, while every recording
    /// already made in it must keep resolving forever.
    ///
    /// Order:
    /// 1. legacy aliases → `he`: `iw` (Locale doesn't canonicalize it), the
    ///    retired `auto`, and `""` — recordings from before per-language UX
    ///    were always Hebrew. Model routing handles `auto` separately.
    /// 2. exact match in `list`
    /// 3. regional variant in `list` (`he-IL`, `en_GB`)
    /// 4. a seed with that code (a hand-edited list that dropped it)
    /// 5. synthesized: Locale-derived name/direction, no flag, default model
    nonisolated static func resolve(_ code: String, in list: [RecordingLanguage]) -> RecordingLanguage {
        var normalized = code.lowercased()
        if ["iw", "auto", ""].contains(normalized) { normalized = "he" }
        if let exact = list.first(where: { $0.code == normalized }) { return exact }
        if let variant = list.first(where: { isVariant(normalized, of: $0.code) }) { return variant }
        if let seed = seeds.first(where: { isVariant(normalized, of: $0.code) }) { return seed }
        return RecordingLanguage(code: normalized)
    }

    /// Whether `code` is `base` or a regional form of it (`en-US`, `en_GB`).
    /// A bare `hasPrefix` would also swallow unrelated codes that merely start
    /// with those letters — `"enochian"` must not pick the English model.
    nonisolated static func isVariant(_ code: String, of base: String) -> Bool {
        code == base || code.hasPrefix("\(base)-") || code.hasPrefix("\(base)_")
    }
}

/// The user's language list and the language the next recording uses.
@MainActor
final class RecordingLanguageSettings: ObservableObject {
    /// Every entry, hidden ones included (they back `resolve`). Publishes only
    /// on user edits — never at audio cadence — so it is safe on this
    /// App-level `@StateObject` (#280).
    @Published private(set) var languages: [RecordingLanguage]

    /// Code of the language for the next voice memo / app-audio recording.
    /// Always a visible entry.
    @Published private(set) var currentCode: String {
        didSet {
            guard currentCode != oldValue else { return }
            defaults.set(currentCode, forKey: Self.key)
        }
    }

    /// The active language. Setting an entry that isn't visible is ignored —
    /// the active language must always be one the pickers offer.
    ///
    /// When a configuration profile locks it (`ManagedSettings`), every write
    /// is refused before anything is stored, published or persisted. The
    /// toolbar picker is disabled then, so this only catches programmatic
    /// writes.
    var current: RecordingLanguage {
        get { resolve(currentCode) }
        set {
            guard !isManaged(.recordingLanguage),
                  let entry = configured(newValue.code) else { return }
            currentCode = entry.code
        }
    }

    /// Entries the pickers offer, in list order.
    var visible: [RecordingLanguage] { languages.filter { !$0.isHidden } }

    /// The administrator-forced fields, if any. Empty (`ManagedSettings.empty`)
    /// unless `MilaApp` passes the system's managed preferences.
    private let managed: ManagedSettings

    /// Whether a configuration profile locks `field` (see `ManagedSettings`).
    func isManaged(_ field: ManagedField) -> Bool { managed.isManaged(field) }

    private let defaults: UserDefaults
    private static let key = "recording.language"
    private static let listKey = "recording.languages"

    init(defaults: UserDefaults = .standard, managed: ManagedSettings = .empty) {
        self.defaults = defaults
        self.managed = managed

        // Seed only when the key is ABSENT. Undecodable bytes (or a list with
        // nothing visible) fall back to the seeds in memory but are left on
        // disk untouched, so a decode bug never overwrites the user's list.
        let loaded: [RecordingLanguage]
        if let data = defaults.data(forKey: Self.listKey) {
            let decoded = try? JSONDecoder().decode([RecordingLanguage].self, from: data)
            loaded = (decoded?.contains { !$0.isHidden } == true) ? decoded! : RecordingLanguage.seeds
        } else {
            loaded = RecordingLanguage.seeds
            if let data = try? JSONEncoder().encode(loaded) {
                defaults.set(data, forKey: Self.listKey)
            }
        }
        self.languages = loaded

        // Stored code → the visible entry it means; anything else (a fresh
        // install, the retired "auto", a since-removed language) lands on the
        // first visible entry. Rewrite a stored value that changed — `didSet`
        // doesn't fire from `init`, so a stale value would otherwise sit in
        // the plist until the user touched the picker. A fresh install writes
        // nothing: "never chosen" stays distinguishable from "chose Hebrew".
        let raw = defaults.string(forKey: Self.key)
        let firstVisible = loaded.first { !$0.isHidden }!.code
        let resolved = raw.map { RecordingLanguage.resolve($0, in: loaded) }
        let active = resolved.flatMap { r in loaded.first { $0.code == r.code && !$0.isHidden } }?.code
            ?? firstVisible
        if let forced = managed.recordingLanguage {
            // The user's stored choice stays in `defaults` untouched, so
            // removing the profile brings it back.
            self.currentCode = forced.code
        } else {
            self.currentCode = active
            if let raw, raw != active {
                defaults.set(active, forKey: Self.key)
            }
        }
    }

    /// The visible entry for `code` (exact or regional variant), or nil.
    /// Drives every picker: a hidden or unknown language is not offered.
    func configured(_ code: String) -> RecordingLanguage? {
        let r = RecordingLanguage.resolve(code, in: languages)
        return visible.first { $0.code == r.code }
    }

    /// What a stored code means, hidden entries included. Never nil.
    func resolve(_ code: String) -> RecordingLanguage {
        RecordingLanguage.resolve(code, in: languages)
    }

    /// The entries a language picker offers: the visible list, plus `code`
    /// at the end when it is set but no longer (or never) offered — a
    /// summary or output language chosen before the user removed it still
    /// shows its ✓ instead of silently looking unset.
    func choices(including code: String?) -> [RecordingLanguage] {
        guard let code, configured(code) == nil else { return visible }
        return visible + [resolve(code)]
    }

    /// The languages a recording in `code` can be re-transcribed INTO: every
    /// offered language except its own, in list order. Re-running in its own
    /// language is a separate action that works even when that language is
    /// no longer offered, so it isn't listed here.
    func retranscribeTargets(for code: String) -> [RecordingLanguage] {
        let own = resolve(code).code
        return visible.filter { $0.code != own }
    }

    // MARK: - Editing
    //
    // Each edit assigns `languages` once — one publish, one write.

    /// Offer `code` in the pickers. Returns the entry, or nil when whisper
    /// can't transcribe the code: it reaches `whisper_lang_id` verbatim, so a
    /// regional variant or a typo would fail at transcription time instead.
    ///
    /// A hidden code is un-hidden with its previous flag and model, in its
    /// original place — removal is a lossless round trip. A visible code is
    /// returned unchanged.
    @discardableResult
    func add(code: String) -> RecordingLanguage? {
        let code = code.lowercased()
        guard WhisperEngine.supportedLanguageCodes.contains(code) else { return nil }
        var list = languages
        if let i = list.firstIndex(where: { $0.code == code }) {
            guard list[i].isHidden else { return list[i] }
            list[i].isHidden = false
            commit(list)
            return list[i]
        }
        let entry = RecordingLanguage(code: code)
        list.append(entry)
        commit(list)
        return entry
    }

    /// Stop offering `code` for new recordings. The entry is hidden, never
    /// deleted, so recordings already in it keep their flag, direction and
    /// model. Refused (false) for the last visible entry and for a code that
    /// isn't visible. Removing the active language re-points it at the first
    /// entry still visible.
    @discardableResult
    func remove(code: String) -> Bool {
        let code = code.lowercased()
        var list = languages
        guard let i = list.firstIndex(where: { $0.code == code && !$0.isHidden }),
              list.filter({ !$0.isHidden }).count > 1
        else { return false }
        list[i].isHidden = true
        commit(list)
        if currentCode == code, !isManaged(.recordingLanguage), let first = visible.first {
            currentCode = first.code
        }
        return true
    }

    /// Change an existing entry's flag and model. Visibility is untouched —
    /// that goes through `add`/`remove` and their guards — and an unknown
    /// code is ignored rather than added.
    func update(_ entry: RecordingLanguage) {
        var list = languages
        guard let i = list.firstIndex(where: { $0.code == entry.code.lowercased() }) else { return }
        list[i].flagEmoji = entry.flagEmoji
        list[i].modelName = entry.modelName
        guard list[i] != languages[i] else { return }
        commit(list)
    }

    private func commit(_ list: [RecordingLanguage]) {
        languages = list
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: Self.listKey)
        }
    }
}
