import XCTest
import TranscriptionCore
@testable import Mila

/// Stands in for `SpeakerDiarizer.embedSpeakers`. Records what it was
/// asked for, optionally throws on the first call (the compression-race
/// retry), and runs `duringEmbed` on the main actor before returning —
/// the seam that makes "the user did X mid-embed" a plain function call.
/// File scope, not nested in the test case: a global actor propagates
/// to nested types, and this one is called from off the main actor.
private final class EmbedProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(url: URL, spans: [SpeakerAudioSpan])] = []
    private var _result: [String: [Float]] = [:]
    private var _failFirstCall = false
    private var _duringEmbed: (() -> Void)?

    var calls: [(url: URL, spans: [SpeakerAudioSpan])] {
        lock.lock(); defer { lock.unlock() }; return _calls
    }
    var callCount: Int { calls.count }

    func returns(_ result: [String: [Float]]) {
        lock.lock(); _result = result; lock.unlock()
    }
    func failFirstCall() {
        lock.lock(); _failFirstCall = true; lock.unlock()
    }
    /// Run on the main actor while the (first) extraction is in flight.
    func onFirstEmbed(_ body: @escaping () -> Void) {
        lock.lock(); _duringEmbed = body; lock.unlock()
    }

    var embed: OfflineVoiceEmbedder.Embed {
        { [self] url, spans in
            lock.lock()
            _calls.append((url: url, spans: spans))
            let isFirst = _calls.count == 1
            let hook: (() -> Void)? = isFirst ? _duringEmbed : nil
            let shouldFail = isFirst && _failFirstCall
            let result = _result
            lock.unlock()
            if let hook { await MainActor.run { hook() } }
            if shouldFail {
                throw SpeakerDiarizer.Error.diarizationFailed("probe failure")
            }
            return result
        }
    }
}

/// `OfflineVoiceEmbedder` learns and recognises voices on recordings the live
/// diarizer pool never covered. Every hazard it guards against lives in the
/// window between "we decided to embed" and "the embedding came back" — a
/// Python launch plus torch plus the pyannote pipeline, i.e. seconds during
/// which the user is free to rename, un-name, re-transcribe or delete.
///
/// That window is exactly what these tests open. The embedding call is
/// injected, so `EmbedProbe.duringEmbed` runs on the main actor *while the
/// extraction is in flight* and can do whatever the user would have done.
/// No Python, no audio decoding, no timing.
@MainActor
final class OfflineVoiceEmbedderTests: XCTestCase {

    private var tempRoot: URL!
    private var suiteNames: [String] = []

    private let aliceStored: [Float] = [1, 0, 0, 0]
    private let aliceSpeaking: [Float] = [0.99, 0.01, 0, 0]
    private let strangerSpeaking: [Float] = [0, 1, 0, 0]
    /// The same person, extracted again from a re-clustered segmentation:
    /// close enough to match her profile, far enough from `aliceSpeaking`
    /// that carrying the wrong one of the two is visible in the centroid.
    private let aliceSpeakingAgain: [Float] = [0.9, 0.4, 0, 0]
    /// A second cluster of hers in the same pass — also over the threshold.
    private let aliceSpeakingThird: [Float] = [0.95, 0.2, 0, 0]

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "OfflineVoiceEmbedderTests")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        suiteNames.removeAll()
        try await super.tearDown()
    }

    // MARK: - Fixture

    private struct World {
        let store: RecordingStore
        let profiles: SpeakerProfileStore
        let snapshots: ObservedVoiceSnapshots
        let settings: VoiceRecognitionSettings
        let embedder: OfflineVoiceEmbedder
        let probe: EmbedProbe
        let recordingID: UUID
        /// Only its hooks are used: `announceCompletion` is what fires them,
        /// in the order the production pass fires them. No whisper runs here.
        let service: TranscriptionService
    }

    private func makeSettings() -> VoiceRecognitionSettings {
        let name = "OfflineVoiceEmbedderTests.\(UUID())"
        suiteNames.append(name)
        let s = VoiceRecognitionSettings(defaults: UserDefaults(suiteName: name)!)
        s.diarizationReady = { true }
        s.isEnabled = true
        return s
    }

    private func segment(_ speaker: String?, _ start: Double, _ end: Double) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: "line at \(start)", speaker: speaker)
    }

    /// A two-speaker recording with its audio file actually on disk (the
    /// embedder refuses to run against a path that isn't there).
    private func makeWorld(segments: [TranscriptSegment]? = nil,
                           speakerNames: [String: String] = [:],
                           threshold: Double = 0.55,
                           audioFileName: String = "meeting.wav") throws -> World {
        // Its own directory: a test that builds two worlds must not have the
        // second one load the first's profiles.json off disk.
        let root = tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let settings = makeSettings()
        let profiles = SpeakerProfileStore(directory: root, settings: settings)
        let store = RecordingStore(rootDirectory: root)
        let snapshots = ObservedVoiceSnapshots()
        let probe = EmbedProbe()

        let segs = segments ?? [segment("SPEAKER_00", 0, 5),
                                segment("SPEAKER_01", 5, 12),
                                segment("SPEAKER_00", 12, 30)]
        let rec = Recording(title: "Meeting",
                            duration: 30,
                            source: .microphone,
                            audioFileName: audioFileName,
                            status: .completed,
                            segments: segs,
                            fullText: "…",
                            speakerNames: speakerNames)
        store.add(rec)
        try writeAudio(named: audioFileName, in: store)

        let embedder = OfflineVoiceEmbedder(store: store,
                                            snapshots: snapshots,
                                            profiles: profiles,
                                            settings: settings,
                                            matchThreshold: { threshold },
                                            embed: probe.embed)

        // The `onSpeakerNamed` half of `MilaApp.init`'s wiring, so a name
        // written by the batch matcher persists a profile exactly the way it
        // does in the app.
        store.onSpeakerNamed = { recordingID, rawID, name in
            guard settings.isConfigured else { return }
            guard let observed = snapshots.observation(forSpeaker: rawID, in: recordingID) else { return }
            profiles.updateProfile(name: name,
                                   embedding: observed.observedCentroid,
                                   sampleCount: observed.observedCount)
        }
        // …and the `onSpeakerUnnamed` half, verbatim too. Every claim this
        // suite makes about a contribution being reversible is checked by
        // actually reversing it, through the same hook the popover uses.
        store.onSpeakerUnnamed = { recordingID, rawID, previousName in
            guard settings.isConfigured else { return }
            guard let observed = snapshots.observation(forSpeaker: rawID, in: recordingID) else { return }
            profiles.subtractObservation(name: previousName,
                                         embedding: observed.observedCentroid,
                                         sampleCount: observed.observedCount)
        }

        // A real `TranscriptionService`, for its completion announcement
        // only: `runPass` drives the two hooks through it rather than calling
        // the embedder in an order this test picked, which is the ordering
        // island-io/mila#260 turns on.
        let suite = "OfflineVoiceEmbedderTests.\(UUID())"
        suiteNames.append("\(suite).diarization")
        suiteNames.append("\(suite).remote")
        let service = TranscriptionService(
            store: store,
            modelManager: ModelManager(modelsDirectory: root.appendingPathComponent("Models")),
            diarizationSettings: DiarizationSettings(
                defaults: UserDefaults(suiteName: "\(suite).diarization")!),
            remoteSettings: TestSupport.isolatedRemoteSettings(label: suite),
            engine: StubWhisperEngine())
        // `MilaApp.init`'s wiring of the two pass hooks, verbatim.
        service.onPassClearedSpeakerNames = { [embedder] recordingID, previousNames in
            embedder.notePassClearedSpeakerNames(previousNames, for: recordingID)
        }
        service.onTranscriptionCompleted = { [embedder] rec, _ in
            embedder.matchAfterPass(recordingID: rec.id)
        }

        return World(store: store, profiles: profiles, snapshots: snapshots,
                     settings: settings, embedder: embedder, probe: probe,
                     recordingID: rec.id, service: service)
    }

    /// Everything a batch pass does *after* whisper returns, in production
    /// order: the store write that puts the pass's segments on the row and
    /// clears the speaker names it re-keyed, then
    /// `TranscriptionService.announceCompletion` — the function that fires
    /// the cleared-names hook and the completion hook, in that order.
    ///
    /// Only the pass OUTPUT is supplied by hand. The half simulated here (the
    /// service capturing the names as it clears them, and announcing them
    /// before the completion) is driven through a real pass, with a real
    /// store write, in `TranscriptionServiceSpeakerCarryTests` — simulating
    /// both halves in one place is how the missing hook in island-io/mila#254
    /// stayed hidden.
    private func runPass(_ w: World, producing segments: [TranscriptSegment]) async {
        var updated = row(w)
        let cleared = updated.speakerNames
        updated.segments = segments
        updated.speakerNames = [:]
        updated.status = .completed
        w.store.update(updated)
        w.service.announceCompletion(updated,
                                     clearedSpeakerNames: cleared,
                                     wasRetranscription: true)
        await w.embedder.awaitPending()
    }

    /// Component-wise, with room for the float error of a fold followed by
    /// its subtraction.
    private func assertCentroid(_ actual: [Float]?, _ expected: [Float],
                                _ message: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        guard let actual else {
            XCTFail("no centroid: \(message)", file: file, line: line)
            return
        }
        XCTAssertEqual(actual.count, expected.count, message, file: file, line: line)
        guard actual.count == expected.count else { return }
        for i in actual.indices {
            XCTAssertEqual(actual[i], expected[i], accuracy: 1e-4,
                           "\(message) — component \(i)", file: file, line: line)
        }
    }

    private func writeAudio(named name: String, in store: RecordingStore) throws {
        let url = store.recordingsDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: store.recordingsDirectory,
                                                withIntermediateDirectories: true)
        try Data([0]).write(to: url)
    }

    private func row(_ w: World) -> Recording {
        w.store.recordings.first { $0.id == w.recordingID }!
    }

    // MARK: - On-demand learning

    func test_naming_a_speaker_with_no_snapshot_learns_that_speakers_voice() async throws {
        let w = try makeWorld()
        w.probe.returns(["SPEAKER_00": aliceSpeaking])
        w.store.setSpeakerName("Alice", forSpeaker: "SPEAKER_00", recordingID: w.recordingID)

        w.embedder.learnNamedSpeaker(recordingID: w.recordingID,
                                     rawID: "SPEAKER_00", name: "Alice")
        await w.embedder.awaitPending()

        XCTAssertEqual(w.profiles.profile(named: "Alice")?.embedding, aliceSpeaking)
        XCTAssertEqual(w.snapshots.observation(forSpeaker: "SPEAKER_00", in: w.recordingID)?
                        .observedCentroid, aliceSpeaking,
                       "the observation is kept so a later un-name can subtract it")
    }

    /// The longest segment for that speaker is the one embedded — 12→30, not
    /// the 0→5 they open with.
    func test_the_longest_segment_is_the_one_embedded() async throws {
        let w = try makeWorld()
        w.probe.returns(["SPEAKER_00": aliceSpeaking])
        w.store.setSpeakerName("Alice", forSpeaker: "SPEAKER_00", recordingID: w.recordingID)

        w.embedder.learnNamedSpeaker(recordingID: w.recordingID,
                                     rawID: "SPEAKER_00", name: "Alice")
        await w.embedder.awaitPending()

        XCTAssertEqual(w.probe.calls.first?.spans,
                       [SpeakerAudioSpan(rawID: "SPEAKER_00", start: 12, end: 30)])
    }

    /// **Finding: the extraction wrote a profile for a name the user had
    /// already cleared, unrecoverably.** Un-naming again is a no-op
    /// (`setSpeakerName` returns early with no previous name) and the UI
    /// offers no other route back, so the fingerprint would have stayed in
    /// Alice's profile for good.
    func test_a_name_cleared_during_the_embed_is_not_written() async throws {
        let w = try makeWorld()
        w.probe.returns(["SPEAKER_00": aliceSpeaking])
        w.store.setSpeakerName("Alice", forSpeaker: "SPEAKER_00", recordingID: w.recordingID)
        w.probe.onFirstEmbed {
            // The user picks "Use default" while Python is still starting up.
            w.store.setSpeakerName(nil, forSpeaker: "SPEAKER_00", recordingID: w.recordingID)
        }

        w.embedder.learnNamedSpeaker(recordingID: w.recordingID,
                                     rawID: "SPEAKER_00", name: "Alice")
        await w.embedder.awaitPending()

        XCTAssertNil(w.profiles.profile(named: "Alice"),
                     "a voice profile for a name the user explicitly cleared")
        XCTAssertNil(w.snapshots.observation(forSpeaker: "SPEAKER_00", in: w.recordingID))
    }

    /// Same window, the other correction: they renamed rather than cleared.
    func test_a_name_changed_during_the_embed_is_not_written_to_the_old_name() async throws {
        let w = try makeWorld()
        w.probe.returns(["SPEAKER_00": aliceSpeaking])
        w.store.setSpeakerName("Alice", forSpeaker: "SPEAKER_00", recordingID: w.recordingID)
        w.probe.onFirstEmbed {
            w.store.setSpeakerName("Dana", forSpeaker: "SPEAKER_00", recordingID: w.recordingID)
        }

        w.embedder.learnNamedSpeaker(recordingID: w.recordingID,
                                     rawID: "SPEAKER_00", name: "Alice")
        await w.embedder.awaitPending()

        XCTAssertNil(w.profiles.profile(named: "Alice"))
        XCTAssertNil(w.profiles.profile(named: "Dana"),
                     "the rename starts its own extraction; this one must not stand in for it")
    }

    /// **Finding: a second on-demand extraction wiped the first one's
    /// snapshot.** Naming two speakers on one old recording is the ordinary
    /// case for this feature, not an edge.
    func test_naming_a_second_speaker_keeps_the_first_ones_observation() async throws {
        let w = try makeWorld()
        w.store.setSpeakerName("Alice", forSpeaker: "SPEAKER_00", recordingID: w.recordingID)
        w.store.setSpeakerName("Bob", forSpeaker: "SPEAKER_01", recordingID: w.recordingID)

        w.probe.returns(["SPEAKER_00": aliceSpeaking])
        w.embedder.learnNamedSpeaker(recordingID: w.recordingID,
                                     rawID: "SPEAKER_00", name: "Alice")
        await w.embedder.awaitPending()

        w.probe.returns(["SPEAKER_01": strangerSpeaking])
        w.embedder.learnNamedSpeaker(recordingID: w.recordingID,
                                     rawID: "SPEAKER_01", name: "Bob")
        await w.embedder.awaitPending()

        XCTAssertEqual(w.snapshots.observation(forSpeaker: "SPEAKER_00", in: w.recordingID)?
                        .observedCentroid, aliceSpeaking,
                       "Bob's extraction must not erase Alice's observation")
        XCTAssertEqual(w.snapshots.observation(forSpeaker: "SPEAKER_01", in: w.recordingID)?
                        .observedCentroid, strangerSpeaking)
    }

    func test_learning_does_nothing_while_voice_recognition_is_off() async throws {
        let w = try makeWorld()
        w.probe.returns(["SPEAKER_00": aliceSpeaking])
        w.store.setSpeakerName("Alice", forSpeaker: "SPEAKER_00", recordingID: w.recordingID)
        w.settings.isEnabled = false

        w.embedder.learnNamedSpeaker(recordingID: w.recordingID,
                                     rawID: "SPEAKER_00", name: "Alice")
        await w.embedder.awaitPending()

        XCTAssertEqual(w.probe.callCount, 0, "an opted-out user's audio is not even read")
    }

    /// Opting out *during* the extraction still has to hold: the gate is
    /// re-read when the result lands.
    func test_opting_out_during_the_embed_discards_the_result() async throws {
        let w = try makeWorld()
        w.probe.returns(["SPEAKER_00": aliceSpeaking])
        w.store.setSpeakerName("Alice", forSpeaker: "SPEAKER_00", recordingID: w.recordingID)
        w.probe.onFirstEmbed { w.settings.isEnabled = false }

        w.embedder.learnNamedSpeaker(recordingID: w.recordingID,
                                     rawID: "SPEAKER_00", name: "Alice")
        await w.embedder.awaitPending()

        XCTAssertNil(w.snapshots.observation(forSpeaker: "SPEAKER_00", in: w.recordingID),
                     "nothing about an opted-out user's voice is retained")
        w.settings.isEnabled = true
        XCTAssertNil(w.profiles.profile(named: "Alice"),
                     "…and nothing was written to disk to be re-loaded on opt-in")
    }

    /// **Finding: an in-flight extraction resurrected a profile the user
    /// deleted while it ran.** `updateProfile` creates on a missing name —
    /// that is how hand-naming makes a profile at all — so the write cannot
    /// simply refuse to create. It has to tell "the profile this naming is
    /// for" from "the profile the user just erased", and the erased one comes
    /// back with a centroid matching it to better than 0.999 cosine. Same
    /// hazard `RecognisedSpeakerAssigner`'s `profileStillStored` gate exists
    /// for.
    func test_a_profile_deleted_during_the_embed_is_not_resurrected() async throws {
        let w = try makeWorld()
        w.profiles.updateProfile(name: "Alice", embedding: aliceStored, sampleCount: 10)
        w.probe.returns(["SPEAKER_00": aliceSpeaking])
        w.store.setSpeakerName("Alice", forSpeaker: "SPEAKER_00", recordingID: w.recordingID)
        w.probe.onFirstEmbed {
            // Settings → Speakers → delete Alice's voice profile.
            w.profiles.deleteProfile(name: "Alice")
        }

        w.embedder.learnNamedSpeaker(recordingID: w.recordingID,
                                     rawID: "SPEAKER_00", name: "Alice")
        await w.embedder.awaitPending()

        XCTAssertNil(w.profiles.profile(named: "Alice"),
                     "the deletion was the user's last word on that profile")
    }

    /// The negative control for the guard above: hand-naming a speaker whose
    /// name has no profile yet is exactly how profiles get created, and must
    /// keep working.
    func test_naming_a_speaker_with_no_existing_profile_still_creates_one() async throws {
        let w = try makeWorld()
        w.probe.returns(["SPEAKER_00": aliceSpeaking])
        w.store.setSpeakerName("Alice", forSpeaker: "SPEAKER_00", recordingID: w.recordingID)
        XCTAssertNil(w.profiles.profile(named: "Alice"), "precondition: no profile yet")

        w.embedder.learnNamedSpeaker(recordingID: w.recordingID,
                                     rawID: "SPEAKER_00", name: "Alice")
        await w.embedder.awaitPending()

        XCTAssertEqual(w.profiles.profile(named: "Alice")?.embedding, aliceSpeaking)
    }

    // MARK: - Post-pass matching

    func test_a_recognised_speaker_is_named_automatically_after_a_pass() async throws {
        let w = try makeWorld(threshold: 0.7)
        w.profiles.updateProfile(name: "Alice", embedding: aliceStored, sampleCount: 10)
        w.probe.returns(["SPEAKER_00": aliceSpeaking, "SPEAKER_01": strangerSpeaking])

        w.embedder.matchAfterPass(recordingID: w.recordingID)
        await w.embedder.awaitPending()

        XCTAssertEqual(row(w).speakerNames["SPEAKER_00"], "Alice")
        XCTAssertNil(row(w).speakerNames["SPEAKER_01"],
                     "a stranger stays unnamed rather than borrowing the only stored profile")
    }

    /// **Finding: auto-matching ignored the user's similarity slider**,
    /// taking `match`'s 0.55 default. Someone who tightened it because of
    /// false matches got the tighter threshold live and the loose one here —
    /// where a wrong name is applied without them watching.
    func test_the_users_similarity_threshold_is_applied() async throws {
        // cos(aliceStored, borderline) ≈ 0.6: over 0.55, under 0.9.
        let borderline: [Float] = [0.6, 0.8, 0, 0]
        let loose = try makeWorld(threshold: 0.55)
        loose.profiles.updateProfile(name: "Alice", embedding: aliceStored, sampleCount: 10)
        loose.probe.returns(["SPEAKER_00": borderline])
        loose.embedder.matchAfterPass(recordingID: loose.recordingID)
        await loose.embedder.awaitPending()
        XCTAssertEqual(row(loose).speakerNames["SPEAKER_00"], "Alice",
                       "precondition: this embedding does match at the default threshold")

        let tight = try makeWorld(threshold: 0.9)
        tight.profiles.updateProfile(name: "Alice", embedding: aliceStored, sampleCount: 10)
        tight.probe.returns(["SPEAKER_00": borderline])
        tight.embedder.matchAfterPass(recordingID: tight.recordingID)
        await tight.embedder.awaitPending()
        XCTAssertNil(row(tight).speakerNames["SPEAKER_00"],
                     "the same embedding must not match once the user tightens the slider")
    }

    /// **Finding: the batch auto-match overwrote a name typed during the
    /// embed.** The `speakerNames.isEmpty` guard was evaluated on the
    /// pre-await copy of the row, so the user's own label lost — and
    /// `onSpeakerNamed` fired a second time, folding this recording's
    /// centroid into two different profiles.
    func test_a_name_typed_during_the_embed_survives_the_auto_match() async throws {
        let w = try makeWorld(threshold: 0.7)
        w.profiles.updateProfile(name: "Alice", embedding: aliceStored, sampleCount: 10)
        w.probe.returns(["SPEAKER_00": aliceSpeaking])
        w.probe.onFirstEmbed {
            w.store.setSpeakerName("Dana", forSpeaker: "SPEAKER_00", recordingID: w.recordingID)
        }

        w.embedder.matchAfterPass(recordingID: w.recordingID)
        await w.embedder.awaitPending()

        XCTAssertEqual(row(w).speakerNames["SPEAKER_00"], "Dana",
                       "the user's own label wins over a recogniser's guess")
    }

    /// **Finding: a pass re-keys every `SPEAKER_NN`, so the embeddings held
    /// under the old ids may denote different people.** Nothing may resolve
    /// through them afterwards, and the batch path must not skip matching
    /// because a (stale) snapshot exists.
    func test_a_pass_invalidates_the_recordings_previous_snapshot() async throws {
        let w = try makeWorld(threshold: 0.7)
        w.profiles.updateProfile(name: "Alice", embedding: aliceStored, sampleCount: 10)
        // Run 1's snapshot: SPEAKER_00 was somebody else entirely.
        w.snapshots.record([(id: "SPEAKER_00", observedCentroid: strangerSpeaking,
                             observedCount: 4, profileName: nil)], for: w.recordingID)
        w.probe.returns(["SPEAKER_00": aliceSpeaking])

        w.embedder.matchAfterPass(recordingID: w.recordingID)
        await w.embedder.awaitPending()

        XCTAssertEqual(w.probe.callCount, 1,
                       "an existing snapshot must not suppress the fresh extraction")
        XCTAssertEqual(w.snapshots.observation(forSpeaker: "SPEAKER_00", in: w.recordingID)?
                        .observedCentroid, aliceSpeaking,
                       "run 1's voice must be gone, replaced by this pass's")
        XCTAssertEqual(row(w).speakerNames["SPEAKER_00"], "Alice")
    }

    /// Invalidation is unconditional — it happens even when nothing else
    /// about this pass is actionable, because holding a stale embedding is
    /// the hazard, not failing to add a new one.
    func test_the_snapshot_is_invalidated_even_with_no_stored_profiles() async throws {
        let w = try makeWorld()
        w.snapshots.record([(id: "SPEAKER_00", observedCentroid: strangerSpeaking,
                             observedCount: 4, profileName: nil)], for: w.recordingID)

        w.embedder.matchAfterPass(recordingID: w.recordingID)
        await w.embedder.awaitPending()

        XCTAssertNil(w.snapshots.observation(forSpeaker: "SPEAKER_00", in: w.recordingID))
        XCTAssertEqual(w.probe.callCount, 0, "…but with nothing to match against, no Python runs")
    }

    func test_a_recording_the_user_already_named_is_left_alone() async throws {
        let w = try makeWorld(speakerNames: ["SPEAKER_00": "Alice"], threshold: 0.7)
        w.profiles.updateProfile(name: "Alice", embedding: aliceStored, sampleCount: 10)

        w.embedder.matchAfterPass(recordingID: w.recordingID)
        await w.embedder.awaitPending()

        XCTAssertEqual(w.probe.callCount, 0)
    }

    // MARK: - The compression race

    /// **Finding: capturing the WAV URL before the `await` did not close the
    /// race — it guaranteed looking at the path about to be deleted.**
    /// `compressRecordingAudio` starts the moment the completion hook
    /// returns, transcodes to `.m4a`, swaps `audioFileName` and removes the
    /// `.wav`. Resolving late sees the new name; `embedSpeakers` decodes it.
    func test_the_audio_url_is_resolved_when_the_extraction_runs() async throws {
        let w = try makeWorld(threshold: 0.7)
        w.profiles.updateProfile(name: "Alice", embedding: aliceStored, sampleCount: 10)
        w.probe.returns(["SPEAKER_00": aliceSpeaking])

        w.embedder.matchAfterPass(recordingID: w.recordingID)
        // Compression lands before the detached task gets the main actor:
        // the WAV is gone and the row points at the m4a.
        var compressed = row(w)
        compressed.audioFileName = "meeting.m4a"
        try writeAudio(named: "meeting.m4a", in: w.store)
        w.store.update(compressed)
        try FileManager.default.removeItem(
            at: w.store.recordingsDirectory.appendingPathComponent("meeting.wav"))

        await w.embedder.awaitPending()

        XCTAssertEqual(w.probe.calls.first?.url.lastPathComponent, "meeting.m4a",
                       "a URL captured before the await would name the deleted .wav")
        XCTAssertEqual(row(w).speakerNames["SPEAKER_00"], "Alice")
    }

    /// A failed extraction is retried once, re-resolving the audio — the
    /// residual window where compression wins between resolve and read.
    func test_a_failed_extraction_is_retried_once() async throws {
        let w = try makeWorld(threshold: 0.7)
        w.profiles.updateProfile(name: "Alice", embedding: aliceStored, sampleCount: 10)
        w.probe.returns(["SPEAKER_00": aliceSpeaking])
        w.probe.failFirstCall()

        w.embedder.matchAfterPass(recordingID: w.recordingID)
        await w.embedder.awaitPending()

        XCTAssertEqual(w.probe.callCount, 2)
        XCTAssertEqual(row(w).speakerNames["SPEAKER_00"], "Alice")
    }

    func test_a_missing_audio_file_is_not_an_endless_retry() async throws {
        let w = try makeWorld(threshold: 0.7)
        w.profiles.updateProfile(name: "Alice", embedding: aliceStored, sampleCount: 10)
        try FileManager.default.removeItem(
            at: w.store.recordingsDirectory.appendingPathComponent("meeting.wav"))

        w.embedder.matchAfterPass(recordingID: w.recordingID)
        await w.embedder.awaitPending()

        XCTAssertEqual(w.probe.callCount, 0)
        XCTAssertNil(row(w).speakerNames["SPEAKER_00"])
    }

    // MARK: - A re-transcribe swaps a contribution, it does not add one
    //
    // The pass clears `speakerNames` wholesale and fires no hook, so every
    // name's voice-profile contribution is left with no label to un-name;
    // the re-match then names the speaker again and folds a SECOND
    // observation of the same recording into the same profile
    // (island-io/mila#260). These pin the repair, and — just as importantly —
    // pin that the repair never subtracts and never deletes.

    /// Alice as she stands from earlier recordings, plus this recording's own
    /// contribution: named by hand, learned on demand, which is how a profile
    /// comes to hold one observation of one recording.
    private func nameAliceHere(_ w: World, priorSamples: Int) async {
        if priorSamples > 0 {
            w.profiles.updateProfile(name: "Alice", embedding: aliceStored, sampleCount: priorSamples)
        }
        w.probe.returns(["SPEAKER_00": aliceSpeaking])
        w.store.setSpeakerName("Alice", forSpeaker: "SPEAKER_00", recordingID: w.recordingID)
        w.embedder.learnNamedSpeaker(recordingID: w.recordingID,
                                     rawID: "SPEAKER_00", name: "Alice")
        await w.embedder.awaitPending()
    }

    /// **The bug this closes.** Alice arrives carrying 3 samples from earlier
    /// recordings and this recording takes her to 4. A re-transcribe clears
    /// her label, strands that 4th contribution — nothing left to un-name —
    /// and then hands her a 5th by matching her voice and naming her again.
    ///
    /// **Discriminating in both directions.**
    ///
    /// * `main` → 5 after the pass, and un-naming leaves 4: one contribution
    ///   stranded under a label that no longer exists.
    /// * Suppress the second fold but leave the fresh observation in the
    ///   snapshot → 4, but the un-name subtracts an embedding the profile
    ///   never received, so her centroid lands at `[1.03, -0.13, 0, 0]`
    ///   instead of back on `[1, 0, 0, 0]`.
    /// * This fix → 4, and the un-name returns her to exactly her
    ///   pre-recording weight *and* her pre-recording centroid.
    func test_a_name_the_pass_cleared_comes_back_without_a_second_contribution() async throws {
        let w = try makeWorld(threshold: 0.7)
        await nameAliceHere(w, priorSamples: 3)
        let named = try XCTUnwrap(w.profiles.profile(named: "Alice"))
        XCTAssertEqual(named.sampleCount, 4,
                       "precondition: her 3 earlier samples plus this recording's one")

        // The re-transcribe: a new clustering, new ids, names cleared, and a
        // fresh extraction of the same voice.
        w.probe.returns(["SPEAKER_01": aliceSpeakingAgain])
        await runPass(w, producing: [segment("SPEAKER_01", 0, 5),
                                     segment("SPEAKER_01", 5, 20)])

        XCTAssertEqual(row(w).speakerNames["SPEAKER_01"], "Alice",
                       "her name comes back on the id the re-match resolved it to")
        let afterPass = try XCTUnwrap(w.profiles.profile(named: "Alice"))
        XCTAssertEqual(afterPass.sampleCount, 4,
                       "and brings no second contribution with it")
        assertCentroid(afterPass.embedding, named.embedding,
                       "her centroid is untouched by a pass that told us nothing new")

        // The whole point: the correction #237 exists for can now reach it.
        w.store.setSpeakerName(nil, forSpeaker: "SPEAKER_01", recordingID: w.recordingID)

        let afterUnname = try XCTUnwrap(w.profiles.profile(named: "Alice"),
                                        "her earlier recordings are untouched")
        XCTAssertEqual(afterUnname.sampleCount, 3,
                       "un-naming returns her to exactly her pre-recording weight")
        assertCentroid(afterUnname.embedding, aliceStored,
                       "…and to her pre-recording centroid, which only holds if what came "
                       + "back out is the observation that actually went in")
    }

    /// The deliberate under-correction, and the reason this path does not use
    /// `RecordingStore.update(_:retiringSpeakerNames:)`: a cleared name whose
    /// voice the re-match cannot find keeps its contribution. Retiring it
    /// would subtract the only weight Alice's profile has and delete her —
    /// on the evidence of a similarity score, not of a user saying "that
    /// isn't her". Residue is recoverable; a deleted voice is not.
    func test_a_cleared_name_the_rematch_cannot_find_keeps_its_contribution() async throws {
        let w = try makeWorld(threshold: 0.7)
        // Her profile's ONLY evidence is this recording — the ordinary state
        // of one created by naming a speaker once.
        await nameAliceHere(w, priorSamples: 0)
        XCTAssertEqual(w.profiles.profile(named: "Alice")?.sampleCount, 1,
                       "precondition: one sample, from here")

        // The re-clustered pass produces a speaker who sounds nothing like her.
        w.probe.returns(["SPEAKER_01": strangerSpeaking])
        await runPass(w, producing: [segment("SPEAKER_01", 0, 5),
                                     segment("SPEAKER_01", 5, 20)])

        XCTAssertNil(row(w).speakerNames["SPEAKER_01"],
                     "a voice that does not match is not handed her name")
        let alice = try XCTUnwrap(w.profiles.profile(named: "Alice"),
                                  "her profile must survive a re-transcribe that failed to "
                                  + "recognise her — deleting it here is the destructive fix #260 rejects")
        XCTAssertEqual(alice.sampleCount, 1)
        assertCentroid(alice.embedding, aliceSpeaking, "and it still holds her voice")
    }

    /// The negative control. A pass with no names to clear must go on folding
    /// what it learns — this is how a batch-transcribed recording contributes
    /// to a profile at all, and suppressing it unconditionally would silently
    /// stop voice recognition improving.
    func test_a_pass_with_no_cleared_names_still_folds_what_it_learns() async throws {
        let w = try makeWorld(threshold: 0.7)
        w.profiles.updateProfile(name: "Alice", embedding: aliceStored, sampleCount: 3)
        w.probe.returns(["SPEAKER_00": aliceSpeaking])

        await runPass(w, producing: [segment("SPEAKER_00", 0, 5),
                                     segment("SPEAKER_00", 5, 20)])

        XCTAssertEqual(row(w).speakerNames["SPEAKER_00"], "Alice")
        XCTAssertEqual(w.profiles.profile(named: "Alice")?.sampleCount, 4,
                       "a recording that had contributed nothing to her profile must still add to it")
    }

    /// A cleared name is claimed by at most ONE new speaker. Two clusters can
    /// legitimately match one profile (`SpeakerCorrectionActionsTests`'
    /// `test_auto_naming_two_clusters_after_one_profile_keeps_them_separate`),
    /// and the second one is a genuinely new contribution: it folds, and it
    /// is reversible on its own.
    ///
    /// Discriminating: treat the claim as a set membership test rather than a
    /// claim and both speakers re-attach — the profile stays at 4 and both
    /// snapshot entries point at the SAME observation, so un-naming the two
    /// of them subtracts it twice and lands on 2.
    func test_only_one_new_speaker_claims_a_cleared_name() async throws {
        let w = try makeWorld(threshold: 0.7)
        await nameAliceHere(w, priorSamples: 3)

        w.probe.returns(["SPEAKER_01": aliceSpeakingAgain,
                         "SPEAKER_02": aliceSpeakingThird])
        await runPass(w, producing: [segment("SPEAKER_01", 0, 5),
                                     segment("SPEAKER_02", 5, 20)])

        XCTAssertEqual(row(w).speakerNames["SPEAKER_01"], "Alice")
        XCTAssertEqual(row(w).speakerNames["SPEAKER_02"], "Alice")
        XCTAssertEqual(w.profiles.profile(named: "Alice")?.sampleCount, 5,
                       "the claim covers one of them; the other is a new observation and folds")

        w.store.setSpeakerName(nil, forSpeaker: "SPEAKER_02", recordingID: w.recordingID)
        w.store.setSpeakerName(nil, forSpeaker: "SPEAKER_01", recordingID: w.recordingID)

        let alice = try XCTUnwrap(w.profiles.profile(named: "Alice"))
        XCTAssertEqual(alice.sampleCount, 3,
                       "un-naming both takes back exactly the two contributions this recording made")
        assertCentroid(alice.embedding, aliceStored, "and nothing else")
    }

    /// Two ids named Alice folded twice into one profile, so what the pass
    /// carries across for her is the combined observation — the single entry
    /// whose subtraction reverses both. Carrying only one of them (or none)
    /// leaves her at 4 after the un-name instead of 3.
    func test_two_ids_that_shared_a_name_carry_one_combined_contribution() async throws {
        let w = try makeWorld(segments: [segment("SPEAKER_00", 0, 5),
                                         segment("SPEAKER_02", 5, 12),
                                         segment("SPEAKER_00", 12, 30)],
                              threshold: 0.7)
        w.profiles.updateProfile(name: "Alice", embedding: aliceStored, sampleCount: 3)
        // The live pool over-segmented her; both fragments were named at stop.
        w.snapshots.record([(id: "SPEAKER_00", observedCentroid: aliceSpeaking,
                             observedCount: 1, profileName: nil),
                            (id: "SPEAKER_02", observedCentroid: aliceSpeaking,
                             observedCount: 1, profileName: nil)], for: w.recordingID)
        for raw in ["SPEAKER_00", "SPEAKER_02"] {
            w.store.setSpeakerName("Alice", forSpeaker: raw, recordingID: w.recordingID)
        }
        XCTAssertEqual(w.profiles.profile(named: "Alice")?.sampleCount, 5,
                       "precondition: two named fragments, two contributions")

        // The pass puts her in one cluster.
        w.probe.returns(["SPEAKER_01": aliceSpeakingAgain])
        await runPass(w, producing: [segment("SPEAKER_01", 0, 5),
                                     segment("SPEAKER_01", 5, 20)])

        XCTAssertEqual(row(w).speakerNames["SPEAKER_01"], "Alice")
        XCTAssertEqual(w.profiles.profile(named: "Alice")?.sampleCount, 5,
                       "no third contribution")

        w.store.setSpeakerName(nil, forSpeaker: "SPEAKER_01", recordingID: w.recordingID)

        let alice = try XCTUnwrap(w.profiles.profile(named: "Alice"))
        XCTAssertEqual(alice.sampleCount, 3,
                       "one un-name gives back BOTH of this recording's contributions")
        assertCentroid(alice.embedding, aliceStored, "exactly")
    }

    /// The carry is scoped to the recording it was announced for. A note left
    /// behind by a pass whose match never ran must not suppress a fold on the
    /// next recording — that would credit one recording's contribution to a
    /// speaker in another, and leave the first one's stranded anyway.
    ///
    /// Driven through the embedder directly rather than `runPass`, because
    /// the point is the slot surviving into a *different* recording's match:
    /// `announceCompletion` always notes before it matches, so the pairing is
    /// what has to be checked, not the ordering.
    func test_a_carry_left_by_another_recording_is_not_applied_here() async throws {
        let w = try makeWorld(threshold: 0.7)
        w.profiles.updateProfile(name: "Alice", embedding: aliceStored, sampleCount: 3)
        w.probe.returns(["SPEAKER_00": aliceSpeaking])

        // A pass on some other recording cleared "Alice", and its match never
        // reached the embedder.
        w.embedder.notePassClearedSpeakerNames(["SPEAKER_00": "Alice"], for: UUID())
        w.embedder.matchAfterPass(recordingID: w.recordingID)
        await w.embedder.awaitPending()

        XCTAssertEqual(row(w).speakerNames["SPEAKER_00"], "Alice")
        XCTAssertEqual(w.profiles.profile(named: "Alice")?.sampleCount, 4,
                       "this recording has contributed nothing to her yet, so its observation folds in")
    }
}
