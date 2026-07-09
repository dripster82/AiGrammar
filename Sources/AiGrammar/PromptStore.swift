import Foundation
import Combine

/// User-editable rewrite prompts, persisted in UserDefaults. The base instruction is shared by all
/// presets; each preset appends its own task line. Users can edit these under Settings › AI Prompts.
final class PromptStore: ObservableObject {
    static let defaultBase =
        "You are a writing assistant editing a single Slack message. Rewrite the message "
        + "and return ONLY the rewritten message text — no preamble, no explanation, no labels "
        + "such as \"Message:\", and no surrounding quotation marks. Preserve the meaning and keep "
        + "any @mentions, #channels, links, and code unchanged. Keep the tone casual and concise."
    static let defaultFixGrammar = "Focus on fixing spelling and grammar, keeping the wording close to the original."
    static let defaultClearer = "Make it clearer and easier to read."
    static let defaultShorter = "Make it more concise while keeping the key points."
    static let defaultProfessional = "Use a more professional tone."

    @Published var base: String { didSet { d.set(base, forKey: "prompt.base") } }
    @Published var fixGrammar: String { didSet { d.set(fixGrammar, forKey: "prompt.fixGrammar") } }
    @Published var clearer: String { didSet { d.set(clearer, forKey: "prompt.clearer") } }
    @Published var shorter: String { didSet { d.set(shorter, forKey: "prompt.shorter") } }
    @Published var professional: String { didSet { d.set(professional, forKey: "prompt.professional") } }

    private let d = UserDefaults.standard

    init() {
        base = d.string(forKey: "prompt.base") ?? Self.defaultBase
        fixGrammar = d.string(forKey: "prompt.fixGrammar") ?? Self.defaultFixGrammar
        clearer = d.string(forKey: "prompt.clearer") ?? Self.defaultClearer
        shorter = d.string(forKey: "prompt.shorter") ?? Self.defaultShorter
        professional = d.string(forKey: "prompt.professional") ?? Self.defaultProfessional
    }

    /// The full system prompt sent to the model for a given instruction.
    func systemPrompt(for instruction: RewriteInstruction) -> String {
        switch instruction {
        case .fixGrammar:   return base + " " + fixGrammar
        case .clearer:      return base + " " + clearer
        case .shorter:      return base + " " + shorter
        case .professional: return base + " " + professional
        case .custom(let ask): return base + " Follow this instruction from the user: \(ask)"
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
