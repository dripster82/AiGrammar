import Foundation

/// Decides which tokens are eligible for spellcheck/autocorrect. Implements the design doc's
/// "do not autocorrect" list: names(-ish), technical terms, code, URLs, Slack mentions, emoji
/// shortcodes, commands, acronyms, camelCase / snake_case. Pure and unit-tested.
public enum WordClassifier {
    /// Structural characters that mark a token as code/URL/mention/handle rather than prose.
    private static let structural = CharacterSet(charactersIn: "/:@#_-.\\~&%$*+=<>|")

    /// True when the token should be left completely alone (not flagged, not corrected).
    public static func shouldSkip(_ word: String) -> Bool {
        if word.count < 2 { return true }
        if word.rangeOfCharacter(from: structural) != nil { return true }
        if word.rangeOfCharacter(from: .decimalDigits) != nil { return true }
        if isAllCaps(word) { return true }          // acronyms: NASA, API
        if hasInternalCapital(word) { return true } // camelCase, PascalCase mid-word
        return false
    }

    static func isAllCaps(_ word: String) -> Bool {
        let letters = word.filter { $0.isLetter }
        guard letters.count >= 2 else { return false }
        return letters == letters.uppercased()
    }

    /// A capital anywhere after the first character → camelCase/PascalCase/Type name.
    static func hasInternalCapital(_ word: String) -> Bool {
        word.dropFirst().contains { $0.isUppercase }
    }
}
