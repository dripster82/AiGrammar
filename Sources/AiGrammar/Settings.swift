import Foundation
import Combine

/// User-facing toggles, persisted in UserDefaults. Local-only; nothing here is transmitted.
final class Settings: ObservableObject {
    @Published var autocorrectEnabled: Bool {
        didSet { UserDefaults.standard.set(autocorrectEnabled, forKey: "autocorrectEnabled") }
    }
    @Published var suggestionsEnabled: Bool {
        didSet { UserDefaults.standard.set(suggestionsEnabled, forKey: "suggestionsEnabled") }
    }

    /// Which rewrite engine to use: "auto", "apple", "cleanup", or a local model's id.
    @Published var rewriteEngineChoice: String {
        didSet { UserDefaults.standard.set(rewriteEngineChoice, forKey: "rewriteEngineChoice") }
    }

    // MARK: AI spell check (model-based, context-aware; supplements the dictionary checker)

    /// Turn on the model-based spell/word-choice checker (catches real-word errors like their/there).
    @Published var aiSpellEnabled: Bool {
        didSet { UserDefaults.standard.set(aiSpellEnabled, forKey: "aiSpell.enabled") }
    }
    /// Engine for AI spell check: "apple" or a local model's id. Empty = none chosen yet.
    @Published var aiSpellModel: String {
        didSet { UserDefaults.standard.set(aiSpellModel, forKey: "aiSpell.model") }
    }
    /// When to run it: "delayed" (after a typing pause), "perword" (each completed word), "ondemand".
    @Published var aiSpellCadence: String {
        didSet { UserDefaults.standard.set(aiSpellCadence, forKey: "aiSpell.cadence") }
    }
    /// Debounce for the "delayed" cadence, in milliseconds.
    @Published var aiSpellDelayMs: Int {
        didSet { UserDefaults.standard.set(aiSpellDelayMs, forKey: "aiSpell.delayMs") }
    }
    /// Reasoning effort for spell check: "none" (fastest, default) | "low" | "medium" | "high".
    /// "none" launches the local server with --reasoning off; use "low" if the model can't disable it.
    @Published var aiSpellReasoning: String {
        didSet { UserDefaults.standard.set(aiSpellReasoning, forKey: "aiSpell.reasoning") }
    }

    init() {
        let d = UserDefaults.standard
        autocorrectEnabled = d.object(forKey: "autocorrectEnabled") as? Bool ?? true
        suggestionsEnabled = d.object(forKey: "suggestionsEnabled") as? Bool ?? true
        rewriteEngineChoice = d.string(forKey: "rewriteEngineChoice") ?? "auto"
        aiSpellEnabled = d.object(forKey: "aiSpell.enabled") as? Bool ?? false
        aiSpellModel = d.string(forKey: "aiSpell.model") ?? ""
        aiSpellCadence = d.string(forKey: "aiSpell.cadence") ?? "delayed"
        aiSpellDelayMs = d.object(forKey: "aiSpell.delayMs") as? Int ?? 700
        aiSpellReasoning = d.string(forKey: "aiSpell.reasoning") ?? "none"
    }
}
