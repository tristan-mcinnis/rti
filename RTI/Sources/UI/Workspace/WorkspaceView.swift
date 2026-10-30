import AppKit
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
    @State private var hoveredPage: WorkspaceModel.Page?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            OverlayShellHeader(status: OverlayShellStatus(
                phase: session.phase.livePhase,
                processingStatus: session.postProcessingStatus
            ), modes: modes, fill: House.ColorToken.surfaceSunken)
            navigation
            sessionChatContext
            ZStack {
                // Keep the composer mounted so a draft, attachments, and scroll
                // position survive trips to the archive or preferences.
                OverlayPanelView(onOpenSettings: { model.showSettings() }, modes: modes, isActive: model.isLivePageActive)
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
            .clipShape(RoundedRectangle(cornerRadius: House.Radius.lg, style: .continuous))
            .slateRaisedCard(cornerRadius: House.Radius.lg)
            .padding(House.Spacing.xs)
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
        .task(id: model.reloadRequest) { await model.reloadVisiblePage() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in
            model.setWindowVisible(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didUnhideNotification)) { _ in
            model.setWindowVisible(WindowCoordinator.shared.overlayIsVisible)
        }
        .onChange(of: LLMController.shared.currentConversationID) { _, id in
            model.conversationDidChange(to: id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .rtiComposerWillResetConversation)) { note in
            guard (note.object as? LLMController) === LLMController.shared else { return }
            model.conversationWillReset(resumingChatID: note.userInfo?["resumingChatID"] as? String)
        }
        .onReceive(NotificationCenter.default.publisher(for: .rtiComposerDidFinishResume)) { note in
            guard (note.object as? LLMController) === LLMController.shared,
                  let id = note.userInfo?["conversationID"] as? String,
                  let succeeded = note.userInfo?["succeeded"] as? Bool else { return }
            model.conversationDidFinishResume(id: id, succeeded: succeeded)
        }
        .onDisappear { model.sessions.playback.pause() }
    }

    @ViewBuilder
    private var sessionChatContext: some View {
        if let row = model.returnSessionRow {
            HStack(spacing: House.Spacing.sm) {
                Button { model.returnToSession(row) } label: {
                    Label("Return to session", systemImage: "arrow.left")
                }
                .buttonStyle(.plain)
                .font(House.TypeToken.label)
                .help("Return to the session and the file you were reading")
                Text(row.title.text)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, House.Spacing.md)
            .frame(minHeight: House.Control.row)
            .foregroundStyle(House.ColorToken.textPrimary)
            .background(House.ColorToken.surfaceSunken)
        } else if model.page == .chats, model.sessions.chatLibrary.openID != nil {
            HStack(spacing: House.Spacing.sm) {
                Text(model.selectedChatHasSessionLink ? "Session chat" : "Saved chat")
                    .font(House.TypeToken.meta)
                if model.linkedSessionRows.count > 1 {
                    ScrollView(.horizontal) {
                        HStack(spacing: House.Spacing.sm) {
                            ForEach(model.linkedSessionRows) { row in
                                Button(row.title.text) { model.returnToSession(row) }
                                    .buttonStyle(.plain)
                                    .font(House.TypeToken.label)
                                    .lineLimit(1)
                                    .padding(.horizontal, House.Spacing.sm)
                                    .frame(minHeight: House.Control.pill)
                                    .background(House.ColorToken.chipFill, in: Capsule())
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: House.Control.pill)
                } else if model.selectedChatHasSessionLink {
                    Text("Session unavailable")
                        .font(House.TypeToken.meta)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(House.ColorToken.textSecondary)
            .padding(.horizontal, House.Spacing.md)
            .frame(minHeight: House.Control.row)
            .background(House.ColorToken.surfaceSunken)
        }
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
                        .background {
                            RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                                .fill(model.page == page ? House.ColorToken.surfaceRaised : (hoveredPage == page ? House.ColorToken.hoverFill : Color.clear))
                                .overlay {
                                    if model.page == page {
                                        RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                                            .strokeBorder(House.ColorToken.selectionRing, lineWidth: House.hairline)
                                    }
                                }
                                .slateSelectionShadow(scheme, active: model.page == page)
                        }
                }
                .buttonStyle(.plain)
                .onHover { hoveredPage = $0 ? page : nil }
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
        .frame(height: House.Control.row)
        .background(House.ColorToken.surfaceSunken)
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
