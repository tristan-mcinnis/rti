import AppKit

/// Stateless factory that builds the runtime command palette entries.
/// Extracted from AppDelegate so the coordinator stays focused on wiring
/// and lifecycle, not on enumerating every affordance in the app.
enum CommandPaletteFactory {

    @MainActor
    static func buildCommands(
        windows: WindowCoordinator,
        session: SessionCoordinator,
        llm: LLMController,
        modes: ModeStore
    ) -> [RTICommand] {
        var cmds: [RTICommand] = [
            RTICommand(
                id: "session.start",
                title: "Start Session",
                subtitle: "⌘⇧R",
                keywords: ["record", "begin", "transcribe"],
                isAvailable: { !session.isRunning },
                perform: { session.toggleSession() }
            ),
            RTICommand(
                id: "session.stop",
                title: "Stop Session",
                subtitle: "⌘⇧R",
                keywords: ["end", "finish"],
                isAvailable: { session.isRunning },
                perform: { session.toggleSession() }
            ),
            RTICommand(
                id: "session.detail",
                title: "Open Current Session Detail",
                keywords: ["view", "transcript"],
                isAvailable: { session.currentSessionId != nil },
                perform: { [weak windows] in
                    guard let id = session.currentSessionId else { return }
                    windows?.openSessionDetail(for: id)
                }
            ),
            RTICommand(
                id: "overlay.toggle",
                title: "Toggle Overlay",
                subtitle: "⌘\\",
                keywords: ["panel", "show", "hide"],
                perform: { [weak windows] in windows?.toggleOverlay() }
            ),
            RTICommand(
                id: "widget.top.toggle",
                title: "Toggle Top Widget",
                keywords: ["pill", "bar"],
                perform: { [weak windows] in windows?.toggleTopWidget() }
            ),
            RTICommand(
                id: "invisibility.toggle",
                title: "Toggle Invisibility",
                keywords: ["sharing", "screencap", "hide from screen"],
                perform: { [weak windows] in
                    let isInvisible = UserDefaults.standard.object(forKey: "rti.invisible") as? Bool ?? true
                    UserDefaults.standard.set(!isInvisible, forKey: "rti.invisible")
                    windows?.setSharingInvisible(!isInvisible)
                }
            ),
            RTICommand(
                id: "smart.toggle",
                title: "Toggle Smart Mode",
                keywords: ["reasoning", "deep"],
                perform: { llm.smartMode.toggle() }
            ),
            RTICommand(
                id: "chat.assist",
                title: "Assist (suggest what to say)",
                subtitle: "⌘⏎",
                keywords: ["help", "suggestion"],
                perform: { llm.sendAssist() }
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
                id: "chat.clear",
                title: "Clear Current Chat",
                keywords: ["delete", "reset"],
                perform: { AppDelegate.confirmThenClearChat() }
            ),
            RTICommand(
                id: "capture.screen",
                title: "Capture Screen for AI",
                subtitle: "⌘H",
                keywords: ["screenshot", "ocr"],
                perform: { ScreenshotManager.shared.captureAndAttach() }
            ),
            RTICommand(
                id: "view.live",
                title: "Show Live Transcript",
                subtitle: "⌘⌥T",
                keywords: ["console", "debug"],
                perform: { [weak windows] in windows?.showDebugConsole() }
            ),
            RTICommand(
                id: "view.history",
                title: "Session History…",
                keywords: ["past", "old", "meetings"],
                perform: { [weak windows] in windows?.showSessionHistory() }
            ),
            RTICommand(
                id: "settings.open",
                title: "Open Settings…",
                subtitle: "⌘,",
                keywords: ["preferences", "config"],
                perform: { [weak windows] in windows?.openSettings() }
            ),
            RTICommand(
                id: "settings.shortcuts",
                title: "Keyboard Shortcuts…",
                keywords: ["hotkeys", "bindings"],
                perform: { [weak windows] in windows?.showShortcuts() }
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
