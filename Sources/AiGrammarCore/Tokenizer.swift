import Foundation

/// Pure text utilities for the spellcheck pipeline (Phase 2). Kept free of AppKit so it unit-tests
/// without the app event loop. Placeholder for now — the tokenizer and confidence rules land here.
public enum Tokenizer {
    /// Splits text into word tokens with their NSString ranges, so corrections can be mapped back
    /// to exact character positions in the composer.
    public struct Token: Equatable {
        public let text: String
        public let range: NSRange
        public init(text: String, range: NSRange) {
            self.text = text
            self.range = range
        }
    }

    public static func words(in text: String) -> [Token] {
        var tokens: [Token] = []
        let ns = text as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.byWords, .localized]) { sub, range, _, _ in
            if let sub { tokens.append(Token(text: sub, range: range)) }
        }
        return tokens
    }
}
