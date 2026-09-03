import RTICore
import SwiftUI

struct OverlayPanelView: View {
    private let llm = LLMController.shared
    private let session = SessionCoordinator.shared
    var onOpenSettings: () -> Void = {}

    @AppStorage(OverlayAppearanceDefaults.appearanceModeKey) private var appearanceMode: String = OverlayAppearanceDefaults.defaultAppearanceMode
    @AppStorage(OverlayAppearanceDefaults.accentColorKey) private var accentColorHex: String = OverlayAppearanceDefaults.defaultAccentColor
    @AppStorage(OverlayAppearanceDefaults.contrastKey) private var contrast: Double = OverlayAppearanceDefaults.defaultContrast
    @AppStorage(OverlayAppearanceDefaults.uiFontSizeKey) private var uiFontSize: Double = OverlayAppearanceDefaults.defaultUIFontSize
    // Live-analysis tabs only show when their tasks are enabled in Prepare.
    // Notes defaults on; Guide/Intel/Auto stay opt-in.
    @AppStorage(AnalysisSettingsDefaults.notesEnabledKey) private var notesEnabled = AnalysisSettingsDefaults.defaultNotesEnabled
    @AppStorage(AnalysisSettingsDefaults.guideEnabledKey) private var guideEnabled = AnalysisSettingsDefaults.defaultGuideEnabled
    @AppStorage(AnalysisSettingsDefaults.findingsEnabledKey) private var findingsEnabled = AnalysisSettingsDefaults.defaultFindingsEnabled
    @AppStorage(AnalysisSettingsDefaults.autoAssistEnabledKey) private var autoAssistEnabled = AnalysisSettingsDefaults.defaultAutoAssistEnabled
    // RTI opens at the beginning of the user's journey: preparing this
    // meeting. Starting the recording moves the user into the live workspace.
    @State private var tab: OverlayTab = .assist

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
                HStack(spacing: RTIDesign.Spacing.xxs + 2) {
                    OverlaySetupButton(selection: $tab)
                    OverlayTabBar(selection: $tab, tabs: visibleTabs)
                    OverlayMicControl()
                    OverlayVisualContextButton()
                    OverlayProjectPicker()
                    OverlayRecordButton()
                    OverlaySessionAuxButton()
                }
                .padding(.horizontal, RTIDesign.Spacing.sm + 2)
                .padding(.vertical, RTIDesign.Spacing.xs + 2)
                // No tint band. A divider is the only line the top bar draws.
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(RTIDesign.Color.divider)
                        .frame(height: House.hairline)
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

                OverlayFooterBar(tab: tab)
            }
        }
        .font(.system(size: CGFloat(uiFontSize), weight: .regular))
        .foregroundStyle(Color.overlayInk)
        // Chrome is ink: system controls (menus, pickers, prominent buttons)
        // must not paint themselves the system accent blue.
        .tint(Color.overlayInk)
        .preferredColorScheme(preferredColorScheme)
        .overlay(themeRefreshToken)
    }

    /// Hosted in a standard titled window. The ground is the same glass as the
    /// launcher: blur material, `panelTint`, and a 1 px top highlight. The
    /// window's own chrome supplies corners, border, and shadow.
    private var panelBackground: some View {
        SlateGlassBackground()
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
            .padding(.horizontal, RTIDesign.Spacing.lg - 4)

            AssistantInputView()
                .padding(.horizontal, RTIDesign.Spacing.sm + 2)
                .padding(.top, RTIDesign.Spacing.xs + 2)
                .padding(.bottom, RTIDesign.Spacing.sm)
        }
    }
}

private extension View {
    /// Uniform padding for the non-assist tab contents.
    func tabContentPadding() -> some View {
        padding(.horizontal, RTIDesign.Spacing.lg - 4).padding(.top, RTIDesign.Spacing.sm)
    }
}

/// The house footer: a sunken well carrying "state · model · mode" on the left
/// and outlined key caps for the live shortcuts on the right. The same table
/// drives the status item and the command registry.
struct OverlayFooterBar: View {
    let tab: OverlayTab

    private let session = SessionCoordinator.shared
    private let llm = LLMController.shared
    private let modes = ModeStore.shared

    var body: some View {
        SlateFooter(statusColor: statusColor, status: statusLine) {
            HStack(spacing: 0) {
                if tab == .assist {
                    SlateKeyHint(label: primaryActionLabel, keys: ["⌘", "↩"])
                }
                SlateKeyHint(label: "Note", keys: ["⌘", "⌥", "N"])
                if tab != .assist {
                    SlateKeyHint(label: session.isRunning ? "Finish" : "Record", keys: ["⌘", "⇧", "R"])
                }
            }
        }
    }

    private var primaryActionLabel: String {
        AssistantAction.byID(llm.primaryActionID)?.label ?? "Assist"
    }

    /// Never colour alone: the dot always sits beside the word.
    private var statusColor: Color {
        switch session.phase {
        case .recording: RTIDesign.Color.danger
        case .paused: RTIDesign.Color.warning
        case .finishing, .summarizing: RTIDesign.Color.warning
        case .idle, .done: RTIDesign.Color.success
        }
    }

    private var statusLine: String {
        var parts: [String] = [phaseWord]
        parts.append(LLMProviders.active.displayName)
        if let mode = modes.activeMode?.name { parts.append("\(mode) mode") }
        return parts.joined(separator: " · ")
    }

    private var phaseWord: String {
        switch session.phase {
        case .idle: "Ready"
        case .recording: "Recording"
        case .paused: "Paused"
        case .finishing: "Saving"
        case .summarizing: "Improving"
        case .done: "Ready"
        }
    }
}
