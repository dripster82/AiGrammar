import Foundation
import Combine

/// Hyperparameters sent to the local llama.cpp server (OpenAI-compatible /v1/chat/completions).
/// Persisted; edited under AI Models → Model parameters. The `extraJSON` field is merged last so any
/// model-specific option (e.g. top_k, min_p, repeat_penalty, chat_template_kwargs) can be passed.
final class InferenceParams: ObservableObject {
    @Published var temperature: Double { didSet { d.set(temperature, forKey: "ip.temperature") } }
    @Published var topP: Double { didSet { d.set(topP, forKey: "ip.topP") } }
    @Published var maxTokens: Int { didSet { d.set(maxTokens, forKey: "ip.maxTokens") } }
    /// "none" | "low" | "medium" | "high" — only used by models that support it. "none" tries to
    /// disable thinking (via chat_template_kwargs.enable_thinking=false; works for Qwen3-style models).
    @Published var reasoningEffort: String { didSet { d.set(reasoningEffort, forKey: "ip.reasoningEffort") } }
    /// Advanced: extra JSON merged into the request body (e.g. {"top_k":40,"min_p":0.05}).
    @Published var extraJSON: String { didSet { d.set(extraJSON, forKey: "ip.extraJSON") } }

    private let d = UserDefaults.standard

    init() {
        temperature = d.object(forKey: "ip.temperature") as? Double ?? 0.3
        topP = d.object(forKey: "ip.topP") as? Double ?? 0.95
        maxTokens = d.object(forKey: "ip.maxTokens") as? Int ?? 2048
        // Default to "low"; migrate an old empty ("Default") value.
        let re = d.string(forKey: "ip.reasoningEffort") ?? ""
        reasoningEffort = re.isEmpty ? "low" : re
        extraJSON = d.string(forKey: "ip.extraJSON") ?? ""
    }

    func resetToDefaults() {
        temperature = 0.3; topP = 0.95; maxTokens = 2048; reasoningEffort = "low"
        extraJSON = ""
    }

    /// Build the request body for a chat-completions call.
    func requestBody(messages: [[String: String]], stream: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "model": "local",
            "stream": stream,
            "temperature": temperature,
            "top_p": topP,
            "messages": messages,
        ]
        if maxTokens > 0 { body["max_tokens"] = maxTokens }
        // "none" is handled at the server launch (--reasoning off), not here. low/medium/high map to
        // the OpenAI-style reasoning_effort param (used by e.g. gpt-oss).
        if ["low", "medium", "high"].contains(reasoningEffort) {
            body["reasoning_effort"] = reasoningEffort
        }
        // Extra JSON merges last, so the user can override any of the above per their model.
        if let data = extraJSON.data(using: .utf8), !extraJSON.trimmingCharacters(in: .whitespaces).isEmpty,
           let extra = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in extra { body[k] = v }
        }
        return body
    }
}
