import XCTest
import TranscriptionCore
@testable import Mila

/// "Transcribe while recording" (`LiveAISettings.transcribeWhileRecording`):
/// switched off, a recording runs no live pipeline — no live whisper, no live
/// diarizer daemon, no Live AI — and is transcribed by the batch pass after
/// Stop, so a call doesn't pay for transcription while it is happening.
///
/// The setting itself is a plain persisted Bool; what needs pinning is
///  * how it composes with the hardware gate without masquerading as it,
///  * that it is decided once per recording, at record start, and
///  * that a recording which skips the live pipeline can never inherit the
///    PREVIOUS recording's live transcript. That leak predates the setting
///    (the hardware-gated branch only called `stop()`, which keeps
///    `segments`), but the setting makes a live recording followed by a
///    live-off one an everyday sequence — it is the first thing anyone
///    trying the setting does.
@MainActor
final class TranscribeWhileRecordingTests: XCTestCase {

    private static let firstMeetingLine = "ZZQQ-FIRST-MEETING-LIVE-LINE"
    private static let secondMeetingLine = "second meeting batch transcript"

    private let suitePrefix = "TranscribeWhileRecordingTests"

    private var tempRoot: URL!
    private var store: RecordingStore!
    private var stub: StubWhisperEngine!
    private var service: TranscriptionService!
    private var transcriber: LiveTranscriber!
    private var liveAISettings: LiveAISettings!
    private var controller: QuickActionsController!

    private static let pro = SystemCapabilities(
        modelIdentifier: "Mac15,3",
        marketingName: "MacBook Pro",
        isMacBookAir: false,
        physicalRamGB: 32,
        performanceCoreCount: 10
    )
    private static let air = SystemCapabilities(
        modelIdentifier: "Mac15,12",
        marketingName: "MacBook Air",
        isMacBookAir: true,
        physicalRamGB: 16,
        performanceCoreCount: 4
    )

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: suitePrefix)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        for suffix in ["diarization", "language", "llm", "liveAI", "settings"] {
            UserDefaults().removePersistentDomain(forName: "\(suitePrefix).\(suffix)")
        }

        store = RecordingStore(rootDirectory: tempRoot)
        try FileManager.default.createDirectory(at: store.recordingsDirectory,
                                                withIntermediateDirectories: true)
        let manager = TestSupport.isolatedModelManager(
            modelsDirectory: tempRoot.appendingPathComponent("Models"),
            label: suitePrefix)
        try TestSupport.installFakeModel(into: manager)

        stub = StubWhisperEngine()
        service = TranscriptionService(
            store: store,
            modelManager: manager,
            diarizationSettings: DiarizationSettings(
                defaults: .init(suiteName: "\(suitePrefix).diarization")!),
            remoteSettings: TestSupport.isolatedRemoteSettings(label: suitePrefix),
            engine: stub)
        let postRecording = PostRecordingCoordinator(
            store: store,
            transcription: service,
            llm: LLMSettings(defaults: UserDefaults(suiteName: "\(suitePrefix).llm")!))
        controller = QuickActionsController(
            session: RecordingSession(),
            store: store,
            transcription: service,
            languageSettings: RecordingLanguageSettings(
                defaults: UserDefaults(suiteName: "\(suitePrefix).language")!),
            postRecording: postRecording)

        transcriber = LiveTranscriber(transcription: service)
        transcriber.chunkSeconds = 5
        transcriber.windowSeconds = 10
        controller.liveTranscriber = transcriber
        // Pinned to non-Air hardware so the only gate in play is the setting.
        liveAISettings = LiveAISettings(
            defaults: UserDefaults(suiteName: "\(suitePrefix).liveAI")!,
            capabilities: Self.pro)
        // Auto-segment ON (the default) is what makes a live transcript
        // authoritative at Stop — i.e. what lets a stale one be saved as
        // final and skip the batch pass.
        liveAISettings.useVAD = true
        controller.liveAISettings = liveAISettings
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        for suffix in ["diarization", "language", "llm", "liveAI", "settings"] {
            UserDefaults().removePersistentDomain(forName: "\(suitePrefix).\(suffix)")
        }
        try await super.tearDown()
    }

    private func freshSettings(_ capabilities: SystemCapabilities) -> LiveAISettings {
        LiveAISettings(defaults: UserDefaults(suiteName: "\(suitePrefix).settings")!,
                       capabilities: capabilities)
    }

    // MARK: - The setting

    func test_defaults_on_and_round_trips_off() {
        let settings = freshSettings(Self.pro)
        XCTAssertTrue(settings.transcribeWhileRecording,
                      "default must stay ON — today's behaviour for everyone who never touches it")
        XCTAssertTrue(settings.runsLivePipeline)

        settings.transcribeWhileRecording = false
        let reopened = freshSettings(Self.pro)
        XCTAssertFalse(reopened.transcribeWhileRecording, "an explicit OFF must survive a relaunch")
        XCTAssertFalse(reopened.runsLivePipeline)
    }

    /// The persisted key is a contract: diagnostics export every `liveAI.*`
    /// key by prefix, and renaming it would silently switch live transcription
    /// back on for everyone who turned it off.
    func test_persists_under_the_liveAI_namespaced_key() {
        let defaults = UserDefaults(suiteName: "\(suitePrefix).settings")!
        defaults.set(false, forKey: "liveAI.transcribeWhileRecording")
        XCTAssertFalse(freshSettings(Self.pro).transcribeWhileRecording)
    }

    /// Both gates have to be open, and switching live transcription off must
    /// NOT read as the hardware gate: `isLiveAIAvailable` drives the "Gated
    /// off on Air-class chips" notice, which a MacBook Pro user who simply
    /// switched the setting off must never see.
    func test_runsLivePipeline_needs_the_hardware_and_the_setting() {
        let pro = freshSettings(Self.pro)
        pro.transcribeWhileRecording = false
        XCTAssertFalse(pro.runsLivePipeline)
        XCTAssertTrue(pro.isLiveAIAvailable,
                      "turning live transcription off must not trip the hardware notice")

        let air = freshSettings(Self.air)
        air.transcribeWhileRecording = true
        air.forceLiveAIOnLowEndHardware = false
        XCTAssertFalse(air.runsLivePipeline, "the hardware gate still wins on an Air")
        air.forceLiveAIOnLowEndHardware = true
        XCTAssertTrue(air.runsLivePipeline, "…unless the user overrode it")
        air.transcribeWhileRecording = false
        XCTAssertFalse(air.runsLivePipeline, "and the setting being OFF beats the override")
    }

    /// `reset()` is what a recording that skips the live pipeline gets instead
    /// of `start()`: everything per-recording goes, nothing is armed.
    func test_reset_clears_the_previous_recordings_live_state() async {
        await stub.setDefaultCanned([TranscriptSegment(start: 0, end: 1, text: Self.firstMeetingLine)])
        transcriber.start(language: "en")
        transcriber.ingest(ArraySlice(Array(repeating: Float(0.3), count: 32_000)))
        await transcriber.transcribeNow()
        transcriber.speakerNames["SPEAKER_00"] = "Dana"
        XCTAssertFalse(transcriber.segments.isEmpty, "precondition")

        transcriber.reset()

        XCTAssertTrue(transcriber.segments.isEmpty)
        XCTAssertTrue(transcriber.fullText.isEmpty)
        XCTAssertTrue(transcriber.speakerNames.isEmpty)
        XCTAssertFalse(transcriber.hasUserDeletedSegments)
        // Nothing is armed: a drain after reset has no buffered audio to run.
        let callsBefore = await stub.transcribeCalls.count
        await transcriber.transcribeNow()
        let callsAfter = await stub.transcribeCalls.count
        XCTAssertEqual(callsAfter, callsBefore, "reset must drop the buffered audio, not transcribe it")
        XCTAssertTrue(transcriber.segments.isEmpty)
    }

    // MARK: - Decided once per recording

    func test_the_controller_decides_at_record_start_and_keeps_it_for_the_recording() async throws {
        liveAISettings.transcribeWhileRecording = false
        try await startFakeRecording(named: "LiveOff")
        XCTAssertFalse(controller.recordingRunsLivePipeline)

        // Flipping it mid-call must not swap the pipeline or the recording
        // view under the user — it applies from the next recording.
        liveAISettings.transcribeWhileRecording = true
        XCTAssertFalse(controller.recordingRunsLivePipeline,
                       "a mid-recording toggle must not change the recording in progress")
        await controller.stopRecording()
        await controller.awaitFinalizeTails()
        await service.waitForIdle()

        try await startFakeRecording(named: "LiveOn")
        XCTAssertTrue(controller.recordingRunsLivePipeline,
                      "the next recording picks up the new setting")
        await controller.stopRecording()
        await controller.awaitFinalizeTails()
        await service.waitForIdle()
    }

    // MARK: - No leak across recordings

    /// A live recording, then a recording with live transcription switched
    /// off. The second one must be batch-transcribed into its OWN transcript.
    ///
    /// Before `LiveTranscriber.reset()` existed, the live-off recording read
    /// the first meeting's `segments` at Stop (nothing cleared them), saved
    /// them as its own transcript, and — auto-segment being on — marked them
    /// final, so the batch pass never ran. Every assertion below fails on
    /// that code.
    func test_a_live_off_recording_never_inherits_the_previous_live_transcript() async throws {
        // Recording 1: live, with one line of live transcript.
        try await startFakeRecording(named: "FirstMeeting")
        XCTAssertTrue(controller.recordingRunsLivePipeline, "precondition: recording 1 runs live")
        await stub.setDefaultCanned([TranscriptSegment(start: 0, end: 1, text: Self.firstMeetingLine)])
        transcriber.start(language: "en")
        transcriber.ingest(ArraySlice(Array(repeating: Float(0.3), count: 32_000)))
        await transcriber.transcribeNow()
        XCTAssertEqual(transcriber.segments.map(\.text), [Self.firstMeetingLine],
                       "precondition: recording 1 has a live transcript")
        await controller.stopRecording()
        await controller.awaitFinalizeTails()
        await service.waitForIdle()
        XCTAssertEqual(store.recordings.count, 1)

        // Recording 2: live transcription switched off. Nothing feeds the
        // live transcriber, exactly as in the app.
        liveAISettings.transcribeWhileRecording = false
        await stub.setDefaultCanned([TranscriptSegment(start: 0, end: 1, text: Self.secondMeetingLine)])
        let secondURL = try await startFakeRecording(named: "SecondMeeting")
        XCTAssertFalse(controller.recordingRunsLivePipeline)
        XCTAssertTrue(transcriber.segments.isEmpty,
                      "record start must clear the previous recording's live transcript")
        await controller.stopRecording()
        await controller.awaitFinalizeTails()
        await service.waitForIdle()

        let second = try XCTUnwrap(store.recordings.first {
            $0.audioFileName == secondURL.lastPathComponent
        })
        XCTAssertEqual(second.status, .completed)
        XCTAssertFalse(second.fullText.contains(Self.firstMeetingLine),
                       "the live-off recording was saved with the PREVIOUS meeting's transcript")
        XCTAssertEqual(second.fullText, Self.secondMeetingLine,
                       "the live-off recording must be transcribed by the batch pass, from its own audio")
    }

    // MARK: - Helpers

    @discardableResult
    private func startFakeRecording(named name: String) async throws -> URL {
        let url = store.freshAudioURL(suggestedName: name)
        try TestSupport.writeStereo48kSineWav(at: url, durationSeconds: 0.6)
        await controller.startFakeRecordingForTesting(outputURL: url)
        XCTAssertTrue(controller.isRecording, "precondition: the fake recording started")
        return url
    }
}
