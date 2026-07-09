import SwiftUI

/// Design system for the control panel — dark + violet sidebar app, matching the AR Workspace
/// Manager look the project is modelled on.
enum PanelTheme {
    static let accent = Color(red: 0.486, green: 0.361, blue: 0.988)   // ~#7C5CFC
    static let bg = Color(red: 0.055, green: 0.055, blue: 0.071)        // ~#0E0E12
    static let sidebar = Color(red: 0.071, green: 0.071, blue: 0.090)   // ~#12121A
    static let card = Color(red: 0.090, green: 0.090, blue: 0.114)      // ~#17171D
    static let border = Color.white.opacity(0.08)
    static let cardCorner: CGFloat = 14
}

/// Holds the selected control-panel page so it can be driven from outside the view (e.g. the menu
/// bar opening the window straight onto Diagnostics).
final class PanelRouter: ObservableObject {
    @Published var route: PanelRoute = .dashboard
}

enum PanelRoute: String, CaseIterable, Identifiable {
    case dashboard, aiModels, chat, aiSpell, settings, diagnostics
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .aiModels: return "AI Models"
        case .chat: return "Chat with AI Model"
        case .aiSpell: return "AI Spell Check"
        case .settings: return "Settings"
        case .diagnostics: return "Diagnostics"
        }
    }
    var subtitle: String {
        switch self {
        case .dashboard: return "Status and quick actions"
        case .aiModels: return "Local models for sentence rewriting"
        case .chat: return "Talk directly to a local model"
        case .aiSpell: return "Model-based, context-aware spell checking"
        case .settings: return "Spellcheck and correction preferences"
        case .diagnostics: return "Accessibility, capabilities, and logs"
        }
    }
    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .aiModels: return "brain"
        case .chat: return "bubble.left.and.bubble.right"
        case .aiSpell: return "text.magnifyingglass"
        case .settings: return "gearshape"
        case .diagnostics: return "stethoscope"
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Binding var route: PanelRoute

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "textformat.abc.dottedunderline")
                    .font(.title3).foregroundStyle(PanelTheme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("AiGrammar").font(.subheadline.weight(.semibold))
                    Text("Local-only · private").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(PanelRoute.allCases) { r in
                        NavRow(route: r, selected: route == r) { route = r }
                    }
                }
                .padding(.horizontal, 10)
            }
            Spacer(minLength: 8)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PanelTheme.sidebar)
    }
}

private struct NavRow: View {
    let route: PanelRoute
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: route.icon).frame(width: 18)
                Text(route.title).font(.callout)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color.white : Color.secondary)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowFill, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? PanelTheme.accent.opacity(0.5) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var rowFill: Color {
        if selected { return PanelTheme.accent.opacity(0.28) }
        return hovering ? Color.white.opacity(0.08) : Color.white.opacity(0.04)
    }
}

// MARK: - Shared chrome

struct PageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title2.weight(.bold))
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A titled card container matching the reference app's `card(title, icon) { … }`.
struct Card<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
                .labelStyle(.titleAndIcon)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PanelTheme.card, in: RoundedRectangle(cornerRadius: PanelTheme.cardCorner))
        .overlay(RoundedRectangle(cornerRadius: PanelTheme.cardCorner).strokeBorder(PanelTheme.border))
    }
}
