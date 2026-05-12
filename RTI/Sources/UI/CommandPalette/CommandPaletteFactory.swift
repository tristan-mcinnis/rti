import AppKit
import Carbon.HIToolbox

/// Stateless factory that builds the runtime command palette / menu / hotkey
/// entries. Extracted from AppDelegate so the coordinator stays focused on
/// wiring and lifecycle, not on enumerating every affordance in the app.
///
/// Every command carries its menu section and optional Carbon hotkey.
/// `MenuCoordinator` and `HotkeyCoordinator` consume this same list — one
/// registry, three consumers (palette, menu, hotkeys).
enum CommandPaletteFactory {

    @MainActor
    static func buildCommands(
        windows: WindowCoordinator,
        session: SessionCoordinator,
        llm: LLMController,
        modes: ModeStore
    ) -> [RTICommand] {
        var cmds: [RTICommand] = [
            // MARK: Session
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
            ),
            RTICommand(
                id: "session.detail",
                title: "View Session Detail",
                keywords: ["view", "transcript"],
                isAvailable: { session.currentSessionId != nil },
                perform: { [weak windows] in
                    guard let id = session.currentSessionId else { return }
                    windows?.openSessionDetail(for: id)
                },
                menuSection: .session
            ),

            // MARK: Navigation
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
                perform: { [weak windows] in windows?.showDebugConsole() },
                menuSection: .navigation,
                hotkeyKeyCode: UInt32(kVK_ANSI_T),
                hotkeyModifiers: UInt32(cmdKey | optionKey)
            ),
            RTICommand(
                id: "view.history",
                title: "Sessions…  ⌘⇧S",
                subtitle: "⌘⇧S",
                keywords: ["past", "old", "meetings", "history", "home"],
                perform: { [weak windows] in windows?.showSessionHistory() },
                menuSection: .navigation,
                hotkeyKeyCode: UInt32(kVK_ANSI_S),
                hotkeyModifiers: UInt32(cmdKey | shiftKey)
            ),
            RTICommand(
                id: "view.command_palette",
                title: "Command Palette",
                subtitle: "⌘K",
                keywords: ["find", "search"],
                perform: { [weak windows] in windows?.toggleCommandPalette() },
                hotkeyKeyCode: UInt32(kVK_ANSI_K),
                hotkeyModifiers: UInt32(cmdKey)
            ),

            // MARK: Actions
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
            ),

            // MARK: Panels
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
                perform: {
                    let isInvisible = UserDefaults.standard.object(forKey: "rti.invisible") as? Bool ?? true
                    UserDefaults.standard.set(!isInvisible, forKey: "rti.invisible")
                },
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
                keywords: ["notes"],
                perform: { [weak windows] in windows?.toggleNotesPanel() },
                menuSection: .panels,
                hotkeyKeyCode: UInt32(kVK_ANSI_N),
                hotkeyModifiers: UInt32(cmdKey | shiftKey)
            ),
            RTICommand(
                id: "panel.dossiers.toggle",
                title: "Toggle Dossiers Panel  ⌘⇧D",
                keywords: ["dossiers", "entities"],
                perform: { [weak windows] in windows?.toggleDossiersPanel() },
                menuSection: .panels,
                hotkeyKeyCode: UInt32(kVK_ANSI_D),
                hotkeyModifiers: UInt32(cmdKey | shiftKey)
            ),
            RTICommand(
                id: "panel.themes.toggle",
                title: "Toggle Themes Panel",
                keywords: ["themes"],
                perform: { [weak windows] in windows?.toggleThemesPanel() },
                menuSection: .panels
            ),
            RTICommand(
                id: "panel.guide.toggle",
                title: "Toggle Discussion Guide",
                keywords: ["guide", "discussion"],
                perform: { [weak windows] in windows?.toggleGuidePanel() },
                menuSection: .panels
            ),
            RTICommand(
                id: "panel.translation.toggle",
                title: "Toggle Translation Panel",
                keywords: ["translation", "translate"],
                perform: { [weak windows] in windows?.toggleTranslationPanel() },
                menuSection: .panels
            ),

            // MARK: App
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
                id: "app.onboarding",
                title: "Show Welcome…",
                keywords: ["intro", "welcome"],
                perform: { [weak windows] in windows?.showOnboarding() },
                menuSection: .app
            ),
            RTICommand(
                id: "app.quit",
                title: "Quit RTI",
                subtitle: "⌘Q",
                perform: { NSApp.terminate(nil) }
            )
        ]

        for mode in modes.modes {
            let modeId = mode.id
            let modeName = mode.name
            cmds.append(RTICommand(
                id: "mode.switch.\(modeId)",
                title: "Switch to: \(modeName)",
                keywords: ["mode", "preset"],
                isAvailable: { modes.activeMode?.id != modeId },
                perform: { modes.activeModeId = modeId }
            ))
        }

        return cmds
    }
}