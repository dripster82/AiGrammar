import Foundation

/// Appends diagnostics to ~/Library/Logs/AiGrammar/aigrammar.log so permission state, focused
/// elements, and capability probes can be reviewed after the fact (tail -f the file).
enum Log {
    /// Log channels the user can switch on/off in Diagnostics. The category is inferred from the
    /// line's prefix (so existing call sites need no changes), or passed explicitly. `.general` is
    /// always on. Full AI prompts/responses are `.aiPayload` (verbose; explicit).
    enum Category: String, CaseIterable {
        case general, focus, pipeline, rewrite, spell, llama, aiPrompt, aiResponse

        var label: String {
            switch self {
            case .general: return "General"
            case .focus: return "Focus / Accessibility"
            case .pipeline: return "Spellcheck pipeline"
            case .rewrite: return "AI rewrite"
            case .spell: return "AI spell check"
            case .llama: return "Local model server"
            case .aiPrompt: return "AI prompts (verbose)"
            case .aiResponse: return "AI responses (verbose)"
            }
        }

        /// `.general` can't be turned off; the rest default on.
        var isEnabled: Bool {
            if self == .general { return true }
            return UserDefaults.standard.object(forKey: "log.\(rawValue)") as? Bool ?? true
        }

        /// Categorise a line by its prefix so we don't have to tag every call site.
        static func infer(from line: String) -> Category {
            if line.hasPrefix("[rewrite]") || line.hasPrefix("rewrite ") { return .rewrite }
            if line.hasPrefix("[aispell]") { return .spell }
            if line.hasPrefix("[llama]") || line.hasPrefix("model ") { return .llama }
            if line.hasPrefix("[focus]") || line.hasPrefix("focus ") { return .focus }
            for p in ["[check]", "[review]", "apply ", "undo ", "replace ", "popover:", "ignore"] {
                if line.hasPrefix(p) { return .pipeline }
            }
            return .general
        }
    }

    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/AiGrammar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("aigrammar.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        return url
    }()

    private static let queue = DispatchQueue(label: "uk.co.ketelle.aigrammar.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ line: String, category: Category? = nil) {
        let cat = category ?? Category.infer(from: line)
        guard cat.isEnabled else { return }
        let text = "[\(stamp.string(from: Date()))] \(line)\n"
        queue.async {
            guard let data = text.data(using: .utf8),
                  let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        }
    }

    /// Log an AI call. The prompt and the response go to SEPARATE channels so you can log just the
    /// response when the prompt is noise. `engine` names the backend/model.
    static func ai(engine: String, prompt: String, response: String) {
        write("── AI PROMPT · \(engine) ──\n\(prompt)\n── end prompt ──", category: .aiPrompt)
        write("── AI RESPONSE · \(engine) ──\n\(response)\n── end response ──", category: .aiResponse)
    }

    /// Empty the log file (from the Diagnostics "Clear log" button).
    static func clear() {
        queue.async {
            try? Data().write(to: fileURL)
            let text = "[\(stamp.string(from: Date()))] log cleared\n"
            if let data = text.data(using: .utf8) { try? data.write(to: fileURL) }
        }
    }
}
