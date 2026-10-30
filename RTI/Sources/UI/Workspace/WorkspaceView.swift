import HouseDesign
import RTICore
import SwiftUI

private struct WorkspaceEmbeddedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isWorkspaceEmbedded: Bool {
        get { self[WorkspaceEmbeddedKey.self] }
        set { self[WorkspaceEmbeddedKey.self] = newValue }
    }
}

/// One recording header and one route bar remain visible on every page.
struct WorkspaceView: View {
    @Bindable var model: WorkspaceModel
    var modes: ModeStore = .shared
    private let session = SessionCoordinator.shared

    var body: some View {
        VStack(spacing: 0) {
            OverlayShellHeader(status: OverlayShellStatus(
                phase: session.phase.livePhase,
                processingStatus: session.postProcessingStatus
            ), modes: modes)
            navigation
            HouseDivider()
            ZStack {
                // Keep the composer mounted so a draft, attachments, and scroll
                // position survive trips to the archive or preferences.
                OverlayPanelView(onOpenSettings: { model.showSettings() }, modes: modes)
                    .workspacePage(isActive: model.page == .live)
                if model.hasVisitedLibrary {
                    SessionsBrowserView(model: model.sessions)
                        .workspacePage(isActive: model.page == .sessions || model.page == .chats)
                }
                if model.page == .settings {
                    SettingsView(onClose: { model.leaveSettings() }, navigation: model.settings, modeStore: modes)
                }
            }
            .environment(\.isWorkspaceEmbedded, true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .overlay(alignment: .topLeading) { OverlayHeaderChooserLayer(modes: modes) }
        .background(House.ColorToken.surface)
        .ignoresSafeArea(.container, edges: .top)
        .onReceive(NotificationCenter.default.publisher(for: .rtiSelectTab)) { _ in model.select(.live) }
        .onReceive(NotificationCenter.default.publisher(for: .rtiShowLogs)) { _ in model.showSettings(.logs) }
        .onReceive(NotificationCenter.default.publisher(for: .rtiFindInSession)) { _ in
            if model.page == .sessions { _ = model.sessions.handle(.find) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .rtiToggleSessionList)) { _ in
            if model.page == .sessions || model.page == .chats { model.sessions.toggleRail() }
        }
        .sheet(isPresented: $model.isBriefPresented) {
            VStack(spacing: 0) {
                HStack {
                    Text("Meeting brief").font(House.TypeToken.heading)
                    Spacer()
                    Button("Done") { model.isBriefPresented = false }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(House.Spacing.md)
                MeetingBriefView(model: model.brief)
                    .environment(\.isWorkspaceEmbedded, true)
            }
            .frame(width: House.Layout.chatWidth, height: House.Layout.chatHeight)
            .background(House.ColorToken.surface)
        }
        .task(id: model.reloadRequest) {
            if model.page == .sessions { await model.sessions.reload() }
        }
        .onDisappear { model.sessions.playback.pause() }
    }

    private var navigation: some View {
        HStack(spacing: House.Spacing.xxs) {
            ForEach(Array(WorkspaceModel.Page.allCases.enumerated()), id: \.element.id) { index, page in
                Button { model.select(page) } label: {
                    Label(page.rawValue, systemImage: page.symbol)
                        .font(House.TypeToken.label)
                        .foregroundStyle(model.page == page ? House.ColorToken.textPrimary : House.ColorToken.textSecondary)
                        .padding(.horizontal, House.Spacing.sm)
                        .frame(height: House.Control.chip)
                        .slateRaisedTile(model.page == page, cornerRadius: House.Radius.sm)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .option])
                .accessibilityAddTraits(model.page == page ? .isSelected : [])
                .help("\(page.rawValue) (⌥⌘\(index + 1))")
            }
            Spacer(minLength: 0)
            if model.page == .sessions || model.page == .chats {
                QuickAIGlyphButton(
                    symbol: "sidebar.left", font: HouseChatType.glyphSmall,
                    color: House.ColorToken.textSecondary,
                    label: model.sessions.isRailVisible ? "Hide library list" : "Show library list",
                    help: "Show or hide the library list (⌃⌘S)",
                    accessibilityValue: model.sessions.isRailVisible ? "Open" : "Closed"
                ) { model.sessions.toggleRail() }
            }
        }
        .padding(.horizontal, House.Spacing.sm)
        .frame(height: House.Control.railRow)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace navigation")
    }
}

private extension View {
    func workspacePage(isActive: Bool) -> some View {
        opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .disabled(!isActive)
            .accessibilityHidden(!isActive)
    }
}
