import AppKit
import ApplicationServices
import Combine

/// What the app can and cannot do against the currently focused element. This checklist is the
/// whole point of Phase 1 — the design doc's "capability detection" against Slack's Electron
/// composer, which decides whether later phases can use the direct AX path or need fallbacks.
struct Capabilities {
    var canReadValue = false
    var canReadSelectedText = false
    var canReadSelectedRange = false
    var canWriteValue = false
    var canWriteSelectedText = false
    var canBoundsForRange = false
    var canObserve = false

    var summary: String {
        func b(_ v: Bool) -> String { v ? "1" : "0" }
        return "value:\(b(canReadValue)) selText:\(b(canReadSelectedText)) selRange:\(b(canReadSelectedRange)) "
             + "wValue:\(b(canWriteValue)) wSel:\(b(canWriteSelectedText)) bounds:\(b(canBoundsForRange)) observe:\(b(canObserve))"
    }
}

struct FocusSnapshot {
    var appName = "—"
    var bundleID = "—"
    var isSlack = false
    var role = "—"
    var roleDescription = "—"
    var attributes: [String] = []
    var text: String?
    var selectedText: String?
    var selectedRange: CFRange?
    var selectionBounds: CGRect?
    var caps = Capabilities()
}

/// Polls the system-wide focused element (0.5s — plenty for a debug panel; the product pipeline
/// will use AXObserver + debounce) and probes what Slack exposes. Also tries to install an
/// AXObserver on the focused element so "can observe changes?" gets a real answer, not a guess.
final class FocusMonitor: ObservableObject {
    static let slackBundleID = "com.tinyspeck.slackmacgap"

    @Published var trusted = AX.isTrusted
    @Published var snapshot = FocusSnapshot()
    @Published var observedChangeCount = 0
    @Published var log: [String] = []

    /// Last element seen focused inside Slack. The write test targets this, so it keeps working
    /// even though clicking our (non-activating) panel can momentarily shift AX focus.
    private(set) var lastSlackElement: AXUIElement?

    private var timer: Timer?
    private var observer: AXObserver?
    private var observedPid: pid_t = 0
    private var slackA11yEnabledPid: pid_t = 0
    private var lastTrusted: Bool?
    private var lastLoggedSignature = ""
    private var lastComposerText: String?
    private var wasComposerFocused = false

    /// Fires when Slack's composer text changes (drives the correction pipeline).
    var onComposerValueChanged: (() -> Void)?
    /// Fires when focus leaves Slack's composer (dismiss transient UI).
    var onComposerUnfocused: (() -> Void)?

    func start() {
        Log.write("AiGrammar launched. Accessibility trusted = \(AX.isTrusted). Log at \(Log.fileURL.path)")
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    func refresh() {
        trusted = AX.isTrusted
        if lastTrusted != trusted {
            lastTrusted = trusted
            Log.write("Accessibility trusted = \(trusted)")
        }

        // Force Slack's Electron accessibility tree on (idempotent per pid). Retries every tick
        // until it succeeds, since it can't work until permission is granted.
        enableSlackAccessibilityIfNeeded()

        // Dev hook: if the sentinel exists and we can reach Slack's composer, run the read
        // diagnostic against the live (frontmost) Slack tree, then clear the sentinel.
        let sentinel = NSHomeDirectory() + "/.aigrammar-readdiag"
        if trusted, FileManager.default.fileExists(atPath: sentinel) {
            if lastSlackElement != nil || acquireSlackComposer() {
                try? FileManager.default.removeItem(atPath: sentinel)
                Log.write("readdiag: composer acquired, running diagnostic.")
                runReadDiagnostic()
            }
        }

        guard trusted, let element = AX.systemWideFocusedElement() else {
            // No AX read available — still show which app is frontmost so the panel isn't blank.
            var snap = FocusSnapshot()
            if let front = NSWorkspace.shared.frontmostApplication {
                snap.appName = front.localizedName ?? "?"
                snap.bundleID = front.bundleIdentifier ?? "?"
                snap.isSlack = front.bundleIdentifier == Self.slackBundleID
            }
            snap.role = trusted ? "(no focused element read)" : "(waiting for Accessibility permission)"
            logSnapshotIfChanged(snap)
            snapshot = snap
            notifyComposerState(snap)
            return
        }

        var snap = FocusSnapshot()
        if let pid = AX.pid(element),
           let app = NSRunningApplication(processIdentifier: pid) {
            // Ignore our own windows so the panel keeps showing the last interesting state.
            if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
            snap.appName = app.localizedName ?? "?"
            snap.bundleID = app.bundleIdentifier ?? "?"
            snap.isSlack = app.bundleIdentifier == Self.slackBundleID
        }

        snap.role = AX.string(element, kAXRoleAttribute as String) ?? "—"
        snap.roleDescription = AX.string(element, kAXRoleDescriptionAttribute as String) ?? "—"
        snap.attributes = AX.attributeNames(element)

        snap.text = AX.string(element, kAXValueAttribute as String)
        snap.selectedText = AX.string(element, kAXSelectedTextAttribute as String)
        snap.selectedRange = AX.range(element, kAXSelectedTextRangeAttribute as String)

        snap.caps.canReadValue = snap.text != nil
        snap.caps.canReadSelectedText = snap.selectedText != nil
        snap.caps.canReadSelectedRange = snap.selectedRange != nil
        snap.caps.canWriteValue = AX.isSettable(element, kAXValueAttribute as String)
        snap.caps.canWriteSelectedText = AX.isSettable(element, kAXSelectedTextAttribute as String)
        if let range = snap.selectedRange {
            snap.selectionBounds = AX.boundsForRange(
                element, location: range.location, length: max(range.length, 1))
            snap.caps.canBoundsForRange = snap.selectionBounds != nil
        }
        snap.caps.canObserve = installObserverIfNeeded(for: element)

        if snap.isSlack {
            lastSlackElement = element
        }
        logSnapshotIfChanged(snap)
        snapshot = snap
        notifyComposerState(snap)
    }

    /// Poll-based fallback so text changes are caught even if the AXObserver missed them (e.g. it
    /// was installed on a sibling element). Both paths funnel into the debounced pipeline.
    private func notifyComposerState(_ snap: FocusSnapshot) {
        if snap.isSlack {
            wasComposerFocused = true
            if snap.text != lastComposerText {
                lastComposerText = snap.text
                onComposerValueChanged?()
            }
        } else if wasComposerFocused {
            wasComposerFocused = false
            lastComposerText = nil
            onComposerUnfocused?()
        }
    }

    /// Acquire Slack's composer without relying on system-wide focus, by asking Slack's app element
    /// for its focused UI element. Used by the headless diagnostic (osascript-activate doesn't make
    /// the composer first responder the way a real click does).
    @discardableResult
    func acquireSlackComposer() -> Bool {
        guard let slack = NSRunningApplication
                .runningApplications(withBundleIdentifier: Self.slackBundleID).first else { return false }
        let app = AXUIElementCreateApplication(slack.processIdentifier)
        guard let focused = AX.copyAttribute(app, kAXFocusedUIElementAttribute as String),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = focused as! AXUIElement
        let role = AX.string(element, kAXRoleAttribute as String)
        if role == kAXTextAreaRole as String || role == kAXTextFieldRole as String {
            lastSlackElement = element
            Log.write("acquireSlackComposer: via focused element (\(role ?? "?"))")
            return true
        }
        // Composer isn't first responder (no click) — search the window tree for the text area.
        if let composer = Self.searchTextArea(app) {
            _ = AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            lastSlackElement = composer
            Log.write("acquireSlackComposer: via tree search")
            return true
        }
        Log.write("acquireSlackComposer: FAILED (focused role=\(role ?? "nil")); keeping \(lastSlackElement == nil ? "no" : "previous") element")
        return false
    }

    private static func searchTextArea(_ element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 14 else { return nil }
        if AX.string(element, kAXRoleAttribute as String) == kAXTextAreaRole as String {
            return element
        }
        for child in AX.children(element) {
            if let found = searchTextArea(child, depth: depth + 1) { return found }
        }
        return nil
    }

    private func enableSlackAccessibilityIfNeeded() {
        guard let slack = NSRunningApplication
                .runningApplications(withBundleIdentifier: Self.slackBundleID).first else { return }
        let pid = slack.processIdentifier
        guard pid != slackA11yEnabledPid else { return }
        if AX.enableManualAccessibility(pid: pid) {
            slackA11yEnabledPid = pid
            Log.write("Enabled AXManualAccessibility on Slack (pid \(pid)).")
        }
    }

    private func logSnapshotIfChanged(_ snap: FocusSnapshot) {
        let sig = "\(snap.bundleID)|\(snap.role)|\(snap.caps.summary)|len=\(snap.text?.count ?? -1)"
        guard sig != lastLoggedSignature else { return }
        lastLoggedSignature = sig
        Log.write("focus app=\(snap.appName) bundle=\(snap.bundleID) slack=\(snap.isSlack) "
                + "role=\(snap.role) [\(snap.caps.summary)] textLen=\(snap.text?.count ?? -1)")
    }

    // MARK: AXObserver probe

    private func installObserverIfNeeded(for element: AXUIElement) -> Bool {
        guard let pid = AX.pid(element) else { return false }
        if pid == observedPid, observer != nil { return true }

        if let old = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(old), .defaultMode)
            observer = nil
            observedPid = 0
        }

        var new: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<FocusMonitor>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            DispatchQueue.main.async { monitor.noteObservedChange(name) }
        }
        guard AXObserverCreate(pid, callback, &new) == .success, let new else { return false }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var added = false
        for notification in [kAXValueChangedNotification, kAXSelectedTextChangedNotification,
                             kAXFocusedUIElementChangedNotification] {
            if AXObserverAddNotification(new, element, notification as CFString, refcon) == .success {
                added = true
            }
        }
        guard added else { return false }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(new), .defaultMode)
        observer = new
        observedPid = pid
        return true
    }

    private func noteObservedChange(_ name: String) {
        observedChangeCount += 1
        if name == kAXValueChangedNotification as String, snapshot.isSlack {
            onComposerValueChanged?()
        }
    }

    // MARK: Write test

    /// The Phase 1 safety gate: read the composer, append a marker via AXValue (falling back to
    /// AXSelectedText), verify the read-back, then restore the original text and cursor. If this
    /// round-trips cleanly against Slack, the direct AX write path is viable.
    func runWriteTest() {
        guard let element = lastSlackElement else {
            appendLog("✗ No Slack composer seen yet — click into Slack's message box first.")
            return
        }
        guard let original = AX.string(element, kAXValueAttribute as String) else {
            appendLog("✗ Could not read AXValue from the Slack composer.")
            return
        }
        let originalRange = AX.range(element, kAXSelectedTextRangeAttribute as String)
        let marker = " ·aigrammar-test·"

        var wrote = false
        var path = "AXValue"
        if AX.setValue(element, original + marker) == .success {
            wrote = true
        } else {
            // Fallback: place the cursor at the end and replace the (empty) selection.
            path = "AXSelectedText"
            _ = AX.setSelectedRange(element, location: (original as NSString).length, length: 0)
            wrote = AX.setSelectedText(element, marker) == .success
        }
        guard wrote else {
            appendLog("✗ Write failed via both AXValue and AXSelectedText — direct AX write path is unavailable.")
            return
        }

        // Verify AFTER the async write settles. Slack's Quill editor applies an AX setValue
        // asynchronously, so an immediate read-back returns the pre-write value even though the
        // text visibly changed — that stale read was the "read-back doesn't show marker" warning.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            let readBack = AX.string(element, kAXValueAttribute as String) ?? ""
            let verified = readBack.hasSuffix(marker)
            self?.appendLog(verified
                ? "✓ Wrote via \(path) and verified read-back after settle."
                : "⚠ Wrote via \(path); read-back still off after settle (got \(readBack.count) chars): the write may not have applied.")
            self?.restoreAfterWriteTest(element: element, original: original, marker: marker,
                                        path: path, originalRange: originalRange)
        }
    }

    private func restoreAfterWriteTest(element: AXUIElement, original: String, marker: String,
                                       path: String, originalRange: CFRange?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            var restored = AX.setValue(element, original) == .success
            if !restored, path == "AXSelectedText" {
                let full = AX.string(element, kAXValueAttribute as String) ?? ""
                if full.hasSuffix(marker) {
                    let start = (full as NSString).length - (marker as NSString).length
                    _ = AX.setSelectedRange(element, location: start, length: (marker as NSString).length)
                    restored = AX.setSelectedText(element, "") == .success
                }
            }
            if restored, let range = originalRange {
                _ = AX.setSelectedRange(element, location: range.location, length: range.length)
            }
            self?.appendLog(restored
                ? "✓ Restored original text\(originalRange != nil ? " and cursor" : "")."
                : "✗ RESTORE FAILED — composer may still contain the test marker; remove it by hand.")
        }
    }

    /// Sets the composer to a KNOWN sentence, then reads it back through every available strategy,
    /// to discover which read path is reliable on Slack's Electron composer (AXValue read-back is
    /// known to be lossy). Restores the original afterwards.
    func runReadDiagnostic() {
        guard let element = lastSlackElement else {
            appendLog("✗ No Slack composer seen yet — click into Slack's message box first.")
            return
        }
        let original = AX.string(element, kAXValueAttribute as String) ?? ""
        let originalRange = AX.range(element, kAXSelectedTextRangeAttribute as String)
        let known = "The quick brown fox jumps over teh lazy dog"

        guard AX.setValue(element, known) == .success else {
            appendLog("✗ Could not set known sentence (AXValue setter failed).")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            let axValue = AX.string(element, kAXValueAttribute as String)
            let nChars = AX.int(element, kAXNumberOfCharactersAttribute as String)
            let viaRange = nChars.flatMap { AX.stringForRange(element, location: 0, length: $0) }
            let viaDescendants = AX.descendantText(element)
            let childCount = AX.children(element).count

            func report(_ label: String, _ text: String?) {
                let ok = text == known
                let shown = text.map { "\"\($0.prefix(60))\" (\($0.count) chars)" } ?? "nil"
                self.appendLog("\(ok ? "✓" : "·") \(label): \(shown)")
            }
            self.appendLog("— read diagnostic (expected \(known.count) chars) —")
            self.appendLog("children of composer: \(childCount), AXNumberOfCharacters: \(nChars.map(String.init) ?? "nil")")
            report("AXValue", axValue)
            report("AXStringForRange(0..<n)", viaRange)
            report("descendant text", viaDescendants.isEmpty ? nil : viaDescendants)

            // Restore.
            _ = AX.setValue(element, original)
            if let range = originalRange {
                _ = AX.setSelectedRange(element, location: range.location, length: range.length)
            }
            self.appendLog(original.isEmpty ? "✓ Cleared test sentence." : "✓ Restored original text.")
        }
    }

    private func appendLog(_ line: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        log.append("[\(stamp)] \(line)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
        Log.write("writetest: \(line)")
    }
}
