import Darwin
import Foundation

/// Manages a local `llama-server` (llama.cpp) subprocess that serves an OpenAI-compatible API on
/// 127.0.0.1. Everything stays on-device — the "server" is just llama.cpp running locally so we can
/// stream tokens over HTTP without any C-interop. Loads a model on first use and keeps it warm.
final class LlamaServer {
    private var process: Process?
    private(set) var port = 0
    private var loadedModelPath: String?

    /// A pidfile records the running server so a crash/force-quit orphan can be killed on next launch.
    private static var pidFileURL: URL {
        ModelManager.modelsDirectory.deletingLastPathComponent().appendingPathComponent("llama-server.pid")
    }

    /// Kill a llama-server left running by a previous session that didn't shut down cleanly (crash /
    /// force-quit / SIGKILL). Verifies the pid is actually a llama-server before killing (pid reuse).
    static func killStaleServer() {
        guard let s = try? String(contentsOf: pidFileURL, encoding: .utf8),
              let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        if executablePath(pid)?.contains("llama-server") == true {
            kill(pid, SIGKILL)
            Log.write("[llama] killed stale server pid \(pid) from a previous session")
        }
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    private static func executablePath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    /// Locate the `llama-server` binary, preferring the copy embedded in the app bundle so it works
    /// with no separate install. Falls back to an explicit user setting, then common install paths.
    static func serverBinaryPath() -> String? {
        let fm = FileManager.default
        // 1. Embedded in the app: Contents/Resources/llama/llama-server.
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("llama/llama-server").path,
           fm.isExecutableFile(atPath: bundled) { return bundled }
        // 2. Explicit user setting.
        if let p = UserDefaults.standard.string(forKey: "llamaServerPath"),
           !p.isEmpty, fm.isExecutableFile(atPath: p) { return p }
        // 3. Common install locations (Homebrew etc.).
        let candidates = ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    static var isInstalled: Bool { serverBinaryPath() != nil }

    private var loadedReasoningOff = false

    /// Ensure a server is running for `modelPath`. Reuses the running one unless the model OR the
    /// reasoning-off setting changed (reasoning is a server-launch flag, not a request parameter).
    func ensureRunning(modelPath: String, reasoningOff: Bool) async throws {
        if let p = process, p.isRunning, loadedModelPath == modelPath, loadedReasoningOff == reasoningOff {
            return
        }
        stop()
        guard let binary = Self.serverBinaryPath() else {
            throw NSError(domain: "AiGrammar", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "llama-server not found — install llama.cpp (see docs/llama-setup.md) or set its path in Settings."])
        }
        let chosenPort = Int.random(in: 8100...8999)
        var args = ["-m", modelPath, "--host", "127.0.0.1", "--port", "\(chosenPort)",
                    "-c", "4096", "--no-webui"]
        // Reasoning is controlled at launch: "--reasoning off" disables thinking for the whole run.
        if reasoningOff { args += ["--reasoning", "off", "--reasoning-budget", "0"] }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        process = proc
        port = chosenPort
        loadedModelPath = modelPath
        loadedReasoningOff = reasoningOff
        try? "\(proc.processIdentifier)".write(to: Self.pidFileURL, atomically: true, encoding: .utf8)
        Log.write("[llama] started llama-server pid \(proc.processIdentifier) on :\(chosenPort) for \((modelPath as NSString).lastPathComponent)\(reasoningOff ? " (reasoning off)" : "")")
        try await waitForHealth(timeout: 60)
        Log.write("[llama] server healthy on :\(chosenPort)")
    }

    private func waitForHealth(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        while Date() < deadline {
            if process?.isRunning != true {
                throw NSError(domain: "AiGrammar", code: 2, userInfo: [NSLocalizedDescriptionKey:
                    "llama-server exited during startup."])
            }
            if let (_, response) = try? await URLSession.shared.data(from: url),
               let http = response as? HTTPURLResponse, http.statusCode == 200 {
                return
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        throw NSError(domain: "AiGrammar", code: 3, userInfo: [NSLocalizedDescriptionKey:
            "llama-server did not become ready (model may be too large or still loading)."])
    }

    func stop() {
        if let p = process, p.isRunning {
            let pid = p.processIdentifier
            p.terminate()                       // SIGTERM
            // If it doesn't exit promptly, force-kill so it can't linger holding GBs of RAM.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            }
            Log.write("[llama] stopped server pid \(pid)")
        }
        try? FileManager.default.removeItem(at: Self.pidFileURL)
        process = nil
        loadedModelPath = nil
        port = 0
    }
}
