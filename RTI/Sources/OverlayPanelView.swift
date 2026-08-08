import SwiftUI

struct OverlayPanelView: View {
    private let llm = LLMController.shared
    private let session = SessionCoordinator.shared
    var onOpenSettings: () -> Void = {}

    @AppStorage(OverlayAppearanceDefaults.opacityKey) private var backgroundOpacity: Double = OverlayAppearanceDefaults.defaultOpacity
    @AppStorage(OverlayAppearanceDefaults.appearanceModeKey) private var appearanceMode: String = OverlayAppearanceDefaults.defaultAppearanceMode
    @AppStorage(OverlayAppearanceDefaults.accentColorKey) private var accentColorHex: String = OverlayAppearanceDefaults.defaultAccentColor
    @AppStorage(OverlayAppearanceDefaults.contrastKey) private var contrast: Double = OverlayAppearanceDefaults.defaultContrast
    @AppStorage(OverlayAppearanceDefaults.translucentPanelKey) private var translucentPanel: Bool = OverlayAppearanceDefaults.defaultTranslucentPanel
    @AppStorage(OverlayAppearanceDefaults.uiFontSizeKey) private var uiFontSize: Double = OverlayAppearanceDefaults.defaultUIFontSize
    // Live-analysis tabs only show when their tasks are enabled in Prepare.
    // Notes defaults on; Guide/Intel/Auto stay opt-in.
    @AppStorage(AnalysisSettingsDefaults.notesEnabledKey) private var notesEnabled = AnalysisSettingsDefaults.defaultNotesEnabled
    @AppStorage(AnalysisSettingsDefaults.guideEnabledKey) private var guideEnabled = AnalysisSettingsDefaults.defaultGuideEnabled
    @AppStorage(AnalysisSettingsDefaults.findingsEnabledKey) private var findingsEnabled = AnalysisSettingsDefaults.defaultFindingsEnabled
    @AppStorage(AnalysisSettingsDefaults.autoAssistEnabledKey) private var autoAssistEnabled = AnalysisSettingsDefaults.defaultAutoAssistEnabled
    // RTI opens at the beginning of the user's journey: preparing this
    // meeting. Starting the recording moves the user into the live workspace.
    @State private var tab: OverlayTab = .setup

    // Prepare is the pre-call surface, not a live tab — it's pulled out of the
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
            panelBackground

            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    OverlaySetupButton(selection: $tab)
                    OverlayTabBar(selection: $tab, tabs: visibleTabs)
                    Divider()
                        .frame(height: 18)
                        .opacity(0.55)
                        .padding(.horizontal, 2)
                    OverlayMicControl()
                    OverlayVisualContextButton()
                    OverlayProjectPicker()
                    OverlayRecordButton()
                    OverlaySessionAuxButton()
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .background(Color.overlayInk.opacity(0.018))
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.overlayBorder.opacity(0.65))
                        .frame(height: 1)
                }
                // If the active tab gets turned off in Prepare, fall back to Assist.
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
                .onChange(of: session.phase) { previous, current in
                    // Prepare → Live is the primary hand-off in RTI. Do not
                    // interrupt someone who has deliberately navigated away
                    // from Prepare after the recording is already underway.
                    if previous == .idle, current == .recording, tab == .setup {
                        tab = .assist
                    }
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
        .font(.system(size: CGFloat(uiFontSize), weight: .regular))
        .tint(Color.overlayAccent)
        .accentColor(Color.overlayAccent)
        .preferredColorScheme(preferredColorScheme)
        .overlay(themeRefreshToken)
    }

    @ViewBuilder
    private var panelBackground: some View {
        if translucentPanel {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .opacity(backgroundOpacity)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.overlayPanel.opacity(backgroundOpacity * 0.72))
                )
                .overlay(panelStroke)
                .shadow(color: Color.black.opacity(0.10), radius: 24, x: 0, y: 10)
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.overlayPanel.opacity(backgroundOpacity))
                .overlay(panelStroke)
                .shadow(color: Color.black.opacity(0.10), radius: 24, x: 0, y: 10)
        }
    }

    private var panelStroke: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(Color.overlayBorder, lineWidth: 1)
    }

    private var preferredColorScheme: ColorScheme? {
        switch RTIAppearanceMode(rawValue: appearanceMode) ?? .system {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    private var themeRefreshToken: some View {
        Color.clear
            .opacity((accentColorHex.isEmpty || contrast < 0) ? 0 : 0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private func normalizeSelection() {
        // Prepare lives outside visibleTabs but is always reachable, so don't
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

            AssistantInputView()
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
