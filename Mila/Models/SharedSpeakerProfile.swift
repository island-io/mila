import Foundation

/// One voice profile as carried inside a `.milashare` bundle.
///
/// Deliberately **not** the local `VoiceProfile`:
///   * no `id` — a `VoiceProfile.id` is minted per Mac and means nothing on
///     another one; the receiver mints its own when it adds a profile;
///   * no `createdAt` / `lastSeenAt` — when the *sender* last heard this
///     person is metadata nobody on the receiving side needs;
///   * `embeddingModel` is **required** — vectors from different embedding
///     models are incomparable, and the receiver refuses to fold one it does
///     not recognise (see `SpeakerEmbeddingModel`).
///
/// Decoding is lenient (every key `decodeIfPresent`, with defaults that fail
/// validation downstream rather than failing the decode) so one odd profile
/// entry cannot make the whole manifest — and with it the recording — unreadable.
/// `SpeakerProfileImportResolver` turns an empty name, a missing model id or a
/// wrong-width vector into a per-row blocker.
struct SharedSpeakerProfile: Codable, Equatable, Hashable {
    var name: String
    var embedding: [Float]
    var sampleCount: Int
    /// e.g. `"pyannote-wespeaker-voxceleb-resnet34-LM"`.
    var embeddingModel: String

    init(name: String, embedding: [Float], sampleCount: Int, embeddingModel: String) {
        self.name = name
        self.embedding = embedding
        self.sampleCount = sampleCount
        self.embeddingModel = embeddingModel
    }

    private enum CodingKeys: String, CodingKey { case name, embedding, sampleCount, embeddingModel }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        embedding = try c.decodeIfPresent([Float].self, forKey: .embedding) ?? []
        sampleCount = try c.decodeIfPresent(Int.self, forKey: .sampleCount) ?? 0
        embeddingModel = try c.decodeIfPresent(String.self, forKey: .embeddingModel) ?? ""
    }
}

/// The speaker-embedding model Mila runs, and the width of the vectors it
/// produces. One place to answer "is this vector from the model we run?".
///
/// Only one model has ever shipped — the bundled
/// `Mila/Resources/DiarizationModels/pyannote-wespeaker-voxceleb-resnet34-LM`
/// (a ResNet34, loaded through pyannote 3.1's `pipeline._embedding`) — which
/// is why `VoiceProfile.effectiveEmbeddingModel` may default a legacy row
/// with no stamp to `current`. The day a second model ships, that default
/// stops being valid and a migration has to stamp existing rows explicitly.
struct SpeakerEmbeddingModel: Equatable {
    let id: String
    let dimension: Int

    static let current = SpeakerEmbeddingModel(
        id: "pyannote-wespeaker-voxceleb-resnet34-LM", dimension: 256)

    /// The model a stamp refers to, or nil for a stamp this build does not
    /// know — in which case the vector must not be folded into anything.
    static func known(id: String) -> SpeakerEmbeddingModel? {
        id == current.id ? current : nil
    }
}

/// A record that a particular shared profile from a particular bundle was
/// already folded into one of the receiver's profiles.
///
/// Lives **on the profile** (`VoiceProfile.importedShares`) rather than in a
/// side ledger so it is self-cleaning: deleting the profile — or every
/// profile — forgets the import with it, and importing the same bundle again
/// becomes legitimately possible. A separate ledger would have to be cleared
/// by `deleteProfile` / `deleteAllProfiles` too, and forgetting that is the
/// "revocation must be complete" class of bug (`bugbot-rules/consent-and-revocation.md`).
struct ImportedShareToken: Codable, Hashable {
    /// `ShareManifest.bundleID`, as a string.
    let bundleKey: String
    /// The profile's name **in the bundle** — the key the resolver looks the
    /// token up by, independent of what the receiver chose to call it.
    let sharedName: String
}
