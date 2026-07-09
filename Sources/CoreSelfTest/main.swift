import AiGrammarCore
import Foundation

// Lightweight assertion-based test runner (XCTest requires full Xcode; only Command Line Tools
// are installed). Exits non-zero on any failure so it can gate CI later.
var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("  ✓ \(msg)") }
    else { print("  ✗ \(msg)"); failures += 1 }
}

print("WordClassifier")
for w in ["https://x.com", "@sam", "#general", ":smile:", "snake_case", "kebab-case",
          "v1.2", "NASA", "camelCase"] {
    check(WordClassifier.shouldSkip(w), "skips \(w)")
}
for w in ["teh", "sentence", "The", "hello", "receive"] {
    check(!WordClassifier.shouldSkip(w), "allows \(w)")
}

print("AutocorrectPolicy")
check(AutocorrectPolicy.classify(word: "teh", topGuess: "the", editDistance: 2) == .autocorrect,
      "teh → autocorrect")
check(AutocorrectPolicy.autocorrection(for: "teh") == "the", "teh corrects to the")
check(AutocorrectPolicy.autocorrection(for: "Teh") == "The", "case preserved (Teh→The)")
check(AutocorrectPolicy.autocorrection(for: "TEH") == "THE", "case preserved (TEH→THE)")
check(AutocorrectPolicy.classify(word: "@sam", topGuess: "sam", editDistance: 1) == .ignore,
      "@sam → ignore")
check(AutocorrectPolicy.classify(word: "helllo", topGuess: "hello", editDistance: 1) == .suggest,
      "helllo → suggest")
check(AutocorrectPolicy.classify(word: "xq", topGuess: "aardvark", editDistance: 7) == .ignore,
      "wild guess → ignore")

print("EditDistance")
check(EditDistance.levenshtein("teh", "the") == 2, "teh/the = 2")
check(EditDistance.levenshtein("kitten", "sitting") == 3, "kitten/sitting = 3")

print("Tokenizer")
check(Tokenizer.words(in: "hello there world").map(\.text) == ["hello", "there", "world"],
      "splits words")

print(failures == 0 ? "\nAll passed." : "\n\(failures) FAILED.")
exit(failures == 0 ? 0 : 1)
