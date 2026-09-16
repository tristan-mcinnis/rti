import Observation
import RTICore
import SwiftUI

/// The overlay's content: a header in the traffic-light row, the tabs row,
/// and the selected tab. House window chrome (chat-surfaces.md section 7) in
/// its live form (section 8): the header says what this meeting is and its
/// state; there is no footer well.
struct OverlayPanelView: View {
    private let llm = LLMController.shared
    private let session = SessionCoordinator.shared
    private let shell = OverlayShellModel.shared
    var onOpenSettings: () -> Void = {}
    /// Render proofs only: draw this header state instead of the session's
    /// (the proofs cannot finish a real session to reach "Notes ready").
    var statusOverride: OverlayShellStatus? = nil

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
    @State private var tab: OverlayTab = .assist

    // Prepare is the pre-call surface, not a live tab — it's pulled out of the
    // equal-weight row into a leading icon button (OverlaySetupButton) so the
    // row gives its weight to the live surfaces.
    private var visibleTabs: [OverlayTab] {
        OverlayTab.visibleTabs(notes: notesEnabled, guide: guideEnabled, findings: findingsEnabled, auto: autoAssistEnabled)
    }

    private var status: OverlayShellStatus {
        statusOverride ?? OverlayShellStatus(
            phase: session.phase.livePhase,
            summaryReady: session.summaryURL != nil,
            processingStatus: session.postProcessingStatus
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            OverlayShellHeader(status: status)
            tabsRow
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
            // The tab content never scrolls up under the header or the
            // transparent title bar.
            .clipped()
        }
        .overlay(alignment: .topLeading) { OverlayHeaderChooserLayer() }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(House.ColorToken.surface)
        // The header shares the title-bar row with the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
        .font(.system(size: CGFloat(uiFontSize), weight: .regular))
        .foregroundStyle(Color.overlayInk)
        // Chrome is ink: system controls (menus, pickers, prominent buttons)
        // must not paint themselves the system accent blue.
        .tint(Color.overlayInk)
        .preferredColorScheme(preferredColorScheme)
        .overlay(themeRefreshToken)
        .onAppear { shell.registerEscape() }
    }

    /// The tabs in a row under the header: Prepare, then the live tabs.
    private var tabsRow: some View {
        HStack(spacing: House.Spacing.xxs) {
            OverlaySetupButton(selection: $tab)
            OverlayTabBar(selection: $tab, tabs: visibleTabs)
        }
        .padding(.horizontal, House.Spacing.sm)
        .frame(height: House.Control.railRow)
        // If the active tab gets turned off in Prepare, fall back to Assist.
        .onChange(of: notesEnabled) { _, _ in normalizeSelection() }
        .onChange(of: guideEnabled) { _, _ in normalizeSelection() }
        .onChange(of: findingsEnabled) { _, _ in normalizeSelection() }
        .onChange(of: autoAssistEnabled) { _, _ in normalizeSelection() }
        // The View menu (⌘1…⌘7) and commands switch tabs by posting a
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

    /// The Assist chat: the thread over the composer row, which is the
    /// surface's footer (no footer well).
    private var assistTab: some View {
        GeometryReader { geometry in
          VStack(spacing: 0) {
            ResponseView(
                entries: llm.entries,
                streaming: llm.streaming,
                error: llm.lastError,
                errorIsAuth: llm.lastErrorIsAuth,
                onOpenSettings: onOpenSettings
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, House.Spacing.lg)

            AssistantInputView(availableHeight: geometry.size.height - House.Spacing.xs)
                .padding(House.Spacing.xs)
          }
        }
    }
}

private extension View {
    /// Uniform padding for the non-assist tab contents.
    func tabContentPadding() -> some View {
        padding(.horizontal, House.Spacing.lg).padding(.top, House.Spacing.xs)
    }
}

// MARK: - Shell state

/// Overlay state the header and the menu bar share: which header chooser is
/// open. In memory only.
@Observable @MainActor
final class OverlayShellModel {
    static let shared = OverlayShellModel()

    enum Chooser: Equatable {
        case model
        case mode
    }

    /// The chooser open under the title block, if any. An in-window layer,
    /// never a menu window, so it stays out of screen shares with the
    /// overlay (`sharingType = .none`).
    var chooser: Chooser?

    @ObservationIgnored private var escapeRegistered = false

    private init() {}

    func toggle(_ chooser: Chooser) {
        self.chooser = self.chooser == chooser ? nil : chooser
    }

    /// `esc` closes the chooser first.
    func registerEscape() {
        guard !escapeRegistered else { return }
        escapeRegistered = true
        OverlayEscapeRouter.shared.registerLayer(
            "header.chooser",
            isOpen: { OverlayShellModel.shared.chooser != nil },
            close: { OverlayShellModel.shared.chooser = nil }
        )
    }
}

extension SessionCoordinator.Phase {
    /// The header's copy of the phase (`OverlayShellStatus` lives in RTICore).
    var livePhase: OverlayLivePhase {
        switch self {
        case .idle: .idle
        case .recording: .recording
        case .paused: .paused
        case .finishing: .finishing
        case .summarizing: .summarizing
        case .done: .done
        }
    }
}

// MARK: - Header

/// The overlay header (chat-surfaces.md sections 1 and 8): the title block
/// over its state line on the left, the capture controls and the record
/// chip (the one live action) on the right. `Control.composer` high, in the
/// title-bar row, no divider. Its empty space drags the window.
struct OverlayShellHeader: View {
    let status: OverlayShellStatus

    private let chrome = OverlayWindowChrome.shared
    @State private var width: CGFloat = 0

    /// Below the overlay's standard width the record chip drops its key caps
    /// (the key stays in its help text), so the title keeps room at 600.
    private var isCompact: Bool {
        width > 0 && width < OverlayAppearanceDefaults.defaultWidth
    }

    /// The record chip's key caps. While capture runs, the clock takes their
    /// place, so the model line keeps its room; ⌘⇧R stays in the chip's help
    /// and the Session menu.
    private var showsRecordKeys: Bool {
        !isCompact && !status.recordChip.showsClock
    }

    /// At the minimum width a live chip is the registered recording chip
    /// alone: the `danger` mark and the clock. "Finish" moves to its help.
    private var showsRecordTitle: Bool {
        !(isCompact && status.recordChip.showsClock)
    }

    var body: some View {
        HStack(spacing: House.Spacing.sm) {
            OverlayHeaderTitle(status: status)
            Spacer(minLength: House.Spacing.xs)
            if chrome.isKeptOnTop {
                QuickAIGlyphButton(
                    symbol: "pin.fill",
                    font: HouseChatType.glyphSmall,
                    color: House.ColorToken.textSecondary,
                    label: "Kept on top",
                    help: "Kept on top of other windows. Click to stop."
                ) {
                    chrome.isKeptOnTop = false
                }
            }
            HStack(spacing: House.Spacing.xs) {
                OverlayMicControl()
                OverlayVisualContextButton(isLive: status.phase.isLive)
                // While capture runs the state line needs the room; the
                // project's name stays in the chip's tooltip.
                OverlayProjectPicker(allowsName: !isCompact && !status.phase.isLive)
                OverlayRecordButton(status: status, showsTitle: showsRecordTitle, showsKeys: showsRecordKeys)
                OverlaySessionAuxButton(phase: status.phase)
            }
            .fixedSize()
        }
        .padding(.leading, chrome.isFullScreen ? House.Spacing.sm : HouseChatMetrics.trafficLightInset)
        .padding(.trailing, House.Spacing.lg)
        .frame(maxWidth: .infinity)
        .frame(height: House.Control.composer)
        .background {
            ZStack {
                House.ColorToken.surface
                // The title-bar row drags the window, as a normal title bar
                // does (macOS 14 stand-in for WindowDragGesture).
                WindowDragArea()
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { width = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, newWidth in width = newWidth }
                }
            }
        }
        .zIndex(1)
    }
}

/// The title over the state line: status dot and word, then the mode (in
/// full ink, like an assistant's name), then the model. Mode and model open
/// in-window choosers.
struct OverlayHeaderTitle: View {
    let status: OverlayShellStatus

    private let context = MeetingContextStore.shared
    private let modes = ModeStore.shared
    private let llm = LLMController.shared
    private let shell = OverlayShellModel.shared

    private var title: String {
        OverlayShellStatus.title(
            calendarTitle: context.calendarMeeting?.title,
            projectName: context.workstreamName,
            phase: status.phase
        )
    }

    private var modelTitle: String {
        let name = LLMProviders.active.displayName
        return llm.smartMode ? "\(name) · Smart" : name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            Text(title)
                .font(HouseChatType.subheading)
                .foregroundStyle(House.ColorToken.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: House.Spacing.xxs) {
                HStack(spacing: House.Spacing.xxs) {
                    SlateStatusDot(color: status.tone.color)
                    Text(status.word)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textSecondary)
                        .lineLimit(1)
                }
                .fixedSize()
                .accessibilityElement(children: .combine)
                .accessibilityLabel("State: \(status.word)")
                if let mode = modes.activeMode?.name {
                    separator
                    chooserButton(
                        mode,
                        emphasised: true,
                        kind: .mode,
                        label: "Mode: \(mode)",
                        hint: "Change the mode"
                    )
                }
                separator
                chooserButton(
                    modelTitle,
                    emphasised: false,
                    kind: .model,
                    label: "Model: \(modelTitle)",
                    hint: "Change the model"
                )
            }
        }
    }

    private var separator: some View {
        Text("·")
            .font(House.TypeToken.meta)
            .foregroundStyle(House.ColorToken.textTertiary)
            .accessibilityHidden(true)
    }

    private func chooserButton(
        _ text: String,
        emphasised: Bool,
        kind: OverlayShellModel.Chooser,
        label: String,
        hint: String
    ) -> some View {
        Button {
            shell.toggle(kind)
        } label: {
            Text(text)
                .font(House.TypeToken.meta)
                .foregroundStyle(emphasised ? House.ColorToken.textPrimary : House.ColorToken.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
        .accessibilityValue(shell.chooser == kind ? "Open" : "Closed")
        .help(hint)
    }
}

extension OverlayStatusTone {
    /// The status token for the dot. The word beside it says the same thing.
    var color: Color {
        switch self {
        case .ready: House.ColorToken.success
        case .recording: House.ColorToken.danger
        case .busy: House.ColorToken.warning
        }
    }
}

// MARK: - Header choosers

/// The model or mode chooser, floating under the title block on panel glass
/// (chat-surfaces.md section 3 "Floating layers"). In-window SwiftUI, so it
/// inherits the overlay's `sharingType = .none`. A click outside or `esc`
/// closes it.
struct OverlayHeaderChooserLayer: View {
    private let shell = OverlayShellModel.shared
    private let chrome = OverlayWindowChrome.shared

    var body: some View {
        if let chooser = shell.chooser {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { shell.chooser = nil }
                    .accessibilityHidden(true)
                OverlayHeaderChooser(kind: chooser)
                    .frame(width: House.Layout.chatRail + House.Spacing.xxxxl)
                    .panelGlass(radius: House.Radius.lg)
                    .panelShadows()
                    .padding(.leading, chrome.isFullScreen ? House.Spacing.sm : HouseChatMetrics.trafficLightInset)
                    .padding(.top, House.Control.composer)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
    }
}

/// The rows of one header chooser.
struct OverlayHeaderChooser: View {
    let kind: OverlayShellModel.Chooser

    private let shell = OverlayShellModel.shared
    private let llm = LLMController.shared
    private let modes = ModeStore.shared
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            SlateSectionLabel(text: kind == .model ? "Model" : "Mode")
                .padding(.horizontal, House.Spacing.xs)
                .padding(.top, House.Spacing.xxs)
            switch kind {
            case .model:
                ForEach(LLMProviders.all) { provider in
                    row(id: provider.id, title: provider.displayName, detail: provider.model,
                        isChecked: LLMProviders.activeId == provider.id) {
                        LLMProviders.activeId = provider.id
                    }
                }
                HouseDivider()
                    .padding(.vertical, House.Spacing.xxs)
                row(id: "smart", title: "Smart mode", detail: "Slower, deeper", isChecked: llm.smartMode) {
                    llm.smartMode.toggle()
                }
            case .mode:
                ForEach(modes.modes) { mode in
                    row(id: mode.id, title: mode.name, detail: nil,
                        isChecked: modes.activeMode?.id == mode.id) {
                        CommandBuilder.switchMode(to: mode, modes: modes, llm: llm)
                    }
                }
            }
        }
        .padding(House.Spacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(kind == .model ? "Choose a model" : "Choose a mode")
    }

    private func row(id: String, title: String, detail: String?, isChecked: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            shell.chooser = nil
        } label: {
            HStack(spacing: House.Spacing.xs) {
                Image(systemName: "checkmark")
                    .font(House.TypeToken.caption)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .opacity(isChecked ? 1 : 0)
                    .frame(width: House.Control.keyCap)
                Text(title)
                    .font(House.TypeToken.label)
                    .foregroundStyle(House.ColorToken.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: House.Spacing.xs)
                if let detail {
                    Text(detail)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, House.Spacing.xs)
            .frame(height: House.Control.railRow)
            .background { RowHighlight(isSelected: false, isHovering: hovered == id) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight($hovered, id: id)
        .accessibilityLabel(title)
        .accessibilityValue(isChecked ? "Selected" : "")
    }
}
