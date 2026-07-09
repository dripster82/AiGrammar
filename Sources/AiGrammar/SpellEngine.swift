import AppKit
import AiGrammarCore

/// One flagged word in the composer, with where it is, what to replace it with, and how confident
/// we are (which drives autocorrect vs suggestion).
struct SpellIssue {
    let range: NSRange          // NSString range within the composer text
    let word: String
    let guesses: [String]
    let disposition: Disposition

    /// Best replacement: the curated high-confidence correction if any, else the spellchecker's
    /// top guess.
    var topGuess: String? {
        AutocorrectPolicy.autocorrection(for: word) ?? guesses.first
    }
}

/// Local dictionary spellcheck via macOS `NSSpellChecker` (same engine as system-wide spellcheck —
/// on-device, no network), filtered through the pure `WordClassifier`/`AutocorrectPolicy` rules.
final class SpellEngine {
    private let checker = NSSpellChecker.shared
    private let tag = NSSpellChecker.uniqueSpellDocumentTag()

    func issues(in text: String) -> [SpellIssue] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        var byLocation: [Int: SpellIssue] = [:]

        // 1) Curated high-confidence typos, checked directly against the token stream. macOS's
        // spellchecker silently tolerates some common slips (e.g. "teh"), so we cannot rely on it
        // to surface these — the whole point of the curated list is to catch them regardless.
        for token in Tokenizer.words(in: text) {
            guard !WordClassifier.shouldSkip(token.text),
                  let correction = AutocorrectPolicy.autocorrection(for: token.text) else { continue }
            byLocation[token.range.location] = SpellIssue(
                range: token.range, word: token.text,
                guesses: [correction], disposition: .autocorrect)
        }

        // 2) Everything else via the system spellchecker. Use `check(...)`, which returns ALL
        // misspellings in one pass — the iterative `checkSpelling(startingAt:language:nil)` API
        // silently stops after the first misspelling, so it missed later typos like "piut".
        let fullRange = NSRange(location: 0, length: ns.length)
        let results = checker.check(text, range: fullRange,
                                    types: NSTextCheckingResult.CheckingType.spelling.rawValue,
                                    options: nil, inSpellDocumentWithTag: tag,
                                    orthography: nil, wordCount: nil)
        for result in results {
            let range = result.range
            guard range.length > 0, byLocation[range.location] == nil else { continue }

            let word = ns.substring(with: range)
            if WordClassifier.shouldSkip(word) { continue }

            let guesses = checker.guesses(forWordRange: range, in: text, language: nil,
                                          inSpellDocumentWithTag: tag) ?? []
            let distance = guesses.first
                .map { EditDistance.levenshtein(word.lowercased(), $0.lowercased()) } ?? 99
            let disposition = AutocorrectPolicy.classify(
                word: word, topGuess: guesses.first, editDistance: distance,
                singleGuess: guesses.count == 1)
            guard disposition != .ignore else { continue }

            byLocation[range.location] = SpellIssue(
                range: range, word: word, guesses: guesses, disposition: disposition)
        }

        return byLocation.values.sorted { $0.range.location < $1.range.location }
    }
}
