import HouseDesign
import Observation
import RTICore
import SwiftUI

/// The Live page's selected view and the views it shows now. Shared so the
/// workspace sidebar and the Live page select the same view; the Live page
/// writes `visible` whenever Notes, the guide or the call type change it.
@Observable @MainActor
final class LiveTabState {
    static let shared = LiveTabState()

    var selected: OverlayTab = .assist
    var visible: [OverlayTab] = OverlayTab.visibleTabs(notes: true)
}

enum WorkspaceSidebarSettings {
    static let visibleKey = "rti.workspace.sidebarVisible"
    /// The chat rail's width, as in the AI Chat window.
    static let width = House.Layout.chatRail
}

/// The workspace's left sidebar, as in the Codex and Claude apps (2026-11-14
/// review): the Live page's views first (Prepare, then the live views that
/// apply), then Sessions, Chats and Settings. It replaces the route segments
/// in the header and the Live page's tab row. ⌘1…⌘7 and ⌥⌘1…⌥⌘4 still work
/// with the sidebar hidden.
struct WorkspaceSidebar: View {
    @Bindable var model: WorkspaceModel
    @Bindable var live = LiveTabState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            row(OverlayTab.setup.title, symbol: OverlayTab.setup.icon,
                selected: model.page == .live && live.selected == .setup,
                help: "Call type, project and guide (\(OverlayTab.setup.shortcutLabel))") { open(.setup) }
            ForEach(live.visible) { tab in
                row(tab.title, symbol: tab.icon, selected: model.page == .live && live.selected == tab,
                    help: "\(tab.title) (\(tab.shortcutLabel))") { open(tab) }
            }
            HouseDivider()
                .padding(.vertical, House.Spacing.xs)
            ForEach(WorkspaceModel.Page.allCases.filter { $0 != .live }) { page in
                row(page.rawValue, symbol: page.symbol, selected: model.page == page,
                    help: "\(page.rawValue) (⌥⌘\(page.shortcutNumber))") { model.select(page) }
            }
            Spacer(minLength: 0)
        }
        .padding(House.Spacing.xs)
        .frame(width: WorkspaceSidebarSettings.width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(House.ColorToken.surfaceSunken)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace navigation")
    }

    private func open(_ tab: OverlayTab) {
        model.select(.live)
        NotificationCenter.default.post(name: .rtiSelectTab, object: tab.rawValue)
    }

    private func row(_ title: String, symbol: String, selected: Bool, help: String,
                     action: @escaping () -> Void) -> some View
    {
        SidebarRow(title: title, symbol: symbol, selected: selected, action: action)
            .help(help)
            .accessibilityIdentifier("workspace.sidebar." + title)
    }
}

private struct SidebarRow: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: House.Spacing.sm) {
                Image(systemName: symbol)
                    .font(House.TypeToken.bodySmall)
                    .frame(width: House.Control.keyCap)
                    .accessibilityHidden(true)
                Text(title)
                    .font(House.TypeToken.label)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected || hovering ? House.ColorToken.textPrimary : House.ColorToken.textSecondary)
            .padding(.horizontal, House.Spacing.sm)
            .frame(height: House.Control.railRow)
            .slateRaisedTile(selected, cornerRadius: House.Radius.sm, hovering: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight($hovering)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The header's left controls in the workspace: the sidebar toggle, and on
/// Sessions and Chats the library list toggle. The page routes moved to the
/// sidebar; their ⌥⌘ keys stay here, so they work with the sidebar hidden.
struct WorkspaceHeaderToggles: View {
    @Bindable var model: WorkspaceModel
    @AppStorage(WorkspaceSidebarSettings.visibleKey) private var sidebarVisible = true

    var body: some View {
        HStack(spacing: House.Spacing.xxs) {
            QuickAIGlyphButton(symbol: "sidebar.left", font: HouseChatType.glyphSmall,
                               color: House.ColorToken.textSecondary,
                               label: sidebarVisible ? "Hide sidebar" : "Show sidebar",
                               help: "Show or hide the sidebar (⌃⌘0)") { sidebarVisible.toggle() }
                .keyboardShortcut("0", modifiers: [.control, .command])
            if model.page == .sessions || model.page == .chats {
                QuickAIGlyphButton(symbol: "list.bullet", font: HouseChatType.glyphSmall,
                                   color: House.ColorToken.textSecondary,
                                   label: model.sessions.isRailVisible ? "Hide library list" : "Show library list",
                                   help: "Show or hide the library list (⌃⌘S)") { model.sessions.toggleRail() }
            }
        }
        .background { routeKeys }
        .fixedSize()
    }

    /// ⌥⌘1…⌥⌘4 pick a page, as the route segments did.
    private var routeKeys: some View {
        ZStack {
            ForEach(WorkspaceModel.Page.allCases) { page in
                Button(page.rawValue) { model.select(page) }
                    .keyboardShortcut(KeyEquivalent(Character(String(page.shortcutNumber))), modifiers: [.command, .option])
                    .accessibilityIdentifier("workspace.route." + page.rawValue)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

extension WorkspaceModel.Page {
    /// The page's ⌥⌘ digit: Live 1, Sessions 2, Chats 3, Settings 4.
    var shortcutNumber: Int {
        (Self.allCases.firstIndex(of: self) ?? 0) + 1
    }
}
