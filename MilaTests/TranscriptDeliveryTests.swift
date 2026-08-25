import XCTest
@testable import Mila

/// Issue #179 — "reference the transcript by file path instead of inlining it
/// in argv".
///
/// The transcript really does travel inside the prompt argument today
/// (`LLMRunnerTests.test_runner_passes_prompt_in_argv_and_closes_stdin` proves
/// it by spawning a script that echoes its last argv token), and inlining it
/// there is lossy in a way nothing in the prompt reveals:
/// `TranscriptFormatter.plainText` keeps speaker labels but drops every
/// timestamp, while the `.srt` sidecar written next to the same audio has both.
/// `TranscriptDelivery.reference` names those files instead of pasting the body.
///
/// What is pinned here is the whole decision surface, and all of it is pure:
/// which references survive the existence filter, when the mode downgrades back
/// to inlining, and the two wire formats `composedPrompt` can emit.
///
/// Deliberately its own file rather than an addition to `LLMRunnerTests`: that
/// class also holds smoke tests that invoke the real `claude` / `cursor-agent` /
/// `gemini` binaries, so it cannot be run casually. Nothing here spawns a
/// process or touches the network; the only I/O is temp files this class writes
/// and removes itself.
final class TranscriptDeliveryTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptDeliveryTests.\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        try super.tearDownWithError()
    }

    /// Write `contents` to `name` under the temp root and return its URL.
    /// Passing `""` creates the zero-byte case on purpose.
    private func makeFile(_ name: String, contents: String = "x") throws -> URL {
        let url = tempRoot.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A path under the temp root that deliberately has no file behind it.
    private func missing(_ name: String) -> URL {
        tempRoot.appendingPathComponent(name)
    }

    // MARK: - TranscriptFiles.existing

    /// The reason `existing` exists at all: none of the three artifacts is
    /// guaranteed to be on disk when a send fires. A path that can't be opened
    /// is worse than no path, because the model then answers from the prompt's
    /// framing ("the transcript is in that file") rather than from anything
    /// that was actually said.
    func test_existing_drops_paths_with_no_file_behind_them() throws {
        let srt = try makeFile("Standup.srt", contents: "1\n00:00:01,000 --> 00:00:02,000\nhi\n\n")
        let files = TranscriptFiles.existing(subtitles: srt,
                                             plainText: missing("Standup.txt"),
                                             audio: missing("Standup.m4a"))

        XCTAssertEqual(files.subtitles, srt)
        XCTAssertNil(files.plainText)
        XCTAssertNil(files.audio)
        XCTAssertFalse(files.isEmpty)
    }

    /// `RecordingStore` deletes an emptied sidecar rather than truncating it,
    /// but an interrupted atomic write can still leave 0 bytes behind — and
    /// "read this empty file" reads to a model as "nothing was said", which is
    /// a confidently wrong answer rather than a missing one.
    func test_existing_drops_zero_byte_files() throws {
        let empty = try makeFile("Silent.srt", contents: "")
        let text = try makeFile("Silent.txt", contents: "we did speak")

        let files = TranscriptFiles.existing(subtitles: empty, plainText: text)

        XCTAssertNil(files.subtitles, "a 0-byte sidecar must not be referenced")
        XCTAssertEqual(files.plainText, text)
    }

    func test_existing_with_nothing_on_disk_is_empty() {
        let files = TranscriptFiles.existing(subtitles: missing("a.srt"),
                                             plainText: missing("a.txt"),
                                             audio: missing("a.m4a"))
        XCTAssertTrue(files.isEmpty)
    }

    // MARK: - log tokens

    /// `refs=` is the only thing in the log that says which artifacts a run
    /// referenced — the paths themselves can't be logged (see
    /// `redactedCommand`), so this token carries the whole diagnosis.
    /// Extensions, never filenames.
    func test_log_token_lists_the_surviving_references() throws {
        let srt = try makeFile("a.srt")
        let txt = try makeFile("a.txt")
        let m4a = try makeFile("a.m4a")

        XCTAssertEqual(TranscriptFiles(subtitles: srt, plainText: txt, audio: m4a).logToken,
                       "srt+txt+audio")
        XCTAssertEqual(TranscriptFiles(subtitles: srt, plainText: nil, audio: m4a).logToken,
                       "srt+audio")
        XCTAssertEqual(TranscriptFiles(plainText: txt).logToken, "txt")
        XCTAssertEqual(TranscriptFiles().logToken, "none")
    }

    /// The pair of tokens has to read consistently for an inline run too, or a
    /// log scan for `refs=` silently skips half the invocations.
    func test_delivery_tokens_render_both_modes() throws {
        let srt = try makeFile("a.srt")
        XCTAssertEqual(TranscriptDelivery.inline.logToken, "inline")
        XCTAssertEqual(TranscriptDelivery.inline.refsToken, "none")

        let reference = TranscriptDelivery.reference(TranscriptFiles(subtitles: srt))
        XCTAssertEqual(reference.logToken, "reference")
        XCTAssertEqual(reference.refsToken, "srt")
    }

    // MARK: - readsLocalFiles (the provider gate)

    /// #179's hard constraint: reference delivery must never apply to the
    /// OpenAI-compatible endpoint, which has no access to the local filesystem.
    /// Stated once on `LLMTool` so the Settings UI and
    /// `LLMRunner.effectiveDelivery` can't drift apart on it.
    func test_only_local_CLIs_read_local_files() {
        XCTAssertTrue(LLMTool.claude.readsLocalFiles)
        XCTAssertTrue(LLMTool.cursor.readsLocalFiles)
        XCTAssertTrue(LLMTool.gemini.readsLocalFiles)
        XCTAssertFalse(LLMTool.openaiCompatible.readsLocalFiles,
                       "a remote HTTP endpoint cannot open a path we name")
        XCTAssertFalse(LLMTool.none.readsLocalFiles)
    }

    // MARK: - effectiveDelivery

    func test_effective_delivery_keeps_reference_for_a_local_cli() throws {
        let srt = try makeFile("a.srt")
        let requested = TranscriptDelivery.reference(TranscriptFiles(subtitles: srt))

        for tool in [LLMTool.claude, .cursor, .gemini] {
            XCTAssertEqual(LLMRunner.effectiveDelivery(requested, tool: tool), requested,
                           "\(tool) can read files — the reference must survive")
        }
    }

    /// Defense in depth behind the Settings gate. `run` returns down the HTTP
    /// branch before it ever composes a CLI prompt, but anything that composes
    /// one directly gets the same answer here.
    func test_effective_delivery_downgrades_for_a_provider_with_no_filesystem() throws {
        let srt = try makeFile("a.srt")
        let requested = TranscriptDelivery.reference(TranscriptFiles(subtitles: srt))

        XCTAssertEqual(LLMRunner.effectiveDelivery(requested, tool: .openaiCompatible),
                       .inline)
        XCTAssertEqual(LLMRunner.effectiveDelivery(requested, tool: .none), .inline)
    }

    /// The transcription pass writes the `.srt` last, so a send fired before it
    /// finishes finds nothing. Inlining whatever body we do have beats sending a
    /// prompt that points nowhere — the worst case of the new mode is exactly
    /// today's behaviour.
    func test_effective_delivery_downgrades_when_no_reference_exists() {
        XCTAssertEqual(
            LLMRunner.effectiveDelivery(.reference(TranscriptFiles()), tool: .claude),
            .inline)
    }

    func test_effective_delivery_leaves_inline_alone() {
        XCTAssertEqual(LLMRunner.effectiveDelivery(.inline, tool: .claude), .inline)
    }

    // MARK: - composedPrompt, reference mode

    /// The wire format from the issue. `.srt` is listed first because it is a
    /// superset of the `.txt` whenever both exist, and the read instruction
    /// covers only the transcripts — the audio line sits *below* it so an agent
    /// doesn't burn a tool call trying to read an `.m4a` it can't decode.
    func test_composed_prompt_reference_lists_srt_then_txt_then_audio() throws {
        let srt = try makeFile("Q3 review.srt")
        let txt = try makeFile("Q3 review.txt")
        let m4a = try makeFile("Q3 review.m4a")

        let composed = LLMRunner.composedPrompt(
            "File this in the tracker.",
            transcript: "unused in reference mode",
            delivery: .reference(TranscriptFiles(subtitles: srt, plainText: txt, audio: m4a)))

        XCTAssertEqual(composed, """
            File this in the tracker.

            ---
            Transcript (SubRip subtitles, with timestamps): \(srt.path)
            Transcript (plain text): \(txt.path)
            Read the transcript file(s) above before answering.
            Audio: \(m4a.path)
            """)
    }

    /// The point of the whole change, asserted directly: in reference mode the
    /// transcript body does not appear in the composed prompt, so it never
    /// reaches argv.
    func test_composed_prompt_reference_omits_the_transcript_body() throws {
        let srt = try makeFile("a.srt")
        let body = "Acme is acquiring Globex for $4.2M"

        let composed = LLMRunner.composedPrompt(
            "Summarize.",
            transcript: body,
            delivery: .reference(TranscriptFiles(subtitles: srt)))

        XCTAssertFalse(composed.contains(body),
                       "reference delivery must not inline the transcript: \(composed)")
        XCTAssertTrue(composed.contains(srt.path))
    }

    /// The summary is NOT dropped with the body. It is a few hundred characters,
    /// it is the gist the model should have before it picks a file to open, and
    /// it can exist for a recording whose sidecars don't (a send fired
    /// mid-meeting). Same `Summary:` label and same position as inline mode, so
    /// a user switching modes doesn't have to re-tune a prompt.
    func test_composed_prompt_reference_keeps_the_summary_above_the_paths() throws {
        let srt = try makeFile("a.srt")

        let composed = LLMRunner.composedPrompt(
            "Draft the follow-up.",
            transcript: "the body",
            summary: "We agreed to ship on Friday.",
            delivery: .reference(TranscriptFiles(subtitles: srt)))

        XCTAssertEqual(composed, """
            Draft the follow-up.

            ---
            Summary:
            We agreed to ship on Friday.

            Transcript (SubRip subtitles, with timestamps): \(srt.path)
            Read the transcript file(s) above before answering.
            """)
    }

    /// A recording with no segments gets no `.srt` at all, and its `.txt` is the
    /// only transcript there is. The label stays honest — it never claims
    /// timestamps for a plain-text file.
    func test_composed_prompt_reference_with_only_plain_text() throws {
        let txt = try makeFile("a.txt")

        let composed = LLMRunner.composedPrompt(
            "Summarize.",
            transcript: "the body",
            delivery: .reference(TranscriptFiles(plainText: txt)))

        XCTAssertEqual(composed, """
            Summarize.

            ---
            Transcript (plain text): \(txt.path)
            Read the transcript file(s) above before answering.
            """)
    }

    /// Audio but no transcript: there is nothing to read, so the read
    /// instruction must not appear — telling a model to read "the file(s) above"
    /// when the only one is an undecodable `.m4a` is an instruction to fail.
    func test_composed_prompt_reference_with_audio_only_omits_the_read_instruction() throws {
        let m4a = try makeFile("a.m4a")

        let composed = LLMRunner.composedPrompt(
            "File this.",
            transcript: "the body",
            delivery: .reference(TranscriptFiles(audio: m4a)))

        XCTAssertEqual(composed, """
            File this.

            ---
            Audio: \(m4a.path)
            """)
        XCTAssertFalse(composed.contains("Read the transcript"))
    }

    /// An empty reference set collapses to the inline format even if
    /// `composedPrompt` is called with `.reference` directly — belt and braces
    /// alongside `effectiveDelivery`, since a prompt whose only content is a
    /// `---` separator is the one output that helps nobody.
    func test_composed_prompt_reference_with_no_files_falls_back_to_inline() {
        let composed = LLMRunner.composedPrompt(
            "Summarize.",
            transcript: "Hello world.",
            delivery: .reference(TranscriptFiles()))

        XCTAssertEqual(composed, "Summarize.\n\n---\nTranscript:\nHello world.")
    }

    // MARK: - composedPrompt, inline mode is untouched

    /// Inlining is the default and every existing caller must keep producing
    /// the byte-identical prompt it produced before #179 — this is the
    /// back-compat guarantee for the OpenAI path, title generation, the
    /// automatic summary, Live AI and the Settings test panel, none of which
    /// pass a delivery at all.
    func test_default_delivery_is_inline_and_unchanged() {
        XCTAssertEqual(
            LLMRunner.composedPrompt("Summarize this.", transcript: "Hello world."),
            "Summarize this.\n\n---\nTranscript:\nHello world.")
        XCTAssertEqual(
            LLMRunner.composedPrompt("Make a tweet.",
                                     transcript: "Hello world.",
                                     summary: "We discussed the new schema."),
            "Make a tweet.\n\n---\nSummary:\nWe discussed the new schema.\n\nFull transcript:\nHello world.")
    }

    // MARK: - LLMSettings gate

    /// Inlining stays the default (#179's first constraint): a fresh install,
    /// and an upgrading user who has never seen this switch, must both keep
    /// pasting the transcript.
    @MainActor
    func test_setting_defaults_to_inline() {
        let suite = "TranscriptDeliveryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let llm = LLMSettings(defaults: defaults,
                              apiKeyKeychainKey: "TranscriptDeliveryTests.\(UUID())")
        llm.tool = .claude

        XCTAssertFalse(llm.actionTranscriptByPath)
        XCTAssertFalse(llm.actionDeliversTranscriptByPath)
    }

    /// The key is the persistence contract — renaming it silently resets the
    /// user's choice, which is what `AISettingsKeyCompatibilityTests` exists to
    /// prevent for the rest of this model.
    @MainActor
    func test_setting_round_trips_through_its_namespaced_key() {
        let suite = "TranscriptDeliveryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychainKey = "TranscriptDeliveryTests.\(UUID())"

        defaults.set(true, forKey: "llm.action.transcriptByPath")
        let restored = LLMSettings(defaults: defaults, apiKeyKeychainKey: keychainKey)
        restored.tool = .claude
        XCTAssertTrue(restored.actionTranscriptByPath,
                      "a stored preference must be adopted at init")
        XCTAssertTrue(restored.actionDeliversTranscriptByPath)

        restored.actionTranscriptByPath = false
        XCTAssertFalse(defaults.bool(forKey: "llm.action.transcriptByPath"))
    }

    /// `.claude/rules/feature-gates.md`: the switch alone is not readiness.
    /// A user who turns this on and later moves to the OpenAI-compatible
    /// endpoint must not start shipping paths to something that cannot open
    /// them — and the stored preference must survive the trip so switching back
    /// to a CLI restores it rather than silently losing it.
    @MainActor
    func test_setting_is_gated_off_for_a_provider_that_cannot_read_files() {
        let suite = "TranscriptDeliveryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let llm = LLMSettings(defaults: defaults,
                              apiKeyKeychainKey: "TranscriptDeliveryTests.\(UUID())")
        llm.tool = .claude
        llm.actionTranscriptByPath = true
        XCTAssertTrue(llm.actionDeliversTranscriptByPath)

        llm.tool = .openaiCompatible
        XCTAssertFalse(llm.actionDeliversTranscriptByPath,
                       "path delivery must be inert for the HTTP provider")
        XCTAssertTrue(llm.actionTranscriptByPath,
                      "the user's stored choice must survive the gate")

        llm.tool = .cursor
        XCTAssertTrue(llm.actionDeliversTranscriptByPath,
                      "switching back to a CLI restores the preference")
    }
}
