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
        modes: ModeStore
    ) -> [RTICommand] {
        sessionCommands(windows: windows, session: session)
            + navigationCommands(windows: windows)
            + tabCommands(windows: windows)
            + actionCommands(llm: llm)
            + panelCommands(windows: windows, llm: llm)
            + appCommands(windows: windows)
            + modeSwitchCommands(modes: modes)
    }

    // MARK: - Tab navigation (⌘⌥0–5)

    /// Jump straight to an overlay tab from anywhere. Each command shows the
    /// overlay then posts the target tab; OverlayPanelView only switches to
    /// tabs that are currently visible (Notes/Guide/Findings are opt-in).
    @MainActor
    private static func tabCommands(windows: WindowCoordinator) -> [RTICommand] {
        func tabCmd(_ tab: String, _ title: String, key: Int, hint: String) -> RTICommand {
            RTICommand(
                id: "view.tab.\(tab)",
                title: "\(title)  \(hint)",
                keywords: ["tab", "switch", "jump", "go", tab],
                perform: { [weak windows] in
                    windows?.showOverlay()
                    NotificationCenter.default.post(name: .rtiSelectTab, object: tab)
                },
                menuSection: .navigation,
                hotkeyKeyCode: UInt32(key),
                hotkeyModifiers: UInt32(cmdKey | optionKey)
            )
        }
        return [
            tabCmd("setup", "Go to Setup", key: kVK_ANSI_0, hint: "⌘⌥0"),
            tabCmd("assist", "Go to Assist", key: kVK_ANSI_1, hint: "⌘⌥1"),
            tabCmd("transcript", "Go to Transcript", key: kVK_ANSI_2, hint: "⌘⌥2"),
            tabCmd("notes", "Go to Notes", key: kVK_ANSI_3, hint: "⌘⌥3"),
            tabCmd("guide", "Go to Guide", key: kVK_ANSI_4, hint: "⌘⌥4"),
            tabCmd("findings", "Go to Findings", key: kVK_ANSI_5, hint: "⌘⌥5"),
        ]
    }

    // MARK: - Section builders

    @MainActor
    private static func sessionCommands(
        windows _: WindowCoordinator,
        session: SessionCoordinator
    ) -> [RTICommand] {
        [
            RTICommand(
                id: "mic.mute.toggle",
                title: "Mute / Unmute My Mic",
                keywords: ["microphone", "mute", "silence", "input"],
                perform: { session.micMuted.toggle() },
                menuSection: .session,
                menuStateProvider: { session.micMuted }
            ),
            RTICommand(
                id: "session.start",
                title: "Start Recording",
                subtitle: "⌘⇧R",
                keywords: ["record", "begin", "transcribe", "finish", "stop", "new"],
                perform: { session.toggleSession() },
                menuSection: .session,
                menuTitleProvider: {
                    switch session.phase {
                    case .recording, .paused: "Finish Recording  ⌘⇧R"
                    case .summarizing, .done: "New Recording  ⌘⇧R"
                    case .finishing: "Saving…"
                    case .idle: "Start Recording  ⌘⇧R"
                    }
                },
                hotkeyKeyCode: UInt32(kVK_ANSI_R),
                hotkeyModifiers: UInt32(cmdKey | shiftKey)
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
                hotkeyModifiers: UInt32(cmdKey | shiftKey)
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
                title: "Show Chat Panel  ⌘\\",
                subtitle: "⌘\\",
                keywords: ["panel", "show", "hide"],
                perform: { [weak windows] in windows?.toggleOverlay() },
                menuSection: .navigation,
                hotkeyKeyCode: UInt32(kVK_ANSI_Backslash),
                hotkeyModifiers: UInt32(cmdKey)
            ),
            RTICommand(
                id: "view.sessions",
                title: "Past Sessions",
                keywords: ["history", "archive", "library", "previous"],
                perform: { [weak windows] in windows?.showSessionsControl(tab: .sessions) },
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

    @MainActor
    private static func actionCommands(
        llm: LLMController
    ) -> [RTICommand] {
        [
            // ⌘⏎ is the remappable "primary" hotkey — it dispatches whatever
            // quick action the user picked (Assist by default; e.g. Recap in
            // a meeting where they're a passive listener).
            RTICommand(
                id: "chat.primary",
                title: "Primary Action (remappable)",
                subtitle: "⌘⏎",
                keywords: ["help", "suggestion", "assist", "primary"],
                perform: { llm.sendPrimary() },
                menuTitleProvider: { "\(llm.primaryAction.label)  ⌘⏎" },
                hotkeyKeyCode: UInt32(kVK_Return),
                hotkeyModifiers: UInt32(cmdKey)
            ),
            RTICommand(
                id: "chat.assist",
                title: "Assist (suggest what to say)",
                keywords: ["help", "suggestion"],
                perform: { llm.sendAssist() }
            ),
            RTICommand(
                id: "chat.saynext",
                title: "Say Next (one-line draft reply)",
                subtitle: "⌘⌥S",
                keywords: ["respond", "reply"],
                perform: { llm.sendSaySomething() },
                hotkeyKeyCode: UInt32(kVK_ANSI_S),
                hotkeyModifiers: UInt32(cmdKey | optionKey)
            ),
            RTICommand(
                id: "chat.followups",
                title: "Follow-up Questions",
                subtitle: "⌘⌥F",
                keywords: ["questions", "ask"],
                perform: { llm.sendFollowupQuestions() },
                hotkeyKeyCode: UInt32(kVK_ANSI_F),
                hotkeyModifiers: UInt32(cmdKey | optionKey)
            ),
            RTICommand(
                id: "chat.recap",
                title: "Recap so far",
                subtitle: "⌘⌥R",
                keywords: ["summary", "review"],
                perform: { llm.sendRecap() },
                hotkeyKeyCode: UInt32(kVK_ANSI_R),
                hotkeyModifiers: UInt32(cmdKey | optionKey)
            ),
            RTICommand(
                id: "chat.summary",
                title: "Meeting Summary (full transcript)",
                subtitle: "⌘⌥M",
                keywords: ["granola", "summarize", "minutes", "wrap"],
                perform: { llm.sendSummary() },
                hotkeyKeyCode: UInt32(kVK_ANSI_M),
                hotkeyModifiers: UInt32(cmdKey | optionKey)
            ),
            // Listener research actions — for sitting in on fieldwork as an
            // observer. The qualitative-researcher counterparts to Say Next /
            // Follow-ups, surfaced in the ✦ menu only in listener mode but
            // always hotkey-reachable.
            RTICommand(
                id: "chat.keyTensions",
                title: "Key Tensions",
                subtitle: "⌘⌥T",
                keywords: ["tension", "disagree", "split", "observe", "listener"],
                perform: { llm.sendKeyTensions() },
                hotkeyKeyCode: UInt32(kVK_ANSI_T),
                hotkeyModifiers: UInt32(cmdKey | optionKey)
            ),
            RTICommand(
                id: "chat.probe",
                title: "What's Unsaid / Probe",
                subtitle: "⌘⌥U",
                keywords: ["probe", "unsaid", "explore", "deepen", "listener"],
                perform: { llm.sendProbe() },
                hotkeyKeyCode: UInt32(kVK_ANSI_U),
                hotkeyModifiers: UInt32(cmdKey | optionKey)
            ),
            RTICommand(
                id: "chat.themes",
                title: "Emerging Themes",
                subtitle: "⌘⌥E",
                keywords: ["theme", "pattern", "synthesis", "listener"],
                perform: { llm.sendThemes() },
                hotkeyKeyCode: UInt32(kVK_ANSI_E),
                hotkeyModifiers: UInt32(cmdKey | optionKey)
            ),
            RTICommand(
                id: "note.toggle",
                title: "Note Mode (type into transcript)",
                subtitle: "⌘⌥N",
                keywords: ["note", "annotate", "inline", "mark"],
                isAvailable: { SessionCoordinator.shared.isRunning },
                perform: {
                    guard SessionCoordinator.shared.isRunning else { return }
                    OverlayInputState.shared.isNoteMode.toggle()
                },
                menuSection: .actions,
                hotkeyKeyCode: UInt32(kVK_ANSI_N),
                hotkeyModifiers: UInt32(cmdKey | optionKey)
            ),
            RTICommand(
                id: "capture.screen",
                title: "Capture Screen  ⌘⇧H",
                subtitle: "⌘H",
                keywords: ["screenshot", "ocr"],
                perform: { ScreenshotManager.shared.captureAndAttach() },
                menuSection: .actions,
                hotkeyKeyCode: UInt32(kVK_ANSI_H),
                hotkeyModifiers: UInt32(cmdKey | shiftKey)
            ),
        ] + LLMController.PrimaryAction.allCases.map { action in
            RTICommand(
                id: "primary.set.\(action.rawValue)",
                title: "Set ⌘⏎ to: \(action.label)",
                keywords: ["primary", "hotkey", "remap", "bind"],
                isAvailable: { llm.primaryAction != action },
                perform: { llm.primaryAction = action }
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
                id: "fieldwork.preset",
                title: "Fieldwork Preset (interview + listener + ⌘⏎ Assist)",
                keywords: ["fgd", "idi", "observe", "research", "preset"],
                perform: {
                    let modes = ModeStore.shared
                    if let interview = modes.modes.first(where: { $0.name.localizedCaseInsensitiveContains("interview") }) {
                        modes.activeModeId = interview.id
                    }
                    llm.listenerMode = true
                    llm.primaryAction = .assist
                }
            ),
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
                id: "invisibility.toggle",
                title: "Hidden from Screen Capture",
                keywords: ["sharing", "screencap", "hide", "show", "stealth"],
                perform: { [weak windows] in windows?.toggleInvisibility() },
                menuSection: .panels,
                menuStateProvider: {
                    UserDefaults.standard.object(forKey: OverlayAppearanceDefaults.invisibilityKey) as? Bool ?? true
                }
            ),
            RTICommand(
                id: "panel.translation.toggle",
                title: "Toggle Translation Panel",
                keywords: ["translation", "translate"],
                perform: { [weak windows] in windows?.toggle(.translation) },
                menuSection: .panels
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
    private static func modeSwitchCommands(
        modes: ModeStore
    ) -> [RTICommand] {
        modes.modes.map { mode in
            RTICommand(
                id: "mode.switch.\(mode.id)",
                title: "Switch to: \(mode.name)",
                keywords: ["mode", "preset"],
                isAvailable: { modes.activeMode?.id != mode.id },
                perform: { modes.activeModeId = mode.id }
            )
        }
    }
}
