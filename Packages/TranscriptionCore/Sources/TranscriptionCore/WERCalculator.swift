import Foundation

public enum WERCalculator {
    public static func calculate(reference: String, hypothesis: String) -> Double {
        let ref = tokenize(reference)
        let hyp = tokenize(hypothesis)

        if ref.isEmpty && hyp.isEmpty { return 0 }
        if ref.isEmpty { return 1.0 }

        // Standard Levenshtein distance on word tokens
        var dp = Array(repeating: Array(repeating: 0, count: hyp.count + 1), count: ref.count + 1)
        for i in 0...ref.count { dp[i][0] = i }
        for j in 0...hyp.count { dp[0][j] = j }

        for i in 1...ref.count {
            for j in 1...hyp.count {
                let cost = ref[i - 1] == hyp[j - 1] ? 0 : 1
                dp[i][j] = min(
                    dp[i - 1][j] + 1,      // deletion
                    dp[i][j - 1] + 1,      // insertion
                    dp[i - 1][j - 1] + cost // substitution
                )
            }
        }

        return min(1.0, Double(dp[ref.count][hyp.count]) / Double(ref.count))
    }

    private static func tokenize(_ text: String) -> [String] {
        // Fold typographic apostrophes to ASCII before the punctuation
        // strip. The filter below exempts only U+0027, so "don’t" (smart
        // quote U+2019, what most editors auto-insert) tokenized to "dont"
        // while "don't" stayed "don't" — every contraction counted as a
        // substitution when reference and hypothesis disagreed on the
        // apostrophe form. Same for Hebrew geresh (U+05F3, ג׳ון) and the
        // modifier-letter apostrophe (U+02BC).
        let folded = text
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{05F3}", with: "'")
            .replacingOccurrences(of: "\u{02BC}", with: "'")
        let stripped = folded.unicodeScalars.filter { char in
            !CharacterSet.punctuationCharacters.contains(char) || CharacterSet(charactersIn: "'").contains(char)
        }
        return String(stripped)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
    }
}
