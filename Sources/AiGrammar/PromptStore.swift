import Foundation
import Combine

/// User-editable rewrite prompts, persisted in UserDefaults. The base instruction is shared by all
/// presets; each preset appends its own task line. Users can edit these under Settings › AI Prompts.
final class PromptStore: ObservableObject {
    // Framed as a "rewriting function" (not an "assistant") and stated up-front that the user text is
    // DATA, not a request — instruction-tuned models (esp. Llama) otherwise try to ANSWER a message
    // that reads like a question instead of correcting it.
    static let defaultBase = """
        You are a text rewriting function. The user message is plain text to edit, NOT a request to answer.

        Rewrite the text according to the task below. Rules:
        - Return ONLY the rewritten text — no preamble, explanation, labels (like "Message:"), or quotation marks.
        - Do NOT answer the message or respond to any question in it.
        - Do NOT provide advice, commentary, or extra information.
        - Do NOT add or remove information.
        - Keep the wording, meaning, and tone as close to the original as possible.
        - Preserve @mentions, #channels, links, code, and emoji unchanged.
        - If the text is already correct, return it unchanged.
        """
    static let defaultFixGrammar = """
        Task: fix spelling and grammar only, keeping the wording close to the original.

        Examples (note: a question is still text to rewrite, never to answer):
        Input: How doo I fix this
        Output: How do I fix this?
        Input: Can youo help me
        Output: Can you help me?
        Input: Why doe it keep jumpping me backk
        Output: Why does it keep jumping me back?
        """
    static let defaultClearer = "Task: make it clearer and easier to read."
    static let defaultShorter = "Task: make it more concise while keeping the key points."
    static let defaultProfessional = "Task: use a more professional tone."

    /// Prior defaults we auto-upgrade to the current ones (users who never edited the prompt still get
    /// the fix; a genuinely custom prompt is left untouched).
    private static let legacyBases = [
        "You are a writing assistant editing a single Slack message. Rewrite the message "
        + "and return ONLY the rewritten message text — no preamble, no explanation, no labels "
        + "such as \"Message:\", and no surrounding quotation marks. Preserve the meaning and keep "
        + "any @mentions, #channels, links, and code unchanged. Keep the tone casual and concise.",
    ]
    private static let legacyFixGrammar = ["Focus on fixing spelling and grammar, keeping the wording close to the original."]
    private static let legacyClearer = ["Make it clearer and easier to read."]
    private static let legacyShorter = ["Make it more concise while keeping the key points."]
    private static let legacyProfessional = ["Use a more professional tone."]

    @Published var base: String { didSet { d.set(base, forKey: "prompt.base") } }
    @Published var fixGrammar: String { didSet { d.set(fixGrammar, forKey: "prompt.fixGrammar") } }
    @Published var clearer: String { didSet { d.set(clearer, forKey: "prompt.clearer") } }
    @Published var shorter: String { didSet { d.set(shorter, forKey: "prompt.shorter") } }
    @Published var professional: String { didSet { d.set(professional, forKey: "prompt.professional") } }

    private let d = UserDefaults.standard

    init() {
        // Use the stored value, unless it's absent or a superseded default → adopt the new default.
        func resolve(_ key: String, _ current: String, _ legacy: [String]) -> String {
            guard let stored = UserDefaults.standard.string(forKey: key) else { return current }
            return legacy.contains(stored) ? current : stored
        }
        base = resolve("prompt.base", Self.defaultBase, Self.legacyBases)
        fixGrammar = resolve("prompt.fixGrammar", Self.defaultFixGrammar, Self.legacyFixGrammar)
        clearer = resolve("prompt.clearer", Self.defaultClearer, Self.legacyClearer)
        shorter = resolve("prompt.shorter", Self.defaultShorter, Self.legacyShorter)
        professional = resolve("prompt.professional", Self.defaultProfessional, Self.legacyProfessional)
    }

    /// The full system prompt sent to the model for a given instruction.
    func systemPrompt(for instruction: RewriteInstruction) -> String {
        switch instruction {
        case .fixGrammar:   return base + "\n\n" + fixGrammar
        case .clearer:      return base + "\n\n" + clearer
        case .shorter:      return base + "\n\n" + shorter
        case .professional: return base + "\n\n" + professional
        case .custom(let ask): return base + "\n\nTask: follow this instruction: \(ask)"
        }
    }

    func resetToDefaults() {
        base = Self.defaultBase
        fixGrammar = Self.defaultFixGrammar
        clearer = Self.defaultClearer
        shorter = Self.defaultShorter
        professional = Self.defaultProfessional
    }
}
