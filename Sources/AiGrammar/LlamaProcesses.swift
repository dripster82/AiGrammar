import Darwin
import Foundation

/// A running `llama-server` process and its live resource use, for the Diagnostics page. Sampled via
/// `ps` (same approach AR Workspace uses to watch colorsync/WindowServer CPU) so we can see how much
/// CPU/RAM the local models are actually costing.
struct LlamaProc: Identifiable {
    let id: Int32          // pid
    let cpu: Double        // percent
    let memMB: Double      // resident size
    let uptimeSec: Int     // elapsed running time in seconds
    let modelPath: String? // full path from the -m argument (to look up the model's stored detail)
    let model: String      // gguf filename (fallback label)
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

    /// Human-readable running time, e.g. "42s", "3m 12s", "1h 5m".
    var uptime: String { Self.formatUptime(uptimeSec) }

    static func formatUptime(_ sec: Int) -> String {
        let s = max(0, sec)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}

enum LlamaProcesses {
    /// Snapshot the running `llama-server` processes. Call off the main thread — it spawns `ps`.
    static func sample() -> [LlamaProc] {
        guard let out = run("/bin/ps", ["-axo", "pid=,pcpu=,rss=,etime=,command="]) else { return [] }
        let roles = pidRoles()
        var procs: [LlamaProc] = []
        for line in out.split(separator: "\n") {
            guard line.contains("llama-server") else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // pid  pcpu  rss  etime  command... (etime = macOS elapsed time, e.g. "03:12" / "1:05:22")
            let parts = trimmed.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count == 5,
                  let pid = Int32(parts[0]), let cpu = Double(parts[1]), let rssKB = Double(parts[2])
            else { continue }
            let command = String(parts[4])
            // Only real llama-server processes: the executable (first token) must be the binary,
            // not some other process that merely mentions "llama-server" in its arguments.
            guard let exe = command.split(separator: " ").first,
                  exe.hasSuffix("llama-server") || exe == "llama-server" else { continue }
            let mPath = modelPath(from: command)
            procs.append(LlamaProc(id: pid, cpu: cpu, memMB: rssKB / 1024.0,
                                   uptimeSec: parseEtime(String(parts[3])),
                                   modelPath: mPath,
                                   model: mPath.map { ($0 as NSString).lastPathComponent } ?? "(unknown model)",
                                   role: roles[pid]))
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

    /// Parse macOS `ps` etime ("[[dd-]hh:]mm:ss") into seconds.
    private static func parseEtime(_ s: String) -> Int {
        var days = 0
        var rest = Substring(s)
        if let dash = s.firstIndex(of: "-") {
            days = Int(s[s.startIndex ..< dash]) ?? 0
            rest = s[s.index(after: dash)...]
        }
        let secs = rest.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
        return days * 86400 + secs
    }

    /// Pull the model path out of the launch command's `-m <path>` argument. The path can contain
    /// spaces (e.g. "…/Application Support/…"), so we take everything after "-m " up to ".gguf"
    /// rather than splitting on spaces.
    private static func modelPath(from command: String) -> String? {
        guard let m = command.range(of: "-m ") else { return nil }
        let after = command[m.upperBound...]
        if let g = after.range(of: ".gguf") { return String(after[..<g.upperBound]) }
        if let flag = after.range(of: " --") { return String(after[..<flag.lowerBound]) }
        return String(after)
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
