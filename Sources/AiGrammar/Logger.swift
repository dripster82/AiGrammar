import Foundation

/// Appends diagnostics to ~/Library/Logs/AiGrammar/aigrammar.log so permission state, focused
/// elements, and capability probes can be reviewed after the fact (tail -f the file).
enum Log {
    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/AiGrammar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("aigrammar.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        return url
    }()

    private static let queue = DispatchQueue(label: "io.github.dripster82.AiGrammar.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ line: String) {
        let text = "[\(stamp.string(from: Date()))] \(line)\n"
        queue.async {
            guard let data = text.data(using: .utf8),
                  let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        }
    }
}
