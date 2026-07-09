import SwiftUI

/// Phase 1 deliverable: a live view of the focused AX element, the text we can extract from it,
/// and the capability checklist that decides the product's write/overlay strategy.
struct DebugPanelView: View {
    @ObservedObject var monitor: FocusMonitor
    @ObservedObject private var aiLog = AIDebugLog.shared

    // Per-channel log toggles (default on; `.general` is always on and not shown). Log reads these
    // same UserDefaults keys, so flipping a toggle takes effect immediately.
    @AppStorage("log.focus") private var logFocus = true
    @AppStorage("log.pipeline") private var logPipeline = true
    @AppStorage("log.rewrite") private var logRewrite = true
    @AppStorage("log.spell") private var logSpell = true
    @AppStorage("log.llama") private var logLlama = true
    @AppStorage("log.aiPayload") private var logAIPayload = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                aiStreamSection
                Divider()
                permissionSection
                Divider()
                loggingSection
                Divider()
                focusSection
                Divider()
                capabilitiesSection
                Divider()
                textSection
                Divider()
                writeTestSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 480, minHeight: 560)
    }

    private var aiStreamSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Live AI stream")
            Text(aiLog.header).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(aiLog.raw.isEmpty ? "(waiting for a rewrite…)" : aiLog.raw)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 160)
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(monitor.trusted ? .green : .red)
                    .frame(width: 10, height: 10)
                Text(monitor.trusted
                     ? "Accessibility permission granted"
                     : "Accessibility permission missing")
                    .font(.callout.weight(.medium))
                Spacer()
            }
            if !monitor.trusted {
                Text("Enable AiGrammar in System Settings › Privacy & Security › Accessibility, then relaunch. The system dialog only appears once per build, so use the buttons below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Open Accessibility Settings") { AX.openAccessibilitySettings() }
                    Button("Request…") { AX.promptForTrust() }
                    Button("Relaunch") { relaunch() }
                }
            }
            HStack(spacing: 6) {
                Text("Log:").foregroundStyle(.secondary)
                Text(Log.fileURL.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
                }
                .controlSize(.small)
            }
            .font(.caption)
        }
    }

    private var loggingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Logging")
            Text("Choose what gets written to the log. ‘AI prompts & responses’ logs the full prompt sent and the model's raw reply — the fastest way to see why spell check differs from rewrite.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Focus / Accessibility", isOn: $logFocus)
            Toggle("Spellcheck pipeline", isOn: $logPipeline)
            Toggle("AI rewrite", isOn: $logRewrite)
            Toggle("AI spell check", isOn: $logSpell)
            Toggle("Local model server", isOn: $logLlama)
            Toggle("AI prompts & responses (verbose)", isOn: $logAIPayload)
        }
        .font(.callout)
        .toggleStyle(.checkbox)
    }

    private func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private var focusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Focused element")
            row("App", "\(monitor.snapshot.appName)  (\(monitor.snapshot.bundleID))")
            row("Slack?", monitor.snapshot.isSlack ? "✓ yes" : "no")
            row("Role", monitor.snapshot.role)
            row("Role description", monitor.snapshot.roleDescription)
            row("AX changes observed", "\(monitor.observedChangeCount)")
            DisclosureGroup("All attributes (\(monitor.snapshot.attributes.count))") {
                Text(monitor.snapshot.attributes.joined(separator: "  "))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .font(.caption)
        }
    }

    private var capabilitiesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Capabilities")
            capRow("Read AXValue", monitor.snapshot.caps.canReadValue)
            capRow("Read AXSelectedText", monitor.snapshot.caps.canReadSelectedText)
            capRow("Read AXSelectedTextRange", monitor.snapshot.caps.canReadSelectedRange)
            capRow("Write AXValue (settable)", monitor.snapshot.caps.canWriteValue)
            capRow("Write AXSelectedText (settable)", monitor.snapshot.caps.canWriteSelectedText)
            capRow("AXBoundsForRange", monitor.snapshot.caps.canBoundsForRange)
            capRow("AXObserver installs", monitor.snapshot.caps.canObserve)
        }
    }

    private var textSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Extracted text")
            if let range = monitor.snapshot.selectedRange {
                row("Cursor / selection", "location \(range.location), length \(range.length)")
            }
            if let bounds = monitor.snapshot.selectionBounds {
                row("Selection bounds", String(format: "x %.0f  y %.0f  w %.0f  h %.0f",
                                               bounds.origin.x, bounds.origin.y,
                                               bounds.width, bounds.height))
            }
            if let selected = monitor.snapshot.selectedText, !selected.isEmpty {
                row("Selected text", "“\(selected)”")
            }
            Text(monitor.snapshot.text ?? "(no AXValue readable)")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var writeTestSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Write test")
            Text("Click into Slack's message box, type something, then run the test. It appends a marker, verifies it, and restores your text.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Run write test on Slack composer") { monitor.runWriteTest() }
                    .disabled(monitor.lastSlackElement == nil)
                Button("Run read diagnostic") { monitor.runReadDiagnostic() }
                    .disabled(monitor.lastSlackElement == nil)
            }
            Text("Read diagnostic temporarily sets a known sentence, reads it back several ways to find the reliable read path, then restores your text.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(monitor.log.suffix(12).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.headline)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label + ":").foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
        .font(.callout)
    }

    private func capRow(_ label: String, _ ok: Bool) -> some View {
        HStack(spacing: 6) {
            Text(ok ? "✓" : "✗")
                .foregroundStyle(ok ? .green : .red)
                .frame(width: 14)
            Text(label)
        }
        .font(.system(.callout, design: .monospaced))
    }
}
