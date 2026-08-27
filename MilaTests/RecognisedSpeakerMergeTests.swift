import XCTest
@testable import Mila

/// **Invariant: one recognition folds into the stored centroid exactly
/// once.**
///
/// `MilaApp.autoAssignRecognisedSpeakers` used to call
/// `SpeakerProfileStore.updateProfile` directly *and* call
/// `RecordingStore.setSpeakerName`, which synchronously fires
/// `onSpeakerNamed` — wired in `MilaApp.init` to that same `updateProfile`.
/// Every recognised speaker was therefore merged twice per recording.
///
/// The centroid *value* survives a double merge (a weighted average of x
/// with x is x), which is why it went unnoticed. What doubles is
/// `sampleCount`, and because the merge weights by sample count, each
/// recording makes the profile more rigid until it stops adapting to the
/// speaker at all: recognition decays with nothing visibly failing, which is
/// strictly worse than a crash. Hence tests on the arithmetic rather than on
/// the profile "looking right".
///
/// **What these tests bind to.** Real `RecordingStore`, real
/// `SpeakerProfileStore`, and the real `setSpeakerName` → `onSpeakerNamed`
/// mechanics that carry the merge. The hook body is the same three lines
/// `MilaApp.init` installs. What they cannot reach is
/// `autoAssignRecognisedSpeakers` itself — it is `private`, and its inputs
/// (`LiveSpeakerDiarizer.pool` / `.intervals`) are private too — so that
/// loop's pool filtering is guarded by the comment at the call site rather
/// than from here. `test_the_regression_shape_doubles_the_sample_count`
/// exists so the assertions below are provably discriminating rather than
/// vacuous.
@MainActor
final class RecognisedSpeakerMergeTests: XCTestCase {

    private var tempRoot: URL!
    private var suiteNames: [String] = []

    /// The profile already on disk from earlier recordings.
    private let storedCentroid: [Float] = [1, 0]
    private let storedSamples = 4
    /// What the diarizer observed for that voice in *this* recording.
    private let observedCentroid: [Float] = [0, 1]
    private let observedSamples = 2

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "RecognisedSpeakerMergeTests")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        suiteNames.removeAll()
        try await super.tearDown()
    }

    // MARK: - Fixture

    /// Opted-in settings on a throwaway suite — never `.standard`.
    private func makeSettings() -> VoiceRecognitionSettings {
        let name = "RecognisedSpeakerMergeTests.\(UUID())"
        suiteNames.append(name)
        let settings = VoiceRecognitionSettings(defaults: UserDefaults(suiteName: name)!)
        settings.diarizationReady = { true }
        settings.isEnabled = true
        return settings
    }

    /// The world as it stands when a recording stops: a stored profile for
    /// Alice, a recording to label, and the `onSpeakerNamed` hook wired the
    /// way `MilaApp.init` wires it.
    private func makeWorld() -> (recordings: RecordingStore,
                                 profiles: SpeakerProfileStore,
                                 recording: Recording) {
        let settings = makeSettings()
        let profiles = SpeakerProfileStore(directory: tempRoot, settings: settings)
        profiles.updateProfile(name: "Alice",
                               embedding: storedCentroid,
                               sampleCount: storedSamples)

        let recordings = RecordingStore(rootDirectory: tempRoot)
        let recording = Recording(title: "Standup",
                                  duration: 60,
                                  source: .microphone,
                                  audioFileName: "standup.wav")
        recordings.add(recording)

        // Verbatim shape of MilaApp.init's wiring. The real hook re-reads the
        // centroid out of the diarizer pool by speaker id; substituting the
        // observation directly is the same thing from the store's side.
        let observed = (centroid: observedCentroid, sampleCount: observedSamples)
        recordings.onSpeakerNamed = { _, _, name in
            guard settings.isConfigured else { return }
            profiles.updateProfile(name: name,
                                   embedding: observed.centroid,
                                   sampleCount: observed.sampleCount)
        }
        return (recordings, profiles, recording)
    }

    private func alice(_ profiles: SpeakerProfileStore) -> VoiceProfile? {
        profiles.profile(named: "Alice")
    }

    // MARK: - The invariant

    /// Auto-assigning a recognised speaker merges the observation once: the
    /// stored sample count goes 4 → 6, not 4 → 8.
    func test_one_recognition_merges_exactly_once() {
        let world = makeWorld()
        XCTAssertEqual(alice(world.profiles)?.sampleCount, storedSamples)

        // What autoAssignRecognisedSpeakers now does, and all it does.
        world.recordings.setSpeakerName("Alice",
                                        forSpeaker: "SPEAKER_00",
                                        recordingID: world.recording.id)

        XCTAssertEqual(alice(world.profiles)?.sampleCount, 6,
                       "one recognition must fold in once — 4 stored + 2 observed")
        // (1*4 + 0*2)/6 and (0*4 + 1*2)/6. A second merge would drag these to
        // 0.5 / 0.5, so the centroid is a second, independent witness.
        XCTAssertEqual(alice(world.profiles)?.embedding[0] ?? 0, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(alice(world.profiles)?.embedding[1] ?? 0, 1.0 / 3.0, accuracy: 0.0001)

        // And the label itself landed.
        XCTAssertEqual(world.recordings.recordings.first?.speakerNames["SPEAKER_00"], "Alice")
    }

    /// Running the auto-assign path more than once for the same recording — a
    /// duplicated stop event, a re-entrant `.onChange` — merges nothing
    /// further. `setSpeakerName` returns early once the name already matches,
    /// so the hook never fires again. That idempotency is a property of
    /// routing persistence through `setSpeakerName`, and it is exactly what a
    /// direct `updateProfile` call alongside it destroys.
    func test_re_running_auto_assign_for_the_same_recording_merges_nothing_further() {
        let world = makeWorld()
        for _ in 0..<3 {
            world.recordings.setSpeakerName("Alice",
                                            forSpeaker: "SPEAKER_00",
                                            recordingID: world.recording.id)
        }
        XCTAssertEqual(alice(world.profiles)?.sampleCount, 6,
                       "re-running auto-assign must not re-merge the same recording")
    }

    /// "Exactly once" is per recognition, not once ever — the next recording
    /// must still improve the profile. 6 → 9 on a three-sample observation.
    func test_a_later_recording_merges_again() {
        let world = makeWorld()
        world.recordings.setSpeakerName("Alice",
                                        forSpeaker: "SPEAKER_00",
                                        recordingID: world.recording.id)

        let second = Recording(title: "Retro",
                               duration: 60,
                               source: .microphone,
                               audioFileName: "retro.wav")
        world.recordings.add(second)
        // Fresh observation from the new recording.
        world.recordings.onSpeakerNamed = { [profiles = world.profiles] _, _, name in
            profiles.updateProfile(name: name, embedding: [0, 1], sampleCount: 3)
        }
        world.recordings.setSpeakerName("Alice",
                                        forSpeaker: "SPEAKER_00",
                                        recordingID: second.id)

        XCTAssertEqual(alice(world.profiles)?.sampleCount, 9)
    }

    /// Guards the guard: reproduce the removed shape — `setSpeakerName`
    /// followed by a direct `updateProfile` with the same entry — and confirm
    /// it doubles the observation. Without this, the `6` asserted above could
    /// pass for the wrong reason and the regression could slip back in
    /// unnoticed.
    func test_the_regression_shape_doubles_the_sample_count() {
        let world = makeWorld()

        world.recordings.setSpeakerName("Alice",
                                        forSpeaker: "SPEAKER_00",
                                        recordingID: world.recording.id)
        // The line that used to sit here in autoAssignRecognisedSpeakers.
        world.profiles.updateProfile(name: "Alice",
                                     embedding: observedCentroid,
                                     sampleCount: observedSamples)

        XCTAssertEqual(alice(world.profiles)?.sampleCount, 8,
                       "the removed second call is what the assertions above discriminate against")
        XCTAssertEqual(alice(world.profiles)?.embedding[0] ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(alice(world.profiles)?.embedding[1] ?? 0, 0.5, accuracy: 0.0001)
    }
}
