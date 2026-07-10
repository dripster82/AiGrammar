import Foundation
import Combine
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Backs the "Chat with AI Model" page: a multi-turn conversation with a chosen on-device model —
/// a local GGUF via a dedicated `llama-server` (full history sent each turn, streamed), or Apple's
/// on-device model (a persistent session that keeps context). Fully local; nothing leaves the Mac.
@MainActor
final class ChatController: ObservableObject {
    struct Msg: Identifiable, Equatable {
        let id = UUID()
        let role: String            // "user" | "assistant"
        var text: String
    }

    @Published var messages: [Msg] = []
    @Published var streaming = false
    /// Chosen engine id: "apple" or a local model's id. Persisted.
    @Published var modelId: String { didSet { UserDefaults.standard.set(modelId, forKey: "aiChat.model") } }

    private let models: ModelManager
    private let params: InferenceParams
    private var task: Task<Void, Never>?

    #if canImport(FoundationModels)
    private var appleSession: Any?   // LanguageModelSession, recreated on New chat / model change
    #endif

    private static let systemPrompt = "You are a helpful, concise assistant."

    init(models: ModelManager, params: InferenceParams, defaultModelId: String) {
        self.models = models
        self.params = params
        let saved = UserDefaults.standard.string(forKey: "aiChat.model") ?? ""
        modelId = saved.isEmpty ? defaultModelId : saved
    }

    func shutdown() { task?.cancel(); Task { await LlamaServerPool.shared.release(purpose: "chat") } }

    /// Available chat engines: Apple on-device (if available) + each ready local model.
    var engineOptions: [(id: String, name: String)] {
        var out: [(String, String)] = []
        if RewriteEngineChoice.appleAvailable() { out.append(("apple", "Apple on-device")) }
        if LlamaServer.isInstalled {
            out.append(contentsOf: models.readyLocalModels.map { ($0.id, "\($0.name) (llama.cpp)") })
        }
        return out
    }

    func newChat() {
        task?.cancel()
        streaming = false
        messages.removeAll()
        #if canImport(FoundationModels)
        appleSession = nil
        #endif
    }

    func stop() { task?.cancel(); streaming = false }

    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !streaming, !modelId.isEmpty else { return }
        messages.append(Msg(role: "user", text: text))
        messages.append(Msg(role: "assistant", text: ""))
        let idx = messages.count - 1
        streaming = true

        let history = messages.dropLast().map { ($0.role, $0.text) }   // exclude the empty assistant
        task = Task { [weak self] in
            guard let self else { return }
            if self.modelId == "apple" {
                await self.streamApple(userText: text, into: idx)
            } else {
                await self.streamLocal(history: Array(history), into: idx)
            }
            self.streaming = false
        }
    }

    private func append(_ chunk: String, to idx: Int) {
        guard idx < messages.count else { return }
        messages[idx].text += chunk
    }

    // MARK: Local GGUF (llama-server, streamed, full history)

    private func streamLocal(history: [(String, String)], into idx: Int) async {
        guard let path = models.path(forID: modelId) else {
            append("[no model file for \(modelId)]", to: idx); return
        }
        do {
            let port = try await LlamaServerPool.shared.ensureRunning(
                purpose: "chat", modelPath: path, reasoningOff: params.reasoningEffort == "none")
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var msgs: [[String: String]] = [["role": "system", "content": Self.systemPrompt]]
            msgs += history.map { ["role": $0.0, "content": $0.1] }
            var body: [String: Any] = [
                "model": "local", "stream": true,
                "temperature": params.temperature, "top_p": params.topP, "messages": msgs,
            ]
            if params.maxTokens > 0 { body["max_tokens"] = params.maxTokens }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (bytes, _) = try await URLSession.shared.bytes(for: request)
            var full = ""
            for try await line in bytes.lines {
                if Task.isCancelled { break }
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any],
                      let content = delta["content"] as? String else { continue }
                full += content
                append(content, to: idx)
            }
            Log.ai(engine: "chat · \((path as NSString).lastPathComponent)",
                   prompt: msgs.map { "\($0["role"]!.uppercased()): \($0["content"]!)" }.joined(separator: "\n"),
                   response: full)
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            append("\n[chat error: \(error.localizedDescription)]", to: idx)
            Log.write("[rewrite] chat error: \(error.localizedDescription)")
        }
    }

    // MARK: Apple on-device (persistent session keeps context)

    private func streamApple(userText: String, into idx: Int) async {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = (appleSession as? LanguageModelSession)
                ?? LanguageModelSession(instructions: Self.systemPrompt)
            appleSession = session
            do {
                let options = GenerationOptions(temperature: params.temperature)
                let stream = session.streamResponse(to: userText, options: options)
                var full = ""
                for try await partial in stream {
                    if Task.isCancelled { break }
                    messages[idx].text = partial.content   // Apple yields cumulative content
                    full = partial.content
                }
                Log.ai(engine: "chat · Apple", prompt: userText, response: full)
            } catch is CancellationError {
            } catch {
                append("\n[chat error: \(error.localizedDescription)]", to: idx)
            }
            return
        }
        #endif
        append("[Apple on-device model unavailable]", to: idx)
    }
}
