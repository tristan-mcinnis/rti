import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
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
        SessionCoordinator.registerAnalysisTasks()
        _ = ModeStore.shared
        LLMController.shared.loadHistoryForCurrentSession()
        CorpusManager.shared.recoverOrphans()
        CorpusIndexer.backfillIfEmpty(
            from: CorpusManager.shared.corpusDirectory,
            in: RTIDatabase.shared.pool
        )

        windows.install(onOpenSettings: { [weak self] in self?.windows.openSettings() })

        let invisible = UserDefaults.standard.object(forKey: Self.invisibleKey) as? Bool ?? true
        windows.setSharingInvisible(invisible)

        // Build the shared command registry once. Menu, hotkeys, and the
        // command palette all consume this same list.
        let commands = CommandPaletteFactory.buildCommands(
            windows: windows,
            session: SessionCoordinator.shared,
            llm: LLMController.shared,
            modes: ModeStore.shared
        )

        CommandRegistry.shared.replaceAll(commands)

        // Menu: dynamic state providers for items whose titles change.
        menu.onRecentSessionSelected = { [weak self] id in self?.windows.openSessionDetail(for: id) }
        menu.recentSessionsProvider = { SessionCoordinator.shared.recentSessions(limit: 10) }
        menu.currentSessionIdProvider = { SessionCoordinator.shared.currentSessionId }
        menu.isRunningProvider = { SessionCoordinator.shared.isRunning }
        menu.smartModeProvider = { LLMController.shared.smartMode }
        menu.invisibilityProvider = { UserDefaults.standard.object(forKey: Self.invisibleKey) as? Bool ?? true }
        menu.install(commands: commands)

        hotkeys.registerAll(commands: commands)

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
            (.rtiToggleNotesPanel, #selector(toggleNotesPanel)),
            (.rtiToggleDossiersPanel, #selector(toggleDossiersPanel)),
            (.rtiToggleThemesPanel, #selector(toggleThemesPanel)),
            (.rtiToggleGuidePanel, #selector(toggleGuidePanel)),
            (.rtiToggleTranslationPanel, #selector(toggleTranslationPanel)),
        ]
        for (name, sel) in observers {
            NotificationCenter.default.addObserver(self, selector: sel, name: name, object: nil)
        }
    }

    @objc private func toggleOverlay() { windows.toggleOverlay() }
    @objc private func clearChat() { Self.confirmThenClearChat() }
    @objc private func toggleCommandPalette() { windows.toggleCommandPalette() }
    @objc private func toggleNotesPanel() { windows.toggle(.notes) }
    @objc private func toggleDossiersPanel() { windows.toggle(.dossiers) }
    @objc private func toggleThemesPanel() { windows.toggle(.themes) }
    @objc private func toggleGuidePanel() { windows.toggle(.discussionGuide) }
    @objc private func toggleTranslationPanel() { windows.toggle(.translation) }

    /// Shows a destructive-confirmation alert; on confirm, clears the
    /// current session's chat messages. Static so `CommandPaletteFactory`
    /// can reference it without a live AppDelegate instance.
    static func confirmThenClearChat() {
        let alert = NSAlert()
        alert.messageText = "Clear current chat?"
        alert.informativeText = "This deletes the chat messages for the current session and dismisses any open auxiliary panels (notes, dossiers, spawned counters/cards). The transcript and audio recording are not affected."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            LLMController.shared.clear()
            NotesGenerationController.shared.clear()
            DossierController.shared.clear()
            ThemesController.shared.clear()
            UserPanelStore.shared.removeAll()
            NotificationCenter.default.post(name: .rtiHideAuxiliaryPanels, object: nil)
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            windows.showOverlay()
        }
        return true
    }

    private static let invisibleKey = "rti.invisible"
}