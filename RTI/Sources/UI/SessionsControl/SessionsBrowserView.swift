// Rail, find bar, and header copied from quick-launch@8ee19aa Sources/Views/AIChatWindowView.swift
// (AIChatRail, OpenChatMarker, AIChatFindBar, header) and CatalogPanes.swift (ChatSnippetText),
// adapted to RTI's macOS 14 floor and to reading archived sessions.
import AppKit
import RTICore
import SwiftUI
import HouseDesign

/// The Sessions window: archived meetings in the AI Chat window shape
/// (design-system docs/chat-surfaces.md sections 1, 5, 6, 7). A header in
/// the traffic-light row, the open session's files as chips, one centred
/// reading column, and the session list as a rail hidden until ⌃⌘S or the
/// header toggle. Read-only reading; past sessions belong to the vault.
///
/// State lives in `SessionsWindowModel`, so the window's keys and the render
/// proofs drive the same object.
struct SessionsBrowserView: View {
    @Environment(\.isWorkspaceEmbedded) private var embedded
    @Bindable var model: SessionsWindowModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(OverlayAppearanceDefaults.appearanceModeKey) private var appearanceMode = OverlayAppearanceDefaults.defaultAppearanceMode

    init(model: SessionsWindowModel = SessionsWindowModel()) {
        self.model = model
    }

    /// The reading column: at most the Quick AI panel width less its sides.
    static let columnWidth = House.Layout.answerMaxWidth

    var body: some View {
        HStack(spacing: 0) {
            if model.isRailVisible {
                rail
                    .frame(width: House.Layout.chatRail)
                    .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
                Rectangle()
                    .fill(House.ColorToken.divider)
                    .frame(width: House.hairline)
                    .accessibilityHidden(true)
            }
            readingColumn
        }
        .frame(
            minWidth: embedded ? nil : House.Layout.chatMinWidth,
            maxWidth: .infinity,
            minHeight: embedded ? nil : House.Layout.chatMinHeight,
            maxHeight: .infinity
        )
        .background(embedded ? House.ColorToken.surfaceRaised : House.ColorToken.surface)
        // The header shares the title-bar row with the traffic lights.
        .ignoresSafeArea(.container, edges: embedded ? [] : .top)
        .animation(reduceMotion ? nil : .easeOut(duration: House.Motion.select), value: model.isRailVisible)
        // Chrome is ink, never the system accent.
        .tint(House.ColorToken.textPrimary)
        .toggleStyle(SlateToggleStyle())
        .preferredColorScheme(preferredColorScheme)
        .task { if !embedded { await model.loadIfNeeded() } }
        .task(id: model.mode) { if !embedded { await model.loadActiveLibrary() } }
        .task(id: model.playbackDirectory) { await model.playback.run(directory: model.playbackDirectory) }
        .task(id: model.deletionRequest) { await model.deleteConfirmedSession() }
        .alert("Move this session to Trash?", isPresented: $model.isDeleteConfirmationPresented) {
            Button("Move to Trash", role: .destructive) { model.confirmDeletion() }
            Button("Cancel", role: .cancel) { model.cancelDeletion() }
        } message: {
            Text("“\(model.deletionTitle)” and its saved audio, transcript, notes, and chat will move to Trash. Restore the folder in Finder if needed. Separately exported meeting notes are kept.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .rtiOpenSessionInBrowser)) { note in
            guard let folder = note.object as? String else { return }
            model.open(folder: folder)
        }
        .sheet(isPresented: $model.isSpeakerEditorPresented) {
            SpeakerEditorSheet(model: model)
        }
        .confirmationDialog(
            "Upgrade transcript with",
            isPresented: $model.isUpgradeChoicePresented,
            titleVisibility: .visible
        ) {
            ForEach(model.upgradeProviderChoices) { provider in
                Button(model.upgradeProviderTitle(provider)) {
                    model.startTranscriptUpgrade(provider: provider)
                }
            }
            Button("Cancel", role: .cancel) { model.cancelUpgradeChoice() }
        } message: {
            Text("Soniox transcribes the saved audio again, in English and Chinese. The current transcript is backed up first.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sessions")
    }

    private var preferredColorScheme: ColorScheme? {
        switch RTIAppearanceMode(rawValue: appearanceMode) ?? .system {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    // MARK: - Library on screen

    /// The rail for the library on screen: the saved sessions, or the chats.
    @ViewBuilder
    private var rail: some View {
        switch model.mode {
        case .sessions: SessionsRail(model: model)
        case .chats: ChatLibraryRail(library: model.chatLibrary)
        }
    }

    /// The reading column: the open session, or the chat library. Chats mode
    /// leaves every meeting path below untouched.
    @ViewBuilder
    private var readingColumn: some View {
        ZStack {
            // Keep the session reader mounted while following a saved chat.
            // Its scroll position and find state belong to the reading origin.
            conversation
                .opacity(model.mode == .sessions ? 1 : 0)
                .allowsHitTesting(model.mode == .sessions)
                .disabled(model.mode != .sessions)
                .accessibilityHidden(model.mode != .sessions)
            if model.mode == .chats {
                VStack(spacing: 0) {
                    if !embedded { SessionsHeader(model: model) }
                    ChatLibraryReader(library: model.chatLibrary)
                }
            }
        }
    }

    // MARK: - Conversation column

    private var conversation: some View {
        VStack(spacing: 0) {
            SessionsHeader(model: model)
            if model.isFindPresented {
                SessionsFindBar(model: model)
            }
            if model.openRow != nil {
                SessionFileChips(model: model)
                    .frame(maxWidth: Self.columnWidth, alignment: .leading)
                    .padding(.horizontal, House.Spacing.lg)
                    .frame(maxWidth: .infinity)
                if model.openRow?.hasRetainedAudio == true {
                    SessionPlaybackBar(playback: model.playback)
                        .frame(maxWidth: Self.columnWidth)
                        .padding(.horizontal, House.Spacing.lg)
                        .padding(.top, House.Spacing.xs)
                        .frame(maxWidth: .infinity)
                }
                if let notice = model.openNotice {
                    SessionNoticeLine(text: notice.text, isRunning: notice.isRunning)
                        .frame(maxWidth: Self.columnWidth, alignment: .leading)
                        .padding(.horizontal, House.Spacing.lg)
                        .padding(.top, House.Spacing.xs)
                        .frame(maxWidth: .infinity)
                }
                SessionReader(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The scroll view would otherwise draw up under the header.
                    .clipped()
                if model.selectedFile?.name == "chat" {
                    VStack(alignment: .leading, spacing: House.Spacing.xs) {
                        if model.relatedChats.count == 1, let chat = model.relatedChats.first {
                            Button {
                                model.onOpenRelatedChat?(chat.id)
                            } label: {
                                Label("Continue saved chat: \(chat.title)", systemImage: "bubble.left.and.text.bubble.right")
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .font(House.TypeToken.label)
                            .foregroundStyle(House.ColorToken.textPrimary)
                            .frame(minHeight: House.Control.pill)
                        } else if !model.relatedChats.isEmpty {
                            Text("Related saved chats")
                                .font(House.TypeToken.meta)
                                .foregroundStyle(House.ColorToken.textSecondary)
                            ScrollView(.horizontal) {
                                HStack(spacing: House.Spacing.sm) {
                                    ForEach(model.relatedChats) { chat in
                                        Button(chat.title) { model.onOpenRelatedChat?(chat.id) }
                                            .buttonStyle(.plain)
                                            .font(House.TypeToken.label)
                                            .foregroundStyle(House.ColorToken.textPrimary)
                                            .lineLimit(1)
                                            .padding(.horizontal, House.Spacing.sm)
                                            .frame(minHeight: House.Control.pill)
                                            .background(House.ColorToken.chipFill, in: Capsule())
                                    }
                                }
                            }
                            .scrollIndicators(.hidden)
                    .frame(height: House.Control.pill)
                        }
                        if model.openRow?.vaultTranscriptPath != nil {
                            HStack(spacing: House.Spacing.sm) {
                                Text("Archived session chat")
                                    .font(House.TypeToken.meta)
                                    .foregroundStyle(House.ColorToken.textTertiary)
                                Spacer(minLength: House.Spacing.sm)
                                Button("Ask about this session", systemImage: "bubble.left.and.text.bubble.right") { model.perform(.ask) }
                                    .buttonStyle(.plain)
                                    .font(House.TypeToken.label)
                                    .padding(.horizontal, House.Spacing.sm)
                                    .frame(minHeight: House.Control.pill)
                                    .background(House.ColorToken.chipFill, in: Capsule())
                                    .help("Open RTI's chat composer with this session's transcript attached")
                            }
                        }
                    }
                    .frame(maxWidth: Self.columnWidth)
                    .padding(.horizontal, House.Spacing.lg)
                    .padding(.vertical, House.Spacing.xs)
                    .frame(maxWidth: .infinity)
                    .task(id: model.selectedFile?.url) {
                        await model.chatLibrary.reload()
                    }
                }
            } else {
                emptyState
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.actionsPlacement == .header {
                SessionActionsCard(model: model, showsKeys: true)
                    .frame(width: House.Layout.chatRail + House.Spacing.xxxxl)
                    .padding(.top, House.Control.composer)
            }
        }
    }

    /// No session to show: three hint lines, each with its real key.
    private var emptyState: some View {
        VStack(spacing: House.Spacing.xs) {
            Text(model.hasLoaded ? "No saved sessions yet" : "Loading sessions…")
            if model.hasLoaded {
                Text("⌘⇧R starts a recording")
                Text("A session saves here when it finishes")
            }
        }
        .font(House.TypeToken.bodySmall)
        .foregroundStyle(House.ColorToken.textTertiary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
