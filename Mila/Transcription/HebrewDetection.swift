import Foundation

extension String {
    /// True when more of this string's letter characters are Hebrew than
    /// Latin. Used by the UI to flip a piece of transcript / action item
    /// text to RTL alignment without depending on the user's language
    /// dropdown — the dropdown affects which whisper model is used but
    /// not which alphabet ends up in any given segment (the user might
    /// have left it on English while talking Hebrew, for example).
    ///
    /// We count only "letter-like" code points so quoted English brand
    /// names embedded in a Hebrew sentence ("...אמרתי Cursor...") don't
    /// flip the verdict.
    var isPredominantlyHebrew: Bool {
        let counts = hebrewAndLatinLetterCounts
        return counts.hebrew > counts.latin
    }

    /// Whether `isPredominantlyHebrew` has anything to go on. For a string
    /// with no letters of either script (empty, digits, punctuation) the
    /// verdict is "not Hebrew" by default, which callers that want a
    /// different fallback — e.g. the recording's own language — must be
    /// able to tell apart from a genuine Latin-script majority.
    var hasHebrewOrLatinLetters: Bool {
        let counts = hebrewAndLatinLetterCounts
        return counts.hebrew > 0 || counts.latin > 0
    }

    private var hebrewAndLatinLetterCounts: (hebrew: Int, latin: Int) {
        var hebrew = 0
        var latin = 0
        for scalar in self.unicodeScalars {
            let value = scalar.value
            // Hebrew block: U+0590..U+05FF (also covers final-form
            // letters + cantillation marks).
            if value >= 0x0590 && value <= 0x05FF {
                hebrew += 1
            } else if (value >= 0x0041 && value <= 0x005A)
                   || (value >= 0x0061 && value <= 0x007A) {
                latin += 1
            }
        }
        return (hebrew, latin)
    }
}
