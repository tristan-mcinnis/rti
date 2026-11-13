import Observation
import RTICore
import SwiftUI
import HouseDesign

/// The overlay's content: a header in the traffic-light row, the tabs row,
/// and the selected tab. House window chrome (chat-surfaces.md section 7) in
/// its live form (section 8): the header says what this meeting is and its
/// state; there is no footer well.
struct OverlayPanelView: View {
    @Environment(\.isWorkspaceEmbedded) private var embedded
    private let llm = LLMController.shared
    private let session = SessionCoordinator.shared
    private let shell = OverlayShellModel.shared
    private let hotkeyNotice = HotkeyNoticeModel.shared
    var onOpenSettings: () -> Void = {}
    /// Render proofs only: draw this header state instead of the session's
    /// (the proofs cannot finish a real session to reach the saved state).
    var statusOverride: OverlayShellStatus? = nil
    /// The call type store the header reads. Production uses the shared store; a
    /// render proof passes an in-memory one so it never touches live prefs.
    var callTypes: CallTypeStore = .shared
    var isActive = true

    @AppStorage(OverlayAppearanceDefaults.appearanceModeKey) private var appearanceMode: String = OverlayAppearanceDefaults.defaultAppearanceMode
    @AppStorage(OverlayAppearanceDefaults.contrastKey) private var contrast: Double = OverlayAppearanceDefaults.defaultContrast
    @AppStorage(OverlayAppearanceDefaults.uiFontSizeKey) private var uiFontSize: Double = OverlayAppearanceDefaults.defaultUIFontSize
    // Notes shows as a tab when enabled in Prepare (default on). Auto has no
    // tab: it defaults on for client and research calls, a stored toggle
    // wins (`AutoAssistSettings.isActive`), and its cards show in the rail.
    @AppStorage(NotesSettings.enabledKey) private var notesEnabled = NotesSettings.defaultEnabled
    @AppStorage(AutoAssistSettings.enabledKey) private var autoAssistStored: Bool?
    @State private var tab: OverlayTab = .assist
    @State private var hasVisitedTranscript = false
    /// The strip's rail sheet. Owned here, not by the strip, so widening the
    /// window or leaving the page closes it on purpose instead of tearing it
    /// down with the strip.
    @State private var railSheetOpen = false

    // Prepare is the pre-call surface, not a live tab — it's pulled out of the
    // equal-weight row into a leading icon button (OverlaySetupButton) so the
    // row gives its weight to the live surfaces.
    private var visibleTabs: [OverlayTab] {
        OverlayTab.visibleTabs(notes: notesEnabled, guide: GuideSessionController.shared.isActive, codebook: callTypes.active == .research)
    }

    private var autoOn: Bool {
        AutoAssistSettings.isActive(for: callTypes.active, stored: autoAssistStored)
    }

    /// Live help sits beside the transcript when Auto runs on this call or a
    /// guide is active.
    private var railApplies: Bool {
        AutoAssistSettings.liveHelpApplies(for: callTypes.active, stored: autoAssistStored,
                                           guideActive: GuideSessionController.shared.isActive)
    }

    /// The transcript with live help beside it (a rail) or over it (a strip
    /// in a narrow window). The transcript keeps its place in the tree, so
    /// its scroll and reading state survive. The rail is mounted only while
    /// the Live page shows the Transcript tab, so it does no work hidden; a
    /// blank of the same width holds the transcript's width meanwhile.
    private var transcriptPage: some View {
        GeometryReader { geometry in
            let mode = LiveRailLayout.mode(width: geometry.size.width, applies: railApplies)
            let showsHelp = isActive && tab == .transcript
            VStack(alignment: .leading, spacing: 0) {
                if mode == .strip, showsHelp {
                    LiveRailStripHost(callType: callTypes.active, autoOn: autoOn) { railSheetOpen = true }
                        .padding(.horizontal, House.Spacing.lg)
                        .padding(.top, House.Spacing.xs)
                }
                HStack(alignment: .top, spacing: 0) {
                    TranscriptTabView(isActive: isActive && tab == .transcript)
                        .tabContentPadding()
                    if mode == .rail {
                        Group {
                            if showsHelp {
                                LiveAssistRailHost(callType: callTypes.active, autoOn: autoOn)
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: LiveRailLayout.width)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(House.ColorToken.divider).frame(width: House.hairline)
                        }
                    }
                }
            }
            // The sheet stands in for the strip: when the strip goes (a
            // wider window shows the rail, or the page is left), so does it.
            .onChange(of: mode == .strip && showsHelp) { _, strip in
                if !strip { railSheetOpen = false }
            }
        }
        // Finish ends live help: a sheet left open does not outlive the call.
        .onChange(of: session.phase.livePhase.isLive) { _, live in
            if !live { railSheetOpen = false }
        }
        .sheet(isPresented: $railSheetOpen) {
            LiveRailSheet(done: { railSheetOpen = false }) {
                LiveAssistRailHost(callType: callTypes.active, autoOn: autoOn)
            }
        }
    }

    private var status: OverlayShellStatus {
        statusOverride ?? OverlayShellStatus(
            phase: session.phase.livePhase,
            processingStatus: session.postProcessingStatus
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if !embedded { OverlayShellHeader(status: status, callTypes: callTypes) }
            tabsRow
            if MuteBannerRule.shows(isRunning: session.isRunning, mic: session.mic) {
                OverlayNoticeBanner(
                    text: "Your mic is muted. Your side is not being recorded.",
                    actionTitle: "Unmute",
                    action: { session.unmuteMic() }
                )
            }
            if let message = hotkeyNotice.message {
                OverlayNoticeBanner(text: message, onDismiss: { hotkeyNotice.dismiss() })
            }
            ZStack(alignment: .topLeading) {
                // Keep the reader's scroll view and local edit state after its
                // first visit. Hidden readers hold their last displayed rows;
                // they catch up once on return instead of laying out each frame.
                if hasVisitedTranscript || tab == .transcript {
                    transcriptPage
                        .opacity(tab == .transcript ? 1 : 0)
                        .allowsHitTesting(tab == .transcript)
                        .disabled(tab != .transcript)
                        .accessibilityHidden(tab != .transcript)
                }
                switch tab {
                case .assist:
                    assistTab
                case .transcript:
                    EmptyView()
                case .codebook:
                    ResearchCodebookTab()
                case .notes:
                    NotesTabView().tabContentPadding()
                case .guide:
                    if let guide = GuideSessionController.shared.guide {
                        GuideTabView(guide: guide, isActive: isActive).tabContentPadding()
                    }
                case .setup:
                    SetupTabView().tabContentPadding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // The tab content never scrolls up under the header or the
            // transparent title bar.
            .clipped()
        }
        .overlay(alignment: .topLeading) {
            if !embedded { OverlayHeaderChooserLayer(callTypes: callTypes) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(embedded ? House.ColorToken.surfaceRaised : House.ColorToken.surface)
        // The header shares the title-bar row with the traffic lights.
        .ignoresSafeArea(.container, edges: embedded ? [] : .top)
        .font(.system(size: CGFloat(uiFontSize), weight: .regular))
        .foregroundStyle(Color.overlayInk)
        // Chrome is ink: system controls (menus, pickers, prominent buttons)
        // must not paint themselves the system accent blue.
        .tint(Color.overlayInk)
        .preferredColorScheme(preferredColorScheme)
        .overlay(themeRefreshToken)
        .onAppear { shell.registerEscape() }
        .onChange(of: tab) { _, selection in
            if selection == .transcript { hasVisitedTranscript = true }
        }
    }

    /// The tabs in a row under the header: Prepare, then the live tabs.
    private var tabsRow: some View {
        HStack(spacing: House.Spacing.xxs) {
            OverlaySetupButton(selection: $tab)
            OverlayTabBar(selection: $tab, tabs: visibleTabs)
        }
        .padding(.horizontal, House.Spacing.sm)
        .frame(height: House.Control.chip)
        .background(embedded ? House.ColorToken.surface : Color.clear)
        // If the active tab gets turned off in Prepare, fall back to Assist.
        .onChange(of: visibleTabs) { _, _ in normalizeSelection() }
        // The View menu (⌘1…⌘7) and commands switch tabs by posting a
        // notification with the target tab's rawValue.
        .onReceive(NotificationCenter.default.publisher(for: .rtiSelectTab)) { note in
            // The kept Auto slot (⌘3) opens Transcript, beside the rail.
            guard let raw = note.object as? String,
                  let target = OverlayTab(rawValue: OverlayTabShortcut.destination(forTab: raw)) else { return }
            if target == .setup || visibleTabs.contains(target) { tab = target }
        }
        .onChange(of: session.phase) { previous, current in
            // Prepare → Live is the primary hand-off in RTI. Do not
            // interrupt someone who has deliberately navigated away
            // from Prepare after the recording is already underway.
            if let landing = LiveLanding.tab(previous: previous, current: current, selection: tab,
                                             autoOn: autoOn,
                                             guideActive: GuideSessionController.shared.isActive,
                                             callType: callTypes.active)
            {
                tab = landing
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
            .opacity(contrast < 0 ? 0 : 0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private func normalizeSelection() {
        // Prepare lives outside visibleTabs but is always reachable, so don't
        // kick the user out of it when a live-tab toggle flips.
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
                .background(embedded ? House.ColorToken.surface : Color.clear)
          }
        }
    }
}

/// Where the Live page lands when a recording starts. Prepare -> Live is the
/// primary hand-off in RTI; someone who has already left Prepare is never
/// moved. Resuming from pause lands only where a fresh start would.
///
/// Live help (the rail) applies when Auto runs, or a guide is active on a
/// research call (`AutoAssistSettings.liveHelpApplies`), and with it the
/// transcript is the live page. So a guided research start lands on the
/// Transcript beside the rail, not on the Guide tab (changed in Band 2: the
/// guide's gaps show in the rail; Guide stays a tab one ⌘ digit away). A
/// guided start on another call type with Auto off has no rail, so it lands
/// on the Guide tab, as before Band 2.
enum LiveLanding {
    static func tab(previous: SessionPhase, current: SessionPhase, selection: OverlayTab,
                    autoOn: Bool, guideActive: Bool, callType: CallType) -> OverlayTab?
    {
        guard current == .recording, selection == .setup else { return nil }
        let guideStart = guideActive && previous != .paused
        guard previous == .idle || guideStart else { return nil }
        if autoOn || (guideActive && callType == .research) { return .transcript }
        return guideStart ? .guide : .assist
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
        case options
        case model
        case callType
    }

    /// The chooser open under the title block, if any. An in-window layer,
    /// never a menu window, so it stays out of screen shares with the
    /// overlay and its window-sharing preference.
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
        case .upgrading: .upgrading
        case .done: .done
        }
    }
}

// MARK: - Header

/// The overlay header (chat-surfaces.md sections 1 and 8): the title block
/// over its state line on the left, the capture controls and the record
/// chip (the one live action) on the right. `Control.composer` high in a
/// windowless proof; in the app it takes the native title bar's height
/// (`OverlayWindowChrome.titleRowHeight`), no divider. Its empty space drags
/// the window.
struct OverlayShellHeader: View {
    let status: OverlayShellStatus
    /// The call type store the title reads. Defaults to the shared one so
    /// production is unchanged; a proof passes an in-memory store.
    var callTypes: CallTypeStore = .shared
    var fill: Color = House.ColorToken.surface
    var workspace: WorkspaceModel?
    var nativeTitlebar = false

    private let chrome = OverlayWindowChrome.shared
    @State private var showsCompactControls = false

    private var sessionIsListeningOnly: Bool { SessionCoordinator.shared.isListeningOnly }

    var body: some View {
        GeometryReader { geometry in
            header(width: geometry.size.width)
        }
        .frame(height: rowHeight)
    }

    /// The native title bar clips anything taller than itself.
    private var rowHeight: CGFloat { nativeTitlebar ? chrome.titleRowHeight : House.Control.composer }

    private func header(width: CGFloat) -> some View {
        let availableWidth = width + (nativeTitlebar ? HouseChatMetrics.trafficLightInset : 0)
        let compact = workspace != nil && availableWidth < WorkspaceLayout.standardSize.width
        let hideStandaloneKeys = width < OverlayAppearanceDefaults.defaultWidth
        return HStack(spacing: House.Spacing.xs) {
            if compact {
                Button { showsCompactControls.toggle() } label: {
                    Image(systemName: "ellipsis.circle").font(House.TypeToken.body)
                        .frame(width: House.Control.chip, height: House.Control.chip)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Meeting, microphone and project")
                .help("Meeting title, microphone, project and assistant options")
                .popover(isPresented: $showsCompactControls) {
                    VStack(alignment: .leading, spacing: House.Spacing.xs) {
                        Text(OverlayShellStatus.title(calendarTitle: MeetingContextStore.shared.calendarMeeting?.title,
                             projectName: MeetingContextStore.shared.workstreamName, phase: status.phase))
                            .font(House.TypeToken.label).lineLimit(2)
                        HStack { OverlayMicControl(); OverlayProjectPicker(allowsName: true) }
                        Button("Assistant options") {
                            showsCompactControls = false
                            OverlayShellModel.shared.toggle(.options)
                        }
                    }
                    .padding(House.Spacing.sm)
                }
            } else {
                OverlayHeaderTitle(status: status, callTypes: callTypes)
                    .layoutPriority(-1)
            }
            if let workspace { WorkspaceRouteSegments(model: workspace) }
            Spacer(minLength: 0).background(WindowDragArea())
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
                if !compact { OverlayMicControl() }
                OverlayVisualContextButton(isLive: status.phase.isLive)
                // While capture runs the state line needs the room; the
                // project's name stays in the chip's tooltip.
                if !compact { OverlayProjectPicker(allowsName: !hideStandaloneKeys && !status.phase.isLive) }
                if status.phase.isLive && sessionIsListeningOnly {
                    Text("Listening only")
                        .font(House.TypeToken.caption)
                        .padding(.horizontal, House.Spacing.xs)
                        .frame(height: House.Control.chip)
                        .background(House.ColorToken.chipFill, in: Capsule())
                        .accessibilityLabel("Listening only. Microphone muted intentionally.")
                }
                OverlaySessionAuxButton(phase: status.phase)
                OverlayRecordButton(status: status, showsTitle: workspace != nil || !(hideStandaloneKeys && status.recordChip.showsClock),
                                    showsKeys: workspace == nil && !hideStandaloneKeys && !status.recordChip.showsClock)
            }
            .fixedSize()
        }
        .padding(.leading, nativeTitlebar ? 0 : (chrome.isFullScreen ? House.Spacing.sm : HouseChatMetrics.trafficLightInset))
        .padding(.trailing, House.Spacing.lg)
        .frame(maxWidth: .infinity)
        .frame(height: rowHeight)
        .background(fill)
        .zIndex(1)
    }
}

/// The meeting title and capture state stay visible. Call type and model live in
/// one in-window options layer, alongside the model and call type choosers.
struct OverlayHeaderTitle: View {
    let status: OverlayShellStatus
    /// The call type store, injected so a proof never reads the live one.
    var callTypes: CallTypeStore = .shared

    private let context = MeetingContextStore.shared
    private let shell = OverlayShellModel.shared

    private var title: String {
        OverlayShellStatus.title(
            calendarTitle: context.calendarMeeting?.title,
            projectName: context.workstreamName,
            phase: status.phase
        )
    }

    var body: some View {
        HStack(spacing: House.Spacing.xs) {
            VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                Text(title)
                    .help(title)
                    .font(HouseChatType.subheading)
                    .foregroundStyle(House.ColorToken.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
            }
            Button {
                shell.toggle(.options)
            } label: {
                Label("Assistant options", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textSecondary)
            }
            .buttonStyle(.plain)
            .frame(width: House.Control.pill, height: House.Control.pill)
            .contentShape(Rectangle())
            .accessibilityLabel("Assistant options")
            .accessibilityValue(shell.chooser == .options ? "Open" : "Closed")
            .help("Change the call type or model")
        }
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

/// Assistant options and model and call type choosers float under the title block on panel glass
/// (chat-surfaces.md section 3 "Floating layers"). In-window SwiftUI, so it
/// inherits the overlay's window-sharing preference. A click outside or `esc`
/// closes it.
struct OverlayHeaderChooserLayer: View {
    /// The call type store, injected so a proof never reads the live one.
    var callTypes: CallTypeStore = .shared
    /// The header row's height: the chooser opens just under it.
    var headerHeight: CGFloat = House.Control.composer

    private let shell = OverlayShellModel.shared
    private let chrome = OverlayWindowChrome.shared

    var body: some View {
        if let chooser = shell.chooser {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { shell.chooser = nil }
                    .accessibilityHidden(true)
                OverlayHeaderChooser(kind: chooser, callTypes: callTypes)
                    .frame(width: House.Layout.chatRail + House.Spacing.xxxxl)
                    .panelGlass(radius: House.Radius.lg)
                    .panelShadows()
                    .padding(.leading, chrome.isFullScreen ? House.Spacing.sm : HouseChatMetrics.trafficLightInset)
                    .padding(.top, headerHeight)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
    }
}

/// The rows of one header chooser.
struct OverlayHeaderChooser: View {
    let kind: OverlayShellModel.Chooser
    /// The call type store, injected so a proof never reads the live one.
    var callTypes: CallTypeStore = .shared

    private let shell = OverlayShellModel.shared
    private let llm = LLMController.shared
    @State private var hovered: String?

    private var title: String {
        switch kind {
        case .options: "Assistant options"
        case .model: "Model · \(llm.chatRouteLabel)"
        case .callType: "Call type"
        }
    }

    private var accessibilityTitle: String {
        switch kind {
        case .options: "Assistant options"
        case .model: "Choose a model"
        case .callType: "Choose a call type"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            if kind != .options {
                row(id: "options", title: "Back to assistant options", detail: nil, isChecked: false, dismissesChooser: false) {
                    shell.chooser = .options
                }
                HouseDivider().padding(.vertical, House.Spacing.xxs)
            }
            SlateSectionLabel(text: title)
                .padding(.horizontal, House.Spacing.xs)
                .padding(.top, House.Spacing.xxs)
            switch kind {
            case .options:
                row(id: "callType", title: "Call type", detail: callTypes.active.name, isChecked: false, dismissesChooser: false) {
                    shell.chooser = .callType
                }
                row(id: "model", title: "Model", detail: llm.chatRouteLabel, isChecked: false, dismissesChooser: false) {
                    shell.chooser = .model
                }
            case .model:
                ForEach(LLMProviders.all) { provider in
                    row(id: provider.id, title: provider.displayName, detail: provider.model,
                        isChecked: llm.chatSelection.providerId == provider.id) {
                        llm.selectChatProvider(provider.id)
                    }
                }
                HouseDivider()
                    .padding(.vertical, House.Spacing.xxs)
                row(id: "thinking", title: "Thinking", detail: "Slower, deeper",
                    isChecked: llm.chatSelection.reasoning == .thinking) {
                    llm.setChatReasoning(llm.chatSelection.reasoning == .thinking ? .fast : .thinking)
                }
            case .callType:
                ForEach(CallType.allCases) { type in
                    row(id: type.id, title: type.name, detail: nil,
                        isChecked: callTypes.active == type) {
                        CommandBuilder.switchCallType(to: type, callTypes: callTypes, llm: llm)
                    }
                }
            }
        }
        .padding(House.Spacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityTitle)
    }

    private func row(id: String, title: String, detail: String?, isChecked: Bool, dismissesChooser: Bool = true, action: @escaping () -> Void) -> some View {
        Button {
            action()
            if dismissesChooser { shell.chooser = nil }
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
