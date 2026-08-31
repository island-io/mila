import XCTest
import MilaKit
import TranscriptionCore
@testable import Mila

/// Deleting a line from the live transcript is a **privacy action**, not a
/// display tweak: the user is removing something said off the record, a
/// misfire, or a hallucinated segment. `bugbot-rules/deleted-data-stays-
/// deleted.md` is the rule it has to satisfy — after the delete, no code path
/// may write that text back.
///
/// `LiveTranscriberTests` covers the in-memory half (the line leaves
/// `segments`, and a later whisper tick can't re-emit it). That is not enough
/// on its own: the live transcript is copied out to SIX places, and an
/// in-memory-only assertion passes just as happily when every one of them
/// still holds the deleted text. This suite drives a real Stop and then goes
/// looking for it in all of them:
///
///   1. the in-memory store row,
///   2. `recordings.json`,
///   3. the per-recording `.txt` transcript sidecar,
///   4. the `.srt` sidecar `finalizeTail` writes,
///   5. the live sidecar `live/current.json` that mila-mcp follows,
///   6. what `MilaStoreReader` / the MCP tools serve — including
///      `search_transcripts`, which reads the sidecar chain rather than the
///      row, so it can disagree with everything above.
///
/// The final sweep reads every file under the store root and asserts the
/// marker text is nowhere on disk, which is the assertion that would have
/// caught a delete that only ever reached the UI.
@MainActor
final class LiveTranscriptLineDeleteTests: XCTestCase {

    /// Distinctive enough that finding it anywhere on disk is unambiguous,
    /// and plain ASCII so a binary audio file can't produce it by accident.
    private static let deletedLine = "ZZQQ-OFF-THE-RECORD-DELETE-ME"
    private static let keptLine = "this part of the meeting is fine to keep"

    private var tempRoot: URL!
    private var store: RecordingStore!
    private var manager: ModelManager!
    private var stub: StubWhisperEngine!
    private var service: TranscriptionService!
    private var session: RecordingSession!
    private var languageSettings: RecordingLanguageSettings!
    private var postRecording: PostRecordingCoordinator!
    private var sidecar: LiveTranscriptSidecarWriter!
    private var transcriber: LiveTranscriber!
    private var liveAISettings: LiveAISettings!
    private var controller: QuickActionsController!

    private let suitePrefix = "LiveTranscriptLineDeleteTests"
    private var savedSelection: String?

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: suitePrefix)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        // One root for everything, which is also the production layout: the
        // store writes `store-location.json` at its own root, so
        // `MilaStoreReader(root:)` and `MilaMCPToolHandlers(root:)` resolve
        // this store the same way mila-mcp resolves the real one.
        store = RecordingStore(rootDirectory: tempRoot)
        try FileManager.default.createDirectory(at: store.recordingsDirectory,
                                                withIntermediateDirectories: true)
        manager = ModelManager(modelsDirectory: tempRoot.appendingPathComponent("Models"))
        savedSelection = UserDefaults.standard.string(forKey: "selectedModelName")
        try TestSupport.installFakeModel(into: manager)

        stub = StubWhisperEngine()
        service = TranscriptionService(
            store: store,
            modelManager: manager,
            diarizationSettings: DiarizationSettings(
                defaults: .init(suiteName: "\(suitePrefix).diarization")!),
            remoteSettings: TestSupport.isolatedRemoteSettings(label: suitePrefix),
            engine: stub)
        session = RecordingSession()
        languageSettings = RecordingLanguageSettings(
            defaults: UserDefaults(suiteName: "\(suitePrefix).language")!)
        postRecording = PostRecordingCoordinator(
            store: store,
            transcription: service,
            llm: LLMSettings(defaults: UserDefaults(suiteName: "\(suitePrefix).llm")!))
        controller = QuickActionsController(session: session,
                                            store: store,
                                            transcription: service,
                                            languageSettings: languageSettings,
                                            postRecording: postRecording)

        transcriber = LiveTranscriber(transcription: service)
        transcriber.chunkSeconds = 5
        transcriber.windowSeconds = 10
        controller.liveTranscriber = transcriber

        liveAISettings = LiveAISettings(
            defaults: UserDefaults(suiteName: "\(suitePrefix).liveAI")!)
        // Auto-segment ON is what makes the live transcript the authoritative
        // one: `stopRecording` then saves the live segments instead of
        // enqueuing the WAV for a batch pass that would overwrite them. It is
        // also the only mode in which the UI offers the delete control (see
        // `liveTranscriptIsSaved` in LiveAIRecordingView).
        liveAISettings.useVAD = true
        controller.liveAISettings = liveAISettings

        // Long heartbeat: every snapshot this suite reads is one the test
        // caused, not a timer tick.
        sidecar = LiveTranscriptSidecarWriter(root: tempRoot,
                                              minWriteInterval: 0,
                                              heartbeatInterval: 3600)
        controller.liveSidecarWriter = sidecar

        try MCPAccessGate.set(true, root: tempRoot)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        if let savedSelection {
            UserDefaults.standard.set(savedSelection, forKey: "selectedModelName")
        } else {
            UserDefaults.standard.removeObject(forKey: "selectedModelName")
        }
        for suffix in ["diarization", "language", "llm", "liveAI"] {
            UserDefaults().removePersistentDomain(forName: "\(suitePrefix).\(suffix)")
        }
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Mirror one live tick to the sidecar exactly as `MilaApp`'s feed loop
    /// does — the loop itself lives in the app scene, so a unit test has to
    /// stand in for it.
    private func feedSidecar() {
        let mapped = transcriber.segments.map {
            TranscriptSegment(start: $0.startSeconds, end: $0.endSeconds,
                              text: $0.text, speaker: $0.speaker)
        }
        sidecar.update(segments: mapped, speakerNames: transcriber.speakerNames)
    }

    /// Two live lines from whisper, then the second one deleted. Returns
    /// nothing — the state to assert on is `transcriber` / `sidecar`.
    private func recordTwoLinesAndDeleteTheSecond() async throws {
        let url = store.freshAudioURL(suggestedName: "LineDelete")
        try TestSupport.writeStereo48kSineWav(at: url, durationSeconds: 0.6)
        await controller.startFakeRecordingForTesting(outputURL: url)
        sidecar.begin(title: "LineDelete", source: "microphone", liveAvailable: true)

        await stub.setDefaultCanned([
            TranscriptSegment(start: 0, end: 1, text: Self.keptLine),
            TranscriptSegment(start: 2, end: 3, text: Self.deletedLine),
        ])
        transcriber.start(language: "en")
        transcriber.ingest(ArraySlice(Array(repeating: Float(0.3), count: 32_000)))
        await transcriber.transcribeNow()
        XCTAssertEqual(transcriber.segments.map(\.text), [Self.keptLine, Self.deletedLine],
                       "precondition: both lines have to be in the live transcript first")
        feedSidecar()
        let published = try XCTUnwrap(liveSnapshot()).segments.map(\.text)
        XCTAssertTrue(published.contains(Self.deletedLine),
                      "precondition: the line the user is about to delete really was published")

        let victim = try XCTUnwrap(transcriber.segments.first { $0.text == Self.deletedLine })
        transcriber.removeSegment(id: victim.id)
        feedSidecar()
    }

    private func liveSnapshot() -> LiveTranscriptSnapshot? {
        LiveTranscriptSnapshot.read(root: tempRoot)
    }

    private func reader() -> MilaStoreReader { MilaStoreReader(root: tempRoot) }

    private func callTool(_ tool: String, _ args: [String: Any]) throws -> [String: Any] {
        let raw = try MilaMCPToolHandlers(root: tempRoot).handle(tool: tool, arguments: args)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    /// Every readable file under the store root, as text. Unreadable files
    /// (the audio) are skipped rather than failing the sweep.
    private func allTextOnDisk() -> [(path: String, text: String)] {
        var found: [(path: String, text: String)] = []
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: tempRoot, includingPropertiesForKeys: keys) else { return found }
        while let next = walker.nextObject() as? URL {
            guard (try? next.resourceValues(forKeys: Set(keys)))?.isRegularFile == true else {
                continue
            }
            guard let text = try? String(contentsOf: next, encoding: .utf8) else { continue }
            found.append((path: next.lastPathComponent, text: text))
        }
        return found
    }

    // MARK: -

    /// The load-bearing test. Delete a line, stop the recording, then check
    /// every artifact the transcript is copied into.
    func test_a_deleted_line_is_absent_from_everything_the_stop_writes() async throws {
        try await recordTwoLinesAndDeleteTheSecond()

        await controller.stopRecording()
        await controller.awaitFinalizeTails()

        // 1. The stored row.
        let saved = try XCTUnwrap(store.recordings.first)
        XCTAssertEqual(saved.status, .completed,
                       "precondition: auto-segment mode saves the live transcript as final — "
                       + "a `.pending` row would mean a batch pass is still owed, and that pass "
                       + "re-transcribes the WAV and brings the deleted line back")
        XCTAssertEqual(saved.segments.map(\.text), [Self.keptLine])
        XCTAssertFalse(saved.fullText.contains(Self.deletedLine))

        // 2. recordings.json.
        let storeJSON = try String(contentsOf: tempRoot.appendingPathComponent("recordings.json"),
                                   encoding: .utf8)
        XCTAssertTrue(storeJSON.contains(Self.keptLine), "precondition: the row really was persisted")
        XCTAssertFalse(storeJSON.contains(Self.deletedLine),
                       "the deleted line was written into recordings.json")

        // 3. The `.txt` transcript sidecar — read through the same chain the
        //    helper uses, which prefers the sidecar over the row.
        let stored = try XCTUnwrap(reader().recording(id: saved.id))
        let sidecarText = reader().transcriptText(for: stored)
        XCTAssertTrue(sidecarText.contains(Self.keptLine),
                      "precondition: the sidecar chain resolved to real text, not an empty string")
        XCTAssertFalse(sidecarText.contains(Self.deletedLine),
                       "MilaStoreReader.transcriptText still serves the deleted line")
        XCTAssertFalse(reader().namedTranscript(for: stored).contains(Self.deletedLine))

        // 4. The `.srt` sidecar written by `finalizeTail`.
        let srt = store.recordingsDirectory
            .appendingPathComponent((saved.audioFileName as NSString).deletingPathExtension + ".srt")
        if let srtText = try? String(contentsOf: srt, encoding: .utf8) {
            XCTAssertFalse(srtText.contains(Self.deletedLine),
                           "the deleted line was exported into the .srt subtitles")
        }

        // 5. The live sidecar mila-mcp follows.
        let snapshot = try XCTUnwrap(liveSnapshot())
        XCTAssertEqual(snapshot.state, .completed)
        XCTAssertFalse(snapshot.segments.map(\.text).contains(Self.deletedLine),
                       "live/current.json still holds the deleted line")

        // 6. Nowhere else under the store root either. This is the assertion
        //    that fails for a delete that only reached the UI.
        for file in allTextOnDisk() {
            XCTAssertFalse(file.text.contains(Self.deletedLine),
                           "deleted transcript text survived in \(file.path)")
        }
    }

    /// The MCP read paths specifically. `search_transcripts` goes through
    /// `namedTranscript` → the `.txt` sidecar, so it can serve text the store
    /// row no longer has; a retained recording id must not be a way back in
    /// either.
    func test_a_deleted_line_is_unreachable_through_the_mcp_tools() async throws {
        try await recordTwoLinesAndDeleteTheSecond()
        await controller.stopRecording()
        await controller.awaitFinalizeTails()
        let saved = try XCTUnwrap(store.recordings.first)

        let control = try callTool("search_transcripts", ["query": Self.keptLine])
        XCTAssertEqual(control["count"] as? Int, 1,
                       "precondition: search can see this recording at all")

        let hits = try callTool("search_transcripts", ["query": Self.deletedLine])
        XCTAssertEqual(hits["count"] as? Int, 0,
                       "search_transcripts still finds the deleted line")

        let transcript = try callTool("get_transcript", ["id": saved.id.uuidString])
        let text = try XCTUnwrap(transcript["transcript"] as? String)
        XCTAssertTrue(text.contains(Self.keptLine))
        XCTAssertFalse(text.contains(Self.deletedLine),
                       "get_transcript still serves the deleted line to an MCP client")
    }

    /// A poller that already fetched the deleted line has to be told, because
    /// the incremental cursor cannot express a removal on its own: it is a
    /// count plus "re-read the entry before it". Without the marker the reply
    /// is an empty delta and the client keeps the line for the rest of the
    /// meeting — with its cursor one ahead of reality, so every later line is
    /// mis-stitched too.
    func test_a_live_poller_holding_the_deleted_line_is_told_to_discard_it() async throws {
        let url = store.freshAudioURL(suggestedName: "LineDeleteLive")
        try TestSupport.writeStereo48kSineWav(at: url, durationSeconds: 0.6)
        await controller.startFakeRecordingForTesting(outputURL: url)
        sidecar.begin(title: "LineDeleteLive", source: "microphone", liveAvailable: true)

        await stub.setDefaultCanned([
            TranscriptSegment(start: 0, end: 1, text: Self.keptLine),
            TranscriptSegment(start: 2, end: 3, text: Self.deletedLine),
        ])
        transcriber.start(language: "en")
        transcriber.ingest(ArraySlice(Array(repeating: Float(0.3), count: 32_000)))
        await transcriber.transcribeNow()
        feedSidecar()

        // What the poller got on its first poll.
        let firstPoll = try callTool("get_live_transcript", [:])
        let session = try XCTUnwrap(firstPoll["session_id"] as? String)
        let revision = try XCTUnwrap(firstPoll["revision"] as? Int)
        let cursor = try XCTUnwrap(firstPoll["next_segment_index"] as? Int)
        XCTAssertEqual(cursor, 2)

        let victim = try XCTUnwrap(transcriber.segments.first { $0.text == Self.deletedLine })
        transcriber.removeSegment(id: victim.id)
        feedSidecar()

        let afterDelete = try callTool("get_live_transcript", [
            "session_id": session,
            "since_revision": revision,
            "since_segment_index": cursor,
        ])
        XCTAssertEqual(afterDelete["segments_removed"] as? Bool, true,
                       "the poller was not told a line went away")
        XCTAssertEqual(afterDelete["next_segment_index"] as? Int, 1,
                       "its cursor has to be corrected as well")
        let segments = (afterDelete["new_segments"] as? [[String: Any]])?
            .compactMap { $0["text"] as? String }
        XCTAssertEqual(segments, [Self.keptLine],
                       "the reply must be the complete surviving set, not an empty delta")
        let rendered = try XCTUnwrap(afterDelete["transcript"] as? String)
        XCTAssertFalse(rendered.contains(Self.deletedLine))

        // Tear the capture down through the real path so nothing is left
        // recording behind the test.
        await controller.stopRecording()
        await controller.awaitFinalizeTails()
    }
}
