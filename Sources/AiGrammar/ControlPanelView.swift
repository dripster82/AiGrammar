import SwiftUI
import AppKit

struct ControlPanelView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var monitor: FocusMonitor
    @ObservedObject var models: ModelManager
    @ObservedObject var prompts: PromptStore
    @ObservedObject var params: InferenceParams
    @State private var route: PanelRoute = .dashboard

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(route: $route).frame(width: 200)
            Divider().overlay(PanelTheme.border)
            VStack(spacing: 0) {
                HStack {
                    PageHeader(title: route.title, subtitle: route.subtitle)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                Divider().overlay(PanelTheme.border)
                ScrollView {
                    detail.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider().overlay(PanelTheme.border)
                buildFooter
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PanelTheme.bg)
        }
        .frame(minWidth: 820, idealWidth: 900, minHeight: 560, idealHeight: 660)
        .preferredColorScheme(.dark)
        .tint(PanelTheme.accent)
    }

    @ViewBuilder private var detail: some View {
        switch route {
        case .dashboard: DashboardPage(settings: settings, monitor: monitor, models: models)
        case .aiModels: AIModelsPage(models: models, settings: settings)
        case .settings: SettingsPage(settings: settings, prompts: prompts, params: params)
        case .diagnostics: DiagnosticsPage(monitor: monitor)
        }
    }

    private var buildFooter: some View {
        HStack(spacing: 6) {
            Circle().fill(monitor.trusted ? .green : .orange).frame(width: 6, height: 6)
            Text("AiGrammar")
            Text("·").foregroundStyle(.tertiary)
            Text("build \(BuildInfo.version)")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 7)
    }
}

// MARK: - Dashboard

private struct DashboardPage: View {
    @ObservedObject var settings: Settings
    @ObservedObject var monitor: FocusMonitor
    @ObservedObject var models: ModelManager

    var body: some View {
        VStack(spacing: 14) {
            Card(title: "Status", icon: "gauge.with.dots.needle.33percent") {
                statusRow("Accessibility permission",
                          monitor.trusted ? "Granted" : "Needed",
                          ok: monitor.trusted,
                          action: monitor.trusted ? nil : { AX.openAccessibilitySettings() })
                statusRow("Slack composer",
                          monitor.snapshot.isSlack ? "Watching" : "Focus Slack to start",
                          ok: monitor.snapshot.isSlack, action: nil)
                statusRow("Rewrite engine",
                          RewriteEngineChoice.resolve(settings.rewriteEngineChoice, models: models).displayName,
                          ok: true, action: nil)
            }
            Card(title: "Corrections", icon: "checkmark.circle") {
                Toggle("Autocorrect high-confidence typos", isOn: $settings.autocorrectEnabled)
                Toggle("Show spelling suggestions", isOn: $settings.suggestionsEnabled)
            }
            Card(title: "Privacy", icon: "lock.shield") {
                Text("Everything runs on your Mac. Spelling uses the on-device dictionary; rewrites use a local model you download here. No message text is ever sent to a server.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func statusRow(_ label: String, _ value: String, ok: Bool,
                           action: (() -> Void)?) -> some View {
        HStack(spacing: 8) {
            Circle().fill(ok ? .green : .orange).frame(width: 8, height: 8)
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
            if let action { Button("Fix…", action: action).controlSize(.small) }
        }
        .font(.callout)
    }
}

// MARK: - AI Models

private struct AIModelsPage: View {
    @ObservedObject var models: ModelManager
    @ObservedObject var settings: Settings
    @State private var customName = ""
    @State private var customLocation = ""
    @State private var llamaPath = UserDefaults.standard.string(forKey: "llamaServerPath") ?? ""
    @State private var llamaInstalled = LlamaServer.isInstalled

    private var usingName: String {
        RewriteEngineChoice.resolve(settings.rewriteEngineChoice, models: models).displayName
    }

    var body: some View {
        VStack(spacing: 14) {
            Card(title: "Rewrite engine", icon: "cpu") {
                Text("Choose which engine rewrites your text. Automatic prefers a local model when one is set, otherwise Apple's on-device model.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Engine", selection: $settings.rewriteEngineChoice) {
                    Text("Automatic").tag("auto")
                    if RewriteEngineChoice.appleAvailable() { Text("Apple on-device").tag("apple") }
                    ForEach(models.readyLocalModels) { m in Text("\(m.name) (llama.cpp)").tag(m.id) }
                    Text("Built-in cleanup (no model)").tag("cleanup")
                }
                .labelsHidden()
                Text("Currently using: \(usingName)")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }

            Card(title: "Apple on-device model", icon: "apple.logo") {
                let status = OnDeviceModel.status
                HStack(spacing: 8) {
                    Circle().fill(status.available ? .green : .orange).frame(width: 8, height: 8)
                    Text(status.available ? "Ready (Apple Intelligence)" : (status.reason ?? "Unavailable"))
                        .font(.callout)
                    Spacer()
                    if !status.available {
                        Button("Enable…") { OnDeviceModel.openSettings() }
                    } else if settings.rewriteEngineChoice == "apple" {
                        Text("SELECTED").font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(PanelTheme.accent.opacity(0.3), in: Capsule())
                    } else {
                        Button("Use") { settings.rewriteEngineChoice = "apple" }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
                Text("Runs on-device (nothing leaves your Mac), no download to manage. Apple Silicon only.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Card(title: "Local models (llama.cpp)", icon: "square.stack.3d.down.right") {
                HStack(spacing: 6) {
                    Circle().fill(llamaInstalled ? .green : .orange).frame(width: 7, height: 7)
                    Text(llamaInstalled
                         ? "llama.cpp runtime found — download a GGUF model below, then click Use to run rewrites through it (works on Intel too)."
                         : "llama.cpp runtime not found. Downloads work now; to run a model, embed it (run Scripts/fetch-llama.sh then rebuild), `brew install llama.cpp`, or set llama-server's path below. See docs/llama-setup.md.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !llamaInstalled {
                    HStack {
                        TextField("/path/to/llama-server", text: $llamaPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse…") { browseForServer() }
                        Button("Save") {
                            UserDefaults.standard.set(llamaPath, forKey: "llamaServerPath")
                            llamaInstalled = LlamaServer.isInstalled
                        }
                    }
                }
                ForEach(models.catalog) { model in
                    ModelRow(model: model, models: models, settings: settings)
                    if model.id != models.catalog.last?.id { Divider().overlay(PanelTheme.border) }
                }
            }

            if !models.custom.isEmpty {
                Card(title: "Your models", icon: "person.crop.square") {
                    ForEach(models.custom) { model in
                        ModelRow(model: model, models: models, settings: settings)
                        if model.id != models.custom.last?.id { Divider().overlay(PanelTheme.border) }
                    }
                }
            }

            Card(title: "Add a model", icon: "plus.square.on.square") {
                Text("Point at a model by download URL (https://…) or a local folder path already on disk.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Name (e.g. My Qwen)", text: $customName)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    TextField("https://…  or  /path/to/model", text: $customLocation)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse…") { browseForFolder() }
                    Button("Add") {
                        models.addCustom(name: customName, urlOrPath: customLocation)
                        customName = ""; customLocation = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(customLocation.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Model parameters (temperature, etc.) are in Settings → Parameters.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func browseForServer() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            llamaPath = url.path
            UserDefaults.standard.set(llamaPath, forKey: "llamaServerPath")
            llamaInstalled = LlamaServer.isInstalled
        }
    }

    private func browseForFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            customLocation = url.path
            if customName.isEmpty { customName = url.lastPathComponent }
        }
    }
}

private struct ModelRow: View {
    let model: ModelInfo
    @ObservedObject var models: ModelManager
    @ObservedObject var settings: Settings

    private var isSelected: Bool { settings.rewriteEngineChoice == model.id }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.name).font(.callout.weight(.medium))
                    if isSelected {
                        Text("SELECTED").font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(PanelTheme.accent.opacity(0.3), in: Capsule())
                    }
                }
                Text(model.sizeNote.isEmpty ? model.detail : "\(model.detail) · \(model.sizeNote)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            controls
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var controls: some View {
        if case .remote(let url) = model.source, model.directDownloadURL == nil {
            // Multi-file repo — no single-file download; open the page to fetch it manually.
            Button("Open page ↗") { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }
                .controlSize(.small)
                .help("Open the model page to download it, then add its folder under \u{201C}Add a model\u{201D}")
        } else {
            // Single-file direct download (GGUF) or a local-path model.
            switch models.state(for: model) {
            case .notDownloaded:
                Button("Download") { models.download(model) }.controlSize(.small)
            case .downloading(let progress):
                HStack(spacing: 8) {
                    ProgressView(value: progress).frame(width: 90)
                    Text("\(Int(progress * 100))%").font(.caption).foregroundStyle(.secondary)
                    Button("Cancel") { models.cancelDownload(model) }.controlSize(.small)
                }
            case .ready:
                HStack(spacing: 8) {
                    if isSelected {
                        Button("Selected") {}.disabled(true).controlSize(.small)
                    } else {
                        Button("Use") { settings.rewriteEngineChoice = model.id }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                    Menu {
                        Button("Remove", role: .destructive) {
                            if isSelected { settings.rewriteEngineChoice = "auto" }
                            models.delete(model)
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).frame(width: 26)
                }
            case .failed(let msg):
                HStack(spacing: 8) {
                    Text(msg).font(.caption).foregroundStyle(.red).lineLimit(1)
                    Button("Retry") { models.download(model) }.controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Settings

private struct SettingsPage: View {
    @ObservedObject var settings: Settings
    @ObservedObject var prompts: PromptStore
    @ObservedObject var params: InferenceParams
    @State private var tab: SettingsTab = .corrections

    enum SettingsTab: String, CaseIterable, Identifiable {
        case corrections, prompts, parameters, shortcuts, about
        var id: String { rawValue }
        var label: String {
            switch self {
            case .corrections: return "Corrections"
            case .prompts: return "AI Prompts"
            case .parameters: return "Parameters"
            case .shortcuts: return "Shortcuts"
            case .about: return "About"
            }
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            Picker("", selection: $tab) {
                ForEach(SettingsTab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            switch tab {
            case .corrections: correctionsCard
            case .prompts: promptsCard
            case .parameters: parametersCard
            case .shortcuts: shortcutsCard
            case .about: aboutCard
            }
        }
    }

    private var parametersCard: some View {
        Card(title: "Model parameters", icon: "slider.horizontal.3") {
            Text("Applied to every rewrite. Temperature, Top-p, and Max tokens work for both Apple's on-device model and local llama.cpp models. Reasoning effort and Advanced apply to llama.cpp only.")
                .font(.caption).foregroundStyle(.secondary)

            sliderRow("Temperature", value: $params.temperature, range: 0...2, step: 0.05,
                      info: "Controls randomness. Low (≈0.2) = focused and consistent; high (≈1.0+) = more varied and creative. For rewrites, lower is usually better.")
            sliderRow("Top-p", value: $params.topP, range: 0...1, step: 0.01,
                      info: "Nucleus sampling: the model only considers the most likely tokens whose probabilities add up to this value. 1.0 = consider everything; lower = safer, less random.")

            HStack {
                labelWithInfo("Max tokens", "The maximum length of the model's response, in tokens (~¾ of a word each). Includes any reasoning tokens, so raise it for reasoning models.")
                TextField("", value: $params.maxTokens, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 80)
                Spacer()
            }

            Divider().overlay(PanelTheme.border)
            Text("llama.cpp only").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)

            HStack {
                labelWithInfo("Reasoning effort", "For reasoning models: how much the model 'thinks' before answering. Higher = more thorough but slower. None disables thinking (llama.cpp launches the model with --reasoning off; the local server restarts automatically when you change this). Low/Medium/High map to reasoning_effort for models that support it.")
                Picker("", selection: $params.reasoningEffort) {
                    Text("None").tag("none")
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                }.labelsHidden().fixedSize()
                Spacer()
            }

            HStack(spacing: 4) {
                Toggle("Short-circuit thinking", isOn: $params.shortcircuitThinking)
                Image(systemName: "info.circle").font(.caption).foregroundStyle(.secondary)
                    .help("Prefills an empty <think></think> block so models with baked-in reasoning (e.g. MiMo) skip straight to the answer. Experimental — works only if the model continues an assistant prefix. Try this when Reasoning effort: None doesn't stop a model from thinking.")
                Spacer()
            }

            DisclosureGroup("Advanced (extra JSON)") {
                Text("Merged into the llama.cpp request, e.g. {\"top_k\": 40, \"min_p\": 0.05, \"repeat_penalty\": 1.1}")
                    .font(.caption2).foregroundStyle(.tertiary)
                TextField("{ }", text: $params.extraJSON, axis: .vertical)
                    .textFieldStyle(.roundedBorder).font(.system(.caption, design: .monospaced))
                    .lineLimit(2...4)
            }
            .font(.caption)

            HStack {
                Spacer()
                Button("Reset to defaults") { params.resetToDefaults() }.controlSize(.small)
            }
        }
    }

    private func labelWithInfo(_ label: String, _ info: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
            Image(systemName: "info.circle").font(.caption).foregroundStyle(.secondary).help(info)
        }
        .frame(width: 130, alignment: .leading)
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>,
                           step: Double, info: String) -> some View {
        HStack {
            labelWithInfo(label, info)
            Slider(value: value, in: range, step: step)
            Text(String(format: "%.2f", value.wrappedValue))
                .font(.system(.caption, design: .monospaced)).frame(width: 40)
        }
    }

    private var correctionsCard: some View {
        Card(title: "Corrections", icon: "textformat.abc") {
            Toggle("Autocorrect high-confidence typos", isOn: $settings.autocorrectEnabled)
            Text("Only unambiguous typos (like “teh” → “the”) are corrected automatically, always with an undo chip. Names, code, URLs, mentions, and acronyms are never touched.")
                .font(.caption).foregroundStyle(.secondary)
            Divider().overlay(PanelTheme.border)
            Toggle("Show spelling suggestions", isOn: $settings.suggestionsEnabled)
            Text("A popover offers a fix near the misspelled word; apply or ignore it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var promptsCard: some View {
        Card(title: "AI Prompts", icon: "text.bubble") {
            Text("Customise the instructions sent to the model. The base prompt is shared by every rewrite; each preset appends its own line.")
                .font(.caption).foregroundStyle(.secondary)
            promptField("Base prompt (all rewrites)", text: $prompts.base, height: 90)
            Divider().overlay(PanelTheme.border)
            promptField("Fix grammar", text: $prompts.fixGrammar)
            promptField("Make clearer", text: $prompts.clearer)
            promptField("Shorten", text: $prompts.shorter)
            promptField("More professional", text: $prompts.professional)
            HStack {
                Spacer()
                Button("Reset to defaults") { prompts.resetToDefaults() }.controlSize(.small)
            }
        }
    }

    private var shortcutsCard: some View {
        Card(title: "Keyboard Shortcuts", icon: "keyboard") {
            ForEach(Shortcuts.all) { s in
                HStack(spacing: 12) {
                    Text(s.keys)
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .frame(width: 52, alignment: .leading)
                        .padding(.vertical, 2).padding(.horizontal, 6)
                        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 5))
                    Text(s.title).font(.callout)
                    Spacer()
                }
            }
        }
    }

    private var aboutCard: some View {
        Card(title: "About", icon: "info.circle") {
            Text("AiGrammar").font(.headline)
            Text("Build \(BuildInfo.version)")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Divider().overlay(PanelTheme.border)
            Label("Local-only. Spelling and rewrites run on your Mac; no message text is sent to any server.",
                  systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func promptField(_ label: String, text: Binding<String>, height: CGFloat = 54) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption.weight(.medium))
            TextEditor(text: text)
                .font(.callout)
                .frame(height: height)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(PanelTheme.border))
        }
    }
}

// MARK: - Diagnostics

private struct DiagnosticsPage: View {
    @ObservedObject var monitor: FocusMonitor
    var body: some View {
        VStack(spacing: 14) {
            Card(title: "Accessibility", icon: "lock.shield") {
                HStack {
                    Circle().fill(monitor.trusted ? .green : .red).frame(width: 8, height: 8)
                    Text(monitor.trusted ? "Permission granted" : "Permission needed")
                    Spacer()
                    if !monitor.trusted {
                        Button("Open Settings…") { AX.openAccessibilitySettings() }
                    }
                }
                .font(.callout)
            }
            Card(title: "Focused element", icon: "cursorarrow.rays") {
                let s = monitor.snapshot
                LabeledContent("App", value: "\(s.appName)")
                LabeledContent("Role", value: s.role)
                LabeledContent("Capabilities", value: s.caps.summary)
            }
            Card(title: "Log", icon: "doc.text") {
                HStack {
                    Text(Log.fileURL.path).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
                    }.controlSize(.small)
                }
            }
        }
    }
}
