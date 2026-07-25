import Foundation

extension String {
    /// Per-script counts of "letter-like" Unicode scalars in the string.
    /// Hebrew, Latin, and Cyrillic are the only scripts we weigh when
    /// deciding transcript/AI-output alignment and language auto-routing.
    /// Counting only these keeps quoted English brand names embedded in a
    /// Hebrew sentence ("...אמרתי Cursor...") or a stray Latin token in
    /// Russian text from flipping the verdict.
    private var scriptCounts: (hebrew: Int, latin: Int, cyrillic: Int) {
        var hebrew = 0
        var latin = 0
        var cyrillic = 0
        for scalar in self.unicodeScalars {
            let value = scalar.value
            if value >= 0x0400 && value <= 0x04FF {
                // Cyrillic block.
                cyrillic += 1
            } else if value >= 0x0590 && value <= 0x05FF {
                // Hebrew block: U+0590..U+05FF (covers final-form letters +
                // cantillation marks).
                hebrew += 1
            } else if (value >= 0x0041 && value <= 0x005A)
                   || (value >= 0x0061 && value <= 0x007A) {
                latin += 1
            }
        }
        return (hebrew, latin, cyrillic)
    }

    /// True when Hebrew is the strict plurality of the string's letter-like
    /// characters — i.e. there are more Hebrew letters than Latin *and* more
    /// than Cyrillic. Used by the UI to flip a piece of transcript / action
    /// item text to RTL alignment without depending on the user's language
    /// dropdown — the dropdown affects which whisper model is used but not
    /// which alphabet ends up in any given segment (the user might have left
    /// it on English while talking Hebrew, for example).
    ///
    /// Cyrillic must be weighed here, not just Latin: Russian is an LTR script,
    /// so a Russian-dominant segment with a handful of Hebrew words must NOT
    /// be classified as Hebrew, or it gets rendered right-to-left.
    var isPredominantlyHebrew: Bool {
        let (hebrew, latin, cyrillic) = scriptCounts
        return hebrew > 0 && hebrew > latin && hebrew > cyrillic
    }

    /// True when Cyrillic is the strict plurality of the string's letter-like
    /// characters — more Cyrillic than Latin *and* more than Hebrew. Mirrors
    /// `isPredominantlyHebrew` so the two predicates are mutually exclusive
    /// (mixed Hebrew/Russian text resolves to exactly one verdict rather
    /// than depending on which predicate the caller happens to check first).
    var isPredominantlyCyrillic: Bool {
        let (hebrew, latin, cyrillic) = scriptCounts
        return cyrillic > 0 && cyrillic > latin && cyrillic > hebrew
    }
}