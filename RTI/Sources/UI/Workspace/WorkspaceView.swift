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
    var callTypes: CallTypeStore = .shared
    var nativeTitlebar = false
    private let session = SessionCoordinator.shared

    /// The band under the native title-row header matches the bar AppKit drew.
    private var headerHeight: CGFloat {
        nativeTitlebar ? OverlayWindowChrome.shared.titleRowHeight : House.Control.composer
    }

    var body: some View {
        VStack(spacing: 0) {
            if nativeTitlebar {
                House.ColorToken.surfaceSunken.frame(height: headerHeight)
            } else {
                WorkspaceWindowHeader(model: model, callTypes: callTypes)
            }
            sessionChatContext
            ZStack {
                // Keep the composer mounted so a draft, attachments, and scroll
                // position survive trips to the archive or preferences.
                OverlayPanelView(onOpenSettings: { model.showSettings() }, callTypes: callTypes, isActive: model.isLivePageActive)
                    .workspacePage(isActive: model.page == .live)
                if model.hasVisitedLibrary {
                    SessionsBrowserView(model: model.sessions)
                        .workspacePage(isActive: model.page == .sessions || model.page == .chats)
                }
                if model.page == .settings {
                    SettingsView(onClose: { model.leaveSettings() }, navigation: model.settings)
                }
            }
            .environment(\.isWorkspaceEmbedded, true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: House.Radius.lg, style: .continuous))
            .slateRaisedCard(cornerRadius: House.Radius.lg)
            .padding(House.Spacing.xs)
        }
        .overlay(alignment: .topLeading) { OverlayHeaderChooserLayer(callTypes: callTypes, headerHeight: headerHeight) }
        .background(House.ColorToken.surface)
        .ignoresSafeArea(.container, edges: .top)
        .onReceive(NotificationCenter.default.publisher(for: .rtiSelectTab)) { _ in model.select(.live) }
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


}

/// The same header is hosted by the native title bar in the app and by the
/// workspace in windowless render proofs.
struct WorkspaceWindowHeader: View {
    var model: WorkspaceModel
    var callTypes: CallTypeStore = .shared
    var nativeTitlebar = false
    private let session = SessionCoordinator.shared

    var body: some View {
        OverlayShellHeader(status: OverlayShellStatus(phase: session.phase.livePhase, processingStatus: session.postProcessingStatus),
                           callTypes: callTypes, fill: House.ColorToken.surfaceSunken, workspace: model, nativeTitlebar: nativeTitlebar)
    }
}

struct WorkspaceRouteSegments: View {
    @Bindable var model: WorkspaceModel
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(WorkspaceModel.Page.allCases.enumerated()), id: \.element.id) { index, page in
                Button { model.select(page) } label: {
                    Text(page.rawValue).font(House.TypeToken.meta).lineLimit(1)
                        .padding(.horizontal, House.Spacing.xs)
                        .frame(height: House.Control.chip)
                        .foregroundStyle(model.page == page ? House.ColorToken.textPrimary : House.ColorToken.textSecondary)
                        .slateRaisedTile(model.page == page, cornerRadius: House.Radius.sm)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .option])
                .accessibilityIdentifier("workspace.route." + page.rawValue)
                .accessibilityLabel(page.rawValue)
                .accessibilityValue(model.page == page ? "Selected" : "")
                .accessibilityAddTraits(model.page == page ? .isSelected : [])
                .help("\(page.rawValue) (⌥⌘\(index + 1))")
            }
            if model.page == .sessions || model.page == .chats {
                QuickAIGlyphButton(symbol: "sidebar.left", font: HouseChatType.glyphSmall,
                    color: House.ColorToken.textSecondary, label: model.sessions.isRailVisible ? "Hide library list" : "Show library list",
                    help: "Show or hide the library list (⌃⌘S)") { model.sessions.toggleRail() }
            }
        }
        .background(House.ColorToken.surface, in: RoundedRectangle(cornerRadius: House.Radius.sm))
        .fixedSize()
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
