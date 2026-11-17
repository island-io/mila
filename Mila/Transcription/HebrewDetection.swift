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

    /// True when more of this string's letters belong to a right-to-left
    /// script (Hebrew, Arabic, Syriac, Thaana, N'Ko, …) than to any other.
    /// The script-agnostic form of `isPredominantlyHebrew`, for layout: a
    /// recording can be in any language the user added, so an Arabic
    /// transcript or a Russian summary needs a verdict of its own.
    var isPredominantlyRTL: Bool {
        let counts = directionalLetterCounts
        return counts.rtl > counts.ltr
    }

    /// Whether `isPredominantlyRTL` has anything to go on: false for a
    /// string with no letters at all (empty, digits, punctuation), so a
    /// caller can fall back to the recording's language instead.
    var hasDirectionalLetters: Bool {
        let counts = directionalLetterCounts
        return counts.rtl > 0 || counts.ltr > 0
    }

    private var directionalLetterCounts: (rtl: Int, ltr: Int) {
        var rtl = 0
        var ltr = 0
        for scalar in unicodeScalars where scalar.properties.isAlphabetic {
            if Self.isRTLScalar(scalar.value) { rtl += 1 } else { ltr += 1 }
        }
        return (rtl, ltr)
    }

    /// Hebrew through the Arabic Extended blocks (U+0590–U+08FF: Hebrew,
    /// Arabic, Syriac, Thaana, N'Ko, Samaritan, Mandaic) plus the Hebrew and
    /// Arabic presentation forms.
    private static func isRTLScalar(_ v: UInt32) -> Bool {
        (0x0590...0x08FF).contains(v) || (0xFB1D...0xFDFF).contains(v) || (0xFE70...0xFEFF).contains(v)
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
