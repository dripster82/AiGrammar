import Foundation
import AiGrammarCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Model-based, context-aware spell/word-choice checker. Given a short message it asks the chosen
/// model which words are misspelled OR the wrong word for the context (their/there, form/from,
/// affect/effect) and for 1–3 ordered corrections. Runs fully on-device — a local GGUF model via a
/// dedicated `llama-server` (JSON-schema-constrained output), or Apple's on-device model.
///
/// Output is mapped back to `SpellIssue`s (disposition `.suggest`) so it plugs straight into the
/// existing suggestion/review/undo pipeline, supplementing the instant `NSSpellChecker` pass.
final class AISpellChecker {
    private let models: ModelManager
    private let server = LlamaServer(role: "spell")

    init(models: ModelManager) { self.models = models }
    func shutdown() { server.stop() }

    // The structured shape the model must return.
    private struct AIError: Decodable { let word: String; let suggestions: [String] }
    private struct AIResponse: Decodable { let errors: [AIError] }

    private static let systemPrompt = """
        You are a spelling, spacing, and word-choice checker for a short chat message.

        Find each incorrect span:
        - Misspelling (heer -> here)
        - Word split by a stray space (wh y -> why)
        - Words joined or spaced incorrectly (gettin gthinks -> getting things)
        - Wrong word for the context (their/there/they're, form/from, affect/effect, your/you're)

        A span may be one word or several adjacent words.

        For each error:
        - "word" = the exact text from the input.
        - "suggestions" = 1-3 replacements, best first.
        - Suggestions replace only the matched span.
        - Do not include surrounding words.
        - Do not rewrite, extend, or complete the sentence.
        - Keep the same meaning and grammar.
        - Do not include identical suggestions (for example "why" -> "why").
        - Do not return correct words.

        Ignore @mentions, #channels, URLs, code, email addresses, file paths, emoji shortcodes, and proper names.

        Return ONLY valid JSON:
        {"errors":[{"word":"...","suggestions":["..."]}]}

        EXAMPLE
        Input: I thnik this featre dosent work on mac becuase it keep crasing
        Response: {"errors":[{"word":"thnik","suggestions":["think"]},{"word":"featre","suggestions":["feature"]},{"word":"dosent","suggestions":["doesn't","does not"]},{"word":"becuase","suggestions":["because"]},{"word":"keep","suggestions":["keeps"]},{"word":"crasing","suggestions":["crashing"]}]}

        BAD EXAMPLE 1 (do not add surrounding words to a suggestion)
        Input: Pleese sendd it tommorow
        BAD: {"errors":[{"word":"tommorow","suggestions":["tomorrow","send it tomorrow"]}]}
        GOOD: {"errors":[{"word":"tommorow","suggestions":["tomorrow"]}]}

        BAD EXAMPLE 2 (do not return correct words or identical suggestions)
        Input: I recieved the email yesterday
        BAD: {"errors":[{"word":"yesterday","suggestions":["yesterday"]}]}
        GOOD: {"errors":[{"word":"recieved","suggestions":["received"]}]}
        """

    /// Check `text` with model id "apple" or a local model's id. Returns located issues, or [] on any
    /// failure (never throws — spell check must not disrupt typing).
    func check(_ text: String, modelId: String) async -> [SpellIssue] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        let errors: [AIError]
        if modelId == "apple" {
            errors = await checkApple(text)
        } else if let path = models.path(forID: modelId) {
            errors = await checkLocal(text, modelPath: path)
        } else {
            Log.write("[aispell] no model for id \(modelId)")
            return []
        }
        // Superseded by a newer check (the user typed on) — drop it silently, don't touch the badge.
        if Task.isCancelled { return [] }
        let issues = locate(errors, in: text)
        Log.write("[aispell] \(issues.count) issue(s) from \(errors.count) reported")
        return issues
    }

    // MARK: Local GGUF (llama-server, JSON-schema constrained)

    private func checkLocal(_ text: String, modelPath: String) async -> [AIError] {
        let name = (modelPath as NSString).lastPathComponent
        do {
            AIDebugLog.shared.begin(engine: "spell · \(name)", instruction: "spellcheck")
            try await server.ensureRunning(modelPath: modelPath, reasoningOff: true)
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/v1/chat/completions")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 30
            let schema: [String: Any] = [
                "type": "object",
                "properties": [
                    "errors": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "word": ["type": "string"],
                                "suggestions": ["type": "array", "items": ["type": "string"]],
                            ],
                            "required": ["word", "suggestions"],
                        ],
                    ],
                ],
                "required": ["errors"],
            ]
            let body: [String: Any] = [
                "model": "local",
                "stream": false,
                "temperature": 0.1,
                "messages": [
                    ["role": "system", "content": Self.systemPrompt],
                    ["role": "user", "content": text],
                ],
                "response_format": [
                    "type": "json_schema",
                    "json_schema": ["name": "spellcheck", "strict": true, "schema": schema],
                ],
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let content = (choices.first?["message"] as? [String: Any])?["content"] as? String
            else {
                let raw = String(data: data, encoding: .utf8) ?? "(non-utf8)"
                Log.write("[aispell] local: unexpected response shape")
                Log.ai(engine: "spell · \((modelPath as NSString).lastPathComponent)",
                       prompt: "SYSTEM:\n\(Self.systemPrompt)\n\nUSER:\n\(text)", response: raw)
                return []
            }
            AIDebugLog.shared.update(content)
            AIDebugLog.shared.finish(chars: content.count)
            Log.ai(engine: "spell · \(name)",
                   prompt: "SYSTEM:\n\(Self.systemPrompt)\n\nUSER:\n\(text)", response: content)
            return parse(content)
        } catch is CancellationError {
            return []
        } catch let e as URLError where e.code == .cancelled {
            return []   // superseded by a newer check — expected while typing, not an error
        } catch {
            Log.write("[aispell] local error: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: Apple on-device

    private func checkApple(_ text: String) async -> [AIError] {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do {
                let session = LanguageModelSession(instructions: Self.systemPrompt)
                let options = GenerationOptions(temperature: 0.1)
                let response = try await session.respond(to: text, options: options)
                Log.ai(engine: "spell · Apple",
                       prompt: "SYSTEM:\n\(Self.systemPrompt)\n\nUSER:\n\(text)", response: response.content)
                return parse(response.content)
            } catch {
                Log.write("[aispell] apple error: \(error.localizedDescription)")
            }
        }
        #endif
        return []
    }

    // MARK: Parsing + locating

    /// Decode the model's JSON, tolerating stray prose around it by extracting the outermost object.
    private func parse(_ content: String) -> [AIError] {
        func decode(_ s: String) -> [AIError]? {
            guard let data = s.data(using: .utf8),
                  let r = try? JSONDecoder().decode(AIResponse.self, from: data) else { return nil }
            return r.errors
        }
        if let r = decode(content) { return r }
        if let open = content.firstIndex(of: "{"), let close = content.lastIndex(of: "}"), open < close {
            if let r = decode(String(content[open...close])) { return r }
        }
        Log.write("[aispell] could not parse JSON from model output")
        return []
    }

    /// Map each reported word to a real NSRange in `text` (whole-word, left-to-right, one range per
    /// reported error), dropping anything the classifier says to skip (mentions/URLs/code/names) and
    /// any error with no usable suggestion.
    private func locate(_ errors: [AIError], in text: String) -> [SpellIssue] {
        let ns = text as NSString
        var used: [NSRange] = []
        var issues: [SpellIssue] = []
        for e in errors {
            let word = e.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, !WordClassifier.shouldSkip(word) else { continue }
            let suggestions = e.suggestions
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.lowercased() != word.lowercased() }
            guard !suggestions.isEmpty else { continue }
            var from = 0
            while from <= ns.length {
                let found = ns.range(of: word, options: [],
                                     range: NSRange(location: from, length: ns.length - from))
                if found.location == NSNotFound { break }
                let overlaps = used.contains { NSIntersectionRange($0, found).length > 0 }
                if !overlaps && isWholeWord(found, in: ns) {
                    used.append(found)
                    issues.append(SpellIssue(range: found, word: word, guesses: suggestions,
                                             disposition: .suggest))
                    break
                }
                from = found.location + max(found.length, 1)
            }
        }
        return issues
    }

    private func isWholeWord(_ range: NSRange, in ns: NSString) -> Bool {
        let letters = CharacterSet.alphanumerics
        if range.location > 0,
           ns.substring(with: NSRange(location: range.location - 1, length: 1))
            .rangeOfCharacter(from: letters) != nil { return false }
        let end = range.location + range.length
        if end < ns.length,
           ns.substring(with: NSRange(location: end, length: 1))
            .rangeOfCharacter(from: letters) != nil { return false }
        return true
    }
}
