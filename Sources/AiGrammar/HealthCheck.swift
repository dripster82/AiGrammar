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

/// Runs a health check WITHOUT loading anything: environment (accessibility, Slack, engine) plus a
/// live "reply with OK" ping to each llama-server that is ALREADY running (found via `ps`, addressed
/// by its port), and the Apple model if it's configured. Nothing is spun up or killed.
@MainActor
final class HealthCheck: ObservableObject {
    @Published private(set) var items: [HealthItem] = []
    @Published private(set) var running = false

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
        defer { running = false }

        // --- Environment ---
        set("Accessibility permission", monitor.trusted ? .ok : .fail,
            monitor.trusted ? "Granted" : "Not granted — corrections can't be applied")
        let slackSeen = monitor.lastSlackElement != nil || monitor.snapshot.isSlack
        set("Slack composer", slackSeen ? .ok : .warn,
            slackSeen ? "Detected" : "Click into Slack's message box once, then re-run")
        set("Local model engine", LlamaServer.isInstalled ? .ok : .warn,
            LlamaServer.isInstalled ? "Embedded llama-server present" : "Not found — Apple / cleanup only")

        // --- Ping each ALREADY-RUNNING server (never load one) ---
        let procs = LlamaProcesses.sample()
        for p in procs {
            let modelName = p.modelPath.map { models.modelDisplay(forPath: $0).name } ?? p.model
            let name = "\(p.purpose) · \(modelName)"
            guard let port = p.port else { set(name, .warn, "Couldn't read the server port"); continue }
            set(name, .running, "Sending a test prompt…")
            let (status, detail) = await pingPort(port)
            set(name, status, detail)
        }

        // --- Apple on-device (no server to load) if it's configured anywhere ---
        let appleConfigured = RewriteEngineChoice.resolve(settings.rewriteEngineChoice, models: models) == .apple
            || settings.aiSpellModel == "apple"
            || UserDefaults.standard.string(forKey: "aiChat.model") == "apple"
        if appleConfigured {
            set("Apple on-device", .running, "Sending a test prompt…")
            let (status, detail) = await pingApple()
            set("Apple on-device", status, detail)
        }

        if procs.isEmpty && !appleConfigured {
            set("Model servers", .warn,
                "None running — trigger a rewrite, spell check, or chat first, then re-run.")
        }
    }

    /// Send a minimal prompt to an already-running server on `port` and confirm it replies "OK".
    private func pingPort(_ port: Int) async -> (HealthStatus, String) {
        do {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 30
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
