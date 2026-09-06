import XCTest
import TranscriptionCore
import MilaKit
@testable import Mila

/// Integration tests for the file-import + transcribe pipeline that runs when
/// the user clicks "Open Files" or drops an audio file onto the app.
///
/// We can't easily exercise live mic / system-audio capture in a unit test
/// (no permissions in CI, no real audio source), but the exact same final
/// path — store add + service.enqueue — is shared with `stopRecording`,
/// so this gives us strong coverage of the wiring change.
@MainActor
final class QuickActionsControllerTests: XCTestCase {

    private var tempRoot: URL!
    private var store: RecordingStore!
    private var manager: ModelManager!
    private var stub: StubWhisperEngine!
    private var service: TranscriptionService!
    private var session: RecordingSession!
    private var languageSettings: RecordingLanguageSettings!
    private var controller: QuickActionsController!
    private var languageDefaults: UserDefaults!
    private let languageSuite = "QuickActionsControllerTests.language"

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "QuickActionsControllerTests")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        store = RecordingStore(rootDirectory: tempRoot)
        manager = TestSupport.isolatedModelManager(
            modelsDirectory: tempRoot.appendingPathComponent("Models"),
            label: "QuickActionsControllerTests")
        try TestSupport.installFakeModel(into: manager)

        stub = StubWhisperEngine()
        service = TranscriptionService(store: store, modelManager: manager, diarizationSettings: DiarizationSettings(defaults: .init(suiteName: "QuickActionsControllerTests.diarization")!), remoteSettings: TestSupport.isolatedRemoteSettings(label: "QuickActionsControllerTests"), engine: stub)
        session = RecordingSession()
        UserDefaults().removePersistentDomain(forName: languageSuite)
        languageDefaults = UserDefaults(suiteName: languageSuite)
        languageSettings = RecordingLanguageSettings(defaults: languageDefaults)
        controller = QuickActionsController(session: session,
                                            store: store,
                                            transcription: service,
                                            languageSettings: languageSettings,
                                            postRecording: PostRecordingCoordinator(
                                                store: store,
                                                transcription: service,
                                                llm: LLMSettings(defaults: UserDefaults(suiteName: "QuickActionsControllerTests.llm")!)))
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        languageDefaults?.removePersistentDomain(forName: languageSuite)
        try await super.tearDown()
    }

    // MARK: - Pause / resume

    /// Pause and resume drive the session state through the controller.
    /// Uses the fake-start seam so no real mic/engine is needed on CI.
    func test_pause_and_resume_toggle_session_state() async {
        let url = store.freshAudioURL(suggestedName: "PauseTest")
        await controller.startFakeRecordingForTesting(outputURL: url)
        XCTAssertTrue(controller.isRecording)
        XCTAssertFalse(controller.isPaused)

        await controller.pauseRecording()
        XCTAssertTrue(controller.isPaused)
        XCTAssertTrue(session.state == .paused)

        // Double-pause is a no-op — stays paused.
        await controller.pauseRecording()
        XCTAssertTrue(session.state == .paused)

        // togglePause resumes.
        await controller.togglePause()
        XCTAssertFalse(controller.isPaused)
        XCTAssertTrue(session.state == .recording)

        _ = await session.stop()
    }

    /// Pause/resume are guarded no-ops when nothing is recording, so a
    /// stray keyboard shortcut / menu action can't corrupt session state.
    func test_pause_is_noop_when_not_recording() async {
        XCTAssertFalse(controller.isRecording)
        await controller.pauseRecording()
        XCTAssertFalse(controller.isPaused)
        XCTAssertTrue(session.state == .idle)
        controller.resumeRecording()
        XCTAssertTrue(session.state == .idle)
    }

    /// Pause is refused while the previous recording is finalizing. The
    /// finalize window tears the live pipeline down; letting a Pause land in
    /// it would move the session out from under `stopRecording`.
    func test_pause_is_refused_while_finalizing() async {
        let url = store.freshAudioURL(suggestedName: "PauseFinalizing")
        await controller.startFakeRecordingForTesting(outputURL: url)
        controller.isFinalizingRecording = true
        await controller.pauseRecording()
        XCTAssertFalse(controller.isPaused,
                       "pause must not fire while stopRecording owns the lifecycle")
        XCTAssertTrue(session.state == .recording)
        controller.isFinalizingRecording = false
        _ = await session.stop()
    }

    // MARK: - Pause and the short-capture heuristic

    /// `stopRecording` warns when the audio on disk is far shorter than the
    /// wall clock — capture died mid-session. A paused span shortens the WAV
    /// on purpose, so the warning must not fire for it. This holds only
    /// because `session.elapsed` subtracts paused time: the wall clock handed
    /// to the heuristic is recorded time, not door-to-door time.
    func test_paused_span_does_not_trip_the_short_capture_warning() {
        // 20 minutes of recording with 10 of them paused: the WAV is 10
        // minutes and `elapsed` is 10 minutes. They agree.
        XCTAssertFalse(QuickActionsController.capturedAudioFellShort(
            source: .meeting, wallClock: 600, captured: 600))
        // The regression this guards: if `elapsed` ever counted paused time
        // again, the same recording would look like it lost half its audio.
        XCTAssertTrue(QuickActionsController.capturedAudioFellShort(
            source: .meeting, wallClock: 1200, captured: 600),
            "a 600s file against a 1200s clock IS a real short capture — the point is that a pause must not produce this shape")
    }

    func test_nextRecordingFolder_defaults_to_all_transcriptions() {
        let fresh = QuickActionsController(
            session: RecordingSession(),
            store: store,
            transcription: service,
            languageSettings: languageSettings,
            postRecording: PostRecordingCoordinator(
                store: store,
                transcription: service,
                llm: LLMSettings(defaults: UserDefaults(suiteName: "QuickActionsControllerTests.llm2")!)))
        XCTAssertNil(fresh.nextRecordingFolder,
                     "next-recording folder must default to All Transcriptions, not a persisted folder")
    }

    /// A folder chosen for one recording is one-shot: stop must not leave
    /// it selected for the next recording in the same launch.
    func test_stopRecording_clears_nextRecordingFolder() async throws {
        try FileManager.default.createDirectory(at: store.recordingsDirectory,
                                                withIntermediateDirectories: true)
        let url = store.freshAudioURL(suggestedName: "FolderClear")
        try TestSupport.writeStereo48kSineWav(at: url, durationSeconds: 0.4)
        await controller.startFakeRecordingForTesting(outputURL: url)
        store.createFolder("Work")
        controller.nextRecordingFolder = "Work"
        controller.nextRecordingTitle = "Weekly Sync"

        await controller.stopRecording()
        await controller.awaitFinalizeTails()

        XCTAssertNil(controller.nextRecordingFolder,
                     "nextRecordingFolder must reset after save")
        XCTAssertEqual(controller.nextRecordingTitle, "",
                       "nextRecordingTitle must reset after save")
        let stored = try XCTUnwrap(savedRecording(for: url))
        XCTAssertEqual(stored.folder, "Work")
        XCTAssertEqual(stored.title, "Weekly Sync")
    }

    /// `session.stop()` returning nil never reaches the successful-path
    /// clear, so title/folder would otherwise stick for the next recording.
    func test_failed_stop_clears_nextRecording_title_and_folder() async {
        controller.nextRecordingFolder = "Work"
        controller.nextRecordingTitle = "Weekly Sync"
        XCTAssertFalse(controller.isRecording)

        await controller.stopRecording()

        XCTAssertNil(controller.nextRecordingFolder)
        XCTAssertEqual(controller.nextRecordingTitle, "")
        XCTAssertTrue(store.recordings.isEmpty)
    }

    /// A folder name that isn't already in the store list still gets
    /// registered via assign (new folder / case-insensitive match).
    func test_stopRecording_registers_a_brand_new_folder() async throws {
        try FileManager.default.createDirectory(at: store.recordingsDirectory,
                                                withIntermediateDirectories: true)
        let url = store.freshAudioURL(suggestedName: "NewFolder")
        try TestSupport.writeStereo48kSineWav(at: url, durationSeconds: 0.4)
        await controller.startFakeRecordingForTesting(outputURL: url)
        controller.nextRecordingFolder = "Brand New"

        await controller.stopRecording()
        await controller.awaitFinalizeTails()

        XCTAssertTrue(store.folders.contains("Brand New"))
        let stored = try XCTUnwrap(savedRecording(for: url))
        XCTAssertEqual(stored.folder, "Brand New")
    }

    /// A meeting name typed before recording survives the stop: the rename
    /// sheet's background auto-title job must not hand it to the LLM and
    /// write the suggestion back over it.
    func test_stopRecording_does_not_auto_title_a_user_named_recording() async throws {
        let suite = UserDefaults(suiteName: "QuickActionsControllerTests.autoTitle")!
        suite.removePersistentDomain(forName: "QuickActionsControllerTests.autoTitle")
        let llm = LLMSettings(defaults: suite,
                              apiKeyKeychainKey: "QuickActionsControllerTests.autoTitle")
        llm.tool = .claude
        llm.nameGenerationEnabled = true

        var callCount = 0
        let coordinator = PostRecordingCoordinator(
            store: store, transcription: service, llm: llm,
            runLLM: { _, _, _, _, _, _, _, _, _, _, _, _, _, _ in
                callCount += 1
                return "An LLM Title"
            })
        let named = QuickActionsController(session: session,
                                           store: store,
                                           transcription: service,
                                           languageSettings: languageSettings,
                                           postRecording: coordinator)

        try FileManager.default.createDirectory(at: store.recordingsDirectory,
                                                withIntermediateDirectories: true)
        let url = store.freshAudioURL(suggestedName: "UserNamed")
        try TestSupport.writeStereo48kSineWav(at: url, durationSeconds: 0.4)
        await named.startFakeRecordingForTesting(outputURL: url)
        named.nextRecordingTitle = "Weekly Sync"

        await named.stopRecording()
        await named.awaitFinalizeTails()
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(callCount, 0, "the auto-title CLI must not run for a user-named recording")
        let stored = try XCTUnwrap(savedRecording(for: url))
        XCTAssertEqual(stored.title, "Weekly Sync")
    }

    // MARK: - Resolved recording title (meeting name override)

    /// An empty or whitespace-only meeting name falls back to the
    /// auto-generated date-stamped default title.
    func test_resolvedRecordingTitle_falls_back_to_default_when_empty() {
        let def = "Recording · Jul 20, 2026"
        XCTAssertEqual(QuickActionsController.resolvedRecordingTitle(userProvided: "", defaultTitle: def), def)
        XCTAssertEqual(QuickActionsController.resolvedRecordingTitle(userProvided: "   \n\t", defaultTitle: def), def)
    }

    /// A non-empty meeting name wins over the default and is trimmed of
    /// surrounding whitespace.
    func test_resolvedRecordingTitle_prefers_trimmed_user_title() {
        let def = "Recording · Jul 20, 2026"
        XCTAssertEqual(QuickActionsController.resolvedRecordingTitle(userProvided: "Weekly Sync", defaultTitle: def),
                       "Weekly Sync")
        XCTAssertEqual(QuickActionsController.resolvedRecordingTitle(userProvided: "  Weekly Sync  ", defaultTitle: def),
                       "Weekly Sync")
    }

    // MARK: - Negative controls for the meeting name / folder destination

    /// Find the recording `stopRecording` just saved for `audioURL`.
    ///
    /// Matches on the file STEM, not the full name: `stopRecording`'s tail
    /// enqueues the row for batch transcription, and completion can hand it to
    /// `RecordingStore.compressRecordingAudio`, which rewrites
    /// `audioFileName` from `<stem>.wav` to `<stem>.m4a`. Matching the whole
    /// name would make these tests race that transcode.
    private func savedRecording(for audioURL: URL) -> Recording? {
        let stem = (audioURL.lastPathComponent as NSString).deletingPathExtension
        return store.recordings.first {
            ($0.audioFileName as NSString).deletingPathExtension == stem
        }
    }

    /// NEGATIVE CONTROL — a meeting name is user-typed text, and titles are
    /// what `RecordingStore.freshAudioURL(suggestedName:)` turns into a path
    /// component elsewhere in the app (`FileTranscriber` sanitizes a "/" out
    /// of an imported file's stem for exactly that reason). On this path the
    /// audio file is created at record START, before any name exists, so the
    /// name must never reach a filesystem path at all.
    ///
    /// Pinning it here because "use the meeting name for the filename" is an
    /// obvious-looking follow-up: `freshAudioURL` appends its argument as a
    /// path component with no sanitizing of its own, so wiring the name in
    /// would let "../../x" write outside the recordings directory. The title
    /// itself is deliberately kept verbatim — the user reading their own
    /// meeting name on their own screen is not a leak, and mangling it would
    /// be the wrong fix.
    func test_meeting_name_with_path_separators_cannot_escape_the_recordings_directory() async throws {
        try FileManager.default.createDirectory(at: store.recordingsDirectory,
                                                withIntermediateDirectories: true)
        let url = store.freshAudioURL(suggestedName: "PathEscape")
        try TestSupport.writeStereo48kSineWav(at: url, durationSeconds: 0.4)
        await controller.startFakeRecordingForTesting(outputURL: url)
        controller.nextRecordingTitle = "../../../etc/passwd: Q3 board call"

        await controller.stopRecording()
        await controller.awaitFinalizeTails()

        let stored = try XCTUnwrap(savedRecording(for: url))
        XCTAssertEqual(stored.title, "../../../etc/passwd: Q3 board call",
                       "the title is display text and must survive verbatim — sanitizing it would be the wrong fix")
        XCTAssertEqual((stored.audioFileName as NSString).deletingPathExtension,
                       (url.lastPathComponent as NSString).deletingPathExtension,
                       "the audio file is named at record start; the meeting name must not rename it")
        for name in [stored.audioFileName, stored.transcriptFileName,
                     stored.summaryFileName, stored.subtitleFileName] {
            XCTAssertFalse(name.contains("/"),
                           "\(name) is used as a single path component — a separator in it escapes the recordings directory")
            XCTAssertFalse(name.contains(".."), "\(name) can traverse out of the recordings directory")
        }
        // The real invariant: every sidecar the store resolves for this
        // recording still sits DIRECTLY inside the recordings directory.
        // `standardizedFileURL` collapses any ".." on the way, which is what
        // would expose an escape; symlinks are deliberately not resolved, so
        // both sides stay the same string root (`/var` vs `/private/var` for a
        // temp dir would otherwise differ for a sidecar that isn't on disk).
        let expectedParent = store.recordingsDirectory.standardizedFileURL.path
        for resolved in [store.transcriptURL(for: stored),
                         store.summaryURL(for: stored),
                         store.subtitleURL(for: stored)] {
            XCTAssertEqual((resolved.standardizedFileURL.path as NSString).deletingLastPathComponent,
                           expectedParent,
                           "\(resolved.lastPathComponent) resolved outside the recordings directory")
        }
    }

    /// NEGATIVE CONTROL — the folder pick is one-shot state held from before
    /// the recording started, so the user can delete that folder in the
    /// sidebar mid-recording. The recording must still be saved (never
    /// silently dropped), and it must not be left tagged with a folder that
    /// has no row in `store.folders` — that combination is reachable from
    /// `store.folders` alone, which is what the sidebar is built from.
    ///
    /// This is the test that justifies the `store.assign` call in
    /// `stopRecording`: `Recording(folder:)` already persists the name, so the
    /// `assign` looks redundant and is a tempting deletion. Remove it and this
    /// assertion fails — the row is filed under "Work" while `store.folders`
    /// is empty.
    func test_folder_deleted_mid_recording_still_saves_and_stays_reachable() async throws {
        try FileManager.default.createDirectory(at: store.recordingsDirectory,
                                                withIntermediateDirectories: true)
        let url = store.freshAudioURL(suggestedName: "FolderVanished")
        try TestSupport.writeStereo48kSineWav(at: url, durationSeconds: 0.4)
        store.createFolder("Work")
        await controller.startFakeRecordingForTesting(outputURL: url)
        controller.nextRecordingFolder = "Work"

        // The user deletes the folder while the recording is still running.
        store.deleteFolder("Work")
        XCTAssertTrue(store.folders.isEmpty)

        await controller.stopRecording()
        await controller.awaitFinalizeTails()

        let stored = try XCTUnwrap(savedRecording(for: url),
                                   "a vanished destination folder must not cost the user the recording")
        if let folder = stored.folder {
            XCTAssertTrue(store.folders.contains(folder),
                          "recording filed under \"\(folder)\" but that folder has no row in store.folders — unreachable from the sidebar")
            XCTAssertEqual(store.recordings(inFolder: folder).map(\.id), [stored.id])
        }
    }

    /// NEGATIVE CONTROL for the MCP contract. `Recording.folder` is a metadata
    /// label inside `recordings.json`, NOT a directory — nothing about a folder
    /// choice moves the audio or the `.txt` sidecar out of
    /// `recordingsDirectory`, which is the single location
    /// `store-location.json` points a separate process at.
    ///
    /// So a recording filed at record time has to stay fully resolvable
    /// through `MilaStoreReader` — the same reader `mila-mcp` uses. If a
    /// future change ever made the destination a real folder on disk, this
    /// fails: the reader would resolve `recordingsDirectory/<file>` and find
    /// nothing.
    func test_a_chosen_folder_and_meeting_name_stay_resolvable_to_an_external_reader() async throws {
        try FileManager.default.createDirectory(at: store.recordingsDirectory,
                                                withIntermediateDirectories: true)
        let url = store.freshAudioURL(suggestedName: "ExternalReader")
        try TestSupport.writeStereo48kSineWav(at: url, durationSeconds: 0.4)
        store.createFolder("Work")
        await controller.startFakeRecordingForTesting(outputURL: url)
        controller.nextRecordingFolder = "Work"
        controller.nextRecordingTitle = "Weekly Sync"

        await controller.stopRecording()
        await controller.awaitFinalizeTails()

        let stored = try XCTUnwrap(savedRecording(for: url))
        let reader = MilaStoreReader(recordingsDirectory: store.recordingsDirectory,
                                     storeFileURL: store.storeURL)

        let byID = try XCTUnwrap(reader.recording(id: stored.id),
                                 "mila-mcp could not resolve a recording filed at record time")
        XCTAssertEqual(byID.title, "Weekly Sync")
        XCTAssertEqual(byID.folder, "Work")
        XCTAssertFalse(byID.audioFileName.contains("/"),
                       "audioFileName must stay a single component relative to recordingsDirectory — the reader has no other root")
        XCTAssertTrue(FileManager.default.fileExists(
                        atPath: store.recordingsDirectory
                            .appendingPathComponent(byID.audioFileName).path),
                      "the reader resolves recordingsDirectory/<audioFileName>; a real per-recording folder would break that")

        let listed = try reader.listRecordings(filter: .init(folder: "Work"))
        XCTAssertEqual(listed.map(\.id), [stored.id],
                       "list_recordings(folder:) must see a folder chosen at record time")
    }

    // MARK: - File import → enqueue → transcribe

    func test_transcribe_file_adds_recording_and_kicks_off_transcription() async throws {
        let sourceURL = tempRoot.appendingPathComponent("imported.wav")
        try TestSupport.writeStereo48kSineWav(at: sourceURL, durationSeconds: 0.5)
        await stub.setDefaultCanned([
            TranscriptSegment(start: 0, end: 0.5, text: "imported text")
        ])

        let beforeCount = store.recordings.count
        await controller.transcribeFile(sourceURL)
        await service.waitForIdle()

        XCTAssertEqual(store.recordings.count, beforeCount + 1)
        let imported = try XCTUnwrap(store.recordings.first { $0.title == "imported" })
        XCTAssertEqual(imported.status, .completed)
        XCTAssertEqual(imported.fullText, "imported text")
        XCTAssertEqual(controller.activeJob, .none)
    }

    /// REGRESSION: Importing two files in quick succession used to hold the
    /// second one in `await transcription.transcribe`, blocking until the
    /// first finished and never showing the second as queued. With the new
    /// `enqueue` path, both should be visible in the queue immediately.
    func test_back_to_back_file_imports_both_complete_in_order() async throws {
        let first = tempRoot.appendingPathComponent("first.wav")
        let second = tempRoot.appendingPathComponent("second.wav")
        try TestSupport.writeStereo48kSineWav(at: first, durationSeconds: 0.4)
        try TestSupport.writeStereo48kSineWav(at: second, durationSeconds: 0.4)

        await stub.setDefaultDelay(0.1)
        await stub.setCannedQueue([
            [TranscriptSegment(start: 0, end: 1, text: "first transcript")],
            [TranscriptSegment(start: 0, end: 1, text: "second transcript")]
        ])

        await controller.transcribeFile(first)
        await controller.transcribeFile(second)
        await service.waitForIdle()

        let firstStored = try XCTUnwrap(store.recordings.first { $0.title == "first" })
        let secondStored = try XCTUnwrap(store.recordings.first { $0.title == "second" })

        XCTAssertEqual(firstStored.fullText, "first transcript")
        XCTAssertEqual(secondStored.fullText, "second transcript")

        let maxConcurrent = await stub.maxConcurrentInFlight
        XCTAssertEqual(maxConcurrent, 1)
    }

    // MARK: - State machine

    func test_active_job_is_none_initially() {
        XCTAssertEqual(controller.activeJob, .none)
        XCTAssertFalse(controller.isRecording)
    }

    func test_failed_file_import_clears_active_job() async {
        let bogus = tempRoot.appendingPathComponent("does-not-exist.wav")
        await controller.transcribeFile(bogus)
        XCTAssertEqual(controller.activeJob, .none)
        XCTAssertNotNil(service.lastError)
    }

    /// File imports must adopt whatever language is currently selected in
    /// the toolbar dropdown — otherwise the user picks "English" but their
    /// dragged-in WAV gets routed to the Hebrew model.
    func test_imported_file_uses_language_from_settings() async throws {
        try TestSupport.installFakeModel(into: manager, model: .openaiTurbo)
        let source = tempRoot.appendingPathComponent("english-source.wav")
        try TestSupport.writeStereo48kSineWav(at: source, durationSeconds: 0.4)

        languageSettings.current = .english
        await stub.setDefaultCanned([
            TranscriptSegment(start: 0, end: 1, text: "english import")
        ])

        await controller.transcribeFile(source)
        await service.waitForIdle()

        let imported = try XCTUnwrap(store.recordings.first { $0.title == "english-source" })
        XCTAssertEqual(imported.language, "en",
                       "Imported recording must reflect the user-selected language")
        let loaded = await stub.loadedModel
        XCTAssertEqual(loaded?.lastPathComponent,
                       manager.url(for: .openaiTurbo).lastPathComponent,
                       "English-tagged recording must be transcribed with the OpenAI model")
    }

    // MARK: - Silence watch

    func test_silence_watch_returns_true_when_level_never_crosses_threshold() async {
        let result = await QuickActionsController.silenceWatch(
            totalSeconds: 0.2,
            threshold: 0.5,
            pollIntervalSeconds: 0.02,
            levelProvider: { 0.0 }
        )
        XCTAssertTrue(result, "Constant-zero level over the full window should report silent")
    }

    func test_silence_watch_returns_false_as_soon_as_level_crosses_threshold() async {
        // Counter increases each poll; level crosses threshold on poll #3.
        let counter = SilenceCounter()
        let result = await QuickActionsController.silenceWatch(
            totalSeconds: 0.5,
            threshold: 0.5,
            pollIntervalSeconds: 0.02,
            levelProvider: { @MainActor in
                let i = counter.tick()
                return i >= 3 ? 0.9 : 0.1
            }
        )
        XCTAssertFalse(result,
                       "A level reading at or above threshold should break out without warning")
    }

    func test_silence_watch_returns_false_when_threshold_is_met_exactly() async {
        let result = await QuickActionsController.silenceWatch(
            totalSeconds: 0.1,
            threshold: 0.05,
            pollIntervalSeconds: 0.02,
            levelProvider: { 0.05 }
        )
        XCTAssertFalse(result, "level >= threshold (not strictly greater) must satisfy")
    }

    func test_controller_starts_with_warning_flag_false() {
        XCTAssertFalse(controller.noSoundWarningShown)
        XCTAssertEqual(controller.silenceWatchSeconds, 10)
        XCTAssertGreaterThan(controller.silenceWatchLevelThreshold, 0)
    }

    /// Explicit reproduction of the user-reported bug: enqueue, then
    /// "make a new recording" while the first is still transcribing — the
    /// second must end up with its own transcript, not stay stuck on the
    /// previous one.
    /// MainActor-isolated counter for the silence-watch test — the
    /// levelProvider closure runs on the main actor so the counter has to
    /// be reachable from there. Plain `var` on the test would fire an
    /// isolation warning under strict concurrency.
    @MainActor
    private final class SilenceCounter {
        private var value = 0
        func tick() -> Int { value += 1; return value }
    }

    /// REGRESSION (PR #32 follow-up — Bugbot Finding #1, "inline drain
    /// still races a new recording"):
    ///
    /// `stopRecording`'s inline drain holds `isFinalizingRecording = true`
    /// across multiple `await`s. Without a re-entry guard, a Record-button
    /// tap landing on @MainActor between those awaits would call
    /// `startRecording` → wipe the live segments and apply an empty
    /// snapshot to the OLD recording's id. The guard makes `toggleRecord`
    /// a no-op while finalize is in flight; this test pins that behavior
    /// by setting the flag manually and asserting nothing observable
    /// happens.
    func test_toggleRecord_no_op_while_finalizing() async {
        XCTAssertEqual(controller.activeJob, .none)
        controller.isFinalizingRecording = true
        await controller.toggleRecord(withSystemAudio: false)
        XCTAssertEqual(controller.activeJob, .none,
                       "toggleRecord must not start a recording while finalize is in flight")
        XCTAssertFalse(controller.isRecording)
        controller.isFinalizingRecording = false
    }

    /// Same guard, exercised via the back-compat `toggleVoiceMemo` shim
    /// the menu command + UI tests use. Both entry points must honor
    /// the finalize gate.
    func test_toggleVoiceMemo_no_op_while_finalizing() async {
        XCTAssertEqual(controller.activeJob, .none)
        controller.isFinalizingRecording = true
        await controller.toggleVoiceMemo()
        XCTAssertEqual(controller.activeJob, .none)
        XCTAssertFalse(controller.isRecording)
        controller.isFinalizingRecording = false
    }

    /// REGRESSION (user report: "couldn't start a new recording until the
    /// previous one finished processing; the Record button said
    /// 'Finalizing'").
    ///
    /// `finalizeTail` is the live-singleton-FREE heavy tail that
    /// `stopRecording` now spins off into a background, id-keyed task AFTER
    /// it drains the live pipeline and clears `isFinalizingRecording`. For
    /// the non-authoritative (chunk / empty-segments) path it must enqueue
    /// the recording for batch transcription on the already-serialized
    /// background service — never holding the record button. This pins that
    /// the tail completes the recording in the background without ever
    /// touching the finalize flag.
    func test_finalize_tail_enqueues_batch_transcription_in_background() async throws {
        // The batch worker resolves audio via `store.audioURL(for:)`, which
        // lives under the store's recordings directory — write the WAV there
        // (not the bare temp root) so the tail can actually load it.
        try FileManager.default.createDirectory(at: store.recordingsDirectory,
                                                withIntermediateDirectories: true)
        let url = store.recordingsDirectory.appendingPathComponent("finalize-tail.wav")
        try TestSupport.writeStereo48kSineWav(at: url, durationSeconds: 0.6)
        await stub.setDefaultCanned([
            TranscriptSegment(start: 0, end: 0.6, text: "finalized in background")
        ])

        // A freshly-stopped recording that produced no authoritative live
        // segments (chunk mode / empty): status .pending, awaiting batch.
        let recording = Recording(
            title: "tail-recording",
            duration: 0.6,
            source: .microphone,
            audioFileName: url.lastPathComponent,
            status: .pending,
            language: languageSettings.current.rawValue
        )
        store.add(recording)

        // The button must already be free by the time the tail runs —
        // stopRecording clears the flag before calling finalizeTail.
        controller.isFinalizingRecording = false
        controller.finalizeTail(for: recording, liveTranscriptIsAuthoritative: false)

        // The tail enqueues onto the background service; draining it
        // produces the completed transcript without the finalize flag ever
        // latching.
        await controller.awaitFinalizeTails()
        await service.waitForIdle()

        let stored = try XCTUnwrap(store.recordings.first { $0.id == recording.id })
        XCTAssertEqual(stored.status, .completed)
        XCTAssertEqual(stored.fullText, "finalized in background")
        XCTAssertFalse(controller.isFinalizingRecording,
                       "the heavy finalize tail must run with the record button free")
    }

    /// island-io/mila#86: `stopRecording` no longer blocks the Record button
    /// on the final Live-AI summary tick. Instead, for an authoritative
    /// Live-AI recording, `finalizeTail` regenerates the summary from the FULL
    /// transcript in the BACKGROUND — so a rolling summary that was a
    /// throttle-interval stale at stop time (missing the tail of the
    /// conversation) gets refreshed with the finalize flag already clear.
    func test_finalize_tail_regenerates_live_ai_summary_in_background() async throws {
        // Live AI on + claude configured, on isolated suites.
        let llmSuite = "QuickActionsControllerTests.llm.regen"
        let liveSuite = "QuickActionsControllerTests.live.regen"
        UserDefaults().removePersistentDomain(forName: llmSuite)
        UserDefaults().removePersistentDomain(forName: liveSuite)
        let llm = LLMSettings(defaults: UserDefaults(suiteName: llmSuite)!)
        llm.tool = .claude
        let liveAI = LiveAISettings(defaults: UserDefaults(suiteName: liveSuite)!)
        liveAI.enabled = true
        liveAI.model = ""
        defer {
            UserDefaults().removePersistentDomain(forName: llmSuite)
            UserDefaults().removePersistentDomain(forName: liveSuite)
        }

        // Stubbed summarizer standing in for the real full-transcript claude
        // call — echoes the transcript so the assertion can prove the summary
        // was regenerated from the WHOLE transcript, not the stale rolling one.
        let summarizer = RecordingSummarizer(store: store,
                                             llmSettings: llm,
                                             liveAISettings: liveAI,
                                             runLLM: { _, _, transcript, _, _, _, _, _, _, _, _ in
            "COMPLETE: \(transcript)"
        })
        controller.llmSettings = llm
        controller.liveAISettings = liveAI
        controller.summarizer = summarizer

        // A freshly-stopped Live-AI recording: authoritative live segments
        // covering the whole conversation, but a STALE rolling summary.
        try FileManager.default.createDirectory(at: store.recordingsDirectory,
                                                withIntermediateDirectories: true)
        let url = store.recordingsDirectory.appendingPathComponent("regen.wav")
        try TestSupport.writeStereo48kSineWav(at: url, durationSeconds: 0.6)
        var recording = Recording(
            title: "regen-recording",
            duration: 0.6,
            source: .microphone,
            audioFileName: url.lastPathComponent,
            status: .completed,
            language: languageSettings.current.rawValue,
            segments: [TranscriptSegment(start: 0, end: 0.6,
                                         text: "the whole conversation including the tail")],
            fullText: "the whole conversation including the tail"
        )
        recording.summary = "stale rolling summary"
        store.add(recording)

        // The button is already free by the time the tail runs.
        controller.isFinalizingRecording = false
        controller.finalizeTail(for: recording, liveTranscriptIsAuthoritative: true)
        await controller.awaitFinalizeTails()
        await summarizer.awaitInFlight(recording.id)

        let stored = try XCTUnwrap(store.recordings.first { $0.id == recording.id })
        XCTAssertEqual(stored.summary, "COMPLETE: the whole conversation including the tail",
                       "finalizeTail must regenerate the Live-AI summary from the full transcript in the background")
        XCTAssertFalse(controller.isFinalizingRecording,
                       "summary regeneration must run with the record button free")
    }

    // MARK: - Re-diarize gate (skip when the live pass found few speakers)

    /// The offline re-diarize only fixes the online diarizer's
    /// over-segmentation, which only happens when MANY speakers were
    /// minted. At or below the threshold the live labels are kept as-is
    /// (no heavy pyannote subprocess). `0` (no labels) also skips.
    func test_shouldRediarize_skips_at_or_below_threshold() {
        XCTAssertEqual(QuickActionsController.maxLiveSpeakersToSkipRediarize, 3)
        XCTAssertFalse(QuickActionsController.shouldRediarize(liveSpeakerCount: 0),
                       "No live speaker labels at all — nothing to clean up, skip")
        XCTAssertFalse(QuickActionsController.shouldRediarize(liveSpeakerCount: 1))
        XCTAssertFalse(QuickActionsController.shouldRediarize(liveSpeakerCount: 2))
        XCTAssertFalse(QuickActionsController.shouldRediarize(liveSpeakerCount: 3),
                       "Exactly at the threshold must still skip")
    }

    /// Above the threshold the live pass over-segmented (e.g. one narrator
    /// split into 7 speakers) — re-diarize to re-cluster globally.
    func test_shouldRediarize_runs_above_threshold() {
        XCTAssertTrue(QuickActionsController.shouldRediarize(liveSpeakerCount: 4))
        XCTAssertTrue(QuickActionsController.shouldRediarize(liveSpeakerCount: 7))
    }

    // MARK: - Speaker-finalization gate (issue #211)

    /// `willFinalizeSpeakers` is what decides whether a "Send to Claude"
    /// fired the instant the recording stopped has to wait. It must be true
    /// in exactly the case the offline pass actually runs — otherwise either
    /// the send races the pass (too permissive) or every recording pays a
    /// wait it doesn't need (too strict).
    func test_willFinalizeSpeakers_only_when_the_offline_pass_will_run() {
        XCTAssertTrue(QuickActionsController.willFinalizeSpeakers(
            liveTranscriptIsAuthoritative: true,
            liveSpeakerCount: 4,
            diarizationConfigured: true),
                      "Authoritative live transcript, over-segmented, diarization ready — the pass runs, so a send must wait")

        XCTAssertFalse(QuickActionsController.willFinalizeSpeakers(
            liveTranscriptIsAuthoritative: true,
            liveSpeakerCount: 3,
            diarizationConfigured: true),
                       "At the skip threshold the pass never runs — a short recording must pay no wait")

        XCTAssertFalse(QuickActionsController.willFinalizeSpeakers(
            liveTranscriptIsAuthoritative: true,
            liveSpeakerCount: 7,
            diarizationConfigured: false),
                       "Diarization off — nothing re-keys the labels, so nothing changes for that user")

        XCTAssertFalse(QuickActionsController.willFinalizeSpeakers(
            liveTranscriptIsAuthoritative: false,
            liveSpeakerCount: 7,
            diarizationConfigured: true),
                       "The batch path diarizes inside the transcription pass, before the row leaves .pending")
    }

    /// The marker has to be published SYNCHRONOUSLY by `finalizeTail`, not
    /// from inside its detached task: `stopRecording` flips the row to
    /// `.completed` and calls `finalizeTail` in one uninterrupted main-actor
    /// run, so a send can only ever observe "still transcribing" or
    /// "finalizing speakers" — never the gap between them (issue #211).
    ///
    /// This test drives the gate's OFF side end-to-end, which is the side CI
    /// can run: with diarization unconfigured no marker is published, so a
    /// user who has the feature off waits for nothing. (The ON side needs a
    /// pyannote subprocess; `willFinalizeSpeakers` above pins it purely.)
    func test_finalize_tail_publishes_no_speaker_marker_when_diarization_is_off() async throws {
        try FileManager.default.createDirectory(at: store.recordingsDirectory,
                                                withIntermediateDirectories: true)
        let url = store.recordingsDirectory.appendingPathComponent("speaker-marker.wav")
        try TestSupport.writeStereo48kSineWav(at: url, durationSeconds: 0.6)
        let recording = Recording(
            title: "marker-recording",
            duration: 0.6,
            source: .microphone,
            audioFileName: url.lastPathComponent,
            status: .completed,
            language: languageSettings.current.rawValue,
            // Over-segmented enough that `shouldRediarize` alone would say yes.
            segments: [TranscriptSegment(start: 0, end: 1, text: "a", speaker: "SPEAKER_00"),
                       TranscriptSegment(start: 1, end: 2, text: "b", speaker: "SPEAKER_01"),
                       TranscriptSegment(start: 2, end: 3, text: "c", speaker: "SPEAKER_02"),
                       TranscriptSegment(start: 3, end: 4, text: "d", speaker: "SPEAKER_03")],
            fullText: "a b c d"
        )
        store.add(recording)
        XCTAssertFalse(service.isDiarizationConfigured,
                       "Sanity: the test suite runs with diarization unconfigured")

        controller.isFinalizingRecording = false
        controller.finalizeTail(for: recording, liveTranscriptIsAuthoritative: true)

        // Checked BEFORE awaiting the tail — this is the synchronous window.
        XCTAssertFalse(service.isAwaitingSpeakerFinalization(recording.id),
                       "Diarization is off, so nothing will re-key the labels and nothing must wait")

        await controller.awaitFinalizeTails()
        XCTAssertFalse(service.isAwaitingSpeakerFinalization(recording.id),
                       "The marker must not be left set after the tail finishes")
    }

    func test_user_bug_repro_second_recording_after_first_started_transcribing() async throws {
        let first = tempRoot.appendingPathComponent("recording-A.wav")
        let second = tempRoot.appendingPathComponent("recording-B.wav")
        try TestSupport.writeStereo48kSineWav(at: first, durationSeconds: 0.6)
        try TestSupport.writeStereo48kSineWav(at: second, durationSeconds: 0.6)

        await stub.setDefaultDelay(0.4)
        await stub.setCannedQueue([
            [TranscriptSegment(start: 0, end: 1, text: "A says hi")],
            [TranscriptSegment(start: 0, end: 1, text: "B says hello")]
        ])

        // Start the first import (this returns once the recording is added
        // and enqueued — does NOT wait for transcription).
        await controller.transcribeFile(first)

        // While the first is still transcribing, kick off the second.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotNil(service.activeRecordingID)
        await controller.transcribeFile(second)

        // After everything settles, both recordings should have the right text.
        await service.waitForIdle()

        let storedA = try XCTUnwrap(store.recordings.first { $0.title == "recording-A" })
        let storedB = try XCTUnwrap(store.recordings.first { $0.title == "recording-B" })
        XCTAssertEqual(storedA.fullText, "A says hi",
                       "First recording should have its own transcript")
        XCTAssertEqual(storedB.fullText, "B says hello",
                       "Second recording must NOT show the first recording's transcript")
        XCTAssertEqual(storedA.status, .completed)
        XCTAssertEqual(storedB.status, .completed)
    }
}

/// The short-capture policy that turns "capture died 25 seconds into a
/// 26-minute meeting" from a silent failure into a warning the user can act
/// on. Pure inputs, so no recording or audio device is needed.
final class ShortCapturePolicyTests: XCTestCase {

    func test_healthy_recording_does_not_warn() {
        // A little loss at each end is normal: engine bring-up and teardown.
        XCTAssertFalse(QuickActionsController.capturedAudioFellShort(
            source: .meeting, wallClock: 600, captured: 599.4))
        XCTAssertFalse(QuickActionsController.capturedAudioFellShort(
            source: .microphone, wallClock: 120, captured: 119))
    }

    /// The exact shape of the reported bug: 1583.9s on the clock, 24.6s of
    /// audio on disk.
    func test_capture_that_died_mid_session_warns() {
        XCTAssertTrue(QuickActionsController.capturedAudioFellShort(
            source: .meeting, wallClock: 1583.9, captured: 24.6))
    }

    func test_short_recordings_never_warn() {
        // Below the wall-clock floor, bring-up latency dominates and a warning
        // would fire on ordinary quick memos.
        XCTAssertFalse(QuickActionsController.capturedAudioFellShort(
            source: .microphone, wallClock: 6, captured: 1))
        XCTAssertFalse(QuickActionsController.capturedAudioFellShort(
            source: .microphone,
            wallClock: QuickActionsController.shortCaptureMinimumWallClock - 0.1,
            captured: 1))
    }

    /// ScreenCaptureKit only delivers buffers while something is playing, so a
    /// system-audio capture of a mostly-silent app is legitimately far shorter
    /// than the wall clock.
    func test_system_audio_only_is_exempt() {
        XCTAssertFalse(QuickActionsController.capturedAudioFellShort(
            source: .systemAudio, wallClock: 1800, captured: 12))
    }

    /// Zero captured audio has its own, more specific message and log line —
    /// this policy must not double up on it.
    func test_zero_capture_is_left_to_the_empty_mic_path() {
        XCTAssertFalse(QuickActionsController.capturedAudioFellShort(
            source: .microphone, wallClock: 600, captured: 0))
    }

    func test_threshold_boundary() {
        let wall: TimeInterval = 100
        let ratio = QuickActionsController.shortCaptureRatio
        XCTAssertFalse(QuickActionsController.capturedAudioFellShort(
            source: .meeting, wallClock: wall, captured: wall * ratio))
        XCTAssertTrue(QuickActionsController.capturedAudioFellShort(
            source: .meeting, wallClock: wall, captured: wall * ratio - 0.5))
    }
}
