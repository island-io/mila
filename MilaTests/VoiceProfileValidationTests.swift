import XCTest
@testable import Mila

/// `speaker-profiles.json` is untrusted input.
///
/// It is a plain file in Application Support: hand-editable, truncatable,
/// restorable from a half-written backup. Decoding proves it is *syntactically*
/// valid JSON and nothing more, and the values it can legally hold are ones the
/// arithmetic downstream does not survive. `SpeakerProfileStore.load` therefore
/// re-checks every decoded profile against `VoiceProfile.unusableReason` — the
/// same invariants `updateProfile` enforces on the way in — before installing
/// it.
///
/// Two distinct failure modes, and they are not the same shape:
///
/// 1. **`sampleCount <= 0` silently corrupts.** `seedPool` carries the stored
///    count into the live pool and `LiveSpeakerDiarizer.assign` folds a
///    confident match with `(centroid[i] * Float(n) + embedding[i]) /
///    Float(n + 1)`. At `n == -1` that is a division by zero — but a `Float`
///    one, so nothing traps: the centroid becomes ±inf/NaN, stays NaN through
///    every later fold, and the speaker simply stops being recognised.
/// 2. **`sampleCount == Int.max` crashes.** `updateProfile` evaluates
///    `existing.sampleCount + sampleCount`, and Swift traps on `Int` overflow.
///
/// A non-finite value *stored in the embedding* would do the same damage as
/// (1) with no fold needed, but JSON cannot express one and the decoder
/// refuses every number too large for `Float`, so that clause is an invariant
/// held rather than a hole plugged — asserted on the value type below, with
/// the diarizer-level control that shows why it is worth holding.
///
/// Real `SpeakerProfileStore`, real `LiveSpeakerDiarizer`, real files on disk.
/// Each guarded assertion is paired with a negative control that drives the
/// unguarded values straight into the diarizer and shows the bad outcome
/// actually happening, so a passing test is provably discriminating rather
/// than merely quiet.
@MainActor
final class VoiceProfileValidationTests: XCTestCase {

    private var tempRoot: URL!
    private var suiteNames: [String] = []

    /// Alice, as stored on disk.
    private let aliceStored: [Float] = [1, 0, 0, 0]
    /// Alice speaking — cosine ~0.99995 against `aliceStored`, comfortably a
    /// confident match at the 0.7 threshold used below.
    private let aliceSpeaking: [Float] = [0.99, 0.01, 0, 0]

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "VoiceProfileValidationTests")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        suiteNames.removeAll()
        try await super.tearDown()
    }

    // MARK: - Fixture

    private var profilesFile: URL {
        tempRoot.appendingPathComponent("speaker-profiles.json")
    }

    private func makeSettings() -> VoiceRecognitionSettings {
        let name = "VoiceProfileValidationTests.\(UUID())"
        suiteNames.append(name)
        let settings = VoiceRecognitionSettings(defaults: UserDefaults(suiteName: name)!)
        settings.diarizationReady = { true }
        settings.isEnabled = true
        return settings
    }

    private func profile(name: String,
                         embedding: [Float],
                         sampleCount: Int) -> VoiceProfile {
        VoiceProfile(id: UUID(),
                     name: name,
                     embedding: embedding,
                     sampleCount: sampleCount,
                     createdAt: Date(),
                     lastSeenAt: Date())
    }

    /// Write profiles straight to disk, bypassing the store entirely — the
    /// only way to produce values `updateProfile` would have refused.
    private func writeProfilesFile(_ profiles: [VoiceProfile]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(profiles).write(to: profilesFile)
    }

    /// Write the file as literal text, for shapes no encoder will produce.
    private func writeRawProfilesFile(_ json: String) throws {
        try Data(json.utf8).write(to: profilesFile)
    }

    /// An opted-in store over `tempRoot`, so `init` runs `load()`.
    private func openStore() -> SpeakerProfileStore {
        SpeakerProfileStore(directory: tempRoot, settings: makeSettings())
    }

    private func makeDiarizer() -> LiveSpeakerDiarizer {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = 0.7
        return d
    }

    // MARK: - 1. A non-positive sampleCount never reaches the pool

    func test_a_negative_sampleCount_profile_is_dropped_at_load() throws {
        try writeProfilesFile([profile(name: "Alice", embedding: aliceStored, sampleCount: -1)])

        let store = openStore()

        XCTAssertTrue(store.profiles.isEmpty, "a negative sampleCount is not a usable profile")
        XCTAssertTrue(store.seedEntries().isEmpty, "and nothing reaches the diarizer")
    }

    /// Zero is not the divide-by-zero case — `Float(0 + 1)` is a perfectly
    /// good divisor. It is refused because a centroid that is the mean of no
    /// observations describes nobody, and because `updateProfile` has always
    /// refused to write one. `-1` is the arithmetic hazard; `0` is the
    /// nonsense one, and both are caught by the same clause.
    func test_a_zero_sampleCount_profile_is_dropped_at_load() throws {
        try writeProfilesFile([profile(name: "Alice", embedding: aliceStored, sampleCount: 0)])

        XCTAssertTrue(openStore().profiles.isEmpty,
                      "refused on write, so refused on read")
    }

    /// Negative control, and the whole point of the guard: hand the diarizer
    /// the *unvalidated* stored values and the fold destroys the centroid.
    ///
    /// The corruption is silent — no trap, no error, no log. It shows up as
    /// the same voice, twice in a row, landing on two different speakers:
    /// once the centroid is NaN, `cosineSimilarity` returns NaN for that
    /// entry forever and it can never match again.
    func test_an_unvalidated_negative_count_poisons_the_pool_centroid() {
        let diarizer = makeDiarizer()
        diarizer.reset()
        // Exactly what `seedPool` would have received from an unguarded load.
        diarizer.seedPool(with: [(id: "Alice", name: "Alice",
                                  centroid: aliceStored, sampleCount: -1)])

        // First utterance: a confident match, so it folds — divisor
        // `Float(-1 + 1)` == 0.
        XCTAssertEqual(diarizer.assign(embedding: aliceSpeaking), "SPEAKER_00",
                       "precondition: it must match confidently, or nothing folds")

        // Second, identical utterance from the same person: no longer Alice.
        XCTAssertEqual(diarizer.assign(embedding: aliceSpeaking), "SPEAKER_01",
                       "the poisoned centroid can never match again — this is the damage the guard prevents")
    }

    /// Positive control for the control: with a sound count the very same
    /// fixture matches both times, so the assertion above is discriminating
    /// rather than an artefact of the embeddings or the threshold.
    func test_a_sound_count_folds_and_keeps_matching() {
        let diarizer = makeDiarizer()
        diarizer.reset()
        diarizer.seedPool(with: [(id: "Alice", name: "Alice",
                                  centroid: aliceStored, sampleCount: 3)])

        XCTAssertEqual(diarizer.assign(embedding: aliceSpeaking), "SPEAKER_00")
        XCTAssertEqual(diarizer.assign(embedding: aliceSpeaking), "SPEAKER_00",
                       "a valid count folds cleanly and the speaker stays recognised")
    }

    /// End to end through the guard: the corrupt file yields an empty seed, so
    /// the speaker is minted fresh and — unlike the poisoned case — keeps
    /// matching itself.
    func test_with_the_guard_a_corrupt_file_costs_recognition_not_correctness() throws {
        try writeProfilesFile([profile(name: "Alice", embedding: aliceStored, sampleCount: -1)])
        let store = openStore()

        let diarizer = makeDiarizer()
        diarizer.reset()
        diarizer.seedPool(with: store.seedEntries())

        XCTAssertEqual(diarizer.assign(embedding: aliceSpeaking), "SPEAKER_00")
        XCTAssertEqual(diarizer.assign(embedding: aliceSpeaking), "SPEAKER_00",
                       "the pool still works — it just doesn't know this voice is Alice")
        XCTAssertNil(diarizer.currentProfiles().first?.profileName,
                     "and it is an unnamed speaker, not a mislabelled Alice")
    }

    /// The persistence side of the same divisor, and the reason this is worth
    /// catching at the boundary rather than at each fold: `updateProfile` and
    /// `mergeProfiles` compute their own weighted means, and a stored `-1`
    /// meeting one new sample makes `Float(totalCount)` zero there too. The
    /// resulting NaN is worse than an unrecognised speaker — `JSONEncoder`
    /// refuses to encode it, so `save()` throws and the store silently stops
    /// persisting *anything* for the rest of the session.
    ///
    /// Necessarily arithmetic rather than driven through the store: with the
    /// guard in place a `-1` can no longer reach `profiles` to be folded.
    func test_a_zero_divisor_fold_yields_a_value_that_cannot_be_saved() {
        let existingCount = -1   // as decoded from the file
        let newCount = 1         // one observation from this recording
        let totalCount = existingCount + newCount
        let merged = (Float(1) * Float(existingCount) + Float(1) * Float(newCount))
                     / Float(totalCount)

        XCTAssertTrue(merged.isNaN, "the weighted fold divides by Float(0)")
        XCTAssertThrowsError(try JSONEncoder().encode([merged]),
                             "and JSONEncoder refuses a NaN, so save() throws and nothing persists")
    }

    // MARK: - 2. A non-finite embedding never reaches the pool

    /// Checked on the value rather than through a file, because **JSON cannot
    /// carry a non-finite Float**: there is no NaN or Infinity literal, and a
    /// number too large for `Float` fails the parse (see the test below). The
    /// clause is the arithmetic invariant, asserted where it can be asserted;
    /// the negative control that follows is why it is worth stating at all.
    func test_a_non_finite_embedding_is_not_a_usable_profile() {
        XCTAssertNotNil(profile(name: "NaN", embedding: [.nan, 0, 0, 0], sampleCount: 4)
                            .unusableReason)
        XCTAssertNotNil(profile(name: "Inf", embedding: [1, .infinity, 0, 0], sampleCount: 4)
                            .unusableReason)
        XCTAssertNil(profile(name: "Alice", embedding: aliceStored, sampleCount: 4)
                        .unusableReason,
                     "positive control: a sound profile has no reason to be rejected")
    }

    /// The reachable half of the same story, and the one exception to
    /// per-entry dropping: a number the decoder cannot represent fails inside
    /// `decode`, before any entry exists, so the whole file is refused. The
    /// store is left empty rather than partially populated — and, crucially,
    /// does not go on to overwrite the file.
    func test_an_unrepresentable_number_rejects_the_whole_file() throws {
        try writeRawProfilesFile("""
        [{"id":"\(UUID().uuidString)","name":"Alice","embedding":[1e39,0,0,0],\
        "sampleCount":4,"createdAt":"2026-01-01T00:00:00Z","lastSeenAt":"2026-01-01T00:00:00Z"}]
        """)
        let before = try Data(contentsOf: profilesFile)

        let store = openStore()

        XCTAssertTrue(store.profiles.isEmpty, "1e39 overflows Float, so the parse fails outright")
        XCTAssertTrue(store.hasStoredProfilesOnDisk,
                      "…but Settings still knows there is a file to offer deleting")
        XCTAssertEqual(try Data(contentsOf: profilesFile), before, "and it is left untouched")
    }

    /// Negative control: a NaN centroid needs no fold to do damage. `assign`
    /// picks its best match with `sim > best.sim`, which is **false** for NaN,
    /// so a NaN entry that is reached first captures `best` and nothing can
    /// displace it — including the real, perfectly good profile behind it.
    func test_an_unvalidated_nan_centroid_shadows_the_real_profile() {
        let diarizer = makeDiarizer()
        diarizer.reset()
        diarizer.seedPool(with: [
            (id: "Corrupt", name: "Corrupt", centroid: [Float.nan, 0, 0, 0], sampleCount: 4),
            (id: "Alice", name: "Alice", centroid: aliceStored, sampleCount: 4)
        ])

        XCTAssertEqual(diarizer.assign(embedding: aliceSpeaking), "SPEAKER_02",
                       "Alice is at SPEAKER_01 and matches perfectly, but the NaN entry ahead of her wins `best`")
    }

    /// Positive control: drop the NaN entry — the only change — and Alice is
    /// found. Same embeddings, same threshold.
    func test_without_the_nan_entry_the_real_profile_is_found() {
        let diarizer = makeDiarizer()
        diarizer.reset()
        diarizer.seedPool(with: [(id: "Alice", name: "Alice",
                                  centroid: aliceStored, sampleCount: 4)])

        XCTAssertEqual(diarizer.assign(embedding: aliceSpeaking), "SPEAKER_00")
        XCTAssertEqual(diarizer.currentProfiles().first?.profileName, "Alice")
    }

    // MARK: - 3. An out-of-range sampleCount never reaches the arithmetic

    func test_an_int_max_sampleCount_is_dropped_at_load() throws {
        try writeProfilesFile([profile(name: "Alice", embedding: aliceStored, sampleCount: .max)])

        XCTAssertTrue(openStore().profiles.isEmpty,
                      "Int.max is not a sample count, it is a crash waiting for the next rename")
    }

    /// Negative control for the overflow, stated rather than executed: running
    /// the unguarded addition would trap and take the whole test runner with
    /// it, which is precisely the outcome under test. `addingReportingOverflow`
    /// asks the same question without dying of the answer.
    func test_the_unguarded_addition_would_have_trapped() {
        let stored = Int.max          // as decoded from the file
        let observed = 1              // one utterance, the ordinary case
        XCTAssertTrue(stored.addingReportingOverflow(observed).overflow,
                      "`existing.sampleCount + sampleCount` in updateProfile traps on these operands")

        // And the ceiling is chosen so that any two *valid* counts cannot:
        let ceiling = VoiceProfile.maxSampleCount
        XCTAssertFalse(ceiling.addingReportingOverflow(ceiling).overflow,
                       "two profiles at the ceiling must still be mergeable")
    }

    /// The ceiling admits every count a real store could ever hold, so the
    /// guard rejects corruption and nothing else.
    func test_a_large_but_plausible_sampleCount_still_loads() throws {
        try writeProfilesFile([profile(name: "Alice", embedding: aliceStored, sampleCount: 1_000_000)])

        XCTAssertEqual(openStore().profiles.first?.sampleCount, 1_000_000)
    }

    // MARK: - 4. Nothing to label with, or nothing to match against

    func test_a_nameless_or_embeddingless_profile_is_dropped_at_load() throws {
        try writeProfilesFile([
            profile(name: "", embedding: aliceStored, sampleCount: 4),
            profile(name: "   ", embedding: aliceStored, sampleCount: 4),
            profile(name: "Alice", embedding: [], sampleCount: 4)
        ])

        XCTAssertTrue(openStore().profiles.isEmpty,
                      "nothing to label with, or nothing to match against")
    }

    // MARK: - 5. One bad entry does not cost the good ones

    /// The decision on what to do with an invalid profile: drop that entry and
    /// log it, never reject the file. A single hand-broken profile must not
    /// destroy every other voice the user has trained.
    func test_a_corrupt_entry_does_not_take_the_rest_of_the_file_with_it() throws {
        try writeProfilesFile([
            profile(name: "Broken", embedding: aliceStored, sampleCount: -1),
            profile(name: "Alice", embedding: aliceStored, sampleCount: 40),
            profile(name: "Bob", embedding: [0, 1, 0, 0], sampleCount: 7)
        ])

        let store = openStore()

        XCTAssertEqual(store.profiles.map(\.name), ["Alice", "Bob"],
                       "the sound profiles survive, in order")
        XCTAssertNil(store.profile(named: "Broken"))
        XCTAssertEqual(store.seedEntries().count, 2)
    }

    /// And the drop is in memory only — `load` does not rewrite the file, so a
    /// user who broke it by hand can still fix it by hand.
    func test_dropping_an_entry_does_not_rewrite_the_file() throws {
        try writeProfilesFile([
            profile(name: "Broken", embedding: aliceStored, sampleCount: -1),
            profile(name: "Alice", embedding: aliceStored, sampleCount: 40)
        ])
        let before = try Data(contentsOf: profilesFile)

        _ = openStore()

        XCTAssertEqual(try Data(contentsOf: profilesFile), before,
                       "loading is a read; the bad entry stays on disk until something legitimately saves")
    }

    // MARK: - 6. The write path enforces the same invariants

    /// Read and write validate identically on purpose: the store must never
    /// accept something it would refuse to load back, or the profile would
    /// silently vanish on the next launch.
    func test_updateProfile_refuses_what_load_would_refuse() {
        let store = openStore()

        store.updateProfile(name: "NaN", embedding: [.nan, 0, 0, 0], sampleCount: 1)
        store.updateProfile(name: "Inf", embedding: [1, .infinity, 0, 0], sampleCount: 1)
        store.updateProfile(name: "TooMany", embedding: aliceStored, sampleCount: .max)
        store.updateProfile(name: "Negative", embedding: aliceStored, sampleCount: -1)
        store.updateProfile(name: "   ", embedding: aliceStored, sampleCount: 1)
        store.updateProfile(name: "Empty", embedding: [], sampleCount: 1)

        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: profilesFile.path),
                       "and nothing unusable was written to disk either")
    }

    /// Positive control: the same call with sound values does store.
    func test_updateProfile_still_accepts_a_sound_profile() {
        let store = openStore()

        store.updateProfile(name: "Alice", embedding: aliceStored, sampleCount: 1)

        XCTAssertEqual(store.profiles.map(\.name), ["Alice"])
    }

    /// Round trip: everything `updateProfile` accepted comes back on reload.
    /// The two guards agreeing is what this pins — a validator stricter than
    /// the writer would eat the user's profiles at launch.
    func test_everything_written_survives_a_reload() {
        do {
            let store = openStore()
            store.updateProfile(name: "Alice", embedding: aliceStored, sampleCount: 40)
            store.updateProfile(name: "Bob", embedding: [0, 1, 0, 0], sampleCount: 7)
            XCTAssertEqual(store.profiles.count, 2)
        }

        let reloaded = openStore()
        XCTAssertEqual(reloaded.profiles.map(\.name), ["Alice", "Bob"])
        XCTAssertEqual(reloaded.profiles.map(\.sampleCount), [40, 7])
    }
}
