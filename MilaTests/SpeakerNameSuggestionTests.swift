import XCTest
import TranscriptionCore
@testable import Mila

/// Speaker-name suggestions (issue #348): parsing the model's answer
/// (evidence required), applying an accepted suggestion through the normal
/// rename path, and the "me" default.
///
/// The LLM is never spawned: `SpeakerNameSuggester`'s `runLLM` seam returns
/// canned output, as `RecordingSummarizerTests` does for the summarizer.
@MainActor
final class SpeakerNameSuggestionTests: XCTestCase {

    private var tempRoot: URL!
    private var store: RecordingStore!
    private var llmDefaults: UserDefaults!
    private var liveDefaults: UserDefaults!
    private var identityDefaults: UserDefaults!
    private var llm: LLMSettings!
    private var liveAI: LiveAISettings!
    private var identity: SpeakerIdentitySettings!

    private let llmSuite = "SpeakerNameSuggestionTests.llm"
    private let liveSuite = "SpeakerNameSuggestionTests.liveAI"
    private let identitySuite = "SpeakerNameSuggestionTests.identity"

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "SpeakerNameSuggestionTests")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = RecordingStore(rootDirectory: tempRoot)
        for suite in [llmSuite, liveSuite, identitySuite] {
            UserDefaults().removePersistentDomain(forName: suite)
        }
        llmDefaults = UserDefaults(suiteName: llmSuite)
        liveDefaults = UserDefaults(suiteName: liveSuite)
        identityDefaults = UserDefaults(suiteName: identitySuite)
        llm = LLMSettings(defaults: llmDefaults, apiKeyKeychainKey: "SpeakerNameSuggestionTests.\(UUID())")
        liveAI = LiveAISettings(defaults: liveDefaults)
        identity = SpeakerIdentitySettings(defaults: identityDefaults)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        llmDefaults?.removePersistentDomain(forName: llmSuite)
        liveDefaults?.removePersistentDomain(forName: liveSuite)
        identityDefaults?.removePersistentDomain(forName: identitySuite)
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private let transcript = """
        Hi everyone, my name is Dana. Thanks Dana! Bob, what do you think? \
        I think we should ship it on Friday.
        """

    private func meeting(names: [String: String] = [:]) -> Recording {
        Recording(
            title: "Sync", source: .meeting, audioFileName: "sync.wav",
            status: .completed, language: "en",
            segments: [
                TranscriptSegment(start: 0, end: 2, text: "Hi everyone, my name is Dana.", speaker: "SPEAKER_00"),
                TranscriptSegment(start: 2, end: 4, text: "Thanks Dana! Bob, what do you think?", speaker: "SPEAKER_01"),
                TranscriptSegment(start: 4, end: 6, text: "I think we should ship it on Friday.", speaker: "SPEAKER_02"),
            ],
            fullText: transcript,
            speakerNames: names)
    }

    private func soloMemo(source: RecordingSource = .microphone) -> Recording {
        Recording(
            title: "Note", source: source, audioFileName: "note.wav",
            status: .completed, language: "en",
            segments: [
                TranscriptSegment(start: 0, end: 2, text: "Remember to buy milk.", speaker: "SPEAKER_00"),
                TranscriptSegment(start: 2, end: 4, text: "And call the bank.", speaker: "SPEAKER_00"),
            ],
            fullText: "Remember to buy milk. And call the bank.")
    }

    private let allUnnamed: Set<String> = ["SPEAKER_00", "SPEAKER_01", "SPEAKER_02"]

    private func parse(_ raw: String,
                       unnamed: Set<String>? = nil,
                       taken: [String] = []) -> [SpeakerNameSuggestion] {
        SpeakerNameSuggester.parseSuggestions(from: raw,
                                              unnamedSpeakers: unnamed ?? allUnnamed,
                                              turns: SpeakerNameSuggester.turns(for: meeting()),
                                              takenNames: taken)
    }

    // MARK: - Parsing: what is accepted

    func test_parses_the_requested_envelope_with_quotes() {
        let raw = """
            {"speakers": [
              {"speaker": "SPEAKER_00", "name": "Dana", "quote": "Hi everyone, my name is Dana."},
              {"speaker": "SPEAKER_02", "name": "Bob", "quote": "Bob, what do you think?"}
            ]}
            """
        let result = parse(raw)
        XCTAssertEqual(result.map(\.speaker), ["SPEAKER_00", "SPEAKER_02"])
        XCTAssertEqual(result.map(\.name), ["Dana", "Bob"])
        XCTAssertEqual(result.first?.evidence, "Hi everyone, my name is Dana.")
        XCTAssertTrue(result.allSatisfy { $0.origin == .transcript })
    }

    func test_tolerates_a_bare_array_fences_and_a_lead_in_line() {
        let raw = """
            Here is the JSON:
            ```json
            [{"speaker": "SPEAKER_00", "name": "Dana", "quote": "my name is Dana"}]
            ```
            """
        XCTAssertEqual(parse(raw).map(\.name), ["Dana"])
    }

    func test_quote_matching_ignores_case_and_punctuation_but_not_words() {
        let raw = #"{"speakers": [{"speaker": "SPEAKER_00", "name": "Dana", "quote": "MY NAME IS DANA"}]}"#
        XCTAssertEqual(parse(raw).map(\.name), ["Dana"])
    }

    func test_lowercase_speaker_label_resolves_to_the_raw_id() {
        let raw = #"{"speakers": [{"speaker": "speaker_00", "name": "Dana", "quote": "my name is Dana"}]}"#
        XCTAssertEqual(parse(raw).map(\.speaker), ["SPEAKER_00"])
    }

    func test_hebrew_self_introduction_is_accepted() {
        let turns = [SpeakerNameSuggester.Turn(speaker: "SPEAKER_00", text: "שלום לכולם, קוראים לי דנה."),
                     SpeakerNameSuggester.Turn(speaker: "SPEAKER_01", text: "תודה לדנה!")]
        let raw = #"{"speakers": [{"speaker": "SPEAKER_00", "name": "דנה", "quote": "קוראים לי דנה"}]}"#
        let result = SpeakerNameSuggester.parseSuggestions(from: raw,
                                                           unnamedSpeakers: ["SPEAKER_00", "SPEAKER_01"],
                                                           turns: turns)
        XCTAssertEqual(result.map(\.name), ["דנה"])
    }

    func test_the_name_must_be_a_whole_word_of_the_quote() {
        func states(_ quote: String, _ name: String) -> Bool {
            SpeakerNameSuggester.quoteStatesName(
                normalizedQuote: SpeakerNameSuggester.normalizedForMatching(quote), name: name)
        }
        XCTAssertFalse(states("I edited the deck", "Ed"), "a name inside another word is not stated")
        XCTAssertTrue(states("Thanks, Ed. Go ahead", "Ed"))
        XCTAssertTrue(states("This is Dana speaking", "Dana Cohen"), "a word of the name counts")
        XCTAssertTrue(states("קוראים לי דנה", "דנה"))
        XCTAssertFalse(states("תודה לדנה", "דנה"), "Hebrew is matched on whole words too")
    }

    func test_an_empty_answer_is_no_suggestions() {
        XCTAssertEqual(parse(#"{"speakers": []}"#), [])
    }

    // MARK: - Parsing: evidence is required

    func test_entry_without_a_quote_is_dropped() {
        let raw = """
            {"speakers": [
              {"speaker": "SPEAKER_00", "name": "Dana"},
              {"speaker": "SPEAKER_01", "name": "Alex", "quote": ""},
              {"speaker": "SPEAKER_02", "name": "Bob", "quote": "   "}
            ]}
            """
        XCTAssertEqual(parse(raw), [], "a mapping with no evidence must never become a suggestion")
    }

    func test_quote_that_is_not_in_the_transcript_is_dropped() {
        let raw = #"{"speakers": [{"speaker": "SPEAKER_01", "name": "Alex", "quote": "I'm Alex, the PM"}]}"#
        XCTAssertEqual(parse(raw), [], "an invented quote is not evidence")
    }

    func test_quote_that_does_not_state_the_name_is_dropped() {
        // In the transcript, but says nothing about anyone's name.
        let raw = #"{"speakers": [{"speaker": "SPEAKER_02", "name": "Carol", "quote": "we should ship it on Friday"}]}"#
        XCTAssertEqual(parse(raw), [])
    }

    func test_placeholder_and_label_names_are_dropped() {
        let raw = """
            {"speakers": [
              {"speaker": "SPEAKER_00", "name": "Unknown", "quote": "my name is Dana"},
              {"speaker": "SPEAKER_01", "name": "Speaker B", "quote": "Thanks Dana"},
              {"speaker": "SPEAKER_02", "name": "SPEAKER_02", "quote": "I think"}
            ]}
            """
        XCTAssertEqual(parse(raw), [])
    }

    func test_speakers_that_are_named_or_invented_are_dropped() {
        let raw = """
            {"speakers": [
              {"speaker": "SPEAKER_00", "name": "Dana", "quote": "my name is Dana"},
              {"speaker": "SPEAKER_09", "name": "Bob", "quote": "Bob, what do you think?"},
              {"speaker": "Speaker C", "name": "Bob", "quote": "Bob, what do you think?"}
            ]}
            """
        // SPEAKER_00 already has a name, so it is not in the unnamed set.
        XCTAssertEqual(parse(raw, unnamed: ["SPEAKER_01", "SPEAKER_02"]), [])
    }

    func test_a_wrong_typed_entry_costs_only_itself() {
        let raw = """
            {"speakers": [
              {"speaker": "SPEAKER_00", "name": 42, "quote": "my name is Dana"},
              "garbage",
              {"speaker": "SPEAKER_02", "name": "Bob", "quote": "Bob, what do you think?"}
            ]}
            """
        XCTAssertEqual(parse(raw).map(\.name), ["Bob"])
    }

    func test_malformed_or_prose_output_yields_nothing() {
        XCTAssertEqual(parse(""), [])
        XCTAssertEqual(parse("I could not determine anyone's name."), [])
        XCTAssertEqual(parse(#"{"speakers": [{"speaker": "SPEAKER_00", "name": "Dana""#), [])
        XCTAssertEqual(parse(#"{"names": {"SPEAKER_00": "Dana"}}"#), [])
    }

    func test_one_speaker_given_two_names_keeps_neither() {
        let turns = [SpeakerNameSuggester.Turn(speaker: "SPEAKER_00",
                                               text: "My name is Dana, but just call me Bob.")]
        let raw = """
            {"speakers": [
              {"speaker": "SPEAKER_00", "name": "Dana", "quote": "My name is Dana"},
              {"speaker": "SPEAKER_00", "name": "Bob", "quote": "just call me Bob"}
            ]}
            """
        XCTAssertEqual(SpeakerNameSuggester.parseSuggestions(from: raw, unnamedSpeakers: ["SPEAKER_00"],
                                                             turns: turns), [])
    }

    // MARK: - Parsing: the evidence must be about THIS speaker

    func test_a_self_introduction_by_someone_else_is_not_evidence() {
        // "my name is Dana" is SPEAKER_00's line; SPEAKER_02 never said it and
        // does not answer right after it.
        let raw = #"{"speakers": [{"speaker": "SPEAKER_02", "name": "Dana", "quote": "my name is Dana"}]}"#
        XCTAssertEqual(parse(raw), [])
    }

    func test_being_addressed_counts_only_for_whoever_answers_next() {
        // "Bob, what do you think?" is followed by SPEAKER_02, not SPEAKER_00.
        let raw = #"{"speakers": [{"speaker": "SPEAKER_00", "name": "Bob", "quote": "Bob, what do you think?"}]}"#
        XCTAssertEqual(parse(raw), [])
        let right = #"{"speakers": [{"speaker": "SPEAKER_02", "name": "Bob", "quote": "Bob, what do you think?"}]}"#
        XCTAssertEqual(parse(right).map(\.speaker), ["SPEAKER_02"])
    }

    func test_a_previous_speakers_self_introduction_does_not_name_the_next_speaker() {
        let turns = [SpeakerNameSuggester.Turn(speaker: "SPEAKER_00", text: "Hi, I'm Dana, nice to meet you."),
                     SpeakerNameSuggester.Turn(speaker: "SPEAKER_01", text: "Nice to meet you too.")]
        func suggest(_ speaker: String, _ quote: String) -> [String] {
            let raw = #"{"speakers": [{"speaker": "\#(speaker)", "name": "Dana", "quote": "\#(quote)"}]}"#
            return SpeakerNameSuggester.parseSuggestions(from: raw,
                                                         unnamedSpeakers: ["SPEAKER_00", "SPEAKER_01"],
                                                         turns: turns).map(\.speaker)
        }
        XCTAssertEqual(suggest("SPEAKER_01", "I'm Dana"), [],
                       "the line before SPEAKER_01 is SPEAKER_00 introducing herself")
        XCTAssertEqual(suggest("SPEAKER_01", "I'm Dana, nice to meet you"), [])
        XCTAssertEqual(suggest("SPEAKER_00", "I'm Dana"), ["SPEAKER_00"],
                       "the same quote does name the speaker who said it")
    }

    func test_being_addressed_names_whoever_answers_and_not_the_asker() {
        let turns = [SpeakerNameSuggester.Turn(speaker: "SPEAKER_00", text: "Dana, can you share your screen?"),
                     SpeakerNameSuggester.Turn(speaker: "SPEAKER_01", text: "Sure, one second.")]
        func suggest(_ speaker: String, _ quote: String) -> [String] {
            let raw = #"{"speakers": [{"speaker": "\#(speaker)", "name": "Dana", "quote": "\#(quote)"}]}"#
            return SpeakerNameSuggester.parseSuggestions(from: raw,
                                                         unnamedSpeakers: ["SPEAKER_00", "SPEAKER_01"],
                                                         turns: turns).map(\.speaker)
        }
        XCTAssertEqual(suggest("SPEAKER_01", "Dana, can you share your screen?"), ["SPEAKER_01"])
        XCTAssertEqual(suggest("SPEAKER_00", "Dana, can you share your screen?"), [],
                       "the speaker who said it was talking TO Dana")
    }

    func test_normalizing_is_locale_independent() {
        XCTAssertEqual(SpeakerNameSuggester.normalizedForMatching("I'M DANA!"), "i m dana")
        XCTAssertEqual(SpeakerNameSuggester.normalizedForMatching("I\u{2019}m  Dana"), "i m dana")
        XCTAssertEqual(SpeakerNameSuggester.normalizedForMatching("קוראים לי דנה."), "קוראים לי דנה")
    }

    func test_self_introduction_and_address_patterns() {
        func intro(_ quote: String, _ name: String) -> Bool {
            SpeakerNameSuggester.isSelfIntroduction(
                normalizedQuote: SpeakerNameSuggester.normalizedForMatching(quote), name: name)
        }
        XCTAssertTrue(intro("Hi, my name is Dana", "Dana"))
        XCTAssertTrue(intro("I\u{2019}m Dana", "Dana"))
        XCTAssertTrue(intro("This is Dana speaking", "Dana Cohen"))
        XCTAssertTrue(intro("קוראים לי דנה", "דנה"))
        XCTAssertTrue(intro("שלום, אני דנה", "דנה"))
        XCTAssertFalse(intro("This is Dana, our new PM", "Dana"), "introducing someone else")
        XCTAssertFalse(intro("Dana, what do you think?", "Dana"))

        XCTAssertTrue(SpeakerNameSuggester.addressesByName(quote: "Dana, what do you think?", name: "Dana"))
        XCTAssertTrue(SpeakerNameSuggester.addressesByName(quote: "Hey Dana, go ahead", name: "Dana"))
        XCTAssertTrue(SpeakerNameSuggester.addressesByName(quote: "What do you think, Dana?", name: "Dana"))
        XCTAssertTrue(SpeakerNameSuggester.addressesByName(quote: "דנה, מה דעתך?", name: "דנה"))
        XCTAssertFalse(SpeakerNameSuggester.addressesByName(quote: "I sent it to Dana yesterday", name: "Dana"))
    }

    func test_a_quote_cut_out_of_a_longer_sentence_is_not_an_introduction() {
        func suggest(_ line: String, _ quote: String) -> [String] {
            let turns = [SpeakerNameSuggester.Turn(speaker: "SPEAKER_00", text: line),
                         SpeakerNameSuggester.Turn(speaker: "SPEAKER_01", text: "OK.")]
            let raw = #"{"speakers": [{"speaker": "SPEAKER_00", "name": "Dana", "quote": "\#(quote)"}]}"#
            return SpeakerNameSuggester.parseSuggestions(from: raw,
                                                         unnamedSpeakers: ["SPEAKER_00", "SPEAKER_01"],
                                                         turns: turns).map(\.speaker)
        }
        XCTAssertEqual(suggest("Hi, I'm Dana's manager.", "I'm Dana"), [],
                       "a possessive is not a name")
        XCTAssertEqual(suggest("I left Dana here last week.", "Dana here"), [])
        XCTAssertEqual(suggest("Hi all, Dana here.", "Dana here"), ["SPEAKER_00"])
        XCTAssertEqual(suggest("Dana here, can everyone hear me?", "Dana here"), ["SPEAKER_00"])
        XCTAssertEqual(suggest("Sorry, I'm Dana, I'm late.", "I'm Dana"), ["SPEAKER_00"])
    }

    func test_a_possessive_after_the_last_name_is_not_an_introduction() {
        func suggest(_ line: String, _ name: String, _ quote: String) -> [String] {
            let turns = [SpeakerNameSuggester.Turn(speaker: "SPEAKER_00", text: line),
                         SpeakerNameSuggester.Turn(speaker: "SPEAKER_01", text: "OK.")]
            let raw = #"{"speakers": [{"speaker": "SPEAKER_00", "name": "\#(name)", "quote": "\#(quote)"}]}"#
            return SpeakerNameSuggester.parseSuggestions(from: raw,
                                                         unnamedSpeakers: ["SPEAKER_00", "SPEAKER_01"],
                                                         turns: turns).map(\.speaker)
        }
        XCTAssertEqual(suggest("I'm Dana Cohen's manager.", "Dana Cohen", "I'm Dana Cohen"), [])
        XCTAssertEqual(suggest("I'm Dana Cohen's manager.", "Dana Cohen", "I'm Dana"), [],
                       "the quote stops short of the last name")
        XCTAssertEqual(suggest("Hi, I'm Dana Cohen from sales.", "Dana Cohen", "I'm Dana Cohen"),
                       ["SPEAKER_00"])
    }

    func test_mentioning_a_name_before_a_comma_does_not_address_it() {
        XCTAssertFalse(SpeakerNameSuggester.addressesByName(quote: "I told Dana, it's fine", name: "Dana"))
        XCTAssertFalse(SpeakerNameSuggester.addressesByName(quote: "Ask Dana, she knows", name: "Dana"))
        XCTAssertTrue(SpeakerNameSuggester.addressesByName(quote: "OK so Dana, your turn", name: "Dana"))
        XCTAssertTrue(SpeakerNameSuggester.addressesByName(quote: "היי דנה, מה דעתך?", name: "דנה"))
    }

    func test_a_one_word_quote_that_is_just_the_name_is_dropped() {
        let raw = #"{"speakers": [{"speaker": "SPEAKER_00", "name": "Dana", "quote": "Dana."}]}"#
        XCTAssertEqual(parse(raw), [])
    }

    func test_a_name_another_speaker_already_has_is_dropped() {
        let raw = #"{"speakers": [{"speaker": "SPEAKER_00", "name": "Dana", "quote": "my name is Dana"}]}"#
        XCTAssertEqual(parse(raw, unnamed: ["SPEAKER_00", "SPEAKER_02"], taken: ["dana"]), [],
                       "Dana is already SPEAKER_01's name in this recording")
    }

    func test_one_name_given_to_two_speakers_keeps_neither() {
        let turns = [SpeakerNameSuggester.Turn(speaker: "SPEAKER_00", text: "Hi, my name is Dana."),
                     SpeakerNameSuggester.Turn(speaker: "SPEAKER_01", text: "Funny, I'm Dana too.")]
        let raw = """
            {"speakers": [
              {"speaker": "SPEAKER_00", "name": "Dana", "quote": "my name is Dana"},
              {"speaker": "SPEAKER_01", "name": "dana", "quote": "I'm Dana too"}
            ]}
            """
        XCTAssertEqual(SpeakerNameSuggester.parseSuggestions(from: raw,
                                                             unnamedSpeakers: ["SPEAKER_00", "SPEAKER_01"],
                                                             turns: turns), [])
    }

    func test_thanking_someone_by_name_does_not_name_the_speaker() {
        // "Thanks Dana!" is SPEAKER_01 talking TO Dana, in their own turn.
        let raw = #"{"speakers": [{"speaker": "SPEAKER_01", "name": "Dana", "quote": "Thanks Dana"}]}"#
        XCTAssertEqual(parse(raw, unnamed: ["SPEAKER_01", "SPEAKER_02"]), [])
    }

    func test_same_answer_twice_for_one_speaker_is_one_suggestion() {
        let raw = """
            {"speakers": [
              {"speaker": "SPEAKER_00", "name": "Dana", "quote": "my name is Dana"},
              {"speaker": "SPEAKER_00", "name": "DANA", "quote": "Thanks Dana"}
            ]}
            """
        XCTAssertEqual(parse(raw).map(\.evidence), ["my name is Dana"], "first quote wins")
    }

    // MARK: - Persistence

    func test_suggestions_survive_a_reload_and_are_omitted_when_empty() throws {
        var rec = meeting()
        rec.speakerNameSuggestions = [SpeakerNameSuggestion(speaker: "SPEAKER_00", name: "Dana",
                                                            evidence: "my name is Dana",
                                                            origin: .transcript)]
        store.add(rec)
        let reloaded = RecordingStore(rootDirectory: tempRoot)
        let row = try XCTUnwrap(reloaded.recordings.first { $0.id == rec.id })
        XCTAssertEqual(row.speakerNameSuggestions, rec.speakerNameSuggestions)

        let encoder = JSONEncoder()
        let json = try JSONSerialization.jsonObject(with: encoder.encode(meeting())) as? [String: Any]
        XCTAssertNil(json?["speakerNameSuggestions"], "no key when empty — byte-identical to before")
    }

    func test_an_unknown_origin_or_unreadable_list_never_fails_the_row() throws {
        let id = UUID()
        let json = """
            {"id":"\(id.uuidString)","title":"T","createdAt":"2024-01-01T00:00:00Z","duration":1,
             "source":"meeting","audioFileName":"t.wav","status":"completed","language":"en",
             "segments":[],
             "speakerNameSuggestions":[{"speaker":"SPEAKER_00","name":"Dana","origin":"telepathy"}]}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let rec = try decoder.decode(Recording.self, from: Data(json.utf8))
        XCTAssertEqual(rec.speakerNameSuggestions.first?.origin, .transcript)
        XCTAssertEqual(rec.speakerNameSuggestions.first?.evidence, "")

        let broken = json.replacingOccurrences(of: #"[{"speaker":"SPEAKER_00","name":"Dana","origin":"telepathy"}]"#,
                                               with: #""not a list""#)
        XCTAssertEqual(try decoder.decode(Recording.self, from: Data(broken.utf8)).speakerNameSuggestions, [])
    }

    // MARK: - Applying (store)

    func test_merge_keeps_only_actionable_suggestions_and_never_names_anyone() throws {
        let rec = meeting(names: ["SPEAKER_01": "Alex"])
        store.add(rec)
        var named: [String] = []
        store.onSpeakerNamed = { _, raw, _ in named.append(raw) }

        let changed = store.mergeSpeakerNameSuggestions([
            .init(speaker: "SPEAKER_00", name: "Dana", evidence: "my name is Dana", origin: .transcript),
            .init(speaker: "SPEAKER_01", name: "Bob", evidence: "x", origin: .transcript),   // already named
            .init(speaker: "SPEAKER_07", name: "Eve", evidence: "x", origin: .transcript),   // not in transcript
        ], recordingID: rec.id)

        XCTAssertTrue(changed)
        let row = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(row.speakerNameSuggestions.map(\.speaker), ["SPEAKER_00"])
        XCTAssertEqual(row.speakerNames, ["SPEAKER_01": "Alex"], "a suggestion is not a name")
        XCTAssertEqual(named, [], "no voice profile may learn from an unaccepted suggestion")
    }

    func test_accept_goes_through_the_normal_rename_path() throws {
        let rec = meeting()
        store.add(rec)
        store.mergeSpeakerNameSuggestions([
            .init(speaker: "SPEAKER_00", name: "dana", evidence: "my name is Dana", origin: .transcript),
        ], recordingID: rec.id)
        var namedEvents: [(String, String)] = []
        store.onSpeakerNamed = { _, raw, name in namedEvents.append((raw, name)) }
        let directory = SpeakerDirectory(directory: tempRoot)
        directory.add("Dana")

        let assigned = store.acceptSpeakerNameSuggestion(forSpeaker: "SPEAKER_00",
                                                         recordingID: rec.id,
                                                         canonicalName: { directory.add($0) })

        XCTAssertEqual(assigned, "Dana", "routed through the directory's canonical spelling")
        let row = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(row.speakerNames["SPEAKER_00"], "Dana")
        XCTAssertEqual(row.speakerNameSuggestions, [], "an accepted suggestion is gone")
        XCTAssertEqual(namedEvents.map { $0.0 }, ["SPEAKER_00"])
        XCTAssertEqual(namedEvents.map { $0.1 }, ["Dana"],
                       "accepting fires the same hook a typed rename does — the voice profile learns only now")
    }

    func test_accept_never_replaces_a_name_that_landed_meanwhile() throws {
        let rec = meeting()
        store.add(rec)
        store.mergeSpeakerNameSuggestions([
            .init(speaker: "SPEAKER_00", name: "Dana", evidence: "my name is Dana", origin: .transcript),
        ], recordingID: rec.id)
        store.setSpeakerName("Daniela", forSpeaker: "SPEAKER_00", recordingID: rec.id)

        XCTAssertNil(store.acceptSpeakerNameSuggestion(forSpeaker: "SPEAKER_00", recordingID: rec.id))
        let row = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(row.speakerNames["SPEAKER_00"], "Daniela")
    }

    func test_naming_or_resetting_a_speaker_settles_its_suggestion() throws {
        let rec = meeting()
        store.add(rec)
        store.mergeSpeakerNameSuggestions([
            .init(speaker: "SPEAKER_00", name: "Dana", evidence: "my name is Dana", origin: .transcript),
            .init(speaker: "SPEAKER_02", name: "Bob", evidence: "Bob, what do you think?", origin: .transcript),
        ], recordingID: rec.id)

        store.setSpeakerName("Someone", forSpeaker: "SPEAKER_00", recordingID: rec.id)
        store.setSpeakerName(nil, forSpeaker: "SPEAKER_00", recordingID: rec.id)

        let row = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(row.speakerNameSuggestions.map(\.speaker), ["SPEAKER_02"],
                       "resetting to the default label must not resurrect a suggestion the user overruled")
    }

    func test_dismiss_removes_without_naming() throws {
        let rec = meeting()
        store.add(rec)
        store.mergeSpeakerNameSuggestions([
            .init(speaker: "SPEAKER_00", name: "Dana", evidence: "my name is Dana", origin: .transcript),
        ], recordingID: rec.id)
        var named = false
        store.onSpeakerNamed = { _, _, _ in named = true }

        store.dismissSpeakerNameSuggestion(forSpeaker: "SPEAKER_00", recordingID: rec.id)

        let row = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(row.speakerNameSuggestions, [])
        XCTAssertEqual(row.speakerNames, [:])
        XCTAssertFalse(named)
    }

    func test_merging_a_speaker_away_drops_its_suggestion() throws {
        let rec = meeting()
        store.add(rec)
        store.mergeSpeakerNameSuggestions([
            .init(speaker: "SPEAKER_02", name: "Bob", evidence: "Bob, what do you think?", origin: .transcript),
        ], recordingID: rec.id)

        store.mergeSpeakers(from: "SPEAKER_02", into: "SPEAKER_01", recordingID: rec.id)

        let row = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(row.speakerNameSuggestions, [],
                       "a retired id's suggestion must not wait for split to hand the number out again")
    }

    func test_split_never_reuses_an_id_that_still_carries_a_suggestion() throws {
        // A stale suggestion for SPEAKER_02, which has no lines: the next free
        // number by segments and names alone.
        let rec = Recording(
            title: "Split", source: .meeting, audioFileName: "split.wav",
            status: .completed, language: "en",
            segments: [
                TranscriptSegment(start: 0, end: 1, text: "First line.", speaker: "SPEAKER_00"),
                TranscriptSegment(start: 1, end: 2, text: "Reply.", speaker: "SPEAKER_01"),
                TranscriptSegment(start: 2, end: 3, text: "Second line.", speaker: "SPEAKER_00"),
            ],
            fullText: "First line. Reply. Second line.",
            speakerNameSuggestions: [.init(speaker: "SPEAKER_02", name: "Bob",
                                           evidence: "Bob, over to you", origin: .transcript)])
        store.add(rec)

        store.splitSegmentSpeaker(segmentID: rec.segments[2].id, recordingID: rec.id)

        let row = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(row.segments[2].speaker, "SPEAKER_03")
        XCTAssertEqual(row.actionableSpeakerNameSuggestions, [],
                       "the split-off voice must not inherit Bob")
    }

    func test_deleting_transcript_lines_drops_suggestions_they_backed() throws {
        let rec = meeting()
        store.add(rec)
        store.mergeSpeakerNameSuggestions([
            .init(speaker: "SPEAKER_00", name: "Dana", evidence: "my name is Dana", origin: .transcript),
            .init(speaker: "SPEAKER_02", name: "Bob", evidence: "Bob, what do you think?", origin: .transcript),
        ], recordingID: rec.id)

        // Remove Dana's introduction (her only line): her speaker and the
        // quote are both gone. Bob's quote is on a line that stays.
        XCTAssertNotNil(store.deleteSegments([rec.segments[0].id], recordingID: rec.id))

        let row = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(row.speakerNameSuggestions.map(\.speaker), ["SPEAKER_02"])
    }

    func test_a_suggestion_whose_quoted_line_was_deleted_is_dropped() {
        var rec = meeting()
        rec.speakerNameSuggestions = [.init(speaker: "SPEAKER_02", name: "Bob",
                                            evidence: "Bob, what do you think?", origin: .transcript)]
        // SPEAKER_02 still speaks, but the line that addressed Bob is gone.
        rec.segments.remove(at: 1)
        XCTAssertEqual(rec.speakerNameSuggestionsSurvivingEdit, [],
                       "a deleted line must not live on as a suggestion's quote")
    }

    func test_a_merged_away_speaker_has_no_actionable_suggestion() {
        var rec = meeting()
        rec.speakerNameSuggestions = [.init(speaker: "SPEAKER_02", name: "Bob",
                                            evidence: "Bob, what do you think?", origin: .transcript)]
        rec.segments = rec.segments.map { seg in
            var s = seg
            if s.speaker == "SPEAKER_02" { s.speaker = "SPEAKER_01" }
            return s
        }
        XCTAssertEqual(rec.actionableSpeakerNameSuggestions, [])
    }

    // MARK: - "Me"

    func test_your_name_is_suggested_for_the_only_voice_on_a_mic_recording() {
        for source in [RecordingSource.microphone, .voiceMemo] {
            let suggestion = SpeakerNameSuggester.localUserSuggestion(for: soloMemo(source: source),
                                                                      myName: "  Uri ")
            XCTAssertEqual(suggestion?.speaker, "SPEAKER_00", "\(source)")
            XCTAssertEqual(suggestion?.name, "Uri")
            XCTAssertEqual(suggestion?.origin, .localUser)
        }
    }

    func test_your_name_is_not_guessed_where_the_capture_cannot_tell() {
        // A meeting mixes mic and app audio into one track.
        XCTAssertNil(SpeakerNameSuggester.localUserSuggestion(for: soloMemo(source: .meeting), myName: "Uri"))
        // A file import / system-audio capture is not the user's mic.
        XCTAssertNil(SpeakerNameSuggester.localUserSuggestion(for: soloMemo(source: .systemAudio), myName: "Uri"))
        // Two voices on the mic: nothing says which one is the user.
        var two = soloMemo()
        two.segments[1].speaker = "SPEAKER_01"
        XCTAssertNil(SpeakerNameSuggester.localUserSuggestion(for: two, myName: "Uri"))
        // Already named, or no name set.
        var named = soloMemo()
        named.speakerNames = ["SPEAKER_00": "Someone"]
        XCTAssertNil(SpeakerNameSuggester.localUserSuggestion(for: named, myName: "Uri"))
        XCTAssertNil(SpeakerNameSuggester.localUserSuggestion(for: soloMemo(), myName: "   "))
        XCTAssertNil(SpeakerNameSuggester.localUserSuggestion(for: soloMemo(), myName: nil))
    }

    func test_your_name_persists_in_its_own_suite() {
        XCTAssertNil(identity.resolvedName, "not set by default")
        identity.myName = "Uri Cohen "
        XCTAssertEqual(identity.resolvedName, "Uri Cohen")
        let reloaded = SpeakerIdentitySettings(defaults: identityDefaults)
        XCTAssertEqual(reloaded.resolvedName, "Uri Cohen")
    }

    // MARK: - Settings gate

    func test_transcript_suggestions_default_follows_auto_summary_live() {
        XCTAssertTrue(llm.speakerNameSuggestionsEnabled, "fresh install: auto-summary is on, so this is on")
        llm.summaryEnabled = false
        XCTAssertFalse(llm.speakerNameSuggestionsEnabled,
                       "follows auto-summary within the session, not a copy taken at launch")
        XCTAssertNil(llmDefaults.object(forKey: "llm.speakerNames.enabled"),
                     "following the default writes nothing")
        let relaunched = LLMSettings(defaults: llmDefaults, apiKeyKeychainKey: "SpeakerNameSuggestionTests.\(UUID())")
        XCTAssertFalse(relaunched.speakerNameSuggestionsEnabled, "and agrees after a relaunch")

        relaunched.speakerNameSuggestionsEnabled = true
        relaunched.summaryEnabled = false
        XCTAssertTrue(relaunched.speakerNameSuggestionsEnabled, "an explicit choice wins")
        let explicit = LLMSettings(defaults: llmDefaults, apiKeyKeychainKey: "SpeakerNameSuggestionTests.\(UUID())")
        XCTAssertTrue(explicit.speakerNameSuggestionsEnabled, "and is persisted")
        XCTAssertEqual(llmDefaults.object(forKey: "llm.speakerNames.enabled") as? Bool, true)
    }

    func test_background_model_choice_is_shared_and_tool_conditional() {
        XCTAssertEqual(LLMSettings.backgroundModelName(tool: .openaiCompatible,
                                                       openAIModelName: "gpt-4o-mini",
                                                       liveAIModel: "claude-sonnet"), "gpt-4o-mini")
        XCTAssertEqual(LLMSettings.backgroundModelName(tool: .claude,
                                                       openAIModelName: "gpt-4o-mini",
                                                       liveAIModel: "claude-sonnet"), "claude-sonnet")
    }

    func test_ready_requires_a_configured_provider() {
        llm.speakerNameSuggestionsEnabled = true
        llm.tool = .none
        XCTAssertFalse(llm.isSpeakerNameSuggestionReady)
        llm.tool = .claude
        XCTAssertTrue(llm.isSpeakerNameSuggestionReady)
        llm.speakerNameSuggestionsEnabled = false
        XCTAssertFalse(llm.isSpeakerNameSuggestionReady)
    }

    // MARK: - Suggester end to end (stub runner)

    private final class CallLog {
        var calls: [SpeakerNameSuggester.Call] = []
    }

    private func makeSuggester(answer: String,
                               log: CallLog,
                               during: (@MainActor () -> Void)? = nil) -> SpeakerNameSuggester {
        SpeakerNameSuggester(store: store, llmSettings: llm, liveAISettings: liveAI,
                             identity: identity,
                             runLLM: { call in
                                 log.calls.append(call)
                                 during?()
                                 return answer
                             })
    }

    private let danaAnswer = """
        {"speakers": [{"speaker": "SPEAKER_00", "name": "Dana", "quote": "my name is Dana"}]}
        """

    func test_suggester_asks_once_after_the_summary_settles_and_stores_suggestions() async throws {
        llm.tool = .claude
        let rec = meeting()
        store.add(rec)
        let log = CallLog()
        let suggester = makeSuggester(answer: danaAnswer, log: log)

        // Not marked by a fresh completion (e.g. launch backfill): nothing.
        suggester.suggestIfPending(rec)
        await suggester.awaitIdle()
        XCTAssertEqual(log.calls.count, 0)

        suggester.markPending(rec.id)
        suggester.suggestIfPending(rec)
        await suggester.awaitIdle()

        XCTAssertEqual(log.calls.count, 1)
        let call = try XCTUnwrap(log.calls.first)
        XCTAssertTrue(call.transcript.contains("SPEAKER_00: Hi everyone, my name is Dana."),
                      "the model sees raw labels so it can name them back")
        XCTAssertTrue(call.prompt.contains("SPEAKER_00, SPEAKER_01, SPEAKER_02"))
        let row = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(row.speakerNameSuggestions.map(\.name), ["Dana"])
        XCTAssertEqual(row.speakerNames, [:], "suggested, not applied")

        // The mark is consumed: a later summary regenerate does not re-ask.
        suggester.suggestIfPending(rec)
        await suggester.awaitIdle()
        XCTAssertEqual(log.calls.count, 1)
    }

    func test_suggester_sends_nothing_when_switched_off_or_unconfigured() async {
        let rec = meeting()
        store.add(rec)
        let log = CallLog()
        let suggester = makeSuggester(answer: danaAnswer, log: log)

        llm.tool = .none
        suggester.suggest(recordingID: rec.id)
        await suggester.awaitIdle()
        llm.tool = .claude
        llm.speakerNameSuggestionsEnabled = false
        suggester.suggest(recordingID: rec.id)
        await suggester.awaitIdle()

        XCTAssertEqual(log.calls.count, 0)
    }

    func test_suggester_skips_a_recording_whose_speakers_are_all_named() async {
        llm.tool = .claude
        let rec = meeting(names: ["SPEAKER_00": "A", "SPEAKER_01": "B", "SPEAKER_02": "C"])
        store.add(rec)
        let log = CallLog()
        let suggester = makeSuggester(answer: danaAnswer, log: log)
        suggester.suggest(recordingID: rec.id)
        await suggester.awaitIdle()
        XCTAssertEqual(log.calls.count, 0)
    }

    func test_output_is_discarded_when_the_speakers_changed_mid_flight() async throws {
        llm.tool = .claude
        let rec = meeting()
        store.add(rec)
        let log = CallLog()
        let store = self.store!
        let suggester = makeSuggester(answer: danaAnswer, log: log, during: {
            // The user merges two speakers while the call is out: the labels
            // the model answered about no longer mean the same voices.
            store.mergeSpeakers(from: "SPEAKER_01", into: "SPEAKER_00", recordingID: rec.id)
        })
        suggester.suggest(recordingID: rec.id)
        await suggester.awaitIdle()

        XCTAssertEqual(log.calls.count, 1)
        let row = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(row.speakerNameSuggestions, [])
    }

    func test_local_user_suggestion_needs_no_llm() async throws {
        llm.tool = .none
        identity.myName = "Uri"
        let rec = soloMemo()
        store.add(rec)
        let log = CallLog()
        let suggester = makeSuggester(answer: "", log: log)
        var named = false
        store.onSpeakerNamed = { _, _, _ in named = true }

        suggester.suggest(recordingID: rec.id)
        await suggester.awaitIdle()

        XCTAssertEqual(log.calls.count, 0)
        let row = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(row.speakerNameSuggestions.map(\.name), ["Uri"])
        XCTAssertEqual(row.speakerNameSuggestions.map(\.origin), [.localUser])
        XCTAssertFalse(named, "\"me\" is suggested, not learned into a voice profile")
    }

    func test_transcript_evidence_replaces_the_local_user_guess() async throws {
        llm.tool = .claude
        identity.myName = "Uri"
        var rec = soloMemo()
        rec.segments[0].text = "Hi, this is Dana speaking."
        rec.fullText = "Hi, this is Dana speaking. And call the bank."
        store.add(rec)
        let log = CallLog()
        let suggester = makeSuggester(answer: """
            {"speakers": [{"speaker": "SPEAKER_00", "name": "Dana", "quote": "this is Dana speaking"}]}
            """, log: log)

        suggester.suggest(recordingID: rec.id)
        await suggester.awaitIdle()

        let row = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(row.speakerNameSuggestions.map(\.name), ["Dana"])
        XCTAssertEqual(row.speakerNameSuggestions.map(\.origin), [.transcript])
    }

    func test_a_request_during_a_call_runs_again_after_it() async throws {
        llm.tool = .claude
        let rec = meeting()
        store.add(rec)
        let log = CallLog()
        let store = self.store!
        var suggesterRef: SpeakerNameSuggester?
        let suggester = makeSuggester(answer: danaAnswer, log: log, during: {
            guard log.calls.count == 1 else { return }
            // A new pass lands while the first call is out, and asks again.
            if var row = store.recordings.first(where: { $0.id == rec.id }) {
                row.fullText += " "
                store.update(row)
            }
            suggesterRef?.suggest(recordingID: rec.id)
        })
        suggesterRef = suggester

        suggester.suggest(recordingID: rec.id)
        await suggester.awaitIdle()

        XCTAssertEqual(log.calls.count, 2, "the request is not dropped: it runs after the first call")
        let row = try XCTUnwrap(store.recordings.first { $0.id == rec.id })
        XCTAssertEqual(row.speakerNameSuggestions.map(\.name), ["Dana"],
                       "the first answer (stale transcript) was discarded, the re-run's was kept")
    }

    func test_a_mark_on_a_trashed_recording_does_not_survive_a_restore() async {
        llm.tool = .claude
        let rec = meeting()
        store.add(rec)
        let log = CallLog()
        let suggester = makeSuggester(answer: danaAnswer, log: log)

        suggester.markPending(rec.id)
        // Trashed mid-summary: the summarizer never signals for it.
        store.softDelete(rec)
        if let trashed = store.recordings.first(where: { $0.id == rec.id }) {
            store.restore(trashed)
        }
        // A later manual "Regenerate summary" settles a summary attempt.
        if let live = store.recordings.first(where: { $0.id == rec.id }) {
            suggester.suggestIfPending(live)
        }
        await suggester.awaitIdle()

        XCTAssertEqual(log.calls.count, 0, "only a fresh completion may trigger a call")
    }

    func test_permanent_delete_cancels_and_writes_nothing_back() async {
        llm.tool = .claude
        let rec = meeting()
        store.add(rec)
        let log = CallLog()
        let store = self.store!
        let suggester = makeSuggester(answer: danaAnswer, log: log, during: {
            if let row = store.recordings.first(where: { $0.id == rec.id }) {
                store.permanentlyDelete(row)
            }
        })
        suggester.suggest(recordingID: rec.id)
        await suggester.awaitIdle()
        XCTAssertNil(store.recordings.first { $0.id == rec.id })
    }
}
