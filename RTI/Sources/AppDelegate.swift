import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var overlayController: OverlayWindowController?
    private var topWidget: TopWidgetWindowController?
    private var miniWidget: MiniWidgetWindowController?
    private var debugConsole: DebugConsoleWindowController?
    private var settingsWindow: SettingsWindowController?
    private var hotkey: GlobalHotkey?
    private var sessionMenuItem: NSMenuItem?
    private var recentSessionsItem: NSMenuItem?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        CrashLog.install()
        CredentialStore.migrateLegacyIfNeeded()

        SessionCoordinator.shared.pruneOldSessions(days: 30)
        SessionCoordinator.shared.bootstrapChatSession()
        _ = ModeStore.shared
        LLMController.shared.loadHistoryForCurrentSession()

        installStatusItem()

        settingsWindow = SettingsWindowController()

        let controller = OverlayWindowController { [weak self] in
            self?.openSettings()
        }
        controller.show()
        overlayController = controller

        let top = TopWidgetWindowController { [weak self] in
            self?.collapseToMini()
        }
        top.show()
        topWidget = top

        miniWidget = MiniWidgetWindowController { [weak self] in
            self?.expandFromMini()
        }

        debugConsole = DebugConsoleWindowController()

        let hk = GlobalHotkey()
        hk.register(keyCode: UInt32(kVK_ANSI_Backslash), modifiers: UInt32(cmdKey)) { [weak self] in
            self?.overlayController?.toggle()
        }
        hk.register(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | shiftKey)) {
            SessionCoordinator.shared.toggleSession()
        }
        hk.register(keyCode: UInt32(kVK_Return), modifiers: UInt32(cmdKey)) {
            LLMController.shared.sendAssist()
        }
        hk.register(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey)) {
            ScreenshotManager.shared.captureAndAttach()
        }
        hotkey = hk

        SessionCoordinator.shared.$isRunning
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshStatusItemTitle() }
            }
            .store(in: &cancellables)

        if CredentialStore.kimi == nil {
            settingsWindow?.show()
        }
    }

    func openSettings() { settingsWindow?.show() }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "RTI"
        let menu = NSMenu()
        menu.delegate = self

        let sessionItem = NSMenuItem(title: "Start Session", action: #selector(toggleSession), keyEquivalent: "")
        sessionItem.target = self
        menu.addItem(sessionItem)
        self.sessionMenuItem = sessionItem

        let consoleItem = NSMenuItem(title: "Show Debug Console", action: #selector(showDebugConsole), keyEquivalent: "")
        consoleItem.target = self
        menu.addItem(consoleItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let overlayItem = NSMenuItem(title: "Toggle Overlay (⌘\\)", action: #selector(toggleOverlay), keyEquivalent: "")
        overlayItem.target = self
        menu.addItem(overlayItem)

        let widgetItem = NSMenuItem(title: "Toggle Top Widget", action: #selector(toggleTopWidget), keyEquivalent: "")
        widgetItem.target = self
        menu.addItem(widgetItem)

        let clearItem = NSMenuItem(title: "Clear Current Chat", action: #selector(clearChat), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        let recentItem = NSMenuItem(title: "Recent Sessions", action: nil, keyEquivalent: "")
        recentItem.submenu = NSMenu(title: "Recent Sessions")
        menu.addItem(recentItem)
        recentSessionsItem = recentItem

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit RTI", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshSessionMenuItemTitle()
        rebuildRecentSessionsSubmenu()
    }

    private func rebuildRecentSessionsSubmenu() {
        guard let submenu = recentSessionsItem?.submenu else { return }
        submenu.removeAllItems()

        let sessions = SessionCoordinator.shared.recentSessions(limit: 10)
        if sessions.isEmpty {
            let empty = NSMenuItem(title: "No sessions yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            return
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short

        let currentId = SessionCoordinator.shared.currentSessionId
        for s in sessions {
            let title = "\(formatter.string(from: s.startedAt))\(s.id == currentId ? "  •" : "")"
            let item = NSMenuItem(title: title, action: #selector(switchSession(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s.id
            submenu.addItem(item)
        }
    }

    @objc private func switchSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if SessionCoordinator.shared.isRunning {
            NSSound.beep()
            return
        }
        SessionCoordinator.shared.switchToSession(id: id)
        LLMController.shared.loadHistoryForCurrentSession()
    }

    private func refreshSessionMenuItemTitle() {
        sessionMenuItem?.title = SessionCoordinator.shared.isRunning ? "Stop Session (⌘⇧R)" : "Start Session (⌘⇧R)"
    }

    private func refreshStatusItemTitle() {
        statusItem?.button?.title = SessionCoordinator.shared.isRunning ? "RTI ●" : "RTI"
    }

    @objc private func toggleSession() { SessionCoordinator.shared.toggleSession() }
    @objc private func showDebugConsole() { debugConsole?.show() }
    @objc private func showSettings() { settingsWindow?.show() }
    @objc private func toggleOverlay() { overlayController?.toggle() }
    @objc private func toggleTopWidget() { topWidget?.toggle() }
    @objc private func clearChat() { LLMController.shared.clear() }

    private func collapseToMini() {
        topWidget?.hide()
        miniWidget?.show()
    }

    private func expandFromMini() {
        miniWidget?.hide()
        topWidget?.show()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
