import Foundation

/// Rewrite backend for local GGUF models via llama.cpp's `llama-server` (see LlamaServer). Streams
/// the rewrite over the OpenAI-compatible SSE endpoint on 127.0.0.1 — fully on-device, and works on
/// Intel Macs and when Apple Intelligence is off. Keeps the model warm across rewrites.
final class GGUFRewriter: RewriteEngine {
    var displayName: String { "Local model · \(modelName) (llama.cpp)" }
    var isLocalModel: Bool { true }

    private let modelPath: String
    private let modelName: String
    private let params: InferenceParams

    init(modelPath: String, modelName: String, params: InferenceParams) {
        self.modelPath = modelPath
        self.modelName = modelName
        self.params = params
    }

    func shutdown() {}   // server lifecycle is managed by LlamaServerPool

    func rewrite(_ text: String, instruction: RewriteInstruction,
                 systemPrompt: String) -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    let port = try await LlamaServerPool.shared.ensureRunning(
                        purpose: "rewrite", modelPath: modelPath,
                        reasoningOff: params.reasoningEffort == "none")
                    Log.write("[rewrite] llama.cpp: \(instruction.id) on \(text.count) chars")
                    AIDebugLog.shared.begin(engine: "llama.cpp · \(modelName)", instruction: instruction.id)

                    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
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
                        if Task.isCancelled { break }   // Cancel button / focus-loss dismiss
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String else { continue }
                        acc += content
                        AIDebugLog.shared.update(acc)   // live raw stream → debug panel
                        continuation.yield(RewriteText.display(acc))
                    }
                    continuation.yield(RewriteText.finalDisplay(acc))   // never leave it on "Thinking…"
                    AIDebugLog.shared.finish(chars: acc.count)
                    Log.write("[rewrite] llama.cpp raw response (\(acc.count) chars):\n\(acc)")
                    Log.ai(engine: "rewrite · \(modelName)",
                           prompt: "SYSTEM:\n\(systemPrompt)\n\nUSER:\n\(text)", response: acc)
                } catch is CancellationError {
                    Log.write("[rewrite] llama.cpp generation cancelled")
                } catch let error as URLError where error.code == .cancelled {
                    Log.write("[rewrite] llama.cpp generation cancelled")
                } catch {
                    Log.write("[rewrite] llama.cpp error: \(error.localizedDescription)")
                    continuation.yield("[rewrite failed: \(error.localizedDescription)]")
                }
                continuation.finish()
            }
            // When the consumer cancels (Cancel button, focus-loss dismiss), tear down the producer:
            // cancelling the task aborts the URLSession request, which drops the socket to llama-server
            // so it stops generating instead of running to completion in the background.
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
