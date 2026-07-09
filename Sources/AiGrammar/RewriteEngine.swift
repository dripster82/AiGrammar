import AppKit
import AiGrammarCore

/// What the user asked for — one of the four presets, or a free-text custom instruction. Carries
/// the LLM system prompt used by the on-device model.
enum RewriteInstruction: Identifiable, Equatable {
    case fixGrammar, clearer, shorter, professional
    case custom(String)

    /// The four one-tap presets shown as buttons (custom comes from the text box).
    static let presets: [RewriteInstruction] = [.fixGrammar, .clearer, .shorter, .professional]

    var id: String {
        switch self {
        case .fixGrammar: return "fixGrammar"
        case .clearer: return "clearer"
        case .shorter: return "shorter"
        case .professional: return "professional"
        case .custom: return "custom"
        }
    }
    var label: String {
        switch self {
        case .fixGrammar: return "Fix grammar"
        case .clearer: return "Make clearer"
        case .shorter: return "Shorten"
        case .professional: return "More professional"
        case .custom: return "Custom"
        }
    }
    var icon: String {
        switch self {
        case .fixGrammar: return "checkmark.circle"
        case .clearer: return "sparkles"
        case .shorter: return "arrow.down.right.and.arrow.up.left"
        case .professional: return "briefcase"
        case .custom: return "text.bubble"
        }
    }
    /// Tooltip explaining what each preset does.
    var help: String {
        switch self {
        case .fixGrammar: return "Fix spelling and grammar, keeping your wording"
        case .clearer: return "Reword it to be clearer and easier to read"
        case .shorter: return "Make it more concise"
        case .professional: return "Rewrite in a more professional tone"
        case .custom: return "Your own instruction"
        }
    }
    /// System instructions for the LLM. Strict about returning ONLY the message so the model does
    /// not echo the prompt or add preamble. The shared preamble is exposed as `Self.basePrompt`.
    static let basePrompt =
        "You are a writing assistant editing a single Slack message. Rewrite the message "
        + "and return ONLY the rewritten message text — no preamble, no explanation, no labels "
        + "such as \"Message:\", and no surrounding quotation marks. Preserve the meaning and keep "
        + "any @mentions, #channels, links, and code unchanged. Keep the tone casual and concise."

    var prompt: String {
        switch self {
        case .fixGrammar:   return Self.basePrompt + " Focus on fixing spelling and grammar, keeping the wording close to the original."
        case .clearer:      return Self.basePrompt + " Make it clearer and easier to read."
        case .shorter:      return Self.basePrompt + " Make it more concise while keeping the key points."
        case .professional: return Self.basePrompt + " Use a more professional tone."
        case .custom(let ask): return Self.basePrompt + " Follow this instruction from the user: \(ask)"
        }
    }
}

/// Shared post-processing for LLM output (used by every backend).
enum RewriteText {
    /// What to SHOW for a cumulative stream snapshot: hides reasoning-model `<think>…</think>`
    /// blocks (showing "Thinking…" until they close), then strips preamble/labels/quotes and any
    /// trailing meta note. Engines yield `display(cumulative)`.
    static func display(_ raw: String) -> String {
        if raw.contains("<think>") {
            guard let end = raw.range(of: "</think>") else { return "Thinking…" }
            return finalize(String(raw[end.upperBound...]))
        }
        return finalize(raw)
    }

    /// Terminal snapshot (stream finished): like `display`, but if the reasoning never closed
    /// (`<think>` with no `</think>`), show the reasoning content itself rather than a stuck
    /// "Thinking…" — the model likely ran out of tokens before answering.
    static func finalDisplay(_ raw: String) -> String {
        if raw.contains("<think>"), !raw.contains("</think>") {
            return finalize(raw.replacingOccurrences(of: "<think>", with: ""))
        }
        return display(raw)
    }

    private static func finalize(_ raw: String) -> String {
        stripTrailingNote(clean(raw))
    }

    /// Drop trailing blank lines and a trailing parenthetical note the model sometimes appends to
    /// explain its edits, e.g. "(Revised for clarity, tone… preserving @mentions.)".
    private static func stripTrailingNote(_ s: String) -> String {
        var lines = s.components(separatedBy: "\n")
        let meta = ["revis", "rewrit", "clarity", "tone", "preserv", "correct", "change",
                    "edited", "concise", "kept", "maintain", "professional", "note:"]
        while let last = lines.last {
            let t = last.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { lines.removeLast(); continue }
            if t.hasPrefix("("), t.hasSuffix(")"),
               meta.contains(where: { t.lowercased().contains($0) }) {
                lines.removeLast(); continue
            }
            break
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strip preamble/labels/quotes some models add despite instructions. The reliable signal is a
    /// leading line that ends with a colon ("Here's a rewritten version:", "Message:") — real
    /// message content almost never starts that way — so we drop such lines, then any inline opener.
    static func clean(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let nl = t.firstIndex(of: "\n") {
            let firstLine = String(t[t.startIndex..<nl]).trimmingCharacters(in: .whitespaces)
            if firstLine.count < 80 && firstLine.hasSuffix(":") {
                t = String(t[t.index(after: nl)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                break
            }
        }
        if !t.contains("\n"), let colon = t.range(of: ": ") {
            let lead = t[t.startIndex..<colon.lowerBound].lowercased()
            let openers = ["here", "sure", "certainly", "rewritten", "message", "revised", "okay", "ok"]
            if lead.count < 60 && openers.contains(where: { lead.hasPrefix($0) }) {
                t = String(t[colon.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if t.count > 1, t.hasPrefix("\""), t.hasSuffix("\"") {
            t = String(t.dropFirst().dropLast())
        }
        return t
    }
}

/// A streaming rewrite backend. `rewrite` yields the cumulative text as it is produced, so the
/// popover can render it live (token-by-token for a real LLM; word-by-word for the heuristic).
/// `systemPrompt` is the (user-editable) instruction for the LLM; the heuristic ignores it and
/// works off `instruction`.
protocol RewriteEngine {
    var displayName: String { get }
    var isLocalModel: Bool { get }
    func rewrite(_ text: String, instruction: RewriteInstruction, systemPrompt: String) -> AsyncStream<String>
}

/// On-device rewriter with NO model — deterministic text cleanup using the same `NSSpellChecker`
/// and rules as the spellcheck pipeline. This is the working default and the fallback when no MLC
/// model is active. It genuinely improves messages (spelling, capitalization, spacing, filler,
/// contractions) but is NOT a language model — that is the MLC backend, wired separately.
final class HeuristicRewriter: RewriteEngine {
    var displayName: String { "Built-in cleanup (no model)" }
    var isLocalModel: Bool { false }

    private let checker = NSSpellChecker.shared

    func rewrite(_ text: String, instruction: RewriteInstruction, systemPrompt: String) -> AsyncStream<String> {
        let result = transform(text, instruction)
        return AsyncStream { continuation in
            Task {
                let words = result.split(separator: " ", omittingEmptySubsequences: false)
                var shown = ""
                for (i, word) in words.enumerated() {
                    shown += (i == 0 ? "" : " ") + word
                    continuation.yield(shown)
                    try? await Task.sleep(nanoseconds: 25_000_000)
                }
                if words.isEmpty { continuation.yield(result) }
                continuation.finish()
            }
        }
    }

    // MARK: Transforms

    private func transform(_ text: String, _ instruction: RewriteInstruction) -> String {
        var out = fixSpelling(text)
        out = fixStandaloneI(out)
        if instruction == .shorter || instruction == .clearer {
            out = removeFiller(out)
        }
        if instruction == .professional {
            out = expandContractions(out)
            out = removeCasualisms(out)
        }
        out = normalizeSpacing(out)
        out = capitalizeSentences(out)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fixSpelling(_ text: String) -> String {
        let ns = text as NSString
        var result = text
        // Work back-to-front so earlier ranges stay valid as we splice.
        for token in Tokenizer.words(in: text).reversed() {
            guard !WordClassifier.shouldSkip(token.text) else { continue }
            if let curated = AutocorrectPolicy.autocorrection(for: token.text) {
                result = (result as NSString).replacingCharacters(in: token.range, with: curated)
                continue
            }
            let misspelled = checker.checkSpelling(of: token.text, startingAt: 0)
            if misspelled.location != NSNotFound,
               let guess = checker.guesses(forWordRange: NSRange(location: 0, length: (token.text as NSString).length),
                                           in: token.text, language: nil, inSpellDocumentWithTag: 0)?.first,
               EditDistance.levenshtein(token.text.lowercased(), guess.lowercased()) <= 2 {
                let cased = AutocorrectPolicy.applyingCase(of: token.text, to: guess)
                result = (result as NSString).replacingCharacters(in: token.range, with: cased)
            }
        }
        _ = ns
        return result
    }

    private func fixStandaloneI(_ text: String) -> String {
        var result = text
        for pattern in [" i ", " i'"] {
            result = result.replacingOccurrences(of: pattern, with: pattern.uppercased())
        }
        if result.hasPrefix("i ") { result = "I " + result.dropFirst(2) }
        return result
    }

    private let fillers = ["really", "very", "just", "actually", "basically", "literally", "simply"]
    private func removeFiller(_ text: String) -> String {
        var result = text
        for f in fillers {
            result = result.replacingOccurrences(
                of: "\\b\(f)\\s", with: "", options: [.regularExpression, .caseInsensitive])
        }
        return result
    }

    private let contractions: [String: String] = [
        "don't": "do not", "can't": "cannot", "won't": "will not", "i'm": "I am",
        "it's": "it is", "that's": "that is", "there's": "there is", "we're": "we are",
        "they're": "they are", "you're": "you are", "isn't": "is not", "aren't": "are not",
        "wasn't": "was not", "weren't": "were not", "i've": "I have", "we've": "we have",
        "i'll": "I will", "we'll": "we will", "let's": "let us",
    ]
    private func expandContractions(_ text: String) -> String {
        var result = text
        for (short, long) in contractions {
            result = result.replacingOccurrences(
                of: "\\b\(NSRegularExpression.escapedPattern(for: short))\\b",
                with: long, options: [.regularExpression, .caseInsensitive])
        }
        return result
    }

    private func removeCasualisms(_ text: String) -> String {
        var result = text
        for w in ["lol", "haha", "hah", "yeah", "yep", "nope", "gonna", "wanna"] {
            result = result.replacingOccurrences(
                of: "\\b\(w)\\b\\s?", with: "", options: [.regularExpression, .caseInsensitive])
        }
        return result
    }

    private func normalizeSpacing(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\s+([,.!?;:])", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "([,.!?;:])(?=\\S)", with: "$1 ", options: .regularExpression)
        return result
    }

    private func capitalizeSentences(_ text: String) -> String {
        let ns = text as NSString
        let result = NSMutableString(string: text)
        var capitalizeNext = true
        for i in 0..<ns.length {
            let ch = ns.substring(with: NSRange(location: i, length: 1))
            if capitalizeNext, ch.rangeOfCharacter(from: .letters) != nil {
                result.replaceCharacters(in: NSRange(location: i, length: 1), with: ch.uppercased())
                capitalizeNext = false
            } else if ".!?".contains(ch) {
                capitalizeNext = true
            }
        }
        return result as String
    }
}
