import Foundation

/// Shares llama-server instances across features. If rewrite, spell check, and chat all point at the
/// same model (and reasoning setting), they use ONE server instead of spinning up a copy each — a big
/// memory saving. A server with no feature still pointing at it is stopped.
///
/// Keyed by (modelPath, reasoningOff) since reasoning is a launch flag. @MainActor so all the shared
/// LlamaServer state is touched from one place.
@MainActor
final class LlamaServerPool {
    static let shared = LlamaServerPool()

    private var servers: [String: LlamaServer] = [:]   // key -> server
    private var purposeModel: [String: String] = [:]   // "rewrite"/"spell"/"chat" -> key
    private var nextIndex = 0

    private func key(_ path: String, _ reasoningOff: Bool) -> String { "\(path)\u{1}\(reasoningOff)" }

    /// Ensure a server is running (model loaded) for this purpose's model, reusing a shared one when
    /// another purpose already runs the same model. Returns the localhost port.
    func ensureRunning(purpose: String, modelPath: String, reasoningOff: Bool) async throws -> Int {
        let k = key(modelPath, reasoningOff)
        purposeModel[purpose] = k
        let server: LlamaServer
        if let existing = servers[k] {
            server = existing
        } else {
            server = LlamaServer(role: "pool\(nextIndex)")
            nextIndex += 1
            servers[k] = server
        }
        stopUnused()   // free any server no purpose points at anymore
        try await server.ensureRunning(modelPath: modelPath, reasoningOff: reasoningOff)
        return server.port
    }

    /// A feature no longer needs its model (e.g. disabled). Drops its claim and stops now-unused servers.
    func release(purpose: String) {
        purposeModel[purpose] = nil
        stopUnused()
    }

    /// Stop everything (app quit).
    func stopAll() {
        servers.values.forEach { $0.stop() }
        servers.removeAll()
        purposeModel.removeAll()
    }

    /// Which purposes currently use the server for `modelPath` — for the Diagnostics list, so a shared
    /// server reads e.g. "Rewrite + Spell check".
    func purposes(forModelPath modelPath: String) -> [String] {
        purposeModel.compactMap { purpose, k in
            k.hasPrefix(modelPath + "\u{1}") ? purpose : nil
        }.sorted()
    }

    /// Purposes served by the process with this pid, or nil if the pool doesn't own it (an orphan).
    func purposes(pid: Int32) -> [String]? {
        guard let entry = servers.first(where: { $0.value.currentPid == pid }) else { return nil }
        return purposeModel.compactMap { $0.value == entry.key ? $0.key : nil }.sorted()
    }

    /// "Rewrite + Spell check" style label for the server with this pid, or nil for an orphan.
    func purposeLabel(pid: Int32) -> String? {
        guard let ps = purposes(pid: pid) else { return nil }
        return ps.isEmpty ? "Model server" : ps.map(Self.label).joined(separator: " + ")
    }

    static func label(_ purpose: String) -> String {
        switch purpose {
        case "rewrite": return "Rewrite"
        case "spell": return "Spell check"
        case "chat": return "Chat"
        default: return purpose.capitalized
        }
    }

    private func stopUnused() {
        let inUse = Set(purposeModel.values)
        for (k, server) in servers where !inUse.contains(k) {
            server.stop()
            servers.removeValue(forKey: k)
        }
    }
}
