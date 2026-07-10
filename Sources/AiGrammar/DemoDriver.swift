import AppKit
import ApplicationServices

/// Drives Slack end-to-end using synthesized input, to demonstrate the full flow autonomously.
/// This is possible because AiGrammar is Accessibility-trusted, so it may post `CGEvent`s (a plain
/// tool like osascript cannot). It activates Slack, clicks into the composer (which creates Slack's
/// Chromium a11y node the same way a human click does), types a test string, and reads the composer
/// back to confirm the live pipeline autocorrected it. Dev-only, sentinel-gated; cleans up after.
enum DemoDriver {
    private static let slackBundleID = "com.tinyspeck.slackmacgap"

    static func run(monitor: FocusMonitor, pipeline: ComposerPipeline,
                    suggestionPopover: SuggestionPopoverController,
                    completion: @escaping () -> Void) {
        Log.write("=== live demo: driving Slack via synthesized input ===")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { DispatchQueue.main.async { Log.write("=== live demo done ==="); completion() } }

            guard let slack = NSRunningApplication
                    .runningApplications(withBundleIdentifier: slackBundleID).first else {
                Log.write("demo: Slack is not running"); return
            }
            DispatchQueue.main.sync { slack.activate(options: [.activateIgnoringOtherApps]) }
            usleep(1_300_000)

            // Click the composer. Prefer its known AX frame (robust to which monitor Slack is on —
            // AX position is in the same top-left screen space CGEvent uses); else guess window bottom.
            var clickPoint: CGPoint?
            DispatchQueue.main.sync {
                if let el = monitor.lastTargetElement, let f = AX.frame(el), f.width > 0 {
                    clickPoint = CGPoint(x: f.midX, y: f.midY)
                    Log.write("demo: clicking known composer frame \(rect(f)) at \(pt(clickPoint!))")
                } else if let frame = focusedWindowFrame(pid: slack.processIdentifier) {
                    clickPoint = CGPoint(x: frame.midX, y: frame.maxY - 46)
                    Log.write("demo: Slack window \(rect(frame)), clicking composer at \(pt(clickPoint!))")
                }
            }
            guard let point = clickPoint else { Log.write("demo: couldn't read Slack window frame"); return }
            click(at: point)
            usleep(700_000)

            var acquired = false
            DispatchQueue.main.sync { acquired = monitor.acquireComposer() }
            Log.write("demo: composer acquired after click = \(acquired)")
            guard acquired else {
                Log.write("demo: composer not reachable — click may have missed the message box"); return
            }

            // Start from an empty composer.
            DispatchQueue.main.sync { if let el = monitor.lastTargetElement { AX.setValue(el, "") } }
            usleep(400_000)

            // Type a word that should raise a SUGGESTION (helllo → hello).
            type("helllo ")
            usleep(1_300_000)
            DispatchQueue.main.sync {
                let v = composerText(monitor)
                Log.write("demo: after 'helllo ' composer = \"\(v)\"")
            }

            // Type a word that should AUTOCORRECT once complete (teh → the).
            type("teh ")
            usleep(1_600_000)
            DispatchQueue.main.sync {
                let v = composerText(monitor)
                let pass = v.contains("the ") && !v.lowercased().contains("teh ")
                Log.write("demo: after 'teh ' composer = \"\(v)\" — AUTOCORRECT \(pass ? "PASS ✓" : "FAIL ✗")")
            }

            // UNDO: reverse the autocorrect and confirm the text reverts (the user's undo chip path).
            DispatchQueue.main.sync {
                if let last = pipeline.corrections.last {
                    pipeline.undo(last)
                }
            }
            usleep(1_200_000)
            DispatchQueue.main.sync {
                let v = composerText(monitor)
                let pass = v.lowercased().contains("teh ")
                Log.write("demo: after UNDO composer = \"\(v)\" — UNDO \(pass ? "PASS ✓" : "FAIL ✗")")
            }

            // APPLY A SUGGESTION (the exact click-to-apply path the user reported broken).
            DispatchQueue.main.sync { if let el = monitor.lastTargetElement { AX.setValue(el, "") } }
            usleep(400_000)
            type("speeling ")   // suggestion: spelling
            usleep(1_200_000)
            var applied: (word: String, replacement: String)?
            DispatchQueue.main.sync { applied = pipeline.applyFirstSuggestionForTest() }
            usleep(1_300_000)
            DispatchQueue.main.sync {
                let v = composerText(monitor)
                let want = applied?.replacement ?? "spelling"
                let pass = v.lowercased().contains(want.lowercased())
                    && !v.lowercased().contains("speeling")
                Log.write("demo: applied \(applied.map { "\($0.word)→\($0.replacement)" } ?? "nothing"); "
                        + "composer = \"\(v)\" — APPLY SUGGESTION \(pass ? "PASS ✓" : "FAIL ✗")")
            }

            // Test the MANUAL CHECK path (⌃⌘C / menu): type a misspelling that stays (no trailing
            // boundary so it won't autocorrect), then invoke checkNow and confirm a suggestion fires.
            DispatchQueue.main.sync { if let el = monitor.lastTargetElement { AX.setValue(el, "") } }
            usleep(400_000)
            type("speeling")   // no trailing space → suggestion, not autocorrect
            usleep(1_000_000)
            Log.write("demo: invoking manual check (simulates ⌃⌘C / menu)")
            DispatchQueue.main.sync { pipeline.checkNow() }
            usleep(1_200_000)

            // REAL CLICK on the rendered popover — the closest autonomous analog to the user
            // clicking the suggestion bubble. Type a misspelling, let the live pipeline show the
            // popover, then synthesize a mouse click on its first suggestion row and verify the fix.
            DispatchQueue.main.sync { if let el = monitor.lastTargetElement { AX.setValue(el, "") } }
            usleep(400_000)
            type("helllo")            // no trailing space → stays as a suggestion at the cursor
            usleep(500_000)
            DispatchQueue.main.sync { pipeline.checkNow() }   // ensure the popover is shown now
            usleep(1_000_000)
            var guessPoint: CGPoint?
            var popoverUp = false
            DispatchQueue.main.sync {
                popoverUp = suggestionPopover.isVisible
                guessPoint = suggestionPopover.firstGuessClickPoint()
            }
            Log.write("demo: popover visible = \(popoverUp), click point = \(guessPoint.map(pt) ?? "nil")")
            if let point = guessPoint {
                click(at: point)          // real synthesized mouse click on the popover button
                usleep(1_300_000)
                DispatchQueue.main.sync {
                    let v = composerText(monitor)
                    let pass = v.lowercased().contains("hello") && !v.lowercased().contains("helllo")
                    Log.write("demo: after REAL CLICK on popover, composer = \"\(v)\" — CLICK-TO-APPLY \(pass ? "PASS ✓" : "FAIL ✗")")
                }
            } else {
                Log.write("demo: popover not shown — cannot click-test")
            }

            // Clean up so we don't leave test text in the user's composer (never sends — no Return).
            usleep(300_000)
            DispatchQueue.main.sync { if let el = monitor.lastTargetElement { AX.setValue(el, "") } }
        }
    }

    // MARK: Synthesized input

    private static func click(at point: CGPoint) {
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(60_000)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    /// Types text by posting Unicode keyboard events (no keycode mapping needed).
    private static func type(_ string: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        for ch in string {
            var utf16 = Array(String(ch).utf16)
            if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                up.post(tap: .cghidEventTap)
            }
            usleep(35_000)
        }
    }

    // MARK: Helpers

    private static func composerText(_ monitor: FocusMonitor) -> String {
        monitor.lastTargetElement.flatMap { AX.string($0, kAXValueAttribute as String) } ?? ""
    }

    private static func focusedWindowFrame(pid: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        if let w = AX.copyAttribute(app, kAXFocusedWindowAttribute as String),
           CFGetTypeID(w) == AXUIElementGetTypeID() {
            return AX.frame((w as! AXUIElement))
        }
        if let wins = AX.copyAttribute(app, kAXWindowsAttribute as String) as? [AXUIElement],
           let first = wins.first {
            return AX.frame(first)
        }
        return nil
    }

    private static func rect(_ r: CGRect) -> String {
        String(format: "(%.0f,%.0f %.0fx%.0f)", r.origin.x, r.origin.y, r.width, r.height)
    }
    private static func pt(_ p: CGPoint) -> String { String(format: "(%.0f,%.0f)", p.x, p.y) }
}
