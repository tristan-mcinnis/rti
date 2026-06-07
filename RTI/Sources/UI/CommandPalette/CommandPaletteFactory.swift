import AppKit
import RTICore
import Carbon.HIToolbox

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
        return sessionCommands(windows: windows, session: session)
            + navigationCommands(windows: windows)
            + actionCommands(llm: llm)
            + panelCommands(windows: windows, llm: llm)
            + appCommands(windows: windows)
            + modeSwitchCommands(modes: modes)
    }

    // MARK: - Section builders

    @MainActor
    private static func sessionCommands(
        windows: WindowCoordinator,
        session: SessionCoordinator
    ) -> [RTICommand] {
        [
            RTICommand(
                id: "session.start",
                title: "Start Recording",
                subtitle: "⌘⇧R",
                keywords: ["record", "begin", "transcribe"],
                isAvailable: { !session.isRunning },
                perform: { session.toggleSession() },
                menuSection: .session,
                menuTitleProvider: {
                    session.isRunning ? "Stop Recording  ⌘⇧R" : "Start Recording  ⌘⇧R"
                },
                hotkeyKeyCode: UInt32(kVK_ANSI_R),
                hotkeyModifiers: UInt32(cmdKey | shiftKey)
            )
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
                id: "view.live",
                title: "Live Transcript  ⌘⌥T",
                subtitle: "⌘⌥T",
                keywords: ["console", "debug"],
                perform: { [weak windows] in windows?.showLiveTranscript() },
                menuSection: .navigation,
                hotkeyKeyCode: UInt32(kVK_ANSI_T),
                hotkeyModifiers: UInt32(cmdKey | optionKey)
            ),
            RTICommand(
                id: "view.brief",
                title: "Pre-meeting Brief",
                keywords: ["brief", "prep", "prepare", "agenda", "meeting"],
                perform: { [weak windows] in windows?.showMeetingBrief() },
                menuSection: .navigation
            )
        ]
    }

    @MainActor
    private static func actionCommands(
        llm: LLMController
    ) -> [RTICommand] {
        [
            RTICommand(
                id: "chat.assist",
                title: "Assist (suggest what to say)",
                subtitle: "⌘⏎",
                keywords: ["help", "suggestion"],
                perform: { llm.sendAssist() },
                hotkeyKeyCode: UInt32(kVK_Return),
                hotkeyModifiers: UInt32(cmdKey)
            ),
            RTICommand(
                id: "chat.saynext",
                title: "Say Next (one-line draft reply)",
                keywords: ["respond", "reply"],
                perform: { llm.sendSaySomething() }
            ),
            RTICommand(
                id: "chat.followups",
                title: "Follow-up Questions",
                keywords: ["questions", "ask"],
                perform: { llm.sendFollowupQuestions() }
            ),
            RTICommand(
                id: "chat.recap",
                title: "Recap so far",
                keywords: ["summary", "review"],
                perform: { llm.sendRecap() }
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
            RTICommand(
                id: "chat.clear",
                title: "Clear Current Chat",
                keywords: ["delete", "reset"],
                perform: { AppDelegate.confirmThenClearChat() },
                menuSection: .actions
            )
        ]
    }

    @MainActor
    private static func panelCommands(
        windows: WindowCoordinator,
        llm: LLMController
    ) -> [RTICommand] {
        [
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
                    UserDefaults.standard.object(forKey: "rti.invisible") as? Bool ?? true
                }
            ),
            RTICommand(
                id: "widget.top.toggle",
                title: "Toggle Top Widget  ⌘⇧B",
                keywords: ["pill", "bar"],
                perform: { [weak windows] in windows?.toggleTopWidget() },
                menuSection: .panels,
                hotkeyKeyCode: UInt32(kVK_ANSI_B),
                hotkeyModifiers: UInt32(cmdKey | shiftKey)
            ),
            RTICommand(
                id: "panel.notes.toggle",
                title: "Toggle Notes Panel  ⌘⇧N",
                keywords: ["notes", "minutes", "summary"],
                perform: { [weak windows] in windows?.toggle(.notes) },
                menuSection: .panels,
                hotkeyKeyCode: UInt32(kVK_ANSI_N),
                hotkeyModifiers: UInt32(cmdKey | shiftKey)
            ),
            RTICommand(
                id: "panel.dossiers.toggle",
                title: "Toggle Dossiers Panel  ⌘⇧D",
                keywords: ["dossier", "entities", "people", "brands"],
                perform: { [weak windows] in windows?.toggle(.dossiers) },
                menuSection: .panels,
                hotkeyKeyCode: UInt32(kVK_ANSI_D),
                hotkeyModifiers: UInt32(cmdKey | shiftKey)
            ),
            RTICommand(
                id: "panel.discussionGuide.toggle",
                title: "Toggle Discussion Guide Panel  ⌘⇧G",
                keywords: ["guide", "discussion", "questions", "agenda", "coverage"],
                perform: { [weak windows] in windows?.toggle(.discussionGuide) },
                menuSection: .panels,
                hotkeyKeyCode: UInt32(kVK_ANSI_G),
                hotkeyModifiers: UInt32(cmdKey | shiftKey)
            ),
            RTICommand(
                id: "panel.translation.toggle",
                title: "Toggle Translation Panel",
                keywords: ["translation", "translate"],
                perform: { [weak windows] in windows?.toggle(.translation) },
                menuSection: .panels
            ),
            RTICommand(
                id: "panel.audioIO.toggle",
                title: "Toggle Audio I/O Monitor",
                keywords: ["audio", "input", "output", "mic", "microphone", "levels", "device", "meter"],
                perform: { [weak windows] in windows?.toggle(.audioIO) },
                menuSection: .panels
            )
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
                id: "settings.shortcuts",
                title: "Keyboard Shortcuts…",
                keywords: ["hotkeys", "bindings"],
                perform: { [weak windows] in windows?.showShortcuts() },
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
            )
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
