import Darwin
import Foundation

/// A running `llama-server` process and its live resource use, for the Diagnostics page. Sampled via
/// `ps` (same approach AR Workspace uses to watch colorsync/WindowServer CPU) so we can see how much
/// CPU/RAM the local models are actually costing.
struct LlamaProc: Identifiable {
    let id: Int32          // pid
    let cpu: Double        // percent
    let memMB: Double      // resident size
    let model: String      // gguf filename (from the -m argument)
    let role: String?      // "rewrite" | "spell" | "chat" (from the pidfile), else nil

    /// Friendly purpose label for the role.
    var purpose: String {
        switch role {
        case "rewrite": return "Rewrite"
        case "spell": return "Spell check"
        case "chat": return "Chat"
        case .some(let r): return r.capitalized
        case nil: return "Unknown"
        }
    }
}

enum LlamaProcesses {
    /// Snapshot the running `llama-server` processes. Call off the main thread — it spawns `ps`.
    static func sample() -> [LlamaProc] {
        guard let out = run("/bin/ps", ["-axo", "pid=,pcpu=,rss=,command="]) else { return [] }
        let roles = pidRoles()
        var procs: [LlamaProc] = []
        for line in out.split(separator: "\n") {
            guard line.contains("llama-server") else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // pid  pcpu  rss  command...
            let parts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4,
                  let pid = Int32(parts[0]), let cpu = Double(parts[1]), let rssKB = Double(parts[2])
            else { continue }
            let command = String(parts[3])
            // Only real llama-server processes: the executable (first token) must be the binary,
            // not some other process that merely mentions "llama-server" in its arguments.
            guard let exe = command.split(separator: " ").first,
                  exe.hasSuffix("llama-server") || exe == "llama-server" else { continue }
            procs.append(LlamaProc(id: pid, cpu: cpu, memMB: rssKB / 1024.0,
                                   model: modelName(from: command), role: roles[pid]))
        }
        return procs.sorted { $0.cpu > $1.cpu }
    }

    /// Terminate a llama-server by pid (SIGTERM, then SIGKILL if it lingers). Called from the
    /// Diagnostics "Kill" button. The owning `LlamaServer` will simply relaunch it on next use.
    static func kill(pid: Int32) {
        Darwin.kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            if Darwin.kill(pid, 0) == 0 { Darwin.kill(pid, SIGKILL) }
        }
        Log.write("[llama] killed server pid \(pid) from Diagnostics")
    }

    /// Map each running server's pid to its role, read from the `llama-server-<role>.pid` files.
    private static func pidRoles() -> [Int32: String] {
        let dir = ModelManager.modelsDirectory.deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [:] }
        var map: [Int32: String] = [:]
        for f in files where f.lastPathComponent.hasPrefix("llama-server-") && f.pathExtension == "pid" {
            let role = f.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "llama-server-", with: "")
            if let s = try? String(contentsOf: f, encoding: .utf8),
               let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                map[pid] = role
            }
        }
        return map
    }

    /// Pull the gguf filename out of the launch command's `-m <path>` argument.
    private static func modelName(from command: String) -> String {
        let tokens = command.split(separator: " ").map(String.init)
        if let i = tokens.firstIndex(of: "-m"), i + 1 < tokens.count {
            return (tokens[i + 1] as NSString).lastPathComponent
        }
        return "(unknown model)"
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
