import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

// Programmatic app entry (no @main attribute conflicts with SwiftPM main.swift).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // menu-bar only, no Dock icon
app.run()

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var debugPanel: NSPanel!

    let settings = Settings()
    let monitor = FocusMonitor()
    let models = ModelManager()
    let prompts = PromptStore()
    let inferenceParams = InferenceParams()
    lazy var pipeline = ComposerPipeline(monitor: monitor, settings: settings)
    let suggestionPopover = SuggestionPopoverController()
    let undoChip = UndoChipController()
    let issueIndicator = IssueCountIndicatorController()
    lazy var rewriteController = RewriteController(
        monitor: monitor, models: models, prompts: prompts, settings: settings,
        params: inferenceParams)
    let helpOverlay = HelpOverlayController()
    var controlWindow: NSWindow!
    var hotKeys: [GlobalHotKey] = []
    private var lastIssueCount = 0
    private var cancellables = Set<AnyCancellable>()

    private var sigterm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Kill any llama-server orphaned by a previous crash/force-quit before doing anything else.
        LlamaServer.killStaleServer()
        // Also clean up our llama-server if we're SIGTERM'd (e.g. `pkill`), where applicationWill
        // Terminate doesn't run. (SIGKILL can't be caught — that's what killStaleServer covers.)
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { [weak self] in self?.rewriteController.shutdown(); NSApp.terminate(nil) }
        src.resume()
        sigterm = src

        // Dev hook: exercise the spell engine (NSSpellChecker + policy) headlessly and quit.
        if FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.aigrammar-selftest") {
            try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/.aigrammar-selftest")
            runEngineSelfTest()
            return
        }
        if FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.aigrammar-uiproof") {
            try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/.aigrammar-uiproof")
            let dir = NSHomeDirectory() + "/.aigrammar-uiproof-out"
            UIProof.renderAll(to: dir)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            return
        }
        if !AX.isTrusted { AX.promptForTrust() }
        wirePipeline()
        monitor.start()
        setupMainMenu()
        setupMenuBar()
        setupControlWindow()
        setupDebugPanel()
        showControlWindow()

        // Global shortcuts (all ⌃⌘): C check · R rewrite · 1–4 rewrite presets · H help.
        let cmd = UInt32(controlKey | cmdKey)
        func hk(_ key: Int, _ id: UInt32, _ action: @escaping () -> Void) {
            if let h = GlobalHotKey(keyCode: key, modifiers: cmd, id: id, action: action) {
                hotKeys.append(h)
            }
        }
        hk(kVK_ANSI_C, 1) { [weak self] in
            Log.write("[trigger] ⌃⌘C")
            self?.pipeline.checkNow()
        }
        hk(kVK_ANSI_R, 2) { [weak self] in
            Log.write("[trigger] ⌃⌘R")
            self?.rewriteController.rewriteSelection()
        }
        hk(kVK_ANSI_1, 3) { [weak self] in
            self?.rewriteController.rewriteSelection(preset: .fixGrammar)
        }
        hk(kVK_ANSI_2, 4) { [weak self] in
            self?.rewriteController.rewriteSelection(preset: .clearer)
        }
        hk(kVK_ANSI_3, 5) { [weak self] in
            self?.rewriteController.rewriteSelection(preset: .shorter)
        }
        hk(kVK_ANSI_4, 6) { [weak self] in
            self?.rewriteController.rewriteSelection(preset: .professional)
        }
        hk(kVK_ANSI_H, 7) { [weak self] in self?.helpOverlay.toggle() }
        Log.write("hotkeys registered: \(hotKeys.count)/7")

        // Dev hook: drive Slack end-to-end via synthesized input to demonstrate the live pipeline.
        if FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.aigrammar-demo") {
            try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/.aigrammar-demo")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                DemoDriver.run(
                    monitor: self.monitor, pipeline: self.pipeline,
                    suggestionPopover: self.suggestionPopover
                ) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        rewriteController.shutdown()  // stop any warm llama-server
    }

    // Menu-triggered: opening the menu bar backgrounds Slack, so its composer reads go stale.
    // Re-activate Slack first, then check against the live composer. (The ⌃⌘C shortcut doesn't
    // need this — pressing it leaves Slack focused.)
    @objc private func checkNow() {
        Log.write("[trigger] menu 'Check Spelling Now' selected — re-activating Slack")
        NSRunningApplication.runningApplications(withBundleIdentifier: FocusMonitor.slackBundleID)
            .first?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.pipeline.checkNow()
        }
    }
    @objc private func rewriteSelection() {
        NSRunningApplication.runningApplications(withBundleIdentifier: FocusMonitor.slackBundleID)
            .first?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.rewriteController.rewriteSelection()
        }
    }

    private func setupControlWindow() {
        controlWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        controlWindow.title = "AiGrammar"
        controlWindow.isReleasedWhenClosed = false
        controlWindow.contentView = NSHostingView(
            rootView: ControlPanelView(
                settings: settings, monitor: monitor, models: models,
                prompts: prompts, params: inferenceParams))
        controlWindow.center()
    }

    @objc private func showControlWindow() {
        // Center on the screen under the mouse cursor.
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let f = controlWindow.frame, vf = screen.visibleFrame
            controlWindow.setFrameOrigin(NSPoint(x: vf.midX - f.width / 2, y: vf.midY - f.height / 2))
        }
        controlWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func wirePipeline() {
        pipeline.onSuggestion = { [weak self] issue, bounds in
            self?.suggestionPopover.show(issue: issue, at: bounds)
        }
        pipeline.onAutocorrect = { [weak self] correction, bounds in
            self?.undoChip.show(correction: correction, at: bounds)
        }
        pipeline.onDismissUI = { [weak self] in
            self?.suggestionPopover.hide()
        }
        pipeline.onIssueCount = { [weak self] count in
            self?.lastIssueCount = count
            self?.refreshIndicator()
        }
        issueIndicator.onRecheck = { [weak self] in self?.pipeline.checkNow() }
        issueIndicator.onRewrite = { [weak self] in self?.rewriteController.rewriteSelection() }
        // Reposition/hide the floating badge as focus moves in and out of Slack's composer.
        monitor.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIndicator() }
            .store(in: &cancellables)
        suggestionPopover.onApply = { [weak self] issue, guess in
            self?.pipeline.applySuggestion(issue, replacement: guess)
        }
        suggestionPopover.onIgnore = { [weak self] issue in
            self?.pipeline.ignore(issue)
        }
        suggestionPopover.onSkip = { [weak self] issue in
            self?.pipeline.skipCurrentReview(issue)
        }
        suggestionPopover.onClose = { [weak self] in
            self?.pipeline.endReview()
        }
        undoChip.onUndo = { [weak self] correction in
            self?.pipeline.undo(correction)
        }
        _ = pipeline  // instantiate the lazy pipeline now so callbacks are live
    }

    // MARK: Menu bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "textformat.abc.dottedunderline",
            accessibilityDescription: "AiGrammar")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Keep overlays tied to the focused target window: show the count badge when the composer is
    /// focused; when focus leaves it (to another app/window) hide ALL popups. `FocusMonitor` ignores
    /// our own process, so interacting with our popups doesn't count as leaving — they stay open.
    /// (Currently the target is Slack's composer; this generalizes as more apps are supported.)
    private func refreshIndicator() {
        if monitor.snapshot.isSlack, let element = monitor.lastSlackElement,
            let frame = AX.frame(element)
        {
            issueIndicator.update(count: lastIssueCount, composerAX: frame)
        } else {
            issueIndicator.hide()
            suggestionPopover.hide()
            // The rewrite popover manages its own dismissal via a click-outside monitor (so it isn't
            // evaluated on every poll — which spammed the log — and respects the pin).
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        @discardableResult
        func add(_ title: String, _ sel: Selector?, state: NSControl.StateValue = .off)
            -> NSMenuItem
        {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = sel == nil ? nil : self
            item.state = state
            menu.addItem(item)
            return item
        }

        // Layout mirrors AR Workspace Manager: status → Open → actions → toggles → Shortcuts +
        // Launch at Login → Quit.
        let status =
            monitor.trusted
            ? (monitor.snapshot.isSlack
                ? "Watching Slack composer" : "Ready — focus Slack to start")
            : "Accessibility permission needed"
        add(status, nil)
        menu.addItem(.separator())

        add("Open AiGrammar…", #selector(showControlWindow))
        if !monitor.trusted { add("Grant Accessibility Permission…", #selector(openAccessibility)) }
        menu.addItem(.separator())

        add("Check Spelling Now  (⌃⌘C)", #selector(checkNow))
        add("Rewrite Selection  (⌃⌘R)", #selector(rewriteSelection))
        menu.addItem(.separator())

        add(
            "Autocorrect high-confidence typos", #selector(toggleAutocorrect),
            state: settings.autocorrectEnabled ? .on : .off)
        add(
            "Show spelling suggestions", #selector(toggleSuggestions),
            state: settings.suggestionsEnabled ? .on : .off)
        menu.addItem(.separator())

        add("Keyboard Shortcuts  (⌃⌘H)", #selector(showHelp))
        add(
            "Launch at Login", #selector(toggleLaunchAtLogin),
            state: LaunchAtLogin.isEnabled ? .on : .off)
        add("AX Debug Panel", #selector(toggleDebugPanel))
        menu.addItem(.separator())

        add("Quit AiGrammar", #selector(NSApplication.terminate(_:))).target = nil
    }

    @objc private func toggleLaunchAtLogin() { LaunchAtLogin.isEnabled.toggle() }

    /// A standard Edit menu so ⌘X/⌘C/⌘V/⌘A/⌘Z route to the focused text field everywhere (control
    /// panel, popovers). Without it, an accessory app's text fields ignore those key equivalents.
    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(
            withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        NSApp.mainMenu = mainMenu
    }

    @objc private func showHelp() { helpOverlay.show() }
    @objc private func toggleAutocorrect() { settings.autocorrectEnabled.toggle() }
    @objc private func toggleSuggestions() {
        settings.suggestionsEnabled.toggle()
        if !settings.suggestionsEnabled { suggestionPopover.hide() }
    }
    @objc private func openAccessibility() { AX.openAccessibilitySettings() }

    // MARK: Debug panel

    private func setupDebugPanel() {
        debugPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered, defer: false)
        debugPanel.title = "AiGrammar — AX Debug"
        debugPanel.isFloatingPanel = true
        debugPanel.level = .floating
        debugPanel.isReleasedWhenClosed = false
        debugPanel.hidesOnDeactivate = false
        debugPanel.contentView = NSHostingView(rootView: DebugPanelView(monitor: monitor))
    }

    @objc private func toggleDebugPanel() {
        if debugPanel.isVisible {
            debugPanel.orderOut(nil)
        } else {
            debugPanel.center()
            debugPanel.orderFront(nil)
        }
    }

    // MARK: Engine self-test

    private func runEngineSelfTest() {
        let engine = SpellEngine()
        let cases: [(text: String, word: String, expect: String)] = [
            ("I think teh cat is here", "teh", "autocorrect"),
            ("please recieve this", "recieve", "autocorrect"),
            ("well helllo there", "helllo", "suggest"),
            ("ping @sam now", "@sam", "none"),
            ("see https://x.com/y today", "https://x.com/y", "none"),
        ]
        // RewriteText.display: <think> handling + trailing note stripping.
        let thinkFull =
            "<think>\nlots of reasoning...\n</think>\n\n@team please review #3452.\n\n(Revised for clarity and tone, preserving @mentions.)"
        let d1 = RewriteText.display(thinkFull)
        Log.write(
            "\(d1 == "@team please review #3452." ? "✓" : "✗") think+note stripped → \"\(d1)\"")
        let d2 = RewriteText.display("<think>\nstill reasoning, no close yet")
        Log.write("\(d2 == "Thinking…" ? "✓" : "✗") mid-think → \"\(d2)\"")
        let d3 = RewriteText.display("Just a normal reply.\n(see attached)")
        Log.write(
            "\(d3 == "Just a normal reply.\n(see attached)" ? "✓" : "✗") keeps non-meta paren → \"\(d3.replacingOccurrences(of: "\n", with: "⏎"))\""
        )

        // InferenceParams.requestBody merges temperature, reasoning_effort, and extra JSON.
        let ip = InferenceParams()
        ip.temperature = 0.7
        ip.reasoningEffort = "high"
        ip.extraJSON = "{\"top_k\": 40, \"min_p\": 0.05}"
        let body = ip.requestBody(messages: [["role": "user", "content": "hi"]], stream: true)
        let okBody =
            (body["temperature"] as? Double) == 0.7
            && (body["reasoning_effort"] as? String) == "high"
            && (body["top_k"] as? Int) == 40
        Log.write(
            "\(okBody ? "✓" : "✗") params body: temp=\(body["temperature"] ?? "?") reasoning=\(body["reasoning_effort"] ?? "?") top_k=\(body["top_k"] ?? "?")"
        )
        ip.resetToDefaults()

        Log.write("=== engine self-test ===")
        for c in cases {
            let issues = engine.issues(in: c.text)
            let match = issues.first { $0.word == c.word }
            let got: String
            switch match?.disposition {
            case .autocorrect: got = "autocorrect"
            case .suggest: got = "suggest"
            case .ignore, nil: got = "none"
            }
            let ok = got == c.expect
            let fix = match?.topGuess ?? "-"
            Log.write(
                "\(ok ? "✓" : "✗") \"\(c.word)\" → \(got) (expected \(c.expect)), topGuess=\(fix)")
        }
        Log.write("=== engine self-test done ===")

        // Model manager checks.
        Log.write("=== model manager self-test ===")
        let mm = ModelManager()
        Log.write(
            "\(mm.catalog.count == 4 ? "✓" : "✗") catalog has \(mm.catalog.count) curated models (expected 4)"
        )
        if let first = mm.catalog.first {
            let notDownloaded = mm.state(for: first) == .notDownloaded
            Log.write("\(notDownloaded ? "✓" : "✗") curated model starts not-downloaded")
        }
        let tmp = NSTemporaryDirectory()
        if let custom = mm.addCustom(name: "Local Test", urlOrPath: tmp) {
            let ready: Bool = {
                if case .ready = mm.state(for: custom) { return true }
                return false
            }()
            Log.write("\(ready ? "✓" : "✗") local-path custom model is ready (existing dir)")
            mm.setActive(custom)
            Log.write(
                "\(mm.activeModelID == custom.id ? "✓" : "✗") active model persists selection")
            mm.delete(custom)
            Log.write("\(mm.custom.isEmpty ? "✓" : "✗") custom model removed")
        }
        if let remote = mm.addCustom(
            name: "Remote Test", urlOrPath: "https://example.com/model.bin")
        {
            let isRemote: Bool = {
                if case .remote = remote.source { return true }
                return false
            }()
            Log.write("\(isRemote ? "✓" : "✗") https custom model treated as remote download")
            mm.delete(remote)
        }
        Log.write("=== model manager self-test done ===")

        // Foundation Models (on-device LLM) availability + a real rewrite, if available.
        Log.write("=== foundation models self-test ===")
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                if FoundationModelsRewriter.isAvailable {
                    Log.write("✓ Apple on-device model AVAILABLE — running a real rewrite")
                    Task {
                        let engine = FoundationModelsRewriter(params: InferenceParams())
                        var last = ""
                        let sp = PromptStore.defaultBase + " " + PromptStore.defaultClearer
                        for await partial in engine.rewrite(
                            "i thnik this mesage is bit unclear and to long",
                            instruction: .clearer, systemPrompt: sp)
                        {
                            last = partial
                        }
                        Log.write("LLM rewrite result: \"\(last)\"")
                        Log.write("=== foundation models self-test done ===")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            NSApp.terminate(nil)
                        }
                    }
                    return
                } else {
                    Log.write(
                        "· Apple on-device model unavailable: \(FoundationModelsRewriter.unavailabilityReason() ?? "unknown") — heuristic fallback"
                    )
                }
            } else {
                Log.write("· macOS < 26 — heuristic fallback")
            }
        #else
            Log.write("· FoundationModels SDK not present — heuristic fallback")
        #endif
        Log.write("=== foundation models self-test done ===")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
    }
}
