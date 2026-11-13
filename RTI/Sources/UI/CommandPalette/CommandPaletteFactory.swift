import AppKit
import Carbon.HIToolbox
import RTICore

/// Builds the runtime command palette / menu / hotkey entries. Extracted
/// from AppDelegate so the coordinator stays focused on wiring and
/// lifecycle, not on enumerating every affordance in the app.
///
/// Commands are built in named sections rather than one giant array so
/// adding a new command is a one-line change in the right section. The
/// top-level `build` concatenates all sections.
///
/// `MenuCoordinator` and `HotkeyCoordinator` consume this same list — one
/// registry, three consumers (palette, menu, hotkeys).
enum CommandBuilder {
    @MainActor
    static func buildCommands(
        windows: WindowCoordinator,
        session: SessionCoordinator,
        llm: LLMController,
        callTypes: CallTypeStore
    ) -> [RTICommand] {
        sessionCommands(windows: windows, session: session)
            + navigationCommands(windows: windows)
            + tabCommands(windows: windows)
            + actionCommands(llm: llm)
            + assistantProviderCommands()
            + transcriptionCommands()
            + screenshotCommands()
            + panelCommands(windows: windows, llm: llm)
            + appCommands(windows: windows)
            + callTypeCommands(callTypes: callTypes, llm: llm)
    }

    /// The keyboard route to the Settings default ("Screenshots default:
    /// Off"), the same value as Settings > General. A project's own choice
    /// is set only in the header's eye menu.
    @MainActor
    private static func screenshotCommands() -> [RTICommand] {
        ScreenshotMode.allCases.map { mode in
            RTICommand(
                id: "screenshots.\(mode.rawValue)",
                title: mode.title,
                keywords: ["screenshots", "capture", "screen", "default", mode.title],
                perform: { ScreenshotPolicy.shared.setGlobal(mode) },
                menuSection: .panels,
                menuParent: "Screenshots default",
                menuStateProvider: { ScreenshotPolicy.shared.global == mode }
            )
        }
    }

    // MARK: - Transcription provider (menu quick-switch)

    @MainActor
    private static func assistantProviderCommands() -> [RTICommand] {
        LLMProviders.all.map { provider in
            RTICommand(
                id: "llm.provider.\(provider.id)",
                title: "Assistant: \(provider.displayName)",
                keywords: ["assistant", "llm", "provider", "model", "openai", "deepseek", "openrouter", "switch"],
                // The current chat follows, as the deleted header chooser did.
                perform: { LLMController.shared.selectChatProvider(provider.id) },
                menuSection: .panels,
                menuParent: "Assistant model",
                menuStateProvider: { LLMProviders.activeId == provider.id }
            )
        }
    }

    /// Quick-switch the live speech-to-text engine from the menubar, with a
    /// checkmark on the active one. Applies to the next session — a mid-session
    /// swap would tear down and rebuild both audio legs and risk dropping the
    /// meeting, so we don't hot-swap a live recording.
    @MainActor
    private static func transcriptionCommands() -> [RTICommand] {
        guard STTProviders.all.count > 1 else { return [] }
        return STTProviders.all.map { provider in
            RTICommand(
                id: "stt.provider.\(provider.id)",
                title: "Transcription: \(provider.displayName)",
                keywords: ["transcription", "stt", "provider", "engine", "soniox", "model", "switch"],
                perform: { STTProviders.activeId = provider.id },
                menuSection: .panels,
                menuParent: "Transcription model",
                menuStateProvider: { STTProviders.activeId == provider.id }
            )
        }
    }

    // MARK: - Tab navigation

    /// Jump straight to an overlay tab. ⌘1…⌘7 pick a tab while the overlay is
    /// key (the View menu); they are local keys, never global hotkeys, and
    /// the status-item menu stays uncluttered. The palette row shows the key.
    @MainActor
    private static func tabCommands(windows: WindowCoordinator) -> [RTICommand] {
        let tabs = OverlayTab.allCases.map { tab in
            RTICommand(
                id: "view.tab.\(tab.rawValue)",
                title: "Go to \(tab.title)",
                subtitle: tab.shortcutLabel,
                keywords: ["tab", "switch", "jump", "go", tab.rawValue, tab.title.lowercased()],
                perform: { [weak windows] in
                    windows?.showOverlay()
                    NotificationCenter.default.post(name: .rtiSelectTab, object: tab.rawValue)
                },
                menuTitleProvider: { "Go to \(tab.title)" }
            )
        }
        // The deleted Auto tab's row: its cards sit in the live rail beside
        // the transcript, so "auto" still finds them, on the kept ⌘3.
        let slot = OverlayTabShortcut.liveHelpSlot
        let liveHelp = RTICommand(
            id: "view.tab.\(slot)",
            title: "Go to Live Help",
            subtitle: "⌘\(OverlayTabShortcut.number(forTab: slot) ?? 0)",
            keywords: ["tab", "switch", "jump", "go", "auto", "live help", "rail", "cards", "transcript"],
            // Offered only when live help shows; otherwise it is "Go to Transcript".
            isAvailable: {
                AutoAssistSettings.liveHelpApplies(for: CallTypeStore.shared.active,
                                                   stored: UserDefaults.standard.object(forKey: AutoAssistSettings.enabledKey) as? Bool,
                                                   guideActive: GuideSessionController.shared.isActive)
            },
            perform: { [weak windows] in
                windows?.showOverlay()
                NotificationCenter.default.post(name: .rtiSelectTab, object: slot)
            },
            menuTitleProvider: { "Go to Live Help" }
        )
        return tabs + [liveHelp]
    }

    /// Session-specific rows are evaluated when the palette opens. No guide text is
    /// registered in the persistent menu or global hotkey list.
    @MainActor
    static func guideCommands() -> [RTICommand] {
        let controller = GuideSessionController.shared
        guard let guide = controller.guide else { return [] }
        return guide.sections.flatMap { section in
            section.questions.map { question in
                let title = question.en.isEmpty ? question.zh : question.en
                return RTICommand(
                    id: "guide.question.\(question.qid)",
                    title: "\(question.qid) · \(title)",
                    keywords: ["guide", "jump", section.title, question.en, question.zh],
                    perform: {
                        controller.jump(to: question.qid)
                        NotificationCenter.default.post(name: .rtiSelectTab, object: OverlayTab.guide.rawValue)
                    }
                )
            }
        }
    }

    // MARK: - Section builders

    @MainActor
    private static func sessionCommands(
        windows: WindowCoordinator,
        session: SessionCoordinator
    ) -> [RTICommand] {
        return [
            RTICommand(id: "stimulus.show", title: "Mark Stimulus Shown", keywords: ["material", "board", "guide", "comparison"],
                       isAvailable: { session.isRunning && SessionMarkers.shared.pinned != nil },
                       perform: {
                           windows.showOverlay()
                           NotificationCenter.default.post(name: .rtiSelectTab, object: GuideSessionController.shared.isActive ? OverlayTab.guide.rawValue : OverlayTab.setup.rawValue)
                           SessionMarkers.shared.showsControls = true
                       }),
            RTICommand(
                id: "research.starQuote", title: "Star transcript line", subtitle: "⌘⌥8",
                keywords: ["star", "quote", "bank"],
                isAvailable: { session.isRunning && ResearchCodebookController.shared.location != nil },
                perform: { Task { await ResearchCodebookController.shared.star() } },
                hotkeyKeyCode: UInt32(kVK_ANSI_8), hotkeyModifiers: UInt32(cmdKey | optionKey), hotkeySessionScoped: true
            ),
            RTICommand(
                id: "meeting.project",
                // One name everywhere (palette, Meeting menu, status item);
                // every route opens Prepare, the project's one home.
                title: MainMenuValidation.chooseProjectTitle,
                keywords: ["project", "client", "route", "context", "meeting"],
                perform: {
                    windows.showOverlay()
                    NotificationCenter.default.post(name: .rtiSelectTab, object: OverlayTab.setup.rawValue)
                },
                menuTitleProvider: {
                    MainMenuValidation.chooseProjectTitle(current: MeetingContextStore.shared.workstreamName)
                }
            ),
            RTICommand(
                id: "session.start",
                title: "Start Recording",
                subtitle: "⌘⇧R",
                keywords: ["record", "meeting", "transcribe", "stop", "finish"],
                isAvailable: { session.phase != .finishing },
                perform: { session.toggleSession() },
                menuSection: .session,
                menuTitleProvider: {
                    session.isRunning ? "Finish Recording  ⌘⇧R" : "Start Recording  ⌘⇧R"
                },
                hotkeyKeyCode: UInt32(kVK_ANSI_R),
                hotkeyModifiers: UInt32(cmdKey | shiftKey)
            ),
            RTICommand(
                id: "mic.mute.toggle",
                title: "Mute / Unmute My Mic",
                keywords: ["microphone", "mute", "silence", "input"],
                // Mute works during a call only. For an observed session,
                // turn on Listening only in Prepare.
                isAvailable: { session.canToggleMute },
                perform: { session.toggleUserMute() },
                menuSection: .session,
                menuStateProvider: { session.micMuted }
            ),
            RTICommand(
                id: "session.pause",
                title: "Pause / Resume Recording",
                subtitle: "⌘⇧P",
                keywords: ["pause", "resume", "hold", "suspend"],
                isAvailable: { session.phase == .recording || session.phase == .paused },
                perform: { session.togglePause() },
                menuSection: .session,
                menuTitleProvider: {
                    session.isPaused ? "Resume Recording  ⌘⇧P" : "Pause Recording  ⌘⇧P"
                },
                hotkeyKeyCode: UInt32(kVK_ANSI_P),
                hotkeyModifiers: UInt32(cmdKey | shiftKey),
                hotkeySessionScoped: true
            ),
        ]
    }

    @MainActor
    private static func navigationCommands(
        windows: WindowCoordinator
    ) -> [RTICommand] {
        [
            RTICommand(
                id: "overlay.toggle",
                title: "Show RTI  ⌘\\",
                subtitle: "⌘\\",
                keywords: ["panel", "show", "hide"],
                perform: { [weak windows] in windows?.toggleOverlay() },
                menuSection: .navigation,
                hotkeyKeyCode: UInt32(kVK_ANSI_Backslash),
                hotkeyModifiers: UInt32(cmdKey)
            ),
            RTICommand(
                id: "view.sessions",
                title: "Sessions",
                keywords: ["history", "archive", "library", "previous"],
                perform: { [weak windows] in windows?.showSessions() },
                menuSection: .navigation
            ),
            RTICommand(
                id: "view.brief",
                title: "Pre-meeting Brief",
                keywords: ["brief", "prep", "prepare", "agenda", "meeting"],
                perform: { [weak windows] in windows?.showMeetingBrief() },
                menuSection: .navigation
            ),
        ]
    }

    /// Translate an AssistantAction hotkey letter to a Carbon virtual key code.
    private static func carbonKeyCode(for key: String) -> UInt32? {
        let map: [String: Int] = [
            "A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D,
            "E": kVK_ANSI_E, "F": kVK_ANSI_F, "G": kVK_ANSI_G, "H": kVK_ANSI_H,
            "I": kVK_ANSI_I, "J": kVK_ANSI_J, "K": kVK_ANSI_K, "L": kVK_ANSI_L,
            "M": kVK_ANSI_M, "N": kVK_ANSI_N, "O": kVK_ANSI_O, "P": kVK_ANSI_P,
            "Q": kVK_ANSI_Q, "R": kVK_ANSI_R, "S": kVK_ANSI_S, "T": kVK_ANSI_T,
            "U": kVK_ANSI_U, "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X,
            "Y": kVK_ANSI_Y, "Z": kVK_ANSI_Z,
        ]
        return map[key.uppercased()].map(UInt32.init)
    }

    /// Translate AssistantAction modifier flags to Carbon modifier mask.
    private static func carbonModifiers(_ m: ActionHotkey.Modifiers) -> UInt32 {
        var r = 0
        if m.contains(.command) { r |= cmdKey }
        if m.contains(.option) { r |= optionKey }
        if m.contains(.shift) { r |= shiftKey }
        return UInt32(r)
    }

    @MainActor
    private static func actionCommands(
        llm: LLMController
    ) -> [RTICommand] {
        [
            // ⌘⏎ is the remappable "primary" hotkey — it dispatches whatever
            // quick action the user picked (Quick recap by default: the
            // mid-meeting "catch me up" turn).
            RTICommand(
                id: "chat.primary",
                title: "Primary Action (remappable)",
                subtitle: "⌘⏎",
                keywords: ["help", "suggestion", "assist", "primary"],
                perform: { llm.sendPrimary() },
                menuTitleProvider: { "\(AssistantAction.byID(llm.primaryActionID)?.label ?? "Quick recap")  ⌘⏎" },
                hotkeyKeyCode: UInt32(kVK_Return),
                hotkeyModifiers: UInt32(cmdKey),
                hotkeySessionScoped: true
            ),
        ] + AssistantAction.all.map { action in
            // Every quick action's palette entry + global hotkey is derived
            // from the one AssistantAction catalogue.
            RTICommand(
                id: "chat.\(action.id)",
                title: action.paletteTitle,
                subtitle: action.hotkey?.display,
                keywords: action.keywords,
                perform: { llm.perform(actionID: action.id) },
                hotkeyKeyCode: action.hotkey.flatMap { carbonKeyCode(for: $0.key) },
                hotkeyModifiers: action.hotkey.map { carbonModifiers($0.modifiers) },
                hotkeySessionScoped: true
            )
        } + [
            // One-shot recap depth overrides — not in the catalogue (they don't
            // change the sticky default ⌘⌥R uses; set that in the ✦ "Recap
            // depth" submenu).
            RTICommand(
                id: "chat.recap.brief",
                title: "Recap (brief)",
                keywords: ["recap", "short", "tldr", "length"],
                perform: { llm.sendRecap(depth: .brief) }
            ),
            RTICommand(
                id: "chat.recap.detailed",
                title: "Recap (detailed)",
                keywords: ["recap", "long", "full", "thorough", "length"],
                perform: { llm.sendRecap(depth: .detailed) }
            ),
            RTICommand(
                id: "note.toggle",
                title: "Toggle Note Entry",
                subtitle: "⌘⌥N",
                keywords: ["note", "annotate", "inline", "mark"],
                perform: {
                    let state = OverlayInputState.shared
                    state.mode = state.isNoteMode ? .chat : .liveNote
                },
                menuSection: .actions,
                menuTitleProvider: {
                    "Note Mode  ⌘⌥N"
                },
                hotkeyKeyCode: UInt32(kVK_ANSI_N),
                hotkeyModifiers: UInt32(cmdKey | optionKey),
                hotkeySessionScoped: true
            ),
            RTICommand(
                id: "capture.screen",
                title: "Capture Screen  ⌘⇧H",
                subtitle: "⌘⇧H",
                keywords: ["screenshot", "ocr", "display"],
                perform: { ScreenshotManager.shared.captureAndAttach() },
                menuSection: .actions,
                hotkeyKeyCode: UInt32(kVK_ANSI_H),
                hotkeyModifiers: UInt32(cmdKey | shiftKey),
                hotkeySessionScoped: true
            ),
            RTICommand(
                id: "capture.window",
                title: "Capture Window",
                subtitle: "⌘⇧J",
                keywords: ["screenshot", "ocr", "window", "focused", "frontmost"],
                perform: { ScreenshotManager.shared.captureFocusedWindowAndAttach() },
                menuSection: .actions,
                hotkeyKeyCode: UInt32(kVK_ANSI_J),
                hotkeyModifiers: UInt32(cmdKey | shiftKey),
                hotkeySessionScoped: true
            ),
        ] + AssistantAction.primaryEligibleActions.map { action in
            RTICommand(
                id: "primary.set.\(action.id)",
                title: action.label,
                keywords: ["primary", "hotkey", "remap", "bind", "command assist"],
                perform: { llm.primaryActionID = action.id },
                menuSection: .actions,
                menuParent: "Set ⌘⏎ to",
                menuStateProvider: { llm.primaryActionID == action.id }
            )
        } + [
            RTICommand(
                id: "chat.clear",
                title: "Clear Current Chat",
                keywords: ["delete", "reset"],
                perform: { AppDelegate.clearChatNow() },
                menuSection: .actions
            ),
        ]
    }

    @MainActor
    private static func panelCommands(
        windows: WindowCoordinator,
        llm: LLMController
    ) -> [RTICommand] {
        [
            RTICommand(
                id: "listener.toggle",
                title: "Listener Mode (I'm not speaking)",
                keywords: ["passive", "observer", "listen", "moderator"],
                perform: { llm.listenerMode.toggle() },
                menuSection: .panels,
                menuStateProvider: { llm.listenerMode }
            ),
            RTICommand(
                id: "smart.toggle",
                title: "Smart Mode",
                keywords: ["reasoning", "deep", "enable", "disable"],
                perform: { llm.smartMode.toggle() },
                menuSection: .panels,
                menuStateProvider: { llm.smartMode }
            ),
            RTICommand(
                id: "window.keepOnTop",
                title: "Keep RTI on Top",
                keywords: ["float", "pin", "always", "top", "window"],
                perform: { OverlayWindowChrome.shared.isKeptOnTop.toggle() },
                menuTitleProvider: { OverlayWindowChrome.shared.isKeptOnTop ? "Unpin RTI Window" : "Pin RTI Window" },
                menuStateProvider: { OverlayWindowChrome.shared.isKeptOnTop }
            ),
            RTICommand(
                id: "invisibility.toggle",
                title: "Hide RTI from Screen Capture",
                keywords: ["sharing", "screencap", "hide", "show", "stealth"],
                perform: { [weak windows] in windows?.toggleInvisibility() },
                menuSection: .panels,
                menuStateProvider: {
                    OverlayAppearanceDefaults.hidesWindowsFromScreenCapture()
                }
            ),
        ]
    }

    @MainActor
    private static func appCommands(
        windows: WindowCoordinator
    ) -> [RTICommand] {
        [
            RTICommand(
                id: "settings.open",
                title: "Settings…",
                subtitle: "⌘,",
                keywords: ["preferences", "config"],
                perform: { [weak windows] in windows?.openSettings() },
                menuSection: .app
            ),
            RTICommand(
                id: "app.about",
                title: "About RTI",
                keywords: ["info", "version"],
                perform: { [weak windows] in windows?.showAbout() },
                menuSection: .app
            ),
            RTICommand(
                id: "app.checkUpdates",
                title: "Check for Updates…",
                keywords: ["update", "upgrade", "version", "release"],
                perform: { UpdateChecker.checkAndReport() },
                menuSection: .app
            ),
            RTICommand(
                id: "app.quit",
                title: "Quit RTI",
                subtitle: "⌘Q",
                perform: { NSApp.terminate(nil) }
            ),
        ]
    }

    @MainActor
    private static func callTypeCommands(
        callTypes: CallTypeStore,
        llm: LLMController
    ) -> [RTICommand] {
        CallType.allCases.map { type in
            RTICommand(
                id: "calltype.\(type.rawValue)",
                title: "Call type: \(type.name)",
                keywords: ["mode", "call", "client", "research", "internal", "personal"],
                isAvailable: { callTypes.active != type },
                perform: { switchCallType(to: type, callTypes: callTypes, llm: llm) }
            )
        }
    }

    /// Make `type` active and follow it with the listener framing. Shared by
    /// the palette and Prepare.
    @MainActor
    static func switchCallType(to type: CallType, callTypes: CallTypeStore, llm: LLMController) {
        callTypes.active = type
        llm.listenerMode = type.listens
    }
}
