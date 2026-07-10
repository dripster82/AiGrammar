import Foundation
import Combine

/// A rewrite model — either a curated catalog entry (downloadable) or user-added (a URL or a local
/// folder path pointing at MLC model weights).
struct ModelInfo: Identifiable, Codable, Equatable {
    var id: String                 // stable slug
    var name: String
    var detail: String             // e.g. "Llama 3.2 · 1B · 4-bit"
    var sizeNote: String           // e.g. "~0.7 GB"
    var source: Source
    var builtIn: Bool              // curated catalog vs user-added

    enum Source: Codable, Equatable {
        case remote(url: String)   // download-on-demand
        case localPath(String)     // already on disk (user-provided)
    }

    /// A single-file direct download (e.g. a .gguf) vs a multi-file repo page. Detected from the URL
    /// so no extra stored/Codable fields are needed.
    var directDownloadURL: URL? {
        guard case .remote(let s) = source, let u = URL(string: s) else { return nil }
        let path = u.path.lowercased()
        return (path.hasSuffix(".gguf") || path.contains("/resolve/")) ? u : nil
    }
    var downloadFilename: String {
        if let u = directDownloadURL { return u.lastPathComponent }
        return "model.bin"
    }
}

enum ModelState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case ready(path: String)
    case failed(String)
}

/// Owns the model catalog, downloads, and which model is active. Local-only: models live under
/// Application Support and nothing about them is transmitted. Actual MLC inference is wired
/// separately; this is the management layer the rewrite feature will read from.
final class ModelManager: NSObject, ObservableObject {
    @Published private(set) var catalog: [ModelInfo] = []
    @Published private(set) var custom: [ModelInfo] = []
    @Published private(set) var states: [String: ModelState] = [:]
    @Published var activeModelID: String?

    private var tasks: [String: URLSessionDownloadTask] = [:]
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    var allModels: [ModelInfo] { catalog + custom }

    override init() {
        super.init()
        catalog = Self.curatedCatalog
        loadPersisted()
        refreshStates()
    }

    // MARK: Paths

    static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AiGrammar/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func installURL(for model: ModelInfo) -> URL {
        Self.modelsDirectory.appendingPathComponent(model.id, isDirectory: true)
    }

    /// Path of the downloaded model file on disk.
    func fileURL(for model: ModelInfo) -> URL {
        installURL(for: model).appendingPathComponent(model.downloadFilename)
    }

    // MARK: State

    func state(for model: ModelInfo) -> ModelState {
        if case .localPath(let p) = model.source {
            return FileManager.default.fileExists(atPath: p) ? .ready(path: p) : .failed("Path not found")
        }
        return states[model.id] ?? .notDownloaded
    }

    private func refreshStates() {
        for model in allModels {
            if case .localPath = model.source { continue }
            let file = fileURL(for: model)
            if FileManager.default.fileExists(atPath: file.path) {
                states[model.id] = .ready(path: file.path)
            } else if states[model.id] == nil {
                states[model.id] = .notDownloaded
            }
        }
    }

    // MARK: Downloads

    func download(_ model: ModelInfo) {
        guard case .remote(let urlString) = model.source, let url = URL(string: urlString) else { return }
        guard tasks[model.id] == nil else { return }
        states[model.id] = .downloading(progress: 0)
        Log.write("model download started: \(model.id) from \(urlString)")
        let task = session.downloadTask(with: url)
        task.taskDescription = model.id
        tasks[model.id] = task
        task.resume()
    }

    func cancelDownload(_ model: ModelInfo) {
        tasks[model.id]?.cancel()
        tasks[model.id] = nil
        states[model.id] = .notDownloaded
        Log.write("model download cancelled: \(model.id)")
    }

    func delete(_ model: ModelInfo) {
        if case .remote = model.source {
            try? FileManager.default.removeItem(at: installURL(for: model))
            states[model.id] = .notDownloaded
        }
        if !model.builtIn {
            custom.removeAll { $0.id == model.id }
            persist()
        }
        if activeModelID == model.id { activeModelID = nil; persist() }
        Log.write("model deleted: \(model.id)")
    }

    // MARK: Custom models

    /// Add a user model from a URL (download) or a local folder path (reference).
    @discardableResult
    func addCustom(name: String, urlOrPath: String) -> ModelInfo? {
        let trimmed = urlOrPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let slug = "custom-" + name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let displayName = name.isEmpty ? "Custom model" : name

        let source: ModelInfo.Source
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            source = .remote(url: trimmed)
        } else {
            let expanded = (trimmed as NSString).expandingTildeInPath
            source = .localPath(expanded)
        }
        let model = ModelInfo(id: slug, name: displayName, detail: "User-added",
                              sizeNote: "", source: source, builtIn: false)
        custom.removeAll { $0.id == slug }
        custom.append(model)
        persist()
        refreshStates()
        Log.write("custom model added: \(slug) (\(source))")
        return model
    }

    func setActive(_ model: ModelInfo) {
        activeModelID = model.id
        persist()
    }

    var activeModel: ModelInfo? { allModels.first { $0.id == activeModelID } }

    /// On-disk path of a model's weights by id (the downloaded file, or the user's local path),
    /// or nil if not present.
    func path(forID id: String) -> String? {
        guard let model = allModels.first(where: { $0.id == id }) else { return nil }
        switch model.source {
        case .localPath(let p):
            return FileManager.default.fileExists(atPath: p) ? p : nil
        case .remote:
            let file = fileURL(for: model)
            return FileManager.default.fileExists(atPath: file.path) ? file.path : nil
        }
    }

    /// Downloaded/available local models (their weights are on disk).
    var readyLocalModels: [ModelInfo] {
        allModels.filter { path(forID: $0.id) != nil }
    }

    // MARK: Model metadata (read from the .gguf header)

    /// Parsed detail/size cache for on-disk files, keyed by absolute path.
    private var fileMetaCache: [String: (detail: String, sizeNote: String)] = [:]
    /// Remote (pre-download) metadata fetched via a partial download, keyed by model id.
    @Published private(set) var remoteMeta: [String: (detail: String, sizeNote: String)] = [:]
    private var remoteMetaInFlight: Set<String> = []

    /// Detail + size read from a model's `.gguf` header, for a model whose file is on disk. Nil if
    /// not present or not a readable gguf. Cached per path.
    func fileMetadata(for model: ModelInfo) -> (detail: String, sizeNote: String)? {
        guard let path = path(forID: model.id) else { return nil }
        if let cached = fileMetaCache[path] { return cached }
        guard let info = GGUFMetadata.parse(fileAt: path) else { return nil }
        let detail = GGUFMetadata.detailString(info)
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
        let sizeNote = size.map { Self.sizeString($0) } ?? ""
        guard !detail.isEmpty || !sizeNote.isEmpty else { return nil }
        let result = (detail: detail, sizeNote: sizeNote)
        fileMetaCache[path] = result
        return result
    }

    static func sizeString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// The subtitle line shown on the AI Models page: built-in models keep their curated detail with
    /// the real size; user-added models show detail read from the file. Shared by the model list and
    /// the Diagnostics running-models list so they read the same.
    func displayDetail(for model: ModelInfo) -> String {
        let parsed = fileMetadata(for: model) ?? remoteMeta[model.id]
        if model.builtIn {
            let size = (parsed?.sizeNote).flatMap { $0.isEmpty ? nil : $0 } ?? model.sizeNote
            return size.isEmpty ? model.detail : "\(model.detail) · \(size)"
        }
        if let m = parsed, !(m.detail.isEmpty && m.sizeNote.isEmpty) {
            return m.sizeNote.isEmpty ? m.detail : "\(m.detail) · \(m.sizeNote)"
        }
        return model.sizeNote.isEmpty ? model.detail : "\(model.detail) · \(model.sizeNote)"
    }

    /// Name + detail for a model given the on-disk file path a llama-server was launched with — so the
    /// Diagnostics list reads like the AI Models page. Matches a known model when possible, else reads
    /// the gguf header directly.
    func modelDisplay(forPath path: String) -> (name: String, detail: String) {
        if let model = allModels.first(where: { self.path(forID: $0.id) == path }) {
            return (model.name, displayDetail(for: model))
        }
        let name = (path as NSString).lastPathComponent
        guard let info = GGUFMetadata.parse(fileAt: path) else { return (name, "") }
        var detail = GGUFMetadata.detailString(info)
        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int {
            let sz = Self.sizeString(size)
            detail = detail.isEmpty ? sz : "\(detail) · \(sz)"
        }
        return (name, detail)
    }

    /// Fetch a remote model's header + total size via ONE HTTP Range request — no full download.
    /// Publishes into `remoteMeta` so rows update live. Runs at most once per id; skipped for
    /// local-path models and models already on disk.
    func prefetchRemoteMetadata(for model: ModelInfo) {
        guard case .remote = model.source, let url = model.directDownloadURL,
              remoteMeta[model.id] == nil, !remoteMetaInFlight.contains(model.id),
              path(forID: model.id) == nil else { return }
        remoteMetaInFlight.insert(model.id)
        let id = model.id
        Task { [weak self] in
            let result = await Self.fetchRemoteMetadata(url: url)
            await MainActor.run {
                guard let self else { return }
                self.remoteMetaInFlight.remove(id)
                if let result { self.remoteMeta[id] = result }
            }
        }
    }

    private static func fetchRemoteMetadata(url: URL) async -> (detail: String, sizeNote: String)? {
        var req = URLRequest(url: url)
        // Enough to include general.file_type, which can sit past the tokenizer arrays (~6 MB in).
        req.setValue("bytes=0-8388607", forHTTPHeaderField: "Range")   // first 8 MB
        req.timeoutInterval = 20
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return nil }
            // Total size: Content-Range "bytes 0-…/<total>" on a 206, else Content-Length on a 200.
            var total: Int?
            if let cr = http.value(forHTTPHeaderField: "Content-Range"), let slash = cr.lastIndex(of: "/") {
                total = Int(cr[cr.index(after: slash)...].trimmingCharacters(in: .whitespaces))
            }
            if total == nil, http.statusCode == 200,
               let cl = http.value(forHTTPHeaderField: "Content-Length") {
                total = Int(cl)
            }
            let sizeNote = total.map { sizeString($0) } ?? ""
            let detail = GGUFMetadata.parse(data).map { GGUFMetadata.detailString($0) } ?? ""
            guard !detail.isEmpty || !sizeNote.isEmpty else { return nil }
            return (detail, sizeNote)
        } catch {
            Log.write("model metadata prefetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Persistence

    private struct Persisted: Codable {
        var custom: [ModelInfo]
        var activeModelID: String?
    }

    private var persistURL: URL {
        Self.modelsDirectory.appendingPathComponent("manager.json")
    }

    private func persist() {
        let data = try? JSONEncoder().encode(Persisted(custom: custom, activeModelID: activeModelID))
        try? data?.write(to: persistURL)
    }

    private func loadPersisted() {
        guard let data = try? Data(contentsOf: persistURL),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        custom = p.custom
        activeModelID = p.activeModelID
    }

    // MARK: Curated catalog

    /// A single-file GGUF model with a direct download link (real download, not a repo page).
    /// GGUF is the llama.cpp format — running it needs the llama.cpp backend (see docs/mlc-setup.md
    /// for the runtime status); the download and management work today.
    static let curatedCatalog: [ModelInfo] = [
        ModelInfo(id: "phi-4-mini-instruct-q4ks-gguf",
                  name: "Phi-4 Mini Instruct (GGUF)",
                  detail: "Microsoft · 3.8B · Q4_K_S (llama.cpp)", sizeNote: "~2.3 GB",
                  source: .remote(url: "https://huggingface.co/MaziyarPanahi/Phi-4-mini-instruct-GGUF/resolve/main/Phi-4-mini-instruct.Q4_K_S.gguf?download=true"),
                  builtIn: true),
    ]
}

// MARK: - Download delegate

extension ModelManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        DispatchQueue.main.async { self.states[id] = .downloading(progress: progress) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription,
              let model = allModels.first(where: { $0.id == id }) else { return }
        let dir = installURL(for: model)
        let dest = fileURL(for: model)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            DispatchQueue.main.async {
                self.states[id] = .ready(path: dest.path)
                self.tasks[id] = nil
                Log.write("model download finished: \(id) → \(dest.lastPathComponent)")
            }
        } catch {
            DispatchQueue.main.async {
                self.states[id] = .failed(error.localizedDescription)
                self.tasks[id] = nil
                Log.write("model download move failed: \(id): \(error.localizedDescription)")
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription, let error else { return }
        DispatchQueue.main.async {
            if self.tasks[id] != nil {   // not a user cancel
                self.states[id] = .failed(error.localizedDescription)
                self.tasks[id] = nil
                Log.write("model download error: \(id): \(error.localizedDescription)")
            }
        }
    }
}
