import Foundation

/// The sender's choice of which voice profiles ride along in a `.milashare`.
///
/// `includeProfiles` is the opt-in and **always starts false** — it is never
/// persisted to `UserDefaults`, so every share begins with the privacy
/// default Settings promised ("the fingerprints stay on this Mac"). The
/// per-speaker exclusions exist for "share the recording and the others'
/// voices, but not my own".
struct SharedSpeakersExportSelection: Equatable {
    var includeProfiles = false
    /// Profiles this recording's named speakers have — what can be offered.
    let available: [VoiceProfile]
    var excludedNames: Set<String> = []

    init(available: [VoiceProfile]) {
        self.available = available
    }

    /// What actually goes in the manifest. Empty unless the master toggle
    /// is on.
    var selected: [VoiceProfile] {
        guard includeProfiles else { return [] }
        return available.filter { !excludedNames.contains($0.name) }
    }

    func isIncluded(_ profile: VoiceProfile) -> Bool {
        !excludedNames.contains(profile.name)
    }

    mutating func setIncluded(_ included: Bool, for profile: VoiceProfile) {
        if included { excludedNames.remove(profile.name) } else { excludedNames.insert(profile.name) }
    }
}

@MainActor
enum SharedSpeakerProfileExporter {

    /// The stored profiles for the speakers who are actually named in this
    /// recording's transcript. "All profiles" would ship voices of people who
    /// are not in the recording, which the recipient has no context for and
    /// the privacy copy cannot justify. Empty when voice recognition is off.
    static func availableProfiles(for recording: Recording,
                                  store: SpeakerProfileStore) -> [VoiceProfile] {
        store.profiles(named: namedSpeakers(in: recording))
    }

    /// Display names the transcript resolves to through `speakerNames`. If
    /// no segment carries a speaker id (an older or undiarized recording
    /// whose names map is nonetheless filled), every mapped name counts.
    static func namedSpeakers(in recording: Recording) -> Set<String> {
        let rawIDs = Set(recording.segments.compactMap(\.speaker))
        let names: [String]
        if rawIDs.isEmpty {
            names = Array(recording.speakerNames.values)
        } else {
            names = rawIDs.compactMap { recording.speakerNames[$0] }
        }
        return Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty })
    }

    /// Manifest entries for the selection. Pure, and `[]` unless the user
    /// ticked the box — the one thing the tests pin hardest.
    static func manifestEntries(_ selection: SharedSpeakersExportSelection) -> [SharedSpeakerProfile] {
        selection.selected.map {
            SharedSpeakerProfile(name: $0.name,
                                 embedding: $0.embedding,
                                 sampleCount: $0.sampleCount,
                                 embeddingModel: $0.effectiveEmbeddingModel)
        }
    }
}
