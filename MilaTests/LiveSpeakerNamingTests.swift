import XCTest
import TranscriptionCore
@testable import Mila

/// **Invariant: naming a speaker DURING a recording learns their voice, and
/// learns it exactly once.**
///
/// REGRESSION (island-io/mila#209): it did neither. `LiveAIRecordingView`
/// names a speaker by writing `LiveTranscriber.speakerNames[raw]`, because
/// there is no `Recording` in the store while a recording runs —
/// `QuickActionsController.stopRecording` calls `store.add` *after*
/// `session.stop()`, so `RecordingStore.setSpeakerName(recordingID:)` has no
/// row to resolve and returns without doing anything. The drain then copied
/// that map straight onto the row (`store.add(speakerNames:)`, and again as
/// `updated.speakerNames = …` before `store.update`). By the time
/// `onRecordingFinalized` fired, the row already carried the name, so
/// `setSpeakerName`'s no-change guard returned *before* firing
/// `onSpeakerNamed` — the one hook that persists a voice profile. The label
/// stuck to the transcript, no profile was created, and nothing said so.
///
/// The fix routes those names through `setSpeakerName` at finalization rather
/// than adding a second persistence call at the live site, because "one
/// persistence trigger" is a deliberate invariant: a parallel `updateProfile`
/// alongside it is what caused the double-merge fixed in #204, where every
/// recognised speaker folded in twice and the profile went progressively
/// rigid. So these tests assert the fire *count*, not merely that a profile
/// exists.
///
/// `test_the_pre_fix_shape_learns_nothing` is the negative control: it
/// reconstructs the old sequence from the same real objects and measures the
/// silence.
@MainActor
final class LiveSpeakerNamingTests: XCTestCase {

    private var tempRoot: URL!
    private var suiteNames: [String] = []

    /// What `onSpeakerNamed` was called with, in order. The count is the
    /// point: "exactly once" is what stops the double-merge coming back.
    private struct Fire: Equatable {
        let recordingID: UUID
        let rawID: String
        let name: String
    }
    private var fires: [Fire] = []

    private let aliceStored: [Float] = [1, 0, 0, 0]
    private let aliceSpeaking: [Float] = [0.99, 0.01, 0, 0]
    /// Nothing like Alice — cos(bob, aliceStored) == 0, so a seeded Alice
    /// cannot claim him even at the 0.40 create floor.
    private let bobSpeaking: [Float] = [0, 1, 0, 0]

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "LiveSpeakerNamingTests")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        fires.removeAll()
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        suiteNames.removeAll()
        try await super.tearDown()
    }

    // MARK: - Fixture

    private func makeSettings(enabled: Bool = true) -> VoiceRecognitionSettings {
        let name = "LiveSpeakerNamingTests.\(UUID())"
        suiteNames.append(name)
        let s = VoiceRecognitionSettings(defaults: UserDefaults(suiteName: name)!)
        s.diarizationReady = { true }
        s.isEnabled = enabled
        return s
    }

    private struct World {
        let store: RecordingStore
        let profiles: SpeakerProfileStore
        let snapshots: ObservedVoiceSnapshots
        let diarizer: LiveSpeakerDiarizer
        let assigner: RecognisedSpeakerAssigner
        let settings: VoiceRecognitionSettings
    }

    /// The shipping wiring, assembled from real objects — the same shape
    /// `MilaApp.init` installs, plus a tap on the hook so the tests can count
    /// its fires. `seedAlice` controls whether a stored profile exists to be
    /// auto-recognised; the live-naming tests that do not need one leave the
    /// pool unseeded, which is the ordinary case (a brand-new voice the user
    /// puts a name to).
    private func makeWorld(enabled: Bool = true, seedAlice: Bool = false) -> World {
        let settings = makeSettings(enabled: enabled)
        let profiles = SpeakerProfileStore(directory: tempRoot, settings: settings)
        if seedAlice {
            profiles.updateProfile(name: "Alice", embedding: aliceStored, sampleCount: 40)
        }

        let store = RecordingStore(rootDirectory: tempRoot)
        let snapshots = ObservedVoiceSnapshots()

        // Same wiring MilaApp.init installs, with the fire log wrapped around
        // it. `[weak self]` so the stored closure can't keep the test case
        // alive past tearDown.
        store.onSpeakerNamed = { [weak self] recordingID, rawID, name in
            self?.fires.append(Fire(recordingID: recordingID, rawID: rawID, name: name))
            guard settings.isConfigured else { return }
            guard let observed = snapshots.observation(forSpeaker: rawID,
                                                      in: recordingID) else { return }
            profiles.updateProfile(name: name,
                                   embedding: observed.observedCentroid,
                                   sampleCount: observed.observedCount)
        }

        let diarizer = LiveSpeakerDiarizer()
        diarizer.similarityThreshold = 0.7
        profiles.addDeletionObserver { [weak diarizer] deletion in
            switch deletion {
            case .all: diarizer?.forgetSeededProfiles()
            case .named(let names): diarizer?.forgetSeededProfiles(named: names)
            }
        }
        diarizer.reset()
        diarizer.seedPool(with: profiles.seedEntries())

        let assigner = RecognisedSpeakerAssigner(
            store: store,
            diarizer: diarizer,
            snapshots: snapshots,
            settings: settings,
            profileStillStored: { profiles.profileExists(name: $0) })
        return World(store: store, profiles: profiles, snapshots: snapshots,
                     diarizer: diarizer, assigner: assigner, settings: settings)
    }

    @discardableResult
    private func add(_ title: String, to store: RecordingStore) -> Recording {
        let rec = Recording(title: title, source: .microphone,
                            audioFileName: "\(title).wav")
        store.add(rec)
        return rec
    }

    private func names(_ id: UUID, in store: RecordingStore) -> [String: String] {
        store.recordings.first { $0.id == id }?.speakerNames ?? [:]
    }

    // MARK: - The fix

    /// The bug, from the user's side: someone speaks, the user labels them in
    /// the live pane, the recording stops — and the voice is now stored, so
    /// the next recording recognises them.
    func test_a_name_assigned_during_the_recording_creates_a_voice_profile() {
        let w = makeWorld()
        // A voice nobody has a profile for — the ordinary case for naming.
        XCTAssertEqual(w.diarizer.assign(embedding: bobSpeaking), "SPEAKER_00")
        let meeting = add("Meeting", to: w.store)

        // What the live pane put in `LiveTranscriber.speakerNames`, handed
        // over by `stopRecording` at finalization.
        w.assigner.finish(recording: meeting.id, liveSpeakerNames: ["SPEAKER_00": "Bob"])

        XCTAssertEqual(names(meeting.id, in: w.store)["SPEAKER_00"], "Bob",
                       "the label must still land on the transcript")
        // Bound, not force-unwrapped: `XCTAssertNil` records a failure and
        // carries on, so a force-unwrap here would abort the runner and hide
        // which assertion actually broke.
        let bob = w.profiles.profile(named: "Bob")
        XCTAssertNotNil(bob, "and the voice must now be learned — this is #209")
        XCTAssertEqual(bob?.sampleCount, 1, "one observation, folded in once")
        XCTAssertEqual(bob?.embedding, bobSpeaking)
        XCTAssertEqual(fires, [Fire(recordingID: meeting.id,
                                    rawID: "SPEAKER_00", name: "Bob")],
                       "exactly one persistence trigger, for exactly this speaker")
    }

    /// **Negative control — the pre-fix shape, reconstructed from the same
    /// real objects.** `stopRecording` used to copy `LiveTranscriber.
    /// speakerNames` onto the row before `onRecordingFinalized` ran (twice
    /// over: at `store.add`, then again onto `updated`). That is all it takes:
    /// with the name already there, `setSpeakerName` no-change-guards out and
    /// `onSpeakerNamed` never fires.
    ///
    /// It proves the test above discriminates — the assigner's call alone is
    /// not what makes the profile appear, *not having pre-written the row* is
    /// — and it records what the silence looked like: a correct-looking
    /// transcript label and no voice data at all.
    func test_the_pre_fix_shape_learns_nothing() throws {
        let w = makeWorld()
        XCTAssertEqual(w.diarizer.assign(embedding: bobSpeaking), "SPEAKER_00")
        let meeting = add("Meeting", to: w.store)

        // The removed copy: the drain writing the live map onto the row.
        var preWritten = try XCTUnwrap(w.store.recordings.first { $0.id == meeting.id })
        preWritten.speakerNames = ["SPEAKER_00": "Bob"]
        w.store.update(preWritten)

        w.assigner.finish(recording: meeting.id, liveSpeakerNames: ["SPEAKER_00": "Bob"])

        XCTAssertEqual(names(meeting.id, in: w.store)["SPEAKER_00"], "Bob",
                       "the label looks right, which is why this was easy to miss")
        XCTAssertNil(w.profiles.profile(named: "Bob"),
                     "…but nothing was learned: the no-change guard swallowed the write")
        XCTAssertTrue(fires.isEmpty, "onSpeakerNamed never fired — the whole bug")
    }

    /// Re-running finalization for the same recording — a duplicated stop, a
    /// re-entrant hook — must not fold the same observation in again. This is
    /// the property that routing through `setSpeakerName` buys and that a
    /// parallel `updateProfile` at the live site would destroy (#204).
    func test_running_finalization_twice_folds_the_live_name_in_once() {
        let w = makeWorld()
        XCTAssertEqual(w.diarizer.assign(embedding: bobSpeaking), "SPEAKER_00")
        let meeting = add("Meeting", to: w.store)

        for _ in 0..<3 {
            w.assigner.finish(recording: meeting.id, liveSpeakerNames: ["SPEAKER_00": "Bob"])
        }

        XCTAssertEqual(w.profiles.profile(named: "Bob")?.sampleCount, 1,
                       "one observation, one merge, however many times we finalize")
        XCTAssertEqual(fires.count, 1)
    }

    /// A name the user typed wins over the name the recogniser would have
    /// applied, and the loser does not get a second hook fire. Before the live
    /// names came through this path the auto-name silently clobbered them: the
    /// user labelled SPEAKER_00 "Bob", stop replaced it with the seeded
    /// "Alice", and Alice's profile learned Bob's voice.
    func test_a_live_name_wins_over_the_recognised_profile_name() {
        let w = makeWorld(seedAlice: true)
        // Alice is seeded as SPEAKER_00 and confidently matched, so without
        // the precedence rule the auto-name loop would stamp "Alice" here.
        XCTAssertEqual(w.diarizer.assign(embedding: aliceSpeaking), "SPEAKER_00")
        XCTAssertEqual(w.diarizer.currentProfiles().first?.profileName, "Alice",
                       "precondition: the pool entry carries the seeded name")
        let meeting = add("Meeting", to: w.store)

        // The user disagrees with the recogniser and says so during the call.
        w.assigner.finish(recording: meeting.id, liveSpeakerNames: ["SPEAKER_00": "Bob"])

        XCTAssertEqual(names(meeting.id, in: w.store)["SPEAKER_00"], "Bob",
                       "the user's label must survive finalization")
        XCTAssertEqual(fires.map(\.name), ["Bob"],
                       "one fire, for the user's name — not two, and not Alice's")
        XCTAssertEqual(w.profiles.profile(named: "Alice")?.sampleCount, 40,
                       "Alice must not learn a voice the user says isn't hers")
        XCTAssertEqual(w.profiles.profile(named: "Bob")?.sampleCount, 1)
    }

    /// A speaker the user did NOT name is still auto-named from their stored
    /// profile — the live names must suppress only their own raw ids.
    func test_an_unnamed_speaker_is_still_auto_named() {
        let w = makeWorld(seedAlice: true)
        XCTAssertEqual(w.diarizer.assign(embedding: aliceSpeaking), "SPEAKER_00")
        XCTAssertEqual(w.diarizer.assign(embedding: bobSpeaking), "SPEAKER_01")
        let meeting = add("Meeting", to: w.store)

        w.assigner.finish(recording: meeting.id, liveSpeakerNames: ["SPEAKER_01": "Bob"])

        XCTAssertEqual(names(meeting.id, in: w.store),
                       ["SPEAKER_00": "Alice", "SPEAKER_01": "Bob"])
        XCTAssertEqual(Set(fires.map(\.name)), ["Alice", "Bob"])
        XCTAssertEqual(fires.count, 2, "one fire per speaker, no more")
        XCTAssertEqual(w.profiles.profile(named: "Alice")?.sampleCount, 41)
    }

    /// The label is not voice data. With voice recognition off — the default,
    /// and where most users are — naming a speaker in the live pane must still
    /// label the transcript, while storing nothing and snapshotting nothing.
    ///
    /// Gating the live names on `isConfigured` alongside the snapshot would
    /// have silently dropped every mid-recording label for those users, which
    /// is a worse bug than the one being fixed.
    func test_a_live_name_is_applied_with_voice_recognition_off() {
        let w = makeWorld(enabled: false)
        // Seeding was refused while off, so this speaks into an empty pool.
        _ = w.diarizer.assign(embedding: bobSpeaking)
        let meeting = add("Meeting", to: w.store)

        w.assigner.finish(recording: meeting.id, liveSpeakerNames: ["SPEAKER_00": "Bob"])

        XCTAssertEqual(names(meeting.id, in: w.store)["SPEAKER_00"], "Bob",
                       "naming a speaker keeps working with the feature off")
        XCTAssertTrue(w.profiles.profiles.isEmpty, "and stores no voice data")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: tempRoot.appendingPathComponent("speaker-profiles.json").path),
            "no profiles file may be created for an opted-out user")
        XCTAssertEqual(w.snapshots.heldRecordingCount, 0,
                       "and holds no embeddings in memory either")
    }

    /// A live name for a speaker this recording never observed labels the
    /// transcript and persists nothing — `ObservedVoiceSnapshots` has no
    /// observation for that raw id, so there is no embedding to learn from and
    /// the hook's own guard refuses. Fail-closed, same as a stale id.
    func test_a_live_name_for_an_unobserved_speaker_stores_nothing() {
        let w = makeWorld()
        XCTAssertEqual(w.diarizer.assign(embedding: bobSpeaking), "SPEAKER_00")
        let meeting = add("Meeting", to: w.store)

        // SPEAKER_07 was never minted — a stale label from a re-keyed
        // transcript would look like this.
        w.assigner.finish(recording: meeting.id, liveSpeakerNames: ["SPEAKER_07": "Ghost"])

        XCTAssertEqual(names(meeting.id, in: w.store)["SPEAKER_07"], "Ghost")
        XCTAssertNil(w.profiles.profile(named: "Ghost"))
        XCTAssertEqual(fires.count, 1,
                       "the hook still fires — it is the hook's own snapshot guard that refuses")
    }
}

/// The controller half of island-io/mila#209, driven through the real
/// `QuickActionsController.stopRecording`.
///
/// `LiveSpeakerNamingTests` above pins what the assigner does once it is
/// handed the live names. This pins the part that was actually broken: that
/// `stopRecording` **hands them over** instead of copying them onto the row.
/// The distinction matters because the two failures are independent — an
/// assigner that applies live names perfectly still learns nothing if the
/// drain has already written them, which is precisely the shape
/// `LiveSpeakerNamingTests.test_the_pre_fix_shape_learns_nothing` measures.
/// Re-adding either copy (`store.add(speakerNames:)` or
/// `updated.speakerNames = …`) turns this test red.
@MainActor
final class LiveSpeakerNamingStopRecordingTests: XCTestCase {

    private var tempRoot: URL!
    private var store: RecordingStore!
    private var manager: ModelManager!
    private var stub: StubWhisperEngine!
    private var service: TranscriptionService!
    private var session: RecordingSession!
    private var languageSettings: RecordingLanguageSettings!
    private var postRecording: PostRecordingCoordinator!
    private var controller: QuickActionsController!

    private var voiceSettings: VoiceRecognitionSettings!
    private var profiles: SpeakerProfileStore!
    private var snapshots: ObservedVoiceSnapshots!
    private var diarizer: LiveSpeakerDiarizer!
    private var transcriber: LiveTranscriber!

    private struct Fire: Equatable {
        let rawID: String
        let name: String
    }
    private var fires: [Fire] = []

    private let suitePrefix = "LiveSpeakerNamingStopRecordingTests"

    /// A voice no stored profile matches, so the only way its name can reach
    /// a profile is the live-naming path under test.
    private let bobSpeaking: [Float] = [0, 1, 0, 0]

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: suitePrefix)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        store = RecordingStore(rootDirectory: tempRoot)
        try FileManager.default.createDirectory(at: store.recordingsDirectory,
                                                withIntermediateDirectories: true)
        manager = TestSupport.isolatedModelManager(
            modelsDirectory: tempRoot.appendingPathComponent("Models"),
            label: suitePrefix)
        try TestSupport.installFakeModel(into: manager)

        stub = StubWhisperEngine()
        // No canned segments anywhere: the live drain has no buffered audio to
        // transcribe, and the batch pass this recording gets enqueued for
        // comes back empty — which, per `TranscriptionService.mergePassResult`,
        // is the one pass that does NOT own `speakerNames`. That keeps the
        // assertions below independent of whether the background tail has run.
        await stub.setDefaultCanned([])
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

        voiceSettings = VoiceRecognitionSettings(
            defaults: UserDefaults(suiteName: "\(suitePrefix).voice")!)
        voiceSettings.diarizationReady = { true }
        voiceSettings.isEnabled = true
        profiles = SpeakerProfileStore(directory: tempRoot, settings: voiceSettings)
        snapshots = ObservedVoiceSnapshots()

        // The live singletons `MilaApp` hands the controller. The transcriber
        // is deliberately never `start()`ed — `start` clears `speakerNames`,
        // and with no detector and no buffered audio the drain's
        // `transcribeNow()` is a no-op, so the recording stays on the
        // no-live-segments path.
        diarizer = LiveSpeakerDiarizer()
        diarizer.similarityThreshold = 0.7
        diarizer.reset()
        transcriber = LiveTranscriber(transcription: service)
        controller.liveDiarizer = diarizer
        controller.liveTranscriber = transcriber

        // Same wiring MilaApp.init installs, with a tap on the hook.
        // Explicitly typed so the implicitly-unwrapped properties are captured
        // as non-optionals rather than inferred back into `Optional`.
        let profilesRef: SpeakerProfileStore = profiles
        let snapshotsRef: ObservedVoiceSnapshots = snapshots
        let settingsRef: VoiceRecognitionSettings = voiceSettings
        store.onSpeakerNamed = { [weak self] recordingID, rawID, name in
            self?.fires.append(Fire(rawID: rawID, name: name))
            guard settingsRef.isConfigured else { return }
            guard let observed = snapshotsRef.observation(forSpeaker: rawID,
                                                         in: recordingID) else { return }
            profilesRef.updateProfile(name: name,
                                      embedding: observed.observedCentroid,
                                      sampleCount: observed.observedCount)
        }
        let assigner = RecognisedSpeakerAssigner(
            store: store,
            diarizer: diarizer,
            snapshots: snapshots,
            settings: voiceSettings,
            profileStillStored: { profilesRef.profileExists(name: $0) })
        controller.onRecordingFinalized = { [assigner] recordingID, liveSpeakerNames in
            assigner.finish(recording: recordingID, liveSpeakerNames: liveSpeakerNames)
        }
    }

    override func tearDown() async throws {
        controller?.onRecordingFinalized = nil
        store?.onSpeakerNamed = nil
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        for suffix in ["diarization", "language", "llm", "voice"] {
            UserDefaults().removePersistentDomain(forName: "\(suitePrefix).\(suffix)")
        }
        try await super.tearDown()
    }

    /// The whole reported bug, end to end: a speaker is heard, the user labels
    /// them from the live pane mid-recording, Stop is pressed — and the voice
    /// is stored, once.
    ///
    /// This fails on the pre-fix code: `stopRecording` copied
    /// `transcriber.speakerNames` onto the row at `store.add` and again onto
    /// `updated`, so by the time the finalize hook ran the name already
    /// matched and `setSpeakerName` returned without firing `onSpeakerNamed`
    /// — `fires` empty, no profile, and the transcript label looking correct.
    func test_naming_a_speaker_mid_recording_learns_the_voice_exactly_once() async throws {
        let url = store.freshAudioURL(suggestedName: "LiveNaming")
        try TestSupport.writeStereo48kSineWav(at: url, durationSeconds: 0.6)
        await controller.startFakeRecordingForTesting(outputURL: url)

        // The diarizer hears one voice it has never heard before…
        XCTAssertEqual(diarizer.assign(embedding: bobSpeaking), "SPEAKER_00")
        // …and the user names them in the live transcript. This is exactly
        // what `LiveAIRecordingView`'s `onAssignName` does.
        transcriber.speakerNames["SPEAKER_00"] = "Bob"

        await controller.stopRecording()
        // Drain the background tail so nothing lands mid-assertion.
        await controller.awaitFinalizeTails()
        await service.waitForIdle()

        XCTAssertEqual(fires, [Fire(rawID: "SPEAKER_00", name: "Bob")],
                       "the finalize hook must fire once, for the name the user typed")
        let bob = profiles.profile(named: "Bob")
        XCTAssertNotNil(bob, "naming a speaker mid-recording must create a voice profile")
        XCTAssertEqual(bob?.sampleCount, 1, "one observation, folded in exactly once")
        XCTAssertEqual(bob?.embedding, bobSpeaking)

        let saved = try XCTUnwrap(store.recordings.first)
        XCTAssertEqual(saved.speakerNames, ["SPEAKER_00": "Bob"],
                       "and the label is on the saved recording, via setSpeakerName")
    }

    /// The other half of the same wiring: with nothing named in the live pane,
    /// the saved row carries no names and the hook never fires. Pins that the
    /// hook's new argument is the live map and not, say, a stale or synthesised
    /// one — a hook that fired here would be inventing labels.
    func test_naming_nothing_leaves_the_saved_recording_unnamed() async throws {
        let url = store.freshAudioURL(suggestedName: "LiveNamingNone")
        try TestSupport.writeStereo48kSineWav(at: url, durationSeconds: 0.6)
        await controller.startFakeRecordingForTesting(outputURL: url)
        XCTAssertEqual(diarizer.assign(embedding: bobSpeaking), "SPEAKER_00")

        await controller.stopRecording()
        await controller.awaitFinalizeTails()
        await service.waitForIdle()

        XCTAssertTrue(fires.isEmpty)
        XCTAssertTrue(profiles.profiles.isEmpty)
        let saved = try XCTUnwrap(store.recordings.first)
        XCTAssertTrue(saved.speakerNames.isEmpty)
    }
}
