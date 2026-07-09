import Foundation

/// How confident we are about a fix, which decides the UX: apply silently (with undo), offer a
/// suggestion, or say nothing.
public enum Disposition: Equatable {
    case autocorrect   // very high confidence — apply, show undo chip
    case suggest       // plausible — show popover, wait for the user
    case ignore        // don't surface
}

/// The autocorrect gate. Per the design doc, autocorrect fires ONLY for a curated set of
/// unambiguous typos; everything else from the system spellchecker is suggestion-only, so we never
/// silently rewrite names, jargon, or anything the user might have meant.
public enum AutocorrectPolicy {
    /// Curated high-confidence corrections. Keys are lowercase; matching preserves the original
    /// word's capitalization when applied (see `applyingCase`).
    public static let highConfidence: [String: String] = [
        "teh": "the", "hte": "the", "the​": "the",
        "adn": "and", "nad": "and", "anf": "and",
        "recieve": "receive", "recieved": "received", "reciept": "receipt",
        "wierd": "weird", "freind": "friend", "beleive": "believe",
        "seperate": "separate", "definately": "definitely", "occured": "occurred",
        "untill": "until", "wich": "which", "becuase": "because", "beacuse": "because",
        "cheking": "checking", "sentenace": "sentence", "thier": "their",
        "acheive": "achieve", "accross": "across", "agian": "again",
        "alot": "a lot", "arent": "aren't", "cant": "can't", "dont": "don't",
        "doesnt": "doesn't", "isnt": "isn't", "wasnt": "wasn't", "wont": "won't",
        "wouldnt": "wouldn't", "couldnt": "couldn't", "shouldnt": "shouldn't",
        "im": "I'm", "ive": "I've", "id": "I'd", "youre": "you're", "thats": "that's",
        "hasnt": "hasn't", "havent": "haven't", "didnt": "didn't",
        "tommorow": "tomorrow", "tomorow": "tomorrow", "definetly": "definitely",
        "enviroment": "environment", "goverment": "government", "neccessary": "necessary",
        "occassion": "occasion", "publically": "publicly", "recomend": "recommend",
        "refered": "referred", "succesful": "successful", "successfull": "successful",
        "wanna": "want to", "gonna": "going to", "prob": "probably",
        "thanx": "thanks", "thx": "thanks", "pls": "please", "plz": "please",
    ]

    /// Decide what to do with a flagged word.
    /// - Parameters:
    ///   - word: the misspelled token as it appears in the text.
    ///   - topGuess: the spellchecker's best guess (may be nil).
    ///   - editDistance: Levenshtein distance between word and topGuess.
    /// - Parameter singleGuess: true when the spellchecker offered exactly ONE correction — i.e. the
    ///   fix is unambiguous.
    public static func classify(word: String, topGuess: String?, editDistance: Int,
                                singleGuess: Bool = false) -> Disposition {
        if WordClassifier.shouldSkip(word) { return .ignore }
        if highConfidence[word.lowercased()] != nil { return .autocorrect }
        guard let guess = topGuess, !guess.isEmpty else { return .ignore }
        // A wildly different guess (edit distance too large relative to the word) is nonsense — drop it.
        if editDistance > max(2, word.count / 2) { return .ignore }
        // A misspelling with a single, close correction (e.g. "knowlefge" → "knowledge") is
        // unambiguous — autocorrect it (with an undo chip), like the curated list.
        if singleGuess, editDistance <= 2, word.count >= 4 { return .autocorrect }
        // Otherwise the system spellchecker's suggestions are advisory only (ambiguous).
        return .suggest
    }

    /// The replacement string for an autocorrect hit, matching the original's capitalization.
    public static func autocorrection(for word: String) -> String? {
        guard let base = highConfidence[word.lowercased()] else { return nil }
        return applyingCase(of: word, to: base)
    }

    /// Mirror simple capitalization: "Teh" → "The", "TEH" → "THE", "teh" → "the".
    public static func applyingCase(of source: String, to target: String) -> String {
        if source == source.uppercased() && source != source.lowercased() {
            return target.uppercased()
        }
        if let first = source.first, first.isUppercase {
            return target.prefix(1).uppercased() + target.dropFirst()
        }
        return target
    }
}
