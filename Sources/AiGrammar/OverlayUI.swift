import AiGrammarCore
import AppKit
import SwiftUI

/// A borderless, non-activating panel that can still become key. Borderless panels default to
/// `canBecomeKey == false`, which can swallow clicks to SwiftUI buttons (the "picking a suggestion
/// did nothing" symptom). Overriding it lets the panel take clicks WITHOUT activating our app —
/// so the composer isn't disturbed, but Apply/Undo/Accept reliably fire.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A borderless, non-activating floating panel — clicking its buttons must NOT steal focus from
/// Slack's composer, or the user would be kicked out of the message box on every correction.
private func makeOverlayPanel(size: NSSize) -> NSPanel {
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
    return panel
}

/// Places a panel just below `wordRect` (screen coords), flipping above if it would clip off the
/// bottom of the screen. Falls back to centered if there is no anchor.
private func place(_ panel: NSPanel, below wordRect: CGRect?, size: NSSize) {
    guard let rect = wordRect else {
        panel.center()
        return
    }
    var origin = NSPoint(x: rect.minX, y: rect.minY - size.height - 6)
    if let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main {
        if origin.y < screen.visibleFrame.minY {  // clipped at bottom → show above the word
            origin.y = rect.maxY + 6
        }
        origin.x = min(
            max(origin.x, screen.visibleFrame.minX),
            screen.visibleFrame.maxX - size.width)
    }
    panel.setFrameOrigin(origin)
}

// MARK: - Issue-count indicator (floats by the composer)

/// A small badge pinned near Slack's composer showing the outstanding spelling-issue count
/// (red with a number) or a green check when clean. Clicking it pops a menu: re-check / AI rewrite.
final class IssueCountIndicatorController: NSObject {
    private var panel: NSPanel?
    private var count = 0
    private var lastComposerAX: CGRect?
    private var checking = false
    var onRecheck: (() -> Void)?
    var onRewrite: (() -> Void)?

    /// Toggle the spinner state (an on-demand AI check is running) without changing the count/position.
    func setChecking(_ on: Bool) {
        checking = on
        update(count: count, composerAX: lastComposerAX)
    }

    /// Show/refresh the badge at the composer's top-right. `composerAX` is the composer frame in AX
    /// (top-left origin) coordinates; pass nil to hide.
    func update(count: Int, composerAX: CGRect?) {
        guard let composerAX else {
            hide()
            return
        }
        self.count = count
        self.lastComposerAX = composerAX

        let view = CountBadgeView(count: count, checking: checking, onTap: { [weak self] in self?.popMenu() })
        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        let size = NSSize(
            width: max(hosting.fittingSize.width, 24),
            height: max(hosting.fittingSize.height, 20))

        let panel: NSPanel
        if let existing = self.panel {
            panel = existing
            panel.setContentSize(size)
        } else {
            panel = makeOverlayPanel(size: size)
            self.panel = panel
        }
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting

        // Pin just above the composer's top-right corner (clear of Slack's formatting toolbar).
        let targetAX = CGRect(
            x: composerAX.maxX - size.width - 10,
            y: composerAX.minY - size.height - 4,
            width: size.width, height: size.height)
        panel.setFrameOrigin(Geometry.cocoaRect(fromAX: targetAX).origin)
        panel.orderFront(nil)
    }

    private func popMenu() {
        guard let view = panel?.contentView else { return }
        let menu = NSMenu()
        let recheck = NSMenuItem(
            title: "Check spelling", action: #selector(menuRecheck), keyEquivalent: "")
        recheck.target = self
        let rewrite = NSMenuItem(
            title: "AI rewrite…", action: #selector(menuRewrite), keyEquivalent: "")
        rewrite.target = self
        menu.addItem(recheck)
        menu.addItem(rewrite)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    @objc private func menuRecheck() { onRecheck?() }
    @objc private func menuRewrite() { onRewrite?() }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct CountBadgeView: View {
    let count: Int
    var checking: Bool = false
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: "textformat.abc")
                    .font(.system(size: 14, weight: .bold))
                if checking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else if count > 0 {
                    Text("\(count)").font(.callout.weight(.bold))
                } else {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(checking ? Color.blue : (count > 0 ? Color.red : Color.green), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.25)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(
            checking ? "AI spell check running…"
                : (count > 0
                    ? "\(count) spelling issue\(count == 1 ? "" : "s") — click for options"
                    : "No spelling issues — click for options"))
    }
}

// MARK: - Suggestion popover

final class SuggestionPopoverController {
    private var panel: NSPanel?
    var onApply: ((SpellIssue, String) -> Void)?
    var onIgnore: ((SpellIssue) -> Void)?
    var onSkip: ((SpellIssue) -> Void)?
    var onClose: (() -> Void)?

    func show(issue: SpellIssue, at wordRect: CGRect?) {
        hide()
        // apply/ignore/skip advance the review (which shows the next word or ends and hides), so
        // they must NOT hide here — a trailing hide() would close the freshly-shown next popover.
        let view = SuggestionView(
            issue: issue,
            apply: { [weak self] guess in self?.onApply?(issue, guess) },
            ignore: { [weak self] in self?.onIgnore?(issue) },
            skip: { [weak self] in self?.onSkip?(issue) },
            close: { [weak self] in
                self?.hide()
                self?.onClose?()
            })
        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        let size = NSSize(width: 260, height: max(hosting.fittingSize.height, 44))
        let panel = makeOverlayPanel(size: size)
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        place(panel, below: wordRect, size: size)
        panel.orderFront(nil)
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Global (CGEvent, top-left origin) coordinates of the first suggestion row, so a driver can
    /// synthesize a real click on the rendered button — verifying the full hit-test/apply path.
    func firstGuessClickPoint() -> CGPoint? {
        guard let f = panel?.frame else { return nil }
        // Layout: 10pt padding, ~20pt word row, 6pt spacing, then the first guess row (~20pt).
        let cocoa = CGPoint(x: f.minX + 60, y: f.maxY - 48)
        let primaryHeight =
            NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        let global = CGPoint(x: cocoa.x, y: primaryHeight - cocoa.y)
        Log.write(
            "popover panel frame (\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))) "
                + "→ guess click cocoa(\(Int(cocoa.x)),\(Int(cocoa.y))) global(\(Int(global.x)),\(Int(global.y)))"
        )
        return global
    }

    var isVisible: Bool { panel?.isVisible ?? false }
}

private struct SuggestionView: View {
    let issue: SpellIssue
    let apply: (String) -> Void
    let ignore: () -> Void
    var skip: () -> Void = {}
    let close: () -> Void

    private var choices: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for g in ([issue.topGuess].compactMap { $0 } + issue.guesses) where seen.insert(g).inserted
        {
            out.append(g)
            if out.count == 5 { break }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(issue.word)
                    .strikethrough()
                    .foregroundStyle(.red)
                    .font(.callout.weight(.medium))
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close (the word can appear again)")
            }
            ForEach(choices, id: \.self) { guess in
                let isAI = issue.aiGuesses.contains(guess)
                Button {
                    apply(guess)
                } label: {
                    HStack(spacing: 6) {
                        Text(guess)
                        Spacer()
                        if isAI {
                            Image(systemName: "brain")
                                .font(.caption2).foregroundStyle(.purple)
                                .help("Suggested by the AI model")
                        }
                        Image(systemName: "return").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(isAI ? Color.purple.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider().overlay(.quaternary)
            HStack(spacing: 12) {
                Button(action: skip) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right.to.line").font(.caption2)
                        Text("Skip")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Leave this word and go to the next (stays flagged)")
                Spacer()
                Button(action: ignore) {
                    HStack(spacing: 4) {
                        Image(systemName: "nosign").font(.caption2)
                        Text("Ignore")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Don't flag this word again this session")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(width: 260, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }
}

// MARK: - Undo chip

final class UndoChipController {
    private var panel: NSPanel?
    private var dismissWork: DispatchWorkItem?
    var onUndo: ((Correction) -> Void)?

    func show(correction: Correction, at wordRect: CGRect?) {
        hide()
        let view = UndoChipView(
            correction: correction,
            undo: { [weak self] in
                self?.onUndo?(correction)
                self?.hide()
            })
        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        let size = NSSize(
            width: max(hosting.fittingSize.width, 220),
            height: max(hosting.fittingSize.height, 34))
        let panel = makeOverlayPanel(size: size)
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        place(panel, below: wordRect, size: size)
        panel.orderFront(nil)
        self.panel = panel

        // Auto-dismiss after a few seconds — the correction stays applied; only the chip goes.
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    func hide() {
        dismissWork?.cancel()
        dismissWork = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

/// Renders the actual overlay views to PNGs, so the UI can be inspected without a screen-recording
/// grant. Dev-only, used to produce visual proof of what the user sees.
enum UIProof {
    static func renderAll(to dir: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let issue = SpellIssue(
            range: NSRange(location: 0, length: 8), word: "speeling",
            guesses: ["spelling", "speeding", "sleeping"], disposition: .suggest)
        render(
            SuggestionView(issue: issue, apply: { _ in }, ignore: {}, close: {}),
            to: dir + "/suggestion.png")

        let corr = Correction(
            original: "teh", corrected: "the",
            rangeAfter: NSRange(location: 0, length: 3),
            contextBefore: "", contextAfter: "")
        render(UndoChipView(correction: corr, undo: {}), to: dir + "/undochip.png")

        render(CountBadgeView(count: 3, onTap: {}), to: dir + "/badge-red.png")
        render(CountBadgeView(count: 0, onTap: {}), to: dir + "/badge-green.png")
        render(HelpView(close: {}), to: dir + "/help.png")

        let session = RewriteSession(
            original: "test", makeStream: { _ in AsyncStream { $0.finish() } })
        render(
            RewriteView(
                session: session, engineName: "Built-in cleanup (no model)",
                isCleanup: true, accept: { _ in }, close: {}), to: dir + "/cleanup.png")

        let done = RewriteSession(
            original: "test", makeStream: { _ in AsyncStream { $0.finish() } })
        done.chosen = .professional
        done.output = "Team, could someone please review the code in #3452? Thanks!"
        done.sawThinking = true
        done.thinkingSeconds = 2.4
        done.totalSeconds = 6.1
        render(
            RewriteView(
                session: done, engineName: "Local model · Phi-4 (llama.cpp)",
                accept: { _ in }, close: {}), to: dir + "/result.png")
    }

    private static func render<V: View>(_ view: V, to path: String) {
        let wrapped = view.padding(24).background(Color(red: 0.09, green: 0.10, blue: 0.16))
        let hosting = NSHostingView(rootView: wrapped)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        rep.size = hosting.bounds.size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            Log.write(
                "UIProof rendered \(path) (\(Int(hosting.bounds.width))x\(Int(hosting.bounds.height)))"
            )
        }
        window.orderOut(nil)
    }
}

private struct UndoChipView: View {
    let correction: Correction
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            (Text(correction.original).strikethrough().foregroundStyle(.secondary)
                + Text("  →  ") + Text(correction.corrected).foregroundStyle(.primary))
                .font(.callout)
            Divider().frame(height: 16)
            Button("Undo", action: undo)
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary))
        .fixedSize()
    }
}
