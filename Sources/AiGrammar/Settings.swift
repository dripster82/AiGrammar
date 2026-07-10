import Foundation
import Combine

/// User-facing toggles, persisted in UserDefaults. Local-only; nothing here is transmitted.
final class Settings: ObservableObject {
    static let slackBundleID = "com.tinyspeck.slackmacgap"

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

    // MARK: Which apps AiGrammar acts in

    /// Act in ANY app with an editable text field (except denied ones and secure fields).
    @Published var targetAllApps: Bool {
        didSet { UserDefaults.standard.set(targetAllApps, forKey: "target.allApps") }
    }
    /// Bundle IDs to act in when not "all apps". Slack seeded by default.
    @Published var allowedApps: [String] {
        didSet { UserDefaults.standard.set(allowedApps, forKey: "target.allowed") }
    }
    /// Bundle IDs to NEVER act in (used to carve exceptions out of "all apps").
    @Published var deniedApps: [String] {
        didSet { UserDefaults.standard.set(deniedApps, forKey: "target.denied") }
    }

    /// Whether AiGrammar should act in the app with this bundle id.
    func isAppTargeted(_ bundleID: String) -> Bool {
        guard !bundleID.isEmpty, !deniedApps.contains(bundleID) else { return false }
        return targetAllApps || allowedApps.contains(bundleID)
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
    /// When checked, the AI check runs automatically on a timer (the cadence below). When unchecked,
    /// it only runs on demand (⌃⌘C / menu).
    @Published var aiSpellAuto: Bool {
        didSet { UserDefaults.standard.set(aiSpellAuto, forKey: "aiSpell.auto") }
    }
    /// Automatic cadence (only used when `aiSpellAuto`): "delayed" (after a pause) or "perword".
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
        aiSpellAuto = d.object(forKey: "aiSpell.auto") as? Bool ?? false
        aiSpellCadence = d.string(forKey: "aiSpell.cadence") ?? "delayed"
        aiSpellDelayMs = d.object(forKey: "aiSpell.delayMs") as? Int ?? 700
        aiSpellReasoning = d.string(forKey: "aiSpell.reasoning") ?? "none"
        targetAllApps = d.object(forKey: "target.allApps") as? Bool ?? false
        allowedApps = d.stringArray(forKey: "target.allowed") ?? [Self.slackBundleID]
        deniedApps = d.stringArray(forKey: "target.denied") ?? []
    }
}
