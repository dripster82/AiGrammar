import Foundation

/// Rewrite backend for local GGUF models via llama.cpp's `llama-server` (see LlamaServer). Streams
/// the rewrite over the OpenAI-compatible SSE endpoint on 127.0.0.1 — fully on-device, and works on
/// Intel Macs and when Apple Intelligence is off. Keeps the model warm across rewrites.
final class GGUFRewriter: RewriteEngine {
    var displayName: String { "Local model · \(modelName) (llama.cpp)" }
    var isLocalModel: Bool { true }

    private let server = LlamaServer()
    private let modelPath: String
    private let modelName: String
    private let params: InferenceParams

    init(modelPath: String, modelName: String, params: InferenceParams) {
        self.modelPath = modelPath
        self.modelName = modelName
        self.params = params
    }

    func shutdown() { server.stop() }

    func rewrite(_ text: String, instruction: RewriteInstruction,
                 systemPrompt: String) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task {
                do {
                    try await server.ensureRunning(modelPath: modelPath,
                                                   reasoningOff: params.reasoningEffort == "none")
                    Log.write("[rewrite] llama.cpp: \(instruction.id) on \(text.count) chars")

                    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/v1/chat/completions")!)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let body = params.requestBody(messages: [
                        ["role": "system", "content": systemPrompt],
                        ["role": "user", "content": text],
                    ], stream: true)
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, _) = try await URLSession.shared.bytes(for: request)
                    var acc = ""
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String else { continue }
                        acc += content
                        continuation.yield(RewriteText.display(acc))
                    }
                    continuation.yield(RewriteText.finalDisplay(acc))   // never leave it on "Thinking…"
                    Log.write("[rewrite] llama.cpp raw response (\(acc.count) chars):\n\(acc)")
                } catch {
                    Log.write("[rewrite] llama.cpp error: \(error.localizedDescription)")
                    continuation.yield("[rewrite failed: \(error.localizedDescription)]")
                }
                continuation.finish()
            }
        }
    }
}
