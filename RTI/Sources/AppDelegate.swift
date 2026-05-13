import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private let windows = WindowCoordinator.shared
    private let menu = MenuCoordinator()
    private let hotkeys = HotkeyCoordinator()
    private var sessionObservationTask: Task<Void, Never>?
    private var corpusWatcher: CorpusWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ensureSingleInstance() else { return }

        CrashLog.install()
        CredentialStore.migrateLegacyIfNeeded()

        // Beta gate. Until the user pastes a valid key, no pipelines start
        // and no windows install. The gate window terminates the app if
        // closed without unlocking.
        guard LicenseStore.shared.isValid else {
            LicenseGateWindowController.shared.show { [weak self] in
                self?.continueLaunch()
            }
            return
        }

        continueLaunch()
    }

    @MainActor private func continueLaunch() {
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

        // Keep the FTS + dense indexes in sync with on-disk markdown when
        // anything outside the host writes to the corpus directory — chiefly
        // `rti-mcp append_to_session`, but also manual edits.
        let watcher = CorpusWatcher(
            directory: CorpusManager.shared.corpusDirectory,
            dbPool: RTIDatabase.shared.pool
        )
        watcher.start()
        corpusWatcher = watcher

        windows.install(onOpenSettings: { [weak self] in
            Task { @MainActor [weak self] in self?.windows.openSettings() }
        })

        let invisible = UserDefaults.standard.object(forKey: Self.invisibleKey) as? Bool ?? true
        windows.setSharingInvisible(invisible)

        // Build the shared command registry once. Menu, hotkeys, and the
        // command palette all consume this same list.
        let commands = CommandBuilder.buildCommands(
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

        sessionObservationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = SessionCoordinator.shared.isRunning
                    } onChange: {
                        continuation.resume()
                    }
                }
                self?.menu.refreshTitle()
            }
        }

        registerNotificationObservers()

        if !windows.showOnboardingIfNeeded(),
           CredentialStore.deepseek == nil || CredentialStore.soniox == nil {
            windows.openSettings()
        }
    }

    /// Notification-center observers registered at launch in one call site.
    /// Panel toggles route through `WindowCoordinator.shared` directly —
    /// no notification middleman.
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

    @objc private func toggleOverlay() { windows.toggleOverlay() }
    @objc private func clearChat() { Self.confirmThenClearChat() }
    @objc private func toggleCommandPalette() { windows.toggleCommandPalette() }

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