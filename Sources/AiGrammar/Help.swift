import AppKit
import SwiftUI

/// One keyboard shortcut, shared by the help overlay and the Settings → Shortcuts tab.
struct Shortcut: Identifiable {
    let keys: String
    let title: String
    var id: String { keys }
}

enum Shortcuts {
    static let all: [Shortcut] = [
        Shortcut(keys: "⌃⌘C", title: "Check spelling now"),
        Shortcut(keys: "⌃⌘R", title: "Rewrite selection (or whole message)"),
        Shortcut(keys: "⌃⌘1", title: "Rewrite · Fix grammar"),
        Shortcut(keys: "⌃⌘2", title: "Rewrite · Make clearer"),
        Shortcut(keys: "⌃⌘3", title: "Rewrite · Shorten"),
        Shortcut(keys: "⌃⌘4", title: "Rewrite · More professional"),
        Shortcut(keys: "⌃⌘H", title: "Show this help"),
    ]
}

/// A centered, dismissable shortcuts overlay (⌃⌘H), in the AR Workspace help style.
final class HelpOverlayController {
    private var panel: NSPanel?

    var isVisible: Bool { panel != nil }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        hide()
        let hosting = NSHostingView(rootView: HelpView(close: { [weak self] in self?.hide() }))
        hosting.layoutSubtreeIfNeeded()
        let size = NSSize(width: 380, height: max(hosting.fittingSize.height, 200))
        let panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.isReleasedWhenClosed = false
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct HelpView: View {
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Keyboard Shortcuts", systemImage: "keyboard").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)   // Esc closes
            }
            ForEach(Shortcuts.all) { s in
                HStack(spacing: 12) {
                    Text(s.keys)
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .frame(width: 52, alignment: .leading)
                        .padding(.vertical, 2).padding(.horizontal, 6)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
                    Text(s.title).font(.callout)
                    Spacer()
                }
            }
            Text("Rewrites use your local model (llama.cpp) or Apple's on-device model. Nothing leaves your Mac.")
                .font(.caption2).foregroundStyle(.tertiary).padding(.top, 2)
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }
}
