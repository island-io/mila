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

        return World(store: store, profiles: profiles, snapshots: snapshots,
                     settings: settings, embedder: embedder, probe: probe,
                     recordingID: rec.id)
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
}
