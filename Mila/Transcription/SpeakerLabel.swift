import Foundation
import TranscriptionCore

/// Translation of the diarizer's raw `SPEAKER_00` / `SPEAKER_01` /…
/// identifiers into a label the user actually wants to see — `Speaker A`
/// in English, `דובר א׳` in Hebrew.
///
/// The raw labels stay in the internal data model (segment metadata)
/// because they're stable across runs and tooling outside Mila
/// (pyannote, third-party re-clustering scripts) expects them. The
/// conversion happens at display/export time and when feeding text to
/// the LLM, so the LLM sees the same labels the user sees and emits
/// them back the same way. When the user has assigned a real name to a
/// speaker (`Recording.speakerNames`), that name wins everywhere —
/// UI, clipboard, `.srt` sidecar, LLM feed — via
/// `displaySpeakerName(names:language:)`.
extension String {
    /// The label to show/export for this raw speaker ID: the
    /// user-assigned name when one exists, otherwise the friendly
    /// "Speaker A" / "דובר א׳" fallback.
    func displaySpeakerName(names: [String: String], language: String) -> String {
        if let name = names[self]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return friendlySpeakerLabel(language: language)
    }

    func friendlySpeakerLabel(language: String) -> String {
        guard self.hasPrefix("SPEAKER_") else { return self }
        let suffix = self.dropFirst("SPEAKER_".count)
        guard let n = Int(suffix), n >= 0 else { return self }
        switch language {
        case "he":
            return "דובר \(hebrewOrdinal(n))"
        default:
            return "Speaker \(latinLetter(n))"
        }
    }

    private func latinLetter(_ index: Int) -> String {
        if index < 26 {
            let scalar = UnicodeScalar(UInt8(0x41) + UInt8(index))
            return String(Character(scalar))
        }
        // Wrap around: AA, BB, ... beyond the 26th speaker (extremely
        // unlikely in any real call). Keeps the helper total without
        // an arbitrary cap.
        let letter = String(Character(UnicodeScalar(UInt8(0x41) + UInt8(index % 26))))
        return letter + "\(index / 26 + 1)"
    }

    /// Hebrew "ordinal" letters: א׳, ב׳, ג׳ … Falls back to a numeric
    /// suffix beyond the 22-letter alphabet because we don't try to
    /// build multi-letter Hebrew sequences — anyone hitting that case
    /// has bigger problems than a label format.
    private func hebrewOrdinal(_ index: Int) -> String {
        let letters = ["א", "ב", "ג", "ד", "ה", "ו", "ז", "ח", "ט", "י",
                       "כ", "ל", "מ", "נ", "ס", "ע", "פ", "צ", "ק", "ר",
                       "ש", "ת"]
        if index < letters.count {
            return "\(letters[index])׳"
        }
        return "\(index + 1)"
    }
}

/// Canonicalisation of raw speaker IDs, kept out of `TranscriptionService` so
/// it is reachable from non-`@MainActor` code (`RemoteWhisperEngine`, which
/// has to re-key the labels a server-side diarizer returns).
enum SpeakerLabels {
    /// Re-key every speaker ID in `segments` to a sequential `SPEAKER_NN` in
    /// order of first appearance.
    ///
    /// Two reasons this exists. Pyannote's clustering can leave gaps
    /// (`SPEAKER_00` then `SPEAKER_02` when an intermediate cluster is merged
    /// away), which surfaces as "Speaker A" + "Speaker C" with no B. And a
    /// remote diarization model uses a different label space altogether
    /// (`"A"`, `"B"`, …), which `friendlySpeakerLabel(language:)` would pass
    /// through verbatim — English-looking labels in a Hebrew transcript, and
    /// no stable key for `Recording.speakerNames`. Both become 00, 01, 02… in
    /// transcript order.
    ///
    /// Segments with no label (or an empty one) are left exactly as they are.
    static func normalized(in segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var mapping: [String: String] = [:]
        var nextIndex = 0
        var output = segments
        for i in output.indices {
            guard let original = output[i].speaker, !original.isEmpty else { continue }
            if let remapped = mapping[original] {
                output[i].speaker = remapped
            } else {
                let remapped = String(format: "SPEAKER_%02d", nextIndex)
                mapping[original] = remapped
                output[i].speaker = remapped
                nextIndex += 1
            }
        }
        return output
    }
}
