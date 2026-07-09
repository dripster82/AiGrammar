import AppKit
import ApplicationServices
import Combine
import SwiftUI

/// Drives the "rewrite selected sentence" flow: read the composer selection, run the engine,
/// stream into a popover, and replace on accept (via the proven whole-text `setValue` path).
///
/// The engine is chosen from the active model: a real MLC model when one is wired, otherwise the
/// on-device heuristic cleanup. `AI on explicit action only` — nothing here runs while typing.
final class RewriteController {
    private let monitor: FocusMonitor
    private let models: ModelManager
    private let popover = RewritePopoverController()

    private let prompts: PromptStore
    private let settings: Settings
    private let params: InferenceParams

    init(
        monitor: FocusMonitor, models: ModelManager, prompts: PromptStore,
        settings: Settings, params: InferenceParams
    ) {
        self.monitor = monitor
        self.models = models
        self.prompts = prompts
        self.settings = settings
        self.params = params
        popover.onAccept = { [weak self] range, element, newText in
            self?.applyReplacement(range: range, element: element, newText: newText)
        }
    }

    /// Cached GGUF rewriter (holds a warm llama-server), keyed by model path.
    private var ggufCache: (path: String, engine: GGUFRewriter)?

    /// The engine name shown in the UI (Dashboard / popover footer), without instantiating anything.
    var effectiveEngineName: String {
        RewriteEngineChoice.resolve(settings.rewriteEngineChoice, models: models).displayName
    }

    /// True when the effective engine is the no-model heuristic (offer "Clean up", not AI presets).
    private var isCleanupEngine: Bool {
        RewriteEngineChoice.resolve(settings.rewriteEngineChoice, models: models) == .cleanup
    }

    private func engine() -> RewriteEngine {
        switch RewriteEngineChoice.resolve(settings.rewriteEngineChoice, models: models) {
        case .cleanup:
            return HeuristicRewriter()
        case .apple:
            #if canImport(FoundationModels)
                if #available(macOS 26.0, *) { return FoundationModelsRewriter(params: params) }
            #endif
            return HeuristicRewriter()
        case .local(let model):
            let path = models.path(forID: model.id) ?? ""
            if let cached = ggufCache, cached.path == path { return cached.engine }
            ggufCache?.engine.shutdown()
            let engine = GGUFRewriter(modelPath: path, modelName: model.name, params: params)
            ggufCache = (path, engine)
            return engine
        }
    }

    /// Stop any warm llama-server (called on app quit).
    func shutdown() { ggufCache?.engine.shutdown() }

    /// Triggered by ⌃⌘R or the badge menu. Rewrites the selection — or, if nothing is selected,
    /// the entire composer message. `preset` (from ⌃⌘1–4) runs that rewrite immediately.
    func rewriteSelection(preset: RewriteInstruction? = nil) {
        if !monitor.snapshot.isSlack { monitor.acquireSlackComposer() }
        guard let element = monitor.lastSlackElement else {
            Log.write("rewrite: no Slack composer")
            popover.showMessage("Focus Slack's message box first.")
            return
        }

        let selected = AX.string(element, kAXSelectedTextAttribute as String) ?? ""
        let target: String
        let nsRange: NSRange
        if selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Nothing selected → rewrite the whole message.
            guard let full = AX.string(element, kAXValueAttribute as String),
                !full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                popover.showMessage("Type or select some text to rewrite first.")
                return
            }
            target = full
            nsRange = NSRange(location: 0, length: (full as NSString).length)
            Log.write("rewrite: whole message (\(full.count) chars, no selection)")
        } else {
            guard let range = AX.range(element, kAXSelectedTextRangeAttribute as String) else {
                popover.showMessage("Couldn't read the selection range.")
                return
            }
            target = selected
            nsRange = NSRange(location: range.location, length: range.length)
            Log.write("rewrite: selection \(selected.count) chars at \(range.location)")
        }

        let cfRange = CFRange(location: nsRange.location, length: nsRange.length)
        let bounds = selectionBounds(element: element, range: cfRange)
        popover.show(
            original: target, range: nsRange, element: element,
            engineName: effectiveEngineName, isCleanup: isCleanupEngine,
            at: bounds, autoRun: preset,
            makeStream: { [weak self] instruction in
                guard let self else { return AsyncStream { $0.finish() } }
                let systemPrompt = self.prompts.systemPrompt(for: instruction)
                return self.engine().rewrite(
                    target, instruction: instruction, systemPrompt: systemPrompt)
            })
    }

    private func applyReplacement(range: NSRange, element: AXUIElement, newText: String) {
        guard let current = AX.string(element, kAXValueAttribute as String) else { return }
        let ns = current as NSString
        guard range.location + range.length <= ns.length else {
            Log.write("rewrite apply skipped: range out of bounds (text changed)")
            return
        }
        let updated = ns.replacingCharacters(in: range, with: newText)
        guard AX.setValue(element, updated) == .success else {
            Log.write("rewrite apply failed: setValue rejected")
            return
        }
        let caret = range.location + (newText as NSString).length
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            _ = AX.setSelectedRange(element, location: caret, length: 0)
        }
        Log.write("rewrite applied: \(newText.count) chars")
    }

    private func selectionBounds(element: AXUIElement, range: CFRange) -> CGRect? {
        if let ax = AX.boundsForRange(
            element, location: range.location, length: max(range.length, 1))
        {
            let composer = AX.frame(element)
            let sane =
                ax.width > 0 && ax.height > 0
                && (composer.map {
                    $0.insetBy(dx: -8, dy: -60).contains(CGPoint(x: ax.midX, y: ax.midY))
                } ?? true)
            if sane { return Geometry.cocoaRect(fromAX: ax) }
        }
        if let composer = AX.frame(element) { return Geometry.cocoaRect(fromAX: composer) }
        return nil
    }
}

/// The rewrite engine actually in effect, resolved from the user's choice + what's available.
/// Shared by RewriteController (to run) and the UI (to display / offer the picker).
enum RewriteEngineChoice: Equatable {
    case apple
    case cleanup
    case local(ModelInfo)

    var displayName: String {
        switch self {
        case .apple: return "Apple on-device model"
        case .cleanup: return "Built-in cleanup (no model)"
        case .local(let m): return "\(m.name) · llama.cpp"
        }
    }

    static func appleAvailable() -> Bool {
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) { return FoundationModelsRewriter.isAvailable }
        #endif
        return false
    }

    /// Resolve the stored choice ("auto" | "apple" | "cleanup" | model-id) to a concrete engine,
    /// falling back gracefully when the preferred one isn't usable.
    static func resolve(_ choice: String, models: ModelManager) -> RewriteEngineChoice {
        func usableLocal(_ id: String) -> ModelInfo? {
            guard LlamaServer.isInstalled,
                let m = models.allModels.first(where: { $0.id == id }),
                models.path(forID: id) != nil
            else { return nil }
            return m
        }
        switch choice {
        case "cleanup":
            return .cleanup
        case "apple":
            return appleAvailable() ? .apple : .cleanup
        case "auto":
            if LlamaServer.isInstalled, let m = models.readyLocalModels.first { return .local(m) }
            if appleAvailable() { return .apple }
            return .cleanup
        default:  // a specific local model id
            if let m = usableLocal(choice) { return .local(m) }
            if appleAvailable() { return .apple }
            return .cleanup
        }
    }
}

// MARK: - Streaming session

final class RewriteSession: ObservableObject {
    @Published var output = ""
    @Published var streaming = false
    @Published var chosen: RewriteInstruction?
    // Timings (kept after completion so users can see how long it took).
    @Published var sawThinking = false
    @Published var thinkingSeconds: Double = 0  // duration of the <think> phase (0 if none)
    @Published var totalSeconds: Double = 0  // whole elapsed time

    let original: String
    private let makeStream: (RewriteInstruction) -> AsyncStream<String>
    private var task: Task<Void, Never>?

    private enum Phase { case idle, thinking, rewriting, done }
    private var phase: Phase = .idle
    private var start: Date?
    private var ticker: Timer?

    init(original: String, makeStream: @escaping (RewriteInstruction) -> AsyncStream<String>) {
        self.original = original
        self.makeStream = makeStream
    }

    func run(_ instruction: RewriteInstruction) {
        task?.cancel()
        Log.write("[rewrite] picked option: \(instruction.id) — rewrite begun")
        chosen = instruction
        output = ""
        streaming = true
        sawThinking = false
        thinkingSeconds = 0
        totalSeconds = 0
        start = Date()
        phase = .rewriting  // switches to .thinking if the stream emits "Thinking…"
        startTicker()
        let stream = makeStream(instruction)
        task = Task { [weak self] in
            for await partial in stream {
                await MainActor.run { self?.consume(partial) }
            }
            await MainActor.run { self?.finish() }
        }
    }

    private func consume(_ partial: String) {
        if partial == "Thinking…" {
            if phase != .thinking {
                phase = .thinking
                sawThinking = true
            }
        } else if phase == .thinking {
            // Reasoning finished — freeze the thinking time.
            thinkingSeconds = Date().timeIntervalSince(start ?? Date())
            phase = .rewriting
        }
        output = partial
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let start = self.start else { return }
            self.totalSeconds = Date().timeIntervalSince(start)
            if self.phase == .thinking { self.thinkingSeconds = self.totalSeconds }
        }
    }

    private func finish() {
        if let start { totalSeconds = Date().timeIntervalSince(start) }
        if phase == .thinking { thinkingSeconds = totalSeconds }
        phase = .done
        streaming = false
        ticker?.invalidate()
        ticker = nil
        Log.write(
            "[rewrite] generation complete (total \(formatDuration(totalSeconds))\(sawThinking ? ", thinking \(formatDuration(thinkingSeconds))" : ""))"
        )
    }

    func cancel() {
        task?.cancel()
        streaming = false
        ticker?.invalidate()
        ticker = nil
    }

    /// Back to the preset picker (stops any in-flight rewrite).
    func reset() {
        task?.cancel()
        ticker?.invalidate()
        ticker = nil
        streaming = false
        output = ""
        chosen = nil
        phase = .idle
        sawThinking = false
        thinkingSeconds = 0
        totalSeconds = 0
    }
}

/// Format an elapsed duration: sub-second → milliseconds (0.234s), <1 min → tenths (12.3s),
/// ≥1 min → "1min 23secs".
func formatDuration(_ seconds: Double) -> String {
    if seconds < 1 { return String(format: "%.3fs", seconds) }
    if seconds < 60 { return String(format: "%.1fs", seconds) }
    let m = Int(seconds) / 60
    let s = Int(seconds) % 60
    return "\(m)min \(s)secs"
}

// MARK: - Popover

final class RewritePopoverController {
    private var panel: NSPanel?
    private var session: RewriteSession?
    private var hasBeenClicked = false  // user clicked the popover AFTER generation began/completed
    private var clickMonitor: Any?  // clicks inside our app (engagement)
    private var outsideClickMonitor: Any?  // clicks in other apps (dismiss when not pinned)
    private var streamingCancellable: AnyCancellable?
    /// (selection range, composer element, accepted text)
    var onAccept: ((NSRange, AXUIElement, String) -> Void)?

    /// While a rewrite is generating, or generated-but-the-user-hasn't-clicked-it, the popover is
    /// "pinned" and must NOT be dismissed on focus loss — they haven't engaged with the result yet.
    /// Once generation is done AND they've clicked into it, it becomes dismissable on focus loss.
    var isPinned: Bool {
        guard let session else { return false }  // no active rewrite (e.g. showMessage) → not pinned
        return session.streaming || !hasBeenClicked
    }

    func show(
        original: String, range: NSRange, element: AXUIElement, engineName: String,
        isCleanup: Bool = false, at rect: CGRect?, autoRun: RewriteInstruction? = nil,
        makeStream: @escaping (RewriteInstruction) -> AsyncStream<String>
    ) {
        hide(reason: "new rewrite requested")
        let session = RewriteSession(original: original, makeStream: makeStream)
        self.session = session
        // When a rewrite BEGINS, clear engagement — so the click that picked the preset (to start it)
        // doesn't count as "engaged with the result". Only a click after that lifts the pin.
        streamingCancellable = session.$streaming
            .sink { [weak self] streaming in if streaming { self?.hasBeenClicked = false } }
        let view = RewriteView(
            session: session, engineName: engineName, isCleanup: isCleanup, autoRun: autoRun,
            accept: { [weak self] text in
                self?.onAccept?(range, element, text)
                self?.hide(reason: "accepted")
            },
            close: { [weak self] in
                self?.hide(reason: (self?.session?.streaming ?? false) ? "cancelled" : "rejected")
            })
        present(NSHostingView(rootView: view), at: rect, width: 320)
    }

    func showMessage(_ message: String) {
        hide(reason: "showing message")
        let view = VStack(alignment: .leading, spacing: 8) {
            Label("Rewrite", systemImage: "sparkles").font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary)
        }
        .padding(12).frame(width: 280, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        present(NSHostingView(rootView: view), at: nil, width: 280)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.hide(reason: "message timeout")
        }
    }

    private func present(_ hosting: NSView, at rect: CGRect?, width: CGFloat) {
        hasBeenClicked = false
        hosting.layoutSubtreeIfNeeded()
        let size = NSSize(width: width, height: max(hosting.fittingSize.height, 80))
        let panel = OverlayPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting

        // "Engaged" = a real click INSIDE the popover. A local monitor only fires for events routed
        // to our app (i.e. a click on this panel), never a click in another app — so this is precise,
        // unlike windowDidBecomeKey which could fire on show.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) {
            [weak self, weak panel] event in
            if let self, let panel, event.window == panel {
                self.hasBeenClicked = true
                Log.write("[rewrite] popover clicked → engaged")
            }
            return event
        }
        // A click in ANOTHER app (global monitor) dismisses the popover — but only if it isn't pinned
        // (generating / not-yet-engaged). Only fires on real clicks, so no per-poll log spam.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
            .leftMouseDown, .rightMouseDown,
        ]) { [weak self] _ in
            guard let self, let panel = self.panel else { return }
            if !panel.frame.contains(NSEvent.mouseLocation) {
                Log.write("[rewrite] clicked outside — pinned=\(self.isPinned)")
                if !self.isPinned {
                    self.hide(reason: "clicked outside, generation done + engaged")
                }
            }
        }
        if let rect {
            var origin = NSPoint(x: rect.minX, y: rect.minY - size.height - 8)
            if let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) })
                ?? NSScreen.main
            {
                if origin.y < screen.visibleFrame.minY { origin.y = rect.maxY + 8 }
                origin.x = min(
                    max(origin.x, screen.visibleFrame.minX), screen.visibleFrame.maxX - size.width)
            }
            panel.setFrameOrigin(origin)
        } else {
            panel.center()
        }
        // Open WITHOUT stealing focus, so the pin only lifts on a real click (tracked above).
        panel.orderFront(nil)
        self.panel = panel
        Log.write("[rewrite] show popup")
    }

    func hide(reason: String = "") {
        guard panel != nil else { return }
        Log.write("[rewrite] hide — \(reason.isEmpty ? "unspecified" : reason)")
        session?.cancel()  // stop any in-flight generation (Cancel button / focus-loss dismiss)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        clickMonitor = nil
        outsideClickMonitor = nil
        streamingCancellable = nil
        panel?.orderOut(nil)
        panel = nil
        session = nil
        hasBeenClicked = false
    }
}

struct RewriteView: View {
    @ObservedObject var session: RewriteSession
    let engineName: String
    var isCleanup: Bool = false
    var autoRun: RewriteInstruction? = nil
    let accept: (String) -> Void
    let close: () -> Void
    @State private var customText = ""

    var body: some View {
        content
            .onAppear { if let autoRun, session.chosen == nil { session.run(autoRun) } }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(
                    isCleanup ? "Clean up" : "Rewrite",
                    systemImage: isCleanup ? "textformat.abc" : "sparkles"
                ).font(.headline)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }

            if session.chosen == nil {
                if isCleanup { cleanupPicker } else { presetPicker }
            } else {
                resultView
            }

            Text(engineName).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    /// Shown when no AI model is selected — the heuristic can only tidy, not rewrite, so offer one
    /// clear action describing exactly what it does instead of the AI tone presets.
    private var cleanupPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No AI model selected. This tidies your text without rewriting it:")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Label("Fix spelling", systemImage: "checkmark.circle").font(.caption)
                Label("Capitalize sentences", systemImage: "checkmark.circle").font(.caption)
                Label("Fix spacing & punctuation", systemImage: "checkmark.circle").font(.caption)
            }
            .foregroundStyle(.secondary)
            Button {
                session.run(.fixGrammar)
            } label: {
                Label("Clean up text", systemImage: "textformat.abc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Text(
                "For real rewriting, pick a model in AI Models (Apple on-device or a local model)."
            )
            .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var presetPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Choose how to rewrite the selection:")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(RewriteInstruction.presets.enumerated()), id: \.offset) {
                index, instruction in
                Button {
                    session.run(instruction)
                } label: {
                    HStack {
                        Label(instruction.label, systemImage: instruction.icon)
                        Spacer()
                        Text("⌘\(index + 1)").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .help(instruction.help)
            }
            Divider().overlay(.quaternary)
            Text("…or ask for something specific:")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("e.g. make it friendlier, add a greeting", text: $customText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(runCustom)
                Button(action: runCustom) {
                    Image(systemName: "arrow.up.circle.fill").font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(customText.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Rewrite with your instruction")
            }
        }
    }

    private func runCustom() {
        let ask = customText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ask.isEmpty else { return }
        session.run(.custom(ask))
    }

    @ViewBuilder private var resultView: some View {
        HStack(spacing: 6) {
            Label(session.chosen?.label ?? "", systemImage: session.chosen?.icon ?? "sparkles")
                .font(.caption.weight(.medium))
            Spacer()
            Button("Change") { session.reset() }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.blue)
                .help("Pick a different rewrite")
        }

        ScrollView {
            if session.output.isEmpty || session.output == "Thinking…" {
                HStack(spacing: 6) {
                    if session.streaming { ProgressView().controlSize(.small) }
                    Text(
                        session.output == "Thinking…"
                            ? "Thinking…"
                            : (session.streaming ? "Rewriting…" : "No output")
                    )
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(session.output)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .frame(height: 140)
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))

        HStack(spacing: 10) {
            timerView
            Spacer()
            if session.streaming {
                // Still generating — only offer Cancel (stops generation and closes).
                Button("Cancel", action: close).buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Stop generating and discard")
            } else {
                Button("Reject", action: close).buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Discard and keep your original text")
                Button("Accept") { accept(session.output) }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.output.isEmpty)
                    .help("Replace the selection with this rewrite")
            }
        }
    }

    @ViewBuilder private var timerView: some View {
        if session.streaming {
            // Running → a single total elapsed value.
            Text(formatDuration(session.totalSeconds))
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        } else {
            // Finished → Thinking (only if there was any) + Total.
            HStack(spacing: 8) {
                if session.sawThinking {
                    Text("Thinking: \(formatDuration(session.thinkingSeconds))")
                }
                Text("Writing: \(formatDuration(session.totalSeconds))")
            }
            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}
