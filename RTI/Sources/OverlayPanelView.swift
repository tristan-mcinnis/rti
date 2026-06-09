import SwiftUI

struct OverlayPanelView: View {
    private let llm = LLMController.shared
    var onOpenSettings: () -> Void = {}

    @AppStorage(OverlayAppearanceDefaults.opacityKey) private var backgroundOpacity: Double = OverlayAppearanceDefaults.defaultOpacity
    @AppStorage(OverlayAppearanceDefaults.lightModeKey) private var lightMode = false
    // Notes/Guide are opt-in: their tabs only show when their live analysis is
    // enabled (toggled in Setup). Default tabs are Setup · Assist · Transcript.
    @AppStorage(AnalysisSettingsDefaults.notesEnabledKey) private var notesEnabled = false
    @AppStorage(AnalysisSettingsDefaults.guideEnabledKey) private var guideEnabled = false
    @State private var tab: OverlayTab = .assist

    private var visibleTabs: [OverlayTab] {
        var t: [OverlayTab] = [.setup, .assist, .transcript]
        if notesEnabled { t.append(.notes) }
        if guideEnabled { t.append(.guide) }
        return t
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.overlayPanel.opacity(backgroundOpacity))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.overlayBorder, lineWidth: 1.5)
                )

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    OverlayTabBar(selection: $tab, tabs: visibleTabs)
                    OverlayRecordButton()
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)
                // If the active tab gets turned off in Setup, fall back to Assist.
                .onChange(of: notesEnabled) { _, _ in normalizeSelection() }
                .onChange(of: guideEnabled) { _, _ in normalizeSelection() }

                Group {
                    switch tab {
                    case .assist:
                        assistTab
                    case .transcript:
                        TranscriptTabView().tabContentPadding()
                    case .notes:
                        NotesTabView().tabContentPadding()
                    case .setup:
                        SetupTabView().tabContentPadding()
                    case .guide:
                        GuideTabView().tabContentPadding()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            ResizeHandle()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding([.bottom, .trailing], 6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .preferredColorScheme(lightMode ? .light : .dark)
    }

    private func normalizeSelection() {
        if !visibleTabs.contains(tab) { tab = .assist }
    }

    /// The original chat surface, now the default "Assist" tab.
    private var assistTab: some View {
        VStack(spacing: 0) {
            ResponseView(
                entries: llm.entries,
                streaming: llm.streaming,
                error: llm.lastError,
                errorIsAuth: llm.lastErrorIsAuth,
                onOpenSettings: onOpenSettings
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 18)

            AssistantInputView(onOpenSettings: onOpenSettings)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 14)
        }
    }
}

private extension View {
    /// Uniform padding for the non-assist tab contents.
    func tabContentPadding() -> some View {
        padding(.horizontal, 16).padding(.bottom, 14)
    }
}
