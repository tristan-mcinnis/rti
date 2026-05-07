import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let windows = WindowCoordinator()
    private let menu = MenuCoordinator()
    private let hotkeys = HotkeyCoordinator()
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ensureSingleInstance() else { return }

        CrashLog.install()
        CredentialStore.migrateLegacyIfNeeded()

        SessionCoordinator.shared.bootstrapChatSession()
        SessionCoordinator.shared.pruneOldSessions(days: 30)
        _ = ModeStore.shared
        LLMController.shared.loadHistoryForCurrentSession()
        CorpusManager.shared.recoverOrphans()

        windows.install(onOpenSettings: { [weak self] in self?.windows.openSettings() })

        let invisible = UserDefaults.standard.object(forKey: Self.invisibleKey) as? Bool ?? true
        windows.setSharingInvisible(invisible)

        menu.install()
        menu.onToggleSession = { SessionCoordinator.shared.toggleSession() }
        menu.onToggleSmartMode = { LLMController.shared.smartMode.toggle() }
        menu.onToggleInvisibility = { [weak self] in self?.toggleInvisibility() }
        menu.onOpenCurrentSessionDetail = { [weak self] in
            guard let id = SessionCoordinator.shared.currentSessionId else { return }
            self?.windows.openSessionDetail(for: id)
        }
        menu.onShowDebugConsole = { [weak self] in self?.windows.showDebugConsole() }
        menu.onShowSettings = { [weak self] in self?.windows.openSettings() }
        menu.onShowAbout = { [weak self] in self?.windows.showAbout() }
        menu.onShowShortcuts = { [weak self] in self?.windows.showShortcuts() }
        menu.onToggleOverlay = { [weak self] in self?.windows.toggleOverlay() }
        menu.onToggleTopWidget = { [weak self] in self?.windows.toggleTopWidget() }
        menu.onClearChat = { [weak self] in self?.clearChat() }
        menu.onShowSessionHistory = { [weak self] in self?.windows.showSessionHistory() }
        menu.onRecentSessionSelected = { [weak self] id in self?.windows.openSessionDetail(for: id) }
        menu.recentSessionsProvider = { SessionCoordinator.shared.recentSessions(limit: 10) }
        menu.currentSessionIdProvider = { SessionCoordinator.shared.currentSessionId }
        menu.isRunningProvider = { SessionCoordinator.shared.isRunning }
        menu.smartModeProvider = { LLMController.shared.smartMode }
        menu.invisibilityProvider = { UserDefaults.standard.object(forKey: Self.invisibleKey) as? Bool ?? true }

        hotkeys.onToggleOverlay = { [weak self] in self?.windows.toggleOverlay() }
        hotkeys.onToggleSession = { SessionCoordinator.shared.toggleSession() }
        hotkeys.onSendAssist = { LLMController.shared.sendAssist() }
        hotkeys.onCaptureScreen = { ScreenshotManager.shared.captureAndAttach() }
        hotkeys.onToggleDebugConsole = { [weak self] in self?.windows.toggleDebugConsole() }
        hotkeys.onToggleCommandPalette = { [weak self] in self?.windows.toggleCommandPalette() }
        hotkeys.registerAll()

        registerPaletteCommands()

        SessionCoordinator.shared.$isRunning
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.menu.refreshTitle() }
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenSessionDetailNotification(_:)),
            name: .openSessionDetail,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(toggleOverlay),
            name: .rtiToggleOverlay,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clearChat),
            name: .rtiClearChat,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showDebugConsole),
            name: .rtiShowLiveTranscript,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showSessionHistory),
            name: .rtiShowSessionHistory,
            object: nil
        )

        if !windows.showOnboardingIfNeeded(),
           CredentialStore.deepseek == nil || CredentialStore.soniox == nil {
            windows.openSettings()
        }
    }

    @objc private func handleOpenSessionDetailNotification(_ notification: Notification) {
        guard let id = notification.object as? String else { return }
        windows.openSessionDetail(for: id)
    }

    private func registerPaletteCommands() {
        let coord: () -> SessionCoordinator = { SessionCoordinator.shared }
        let llm: () -> LLMController = { LLMController.shared }
        let modes: () -> ModeStore = { ModeStore.shared }

        var cmds: [RTICommand] = [
            RTICommand(
                id: "session.start",
                title: "Start Session",
                subtitle: "⌘⇧R",
                keywords: ["record", "begin", "transcribe"],
                isAvailable: { !coord().isRunning },
                perform: { coord().toggleSession() }
            ),
            RTICommand(
                id: "session.stop",
                title: "Stop Session",
                subtitle: "⌘⇧R",
                keywords: ["end", "finish"],
                isAvailable: { coord().isRunning },
                perform: { coord().toggleSession() }
            ),
            RTICommand(
                id: "session.detail",
                title: "Open Current Session Detail",
                keywords: ["view", "transcript"],
                isAvailable: { coord().currentSessionId != nil },
                perform: { [weak self] in
                    guard let id = coord().currentSessionId else { return }
                    self?.windows.openSessionDetail(for: id)
                }
            ),
            RTICommand(
                id: "overlay.toggle",
                title: "Toggle Overlay",
                subtitle: "⌘\\",
                keywords: ["panel", "show", "hide"],
                perform: { [weak self] in self?.windows.toggleOverlay() }
            ),
            RTICommand(
                id: "widget.top.toggle",
                title: "Toggle Top Widget",
                keywords: ["pill", "bar"],
                perform: { [weak self] in self?.windows.toggleTopWidget() }
            ),
            RTICommand(
                id: "invisibility.toggle",
                title: "Toggle Invisibility",
                keywords: ["sharing", "screencap", "hide from screen"],
                perform: { [weak self] in self?.toggleInvisibility() }
            ),
            RTICommand(
                id: "smart.toggle",
                title: "Toggle Smart Mode",
                keywords: ["reasoning", "deep"],
                perform: { llm().smartMode.toggle() }
            ),
            RTICommand(
                id: "chat.assist",
                title: "Assist (suggest what to say)",
                subtitle: "⌘⏎",
                keywords: ["help", "suggestion"],
                perform: { llm().sendAssist() }
            ),
            RTICommand(
                id: "chat.saynext",
                title: "Say Next (one-line draft reply)",
                keywords: ["respond", "reply"],
                perform: { llm().sendSaySomething() }
            ),
            RTICommand(
                id: "chat.followups",
                title: "Follow-up Questions",
                keywords: ["questions", "ask"],
                perform: { llm().sendFollowupQuestions() }
            ),
            RTICommand(
                id: "chat.recap",
                title: "Recap so far",
                keywords: ["summary", "review"],
                perform: { llm().sendRecap() }
            ),
            RTICommand(
                id: "chat.clear",
                title: "Clear Current Chat",
                keywords: ["delete", "reset"],
                perform: { [weak self] in self?.clearChat() }
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
                perform: { [weak self] in self?.windows.showDebugConsole() }
            ),
            RTICommand(
                id: "view.history",
                title: "Session History…",
                keywords: ["past", "old", "meetings"],
                perform: { [weak self] in self?.windows.showSessionHistory() }
            ),
            RTICommand(
                id: "settings.open",
                title: "Open Settings…",
                subtitle: "⌘,",
                keywords: ["preferences", "config"],
                perform: { [weak self] in self?.windows.openSettings() }
            ),
            RTICommand(
                id: "settings.shortcuts",
                title: "Keyboard Shortcuts…",
                keywords: ["hotkeys", "bindings"],
                perform: { [weak self] in self?.windows.showShortcuts() }
            ),
            RTICommand(
                id: "app.quit",
                title: "Quit RTI",
                subtitle: "⌘Q",
                perform: { NSApp.terminate(nil) }
            )
        ]

        for mode in modes().modes {
            let modeId = mode.id
            let modeName = mode.name
            cmds.append(RTICommand(
                id: "mode.switch.\(modeId)",
                title: "Switch to: \(modeName)",
                keywords: ["mode", "preset"],
                isAvailable: { modes().activeMode?.id != modeId },
                perform: { modes().activeModeId = modeId }
            ))
        }

        CommandRegistry.shared.replaceAll(cmds)
    }

    private func toggleInvisibility() {
        let isInvisible = UserDefaults.standard.object(forKey: Self.invisibleKey) as? Bool ?? true
        let newValue = !isInvisible
        UserDefaults.standard.set(newValue, forKey: Self.invisibleKey)
        windows.setSharingInvisible(newValue)
    }

    @objc private func toggleOverlay() { windows.toggleOverlay() }
    @objc private func showDebugConsole() { windows.showDebugConsole() }
    @objc private func showSessionHistory() { windows.showSessionHistory() }
    @objc private func clearChat() { _clearChat() }
    private func _clearChat() {
        let alert = NSAlert()
        alert.messageText = "Clear current chat?"
        alert.informativeText = "This deletes the chat messages for the current session from the database. The transcript and audio recording are not affected."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            LLMController.shared.clear()
        }
    }

    private func ensureSingleInstance() -> Bool {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.tristan.rti"
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        if instances.count > 1 {
            instances.first(where: { $0 != NSRunningApplication.current })?.activate(options: .activateIgnoringOtherApps)
            NSApp.terminate(nil)
            return false
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard SessionCoordinator.shared.isRunning else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Recording in progress"
        alert.informativeText = "RTI is currently recording a session. Quitting will stop the recording, flush the WAV file, and finalize the session."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop & Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        SessionCoordinator.shared.emergencyShutdown()
    }

    private static let invisibleKey = "rti.invisible"
}
