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

    init() {
        let d = UserDefaults.standard
        autocorrectEnabled = d.object(forKey: "autocorrectEnabled") as? Bool ?? true
        suggestionsEnabled = d.object(forKey: "suggestionsEnabled") as? Bool ?? true
        rewriteEngineChoice = d.string(forKey: "rewriteEngineChoice") ?? "auto"
    }
}
