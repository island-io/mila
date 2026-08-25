import XCTest
import TranscriptionCore
@testable import Mila

/// Guards on the remote-transcription model catalogue (issue #178).
///
/// The load-bearing one is `test_everyPreset_isReachableByTheEngine`: the whole
/// point of the picker is that it cannot offer a model Mila will then fail to
/// talk to, and the only way to keep that true as the list grows is to assert
/// it rather than to remember it.
final class RemoteModelPresetTests: XCTestCase {

    // MARK: - The catalogue only lists what the engine can reach

    func test_everyPreset_hasANonEmptyIDAndEndpoint() {
        for preset in RemoteModelPreset.all {
            XCTAssertFalse(preset.id.trimmingCharacters(in: .whitespaces).isEmpty,
                           "\(preset.displayName) has no model id")
            XCTAssertFalse(preset.detail.isEmpty, "\(preset.id) has no caption")
            XCTAssertNotNil(URL(string: preset.endpoint)?.host,
                            "\(preset.id) has an unusable endpoint")
        }
    }

    /// Every preset must resolve to a `response_format` the model actually
    /// accepts. `forModel(_:)` returning *something* isn't enough — it has a
    /// `verbose_json` fallback for unknown ids, which is exactly the request
    /// the `gpt-*` models reject with HTTP 400. So assert the mapping per
    /// model family, which is what "reachable" means on the wire.
    func test_everyPreset_isReachableByTheEngine() {
        for preset in RemoteModelPreset.all {
            let format = RemoteWhisperEngine.ResponseFormat.forModel(preset.id)
            let id = preset.id.lowercased()
            if id.contains("diarize") {
                XCTAssertEqual(format, .diarizedJSON, "\(preset.id)")
            } else if id.hasPrefix("gpt-") {
                XCTAssertEqual(format, .json,
                               "\(preset.id) must not be sent a timestamped format")
            } else {
                XCTAssertEqual(format, .verboseJSON, "\(preset.id)")
            }
        }
    }

    func test_noPresetIsListedTwice() {
        let ids = RemoteModelPreset.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate preset ids: \(ids)")
    }

    /// The picker must be able to reach every preset: a group with no rows
    /// would be a section header over nothing.
    func test_everyGroupHasPresets() {
        for group in RemoteModelPreset.Group.allCases {
            XCTAssertFalse(RemoteModelPreset.presets(in: group).isEmpty,
                           "\(group) is empty")
        }
        XCTAssertEqual(RemoteModelPreset.Group.allCases
            .flatMap(RemoteModelPreset.presets(in:)).count,
                       RemoteModelPreset.all.count,
                       "a preset belongs to no listed group")
    }

    func test_theDefaultModelIsAPreset() {
        // Otherwise a fresh install opens Settings already showing "Custom…".
        XCTAssertNotNil(RemoteModelPreset.matching(RemoteTranscriptionSettings.defaultModel))
    }

    // MARK: - Timestamp tradeoff (what the UI has to surface)

    func test_whisperPresetsKeepPerSegmentTimestamps() throws {
        let preset = try XCTUnwrap(RemoteModelPreset.matching("whisper-1"))
        XCTAssertEqual(preset.timestamps, .perSegment)
        XCTAssertFalse(preset.timestamps.isUntimed)
    }

    func test_gptPresetsAreFlaggedAsUntimed() throws {
        for id in ["gpt-transcribe", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"] {
            let preset = try XCTUnwrap(RemoteModelPreset.matching(id), id)
            XCTAssertEqual(preset.timestamps, RemoteWhisperEngine.ResponseFormat.TimestampSupport.none,
                           "\(id) cannot return timings")
            XCTAssertTrue(preset.timestamps.isUntimed, id)
        }
    }

    func test_diarizePresetReportsSpeakerTurnTimestamps() throws {
        let preset = try XCTUnwrap(RemoteModelPreset.matching("gpt-4o-transcribe-diarize"))
        XCTAssertEqual(preset.timestamps, .perSpeakerTurn)
        XCTAssertFalse(preset.timestamps.isUntimed,
                       "the diarize model does carry timings — it must not be warned about")
    }

    func test_selfHostedHebrewPresetKeepsTimestamps() throws {
        let preset = try XCTUnwrap(
            RemoteModelPreset.matching("ivrit-ai/whisper-large-v3-turbo-ct2"))
        XCTAssertEqual(preset.group, .selfHosted)
        XCTAssertEqual(preset.timestamps, .perSegment)
    }

    // MARK: - matching()

    func test_matching_isExactAndCaseInsensitive() {
        XCTAssertNotNil(RemoteModelPreset.matching("  WHISPER-1 "))
        XCTAssertNotNil(RemoteModelPreset.matching("IVRIT-AI/whisper-large-v3-turbo-ct2"))
    }

    /// Deliberately *not* the tolerant substring style of
    /// `isHebrewOnlyModel(_:)`. A near-miss id is a custom id, and describing
    /// it with a preset's guarantees ("per-segment timings", "labels speakers
    /// itself") would be a claim about a model Mila has never seen.
    func test_matching_rejectsNearMisses() {
        XCTAssertNil(RemoteModelPreset.matching("whisper-1-preview"))
        XCTAssertNil(RemoteModelPreset.matching("openai/gpt-4o-transcribe"))
        XCTAssertNil(RemoteModelPreset.matching("ivrit-ai/whisper-large-v3-ggml"))
        XCTAssertNil(RemoteModelPreset.matching(""))
        XCTAssertNil(RemoteModelPreset.matching("   "))
    }

    func test_normalizeEndpoint_ignoresCaseAndTrailingSlash() {
        XCTAssertEqual(RemoteModelPreset.normalizeEndpoint(" https://API.OpenAI.com/v1/ "),
                       "https://api.openai.com/v1")
    }
}

@MainActor
final class RemoteModelPresetSettingsTests: XCTestCase {

    private func makeSettings(_ label: String = #function) -> RemoteTranscriptionSettings {
        let name = "RemoteModelPresetSettingsTests.\(label)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return RemoteTranscriptionSettings(defaults: suite,
                                           apiKeyKeychainKey: "\(name).apiKey")
    }

    func test_selectedPreset_isDerivedFromTheModelID() {
        let settings = makeSettings()
        // Fresh install: the default model is a preset, so the picker opens on
        // a real row rather than "Custom…".
        XCTAssertEqual(settings.selectedPreset?.id, "whisper-1")

        settings.model = "gpt-4o-transcribe-diarize"
        XCTAssertEqual(settings.selectedPreset?.id, "gpt-4o-transcribe-diarize")

        settings.model = "my-org/some-private-finetune"
        XCTAssertNil(settings.selectedPreset, "an unknown id must read as Custom")
    }

    func test_apply_setsModelAndEndpointTogether() throws {
        let settings = makeSettings()
        let hebrew = try XCTUnwrap(
            RemoteModelPreset.matching("ivrit-ai/whisper-large-v3-turbo-ct2"))
        settings.apply(hebrew)
        XCTAssertEqual(settings.model, hebrew.id)
        XCTAssertEqual(settings.endpoint, RemoteModelPreset.selfHostedEndpoint,
                       "leaving OpenAI's endpoint behind a self-hosted model would 404")
    }

    /// The prefill/withdraw rule stays owned by `model.didSet`; `apply` must
    /// ride on it rather than reimplement it.
    func test_apply_inheritsTheEnglishModelPrefill() throws {
        let settings = makeSettings()
        let hebrew = try XCTUnwrap(
            RemoteModelPreset.matching("ivrit-ai/whisper-large-v3-turbo-ct2"))
        settings.apply(hebrew)
        XCTAssertEqual(settings.englishModel,
                       RemoteTranscriptionSettings.defaultEnglishModel)

        let whisper = try XCTUnwrap(RemoteModelPreset.matching("whisper-1"))
        settings.apply(whisper)
        XCTAssertEqual(settings.englishModel, "",
                       "the prefill must be withdrawn for a multilingual primary")
    }

    func test_apply_movesBackToOpenAIsEndpoint() throws {
        let settings = makeSettings()
        settings.apply(try XCTUnwrap(
            RemoteModelPreset.matching("ivrit-ai/whisper-large-v3-turbo-ct2")))
        settings.apply(try XCTUnwrap(RemoteModelPreset.matching("gpt-4o-transcribe")))
        XCTAssertEqual(settings.endpoint, RemoteTranscriptionSettings.defaultEndpoint)
    }

    /// A private gateway or reverse proxy can serve any of these model ids, so
    /// switching model must not silently repoint the user's own URL.
    func test_apply_leavesAUserTypedEndpointAlone() throws {
        let settings = makeSettings()
        settings.endpoint = "https://mila-asr.example.internal/v1"
        settings.apply(try XCTUnwrap(RemoteModelPreset.matching("gpt-4o-transcribe")))
        XCTAssertEqual(settings.endpoint, "https://mila-asr.example.internal/v1")
        XCTAssertEqual(settings.model, "gpt-4o-transcribe")
    }

    func test_apply_fillsInAnUnusableEndpoint() throws {
        let settings = makeSettings()
        settings.endpoint = "not a url"
        settings.apply(try XCTUnwrap(RemoteModelPreset.matching("whisper-1")))
        XCTAssertEqual(settings.endpoint, RemoteTranscriptionSettings.defaultEndpoint)
    }

    /// Re-selecting the same group keeps a preset endpoint that only differs
    /// by case/trailing slash, instead of rewriting it for no reason.
    func test_apply_treatsAnEquivalentPresetEndpointAsAlreadyCorrect() throws {
        let settings = makeSettings()
        settings.endpoint = "https://api.openai.com/v1/"
        settings.apply(try XCTUnwrap(RemoteModelPreset.matching("gpt-transcribe")))
        XCTAssertEqual(settings.endpoint, "https://api.openai.com/v1/")
    }

    func test_apply_persistsLikeAnyOtherEdit() throws {
        let name = "RemoteModelPresetSettingsTests.persist"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        let first = RemoteTranscriptionSettings(defaults: suite,
                                                apiKeyKeychainKey: "\(name).apiKey")
        first.apply(try XCTUnwrap(RemoteModelPreset.matching("gpt-4o-transcribe-diarize")))

        let second = RemoteTranscriptionSettings(defaults: suite,
                                                 apiKeyKeychainKey: "\(name).apiKey")
        XCTAssertEqual(second.model, "gpt-4o-transcribe-diarize")
        XCTAssertEqual(second.selectedPreset?.id, "gpt-4o-transcribe-diarize")
    }
}
