import SwiftUI

struct OverlayPanelView: View {
    private let llm = LLMController.shared
    var onOpenSettings: () -> Void = {}

    @AppStorage(OverlayAppearanceDefaults.opacityKey) private var backgroundOpacity: Double = OverlayAppearanceDefaults.defaultOpacity
    @AppStorage(OverlayAppearanceDefaults.lightModeKey) private var lightMode = false
    // Live-analysis tabs only show when their tasks are enabled in Setup.
    // Notes defaults on; Guide/Findings/Auto stay opt-in.
    @AppStorage(AnalysisSettingsDefaults.notesEnabledKey) private var notesEnabled = AnalysisSettingsDefaults.defaultNotesEnabled
    @AppStorage(AnalysisSettingsDefaults.guideEnabledKey) private var guideEnabled = AnalysisSettingsDefaults.defaultGuideEnabled
    @AppStorage(AnalysisSettingsDefaults.findingsEnabledKey) private var findingsEnabled = AnalysisSettingsDefaults.defaultFindingsEnabled
    @AppStorage(AnalysisSettingsDefaults.autoAssistEnabledKey) private var autoAssistEnabled = AnalysisSettingsDefaults.defaultAutoAssistEnabled
    @State private var tab: OverlayTab = .assist

    // Setup is the pre-call surface, not a live tab — it's pulled out of the
    // equal-weight row into a leading icon button (OverlaySetupButton) so the
    // top bar gives its weight to the live surfaces.
    private var visibleTabs: [OverlayTab] {
        var t: [OverlayTab] = [.assist]
        if autoAssistEnabled { t.append(.auto) }
        t.append(.transcript)
        if notesEnabled { t.append(.notes) }
        if guideEnabled { t.append(.guide) }
        if findingsEnabled { t.append(.findings) }
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
                HStack(spacing: 6) {
                    OverlaySetupButton(selection: $tab)
                    OverlayTabBar(selection: $tab, tabs: visibleTabs)
                    OverlayMicControl()
                    OverlayRecordButton()
                    OverlaySessionAuxButton()
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)
                // If the active tab gets turned off in Setup, fall back to Assist.
                .onChange(of: notesEnabled) { _, _ in normalizeSelection() }
                .onChange(of: guideEnabled) { _, _ in normalizeSelection() }
                .onChange(of: findingsEnabled) { _, _ in normalizeSelection() }
                .onChange(of: autoAssistEnabled) { _, _ in normalizeSelection() }
                // Global hotkeys (⌘⌥1–5) and commands switch tabs by posting a
                // notification with the target tab's rawValue.
                .onReceive(NotificationCenter.default.publisher(for: .rtiSelectTab)) { note in
                    guard let raw = note.object as? String,
                          let target = OverlayTab(rawValue: raw) else { return }
                    if target == .setup || visibleTabs.contains(target) { tab = target }
                }

                Group {
                    switch tab {
                    case .assist:
                        assistTab
                    case .auto:
                        AutoTabView().tabContentPadding()
                    case .transcript:
                        TranscriptTabView().tabContentPadding()
                    case .notes:
                        NotesTabView().tabContentPadding()
                    case .setup:
                        SetupTabView().tabContentPadding()
                    case .guide:
                        GuideTabView().tabContentPadding()
                    case .findings:
                        FindingsTabView().tabContentPadding()
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
        // Setup lives outside visibleTabs but is always reachable, so don't
        // kick the user out of it when a live-analysis toggle flips.
        if tab != .setup, !visibleTabs.contains(tab) { tab = .assist }
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
