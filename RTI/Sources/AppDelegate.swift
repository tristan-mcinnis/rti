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
        menu.onShowOnboarding = { [weak self] in self?.windows.showOnboarding() }
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
        hotkeys.onToggleTopWidget = { [weak self] in self?.windows.toggleTopWidget() }
        hotkeys.registerAll()

        CommandRegistry.shared.replaceAll(
            CommandPaletteFactory.buildCommands(
                windows: windows,
                session: SessionCoordinator.shared,
                llm: LLMController.shared,
                modes: ModeStore.shared
            )
        )

        SessionCoordinator.shared.$isRunning
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.menu.refreshTitle() }
            }
            .store(in: &cancellables)

        registerNotificationObservers()

        if !windows.showOnboardingIfNeeded(),
           CredentialStore.deepseek == nil || CredentialStore.soniox == nil {
            windows.openSettings()
        }
    }

    /// All five notification-center observers registered at launch in one
    /// call site so the wiring is visible in a single glance.
    private func registerNotificationObservers() {
        let observers: [(NSNotification.Name, Selector)] = [
            (.rtiToggleOverlay, #selector(toggleOverlay)),
            (.rtiClearChat, #selector(clearChat)),
            (.rtiToggleCommandPalette, #selector(toggleCommandPalette)),
        ]
        for (name, sel) in observers {
            NotificationCenter.default.addObserver(self, selector: sel, name: name, object: nil)
        }
    }

    private func toggleInvisibility() {
        let isInvisible = UserDefaults.standard.object(forKey: Self.invisibleKey) as? Bool ?? true
        let newValue = !isInvisible
        UserDefaults.standard.set(newValue, forKey: Self.invisibleKey)
        windows.setSharingInvisible(newValue)
    }

    @objc private func toggleOverlay() { windows.toggleOverlay() }
    @objc private func clearChat() { Self.confirmThenClearChat() }
    @objc private func toggleCommandPalette() { windows.toggleCommandPalette() }

    /// Shows a destructive-confirmation alert; on confirm, clears the
    /// current session's chat messages. Static so `CommandPaletteFactory`
    /// can reference it without a live AppDelegate instance.
    static func confirmThenClearChat() {
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
        // Emergency shutdown flushes the JSONL writer and audio pipeline.
        // We can't do unbounded async work here (the OS will kill us), but
        // we can at least give the synchronous parts a chance to land.
        SessionCoordinator.shared.emergencyShutdown()
    }

    /// Bring the overlay back when the user clicks the app's Dock icon, the
    /// running-app indicator, or relaunches while a single instance is
    /// already alive. Without this, an `LSUIElement` app whose overlay was
    /// dismissed has no obvious entry point besides the menubar item.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            windows.showOverlay()
        }
        return true
    }

    private static let invisibleKey = "rti.invisible"
}
