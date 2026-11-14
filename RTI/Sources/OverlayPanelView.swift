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
    private let hotkeyNotice = HotkeyNoticeModel.shared
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
    /// The selected Live view, shared with the workspace sidebar.
    @Bindable private var liveTabs = LiveTabState.shared
    private var tab: OverlayTab {
        get { liveTabs.selected }
        nonmutating set { liveTabs.selected = newValue }
    }
    @State private var hasVisitedTranscript = false
    /// Live views built once and then shown or hidden, never rebuilt: a
    /// switch rebuilt the Markdown thread, notes or codebook every time,
    /// about 200 ms each during a call (2026-11-14). Prepare stays rebuilt:
    /// it is cheap and refreshes on each visit.
    @State private var visited: Set<OverlayTab> = []
    private static var keptTabs: [OverlayTab] { keepsViews ? [.assist, .notes, .codebook, .guide] : [] }
    /// The latency harness turns this off to measure the old rebuild-on-switch.
    nonisolated(unsafe) static var keepsViews = true
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
            if !embedded { OverlayShellHeader(status: status) }
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
                    IsolatedPage(isVisible: tab == .transcript, content: AnyView(
                        transcriptPage
                            .environment(\.isWorkspaceEmbedded, embedded)
                            .font(.system(size: CGFloat(uiFontSize), weight: .regular))
                            .foregroundStyle(Color.overlayInk)
                            .tint(Color.overlayInk)
                    ))
                    .accessibilityHidden(tab != .transcript)
                }
                ForEach(Self.keptTabs) { kept in
                    if visited.contains(kept) || tab == kept {
                        // Each kept view has its own hosting view and graph
                        // (`IsolatedPage`); the composer is disabled on its
                        // own when hidden (`assistTab(active:)`).
                        IsolatedPage(isVisible: tab == kept, content: AnyView(
                            keptView(kept)
                                .environment(\.isWorkspaceEmbedded, embedded)
                                .font(.system(size: CGFloat(uiFontSize), weight: .regular))
                                .foregroundStyle(Color.overlayInk)
                                .tint(Color.overlayInk)
                        ))
                        .accessibilityHidden(tab != kept)
                    }
                }
                if tab == .setup {
                    SetupTabView().tabContentPadding()
                } else if !Self.keepsViews, tab != .transcript {
                    keptView(tab)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // The tab content never scrolls up under the header or the
            // transparent title bar.
            .clipped()
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
        // The shared Live view may already be selected when this view
        // appears (a recording that landed on Transcript), so the first view
        // counts as visited too; otherwise leaving it removed it instead of
        // hiding it, and its reading position was lost.
        .onAppear { markVisited(tab) }
        .onChange(of: tab) { _, selection in
            markVisited(selection)
        }
    }

    private func markVisited(_ selection: OverlayTab) {
        if selection == .transcript { hasVisitedTranscript = true }
        if Self.keptTabs.contains(selection) { visited.insert(selection) }
    }

    @ViewBuilder
    private func keptView(_ kept: OverlayTab) -> some View {
        switch kept {
        case .assist:
            assistTab(active: tab == .assist)
        case .codebook:
            ResearchCodebookTab()
        case .notes:
            NotesTabView().tabContentPadding()
        case .guide:
            if let guide = GuideSessionController.shared.guide {
                GuideTabView(guide: guide, isActive: isActive && tab == .guide).tabContentPadding()
            }
        case .setup, .transcript:
            EmptyView()
        }
    }

    /// The tabs in a row under the header: Prepare, then the live tabs.
    /// In the workspace the sidebar lists the views, so the row draws
    /// nothing there; it still owns the tab routing below.
    private var tabsRow: some View {
        Group {
            if embedded {
                Color.clear.frame(height: 0)
            } else {
                HStack(spacing: House.Spacing.xxs) {
                    OverlaySetupButton(selection: $liveTabs.selected)
                    OverlayTabBar(selection: $liveTabs.selected, tabs: visibleTabs)
                }
                .padding(.horizontal, House.Spacing.sm)
                .frame(height: House.Control.chip)
            }
        }
        .onAppear { liveTabs.visible = visibleTabs }
        // If the active tab gets turned off in Prepare, fall back to Assist.
        .onChange(of: visibleTabs) { _, tabs in
            liveTabs.visible = tabs
            normalizeSelection()
        }
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
    private func assistTab(active: Bool) -> some View {
        GeometryReader { geometry in
          VStack(spacing: 0) {
            ResponseView(
                entries: llm.entries,
                streaming: llm.streaming,
                error: llm.lastError,
                errorIsAuth: llm.lastErrorIsAuth
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, House.Spacing.lg)

            AssistantInputView(availableHeight: geometry.size.height - House.Spacing.xs)
                .disabled(!active)
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
    var fill: Color = House.ColorToken.surface
    var workspace: WorkspaceModel?
    var nativeTitlebar = false

    private let chrome = OverlayWindowChrome.shared

    private var sessionIsListeningOnly: Bool { SessionCoordinator.shared.isListeningOnly }

    var body: some View {
        GeometryReader { geometry in
            header(width: geometry.size.width)
        }
        .frame(height: rowHeight)
    }

    /// The native title bar clips anything taller than itself.
    private var rowHeight: CGFloat { nativeTitlebar ? chrome.titleRowHeight : House.Control.composer }

    static let listeningOnlyWord = "Listening only"

    /// True when the workspace row is narrower than its standard width: the
    /// Listening only chip would then squeeze the title to a letter.
    static func foldsListeningOnly(width: CGFloat, inWorkspace: Bool) -> Bool {
        inWorkspace && width < House.Layout.chatWidth
    }

    /// The title's column in the workspace header. Fixed, so the route
    /// segments beside it never move when the title changes ("RTI" to "Live
    /// session" on Record); a row tighter than 720 pt would shrink
    /// it, never hides it. Not a token yet: half the chat rail.
    /// The route segments left the header for the sidebar (2026-11-14), so
    /// the title takes the chat rail's width: "SH Yo…gnosis" was cut at 110.
    static let workspaceTitleWidth = House.Layout.chatRail

    /// Each control here has one home (2026-11-13): call type, project and
    /// guide live on Prepare (the title opens it), the model in Settings and
    /// the palette, the microphone in the mic menu, the project's screenshot
    /// choice in the eye menu. The title shows at every width. Below the
    /// workspace's standard width a live Listening only folds into the
    /// title's state line instead of its own chip, so the title keeps its
    /// column beside the clock (`foldsListeningOnly`).
    private func header(width: CGFloat) -> some View {
        let hideStandaloneKeys = width < OverlayAppearanceDefaults.defaultWidth
        let listeningOnly = status.phase.isLive && sessionIsListeningOnly
        let foldsListening = listeningOnly && Self.foldsListeningOnly(
            width: width + (nativeTitlebar ? HouseChatMetrics.trafficLightInset : 0), inWorkspace: workspace != nil)
        return HStack(spacing: House.Spacing.xs) {
            if let workspace { WorkspaceHeaderToggles(model: workspace) }
            OverlayHeaderTitle(status: status, stateOverride: foldsListening ? Self.listeningOnlyWord : nil)
                .frame(minWidth: 0, maxWidth: workspace == nil ? House.Layout.chatRail : Self.workspaceTitleWidth,
                       alignment: .leading)
            // Lowest priority: the title takes its column first, the drag
            // area what is left.
            Spacer(minLength: 0).background(WindowDragArea())
                .layoutPriority(-1)
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
                if listeningOnly && !foldsListening {
                    Text(Self.listeningOnlyWord)
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

/// The meeting title and capture state. The title names the calendar event,
/// else the project; with an event, the project follows the state word
/// ("Ready · Northwind app"), so the header always names it. A click opens
/// the Live page's Prepare tab, the one home of call type, project and guide.
struct OverlayHeaderTitle: View {
    let status: OverlayShellStatus
    /// Replaces the state word when the row folds a chip into it
    /// ("Listening only" at 720 pt).
    var stateOverride: String? = nil

    private let context = MeetingContextStore.shared
    @State private var hovering = false

    private var title: String {
        OverlayShellStatus.title(
            calendarTitle: context.calendarMeeting?.title,
            projectName: context.workstreamName,
            phase: status.phase
        )
    }

    private var projectDetail: String? {
        OverlayShellStatus.projectDetail(calendarTitle: context.calendarMeeting?.title, projectName: context.workstreamName)
    }

    private var stateLine: String {
        if let stateOverride { return stateOverride }
        return projectDetail.map { "\(status.word) · \($0)" } ?? status.word
    }

    private var stateWords: String {
        stateOverride.map { "\(status.word), \($0)" } ?? status.word
    }

    /// What a click does: show Prepare. Tests call it without a click.
    static func openPrepare() {
        NotificationCenter.default.post(name: .rtiSelectTab, object: OverlayTab.setup.rawValue)
    }

    var body: some View {
        Button {
            Self.openPrepare()
        } label: {
            VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                Text(title)
                    .font(HouseChatType.subheading)
                    .foregroundStyle(House.ColorToken.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: House.Spacing.xxs) {
                    SlateStatusDot(color: status.tone.color)
                    Text(stateLine)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, House.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                    .fill(hovering ? House.ColorToken.hoverFill : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight($hovering)
        .accessibilityLabel(Self.summary(title: title, project: projectDetail, state: stateWords))
        .accessibilityHint("Opens Prepare")
        .help("\(Self.summary(title: title, project: projectDetail, state: stateWords)). Click to open Prepare: call type, project and guide (\(OverlayTab.setup.shortcutLabel))")
    }

    /// The tooltip and VoiceOver line: the title, the project when the
    /// title does not name it, and the state.
    static func summary(title: String, project: String?, state: String) -> String {
        let project = project.map { ", project \($0)" } ?? ""
        return "\(title)\(project). State: \(state)"
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
