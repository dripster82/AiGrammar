import Foundation
import Combine
#if canImport(FoundationModels)
import FoundationModels
#endif

/// One line of the Diagnostics health check.
struct HealthItem: Identifiable {
    let id = UUID()
    let name: String
    var status: HealthStatus
    var detail: String
}

enum HealthStatus {
    case ok, warn, fail, running
    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.circle.fill"
        case .running: return "clock"
        }
    }
}

/// Runs an end-to-end health check: environment (accessibility, Slack, engine) plus a live "reply
/// with OK" inference against each configured model so you can confirm the whole pipeline works —
/// not just that a server is up. Uses its own llama-server (role "health") which it stops afterwards.
@MainActor
final class HealthCheck: ObservableObject {
    @Published private(set) var items: [HealthItem] = []
    @Published private(set) var running = false

    private let server = LlamaServer(role: "health")
    func shutdown() { server.stop() }

    private func set(_ name: String, _ status: HealthStatus, _ detail: String) {
        if let i = items.firstIndex(where: { $0.name == name }) {
            items[i].status = status; items[i].detail = detail
        } else {
            items.append(HealthItem(name: name, status: status, detail: detail))
        }
    }

    func run(monitor: FocusMonitor, models: ModelManager, settings: Settings, params: InferenceParams) async {
        guard !running else { return }
        running = true
        items = []
        defer { running = false; server.stop() }   // free the health model once done

        // --- Environment ---
        set("Accessibility permission", monitor.trusted ? .ok : .fail,
            monitor.trusted ? "Granted" : "Not granted — corrections can't be applied")
        let slackSeen = monitor.lastSlackElement != nil || monitor.snapshot.isSlack
        set("Slack composer", slackSeen ? .ok : .warn,
            slackSeen ? "Detected" : "Click into Slack's message box once, then re-run")
        set("Local model engine", LlamaServer.isInstalled ? .ok : .warn,
            LlamaServer.isInstalled ? "Embedded llama-server present" : "Not found — Apple / cleanup only")

        // --- Which models to test (deduped; a model shared by roles is pinged once) ---
        var order: [String] = []
        var labels: [String: [String]] = [:]
        func want(_ label: String, _ id: String) {
            if labels[id] == nil { order.append(id) }
            labels[id, default: []].append(label)
        }
        switch RewriteEngineChoice.resolve(settings.rewriteEngineChoice, models: models) {
        case .apple: want("Rewrite", "apple")
        case .local(let m): want("Rewrite", m.id)
        case .cleanup: set("Rewrite model", .warn, "No AI model selected — built-in cleanup only")
        }
        if settings.aiSpellEnabled, !settings.aiSpellModel.isEmpty { want("Spell check", settings.aiSpellModel) }
        let chatId = UserDefaults.standard.string(forKey: "aiChat.model") ?? ""
        if !chatId.isEmpty { want("Chat", chatId) }

        // --- Live "reply OK" ping per distinct model ---
        for id in order {
            let roles = labels[id]!.joined(separator: " + ")
            let modelName = id == "apple" ? "Apple on-device"
                : (models.allModels.first { $0.id == id }?.name ?? id)
            let name = "\(roles) · \(modelName)"
            set(name, .running, "Loading model and sending a test prompt…")
            let (status, detail) = await ping(id: id, models: models, params: params)
            set(name, status, detail)
        }
    }

    /// Send a minimal prompt and confirm the model replies with "OK".
    private func ping(id: String, models: ModelManager, params: InferenceParams) async -> (HealthStatus, String) {
        if id == "apple" { return await pingApple() }
        guard let path = models.path(forID: id) else { return (.fail, "Model file not found on disk") }
        do {
            try await server.ensureRunning(modelPath: path, reasoningOff: true)
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/v1/chat/completions")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 60
            let body: [String: Any] = [
                "model": "local", "stream": false, "temperature": 0, "max_tokens": 16,
                "messages": [
                    ["role": "system", "content": "You are a connectivity test. Reply with exactly: OK"],
                    ["role": "user", "content": "ping"],
                ],
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                return (.fail, "Server returned HTTP \(http.statusCode)")
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let content = (choices.first?["message"] as? [String: Any])?["content"] as? String
            else { return (.fail, "Unexpected response shape") }
            let reply = content.trimmingCharacters(in: .whitespacesAndNewlines)
            let ok = reply.uppercased().contains("OK")
            return (ok ? .ok : .warn, ok ? "Replied “\(reply.prefix(30))”" : "Reachable, but replied “\(reply.prefix(40))”")
        } catch {
            return (.fail, error.localizedDescription)
        }
    }

    private func pingApple() async -> (HealthStatus, String) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard FoundationModelsRewriter.isAvailable else {
                return (.warn, FoundationModelsRewriter.unavailabilityReason() ?? "Unavailable")
            }
            do {
                let session = LanguageModelSession(instructions: "You are a connectivity test. Reply with exactly: OK")
                let r = try await session.respond(to: "ping")
                let reply = r.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let ok = reply.uppercased().contains("OK")
                return (ok ? .ok : .warn, ok ? "Replied “\(reply.prefix(30))”" : "Replied “\(reply.prefix(40))”")
            } catch { return (.fail, error.localizedDescription) }
        }
        #endif
        return (.warn, "Requires macOS 26 with Apple Intelligence")
    }
}
