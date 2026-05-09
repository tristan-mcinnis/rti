import AppKit

/// Owns the status-item menu and its dynamic state (recent sessions,
/// smart mode toggle, session start/stop label, etc.).
@MainActor
final class MenuCoordinator: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var sessionMenuItem: NSMenuItem?
    private var smartModeItem: NSMenuItem?
    private var invisibilityItem: NSMenuItem?
    private var recentSessionsItem: NSMenuItem?

    var onToggleSession: (() -> Void)?
    var onToggleSmartMode: (() -> Void)?
    var onToggleInvisibility: (() -> Void)?
    var onOpenCurrentSessionDetail: (() -> Void)?
    var onShowDebugConsole: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onShowAbout: (() -> Void)?
    var onShowShortcuts: (() -> Void)?
    var onShowOnboarding: (() -> Void)?
    var onToggleOverlay: (() -> Void)?
    var onToggleTopWidget: (() -> Void)?
    var onClearChat: (() -> Void)?
    var onShowSessionHistory: (() -> Void)?
    var onRecentSessionSelected: ((String) -> Void)?
    var recentSessionsProvider: (() -> [Session])?
    var currentSessionIdProvider: (() -> String?)?
    var isRunningProvider: (() -> Bool)?
    var smartModeProvider: (() -> Bool)?
    var invisibilityProvider: (() -> Bool)?

    private static let invisibleKey = "rti.invisible"

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "RTI"
        item.button?.toolTip = "RTI — click for menu (⌘\\ to toggle overlay)"
        let menu = NSMenu()
        menu.delegate = self

        let sessionItem = NSMenuItem(title: "Start Session", action: #selector(toggleSession), keyEquivalent: "")
        sessionItem.target = self
        menu.addItem(sessionItem)
        self.sessionMenuItem = sessionItem

        let smartItem = NSMenuItem(title: "Smart Mode: On", action: #selector(toggleSmartMode), keyEquivalent: "")
        smartItem.target = self
        menu.addItem(smartItem)
        self.smartModeItem = smartItem

        let userInvisible = UserDefaults.standard.object(forKey: Self.invisibleKey) as? Bool ?? true
        let invisState: NSControl.StateValue = userInvisible ? .on : .off
        let invisItem = NSMenuItem(title: userInvisible ? "Invisible: On" : "Invisible: Off", action: #selector(toggleInvisibility), keyEquivalent: "")
        invisItem.target = self
        invisItem.state = invisState
        menu.addItem(invisItem)
        self.invisibilityItem = invisItem

        menu.addItem(NSMenuItem.separator())

        let detailItem = NSMenuItem(title: "View Session Detail", action: #selector(openCurrentSessionDetail), keyEquivalent: "")
        detailItem.target = self
        menu.addItem(detailItem)

        let consoleItem = NSMenuItem(title: "Show Live Transcript (⌘⌥T)", action: #selector(showDebugConsole), keyEquivalent: "")
        consoleItem.target = self
        menu.addItem(consoleItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let aboutItem = NSMenuItem(title: "About RTI", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let shortcutsItem = NSMenuItem(title: "Keyboard Shortcuts…", action: #selector(showShortcuts), keyEquivalent: "")
        shortcutsItem.target = self
        menu.addItem(shortcutsItem)

        let welcomeItem = NSMenuItem(title: "Show Welcome…", action: #selector(showOnboarding), keyEquivalent: "")
        welcomeItem.target = self
        menu.addItem(welcomeItem)

        menu.addItem(NSMenuItem.separator())

        let overlayItem = NSMenuItem(title: "Toggle Overlay (⌘\\)", action: #selector(toggleOverlay), keyEquivalent: "")
        overlayItem.target = self
        menu.addItem(overlayItem)

        let widgetItem = NSMenuItem(title: "Toggle Top Widget (⌘⇧B)", action: #selector(toggleTopWidget), keyEquivalent: "")
        widgetItem.target = self
        menu.addItem(widgetItem)

        let clearItem = NSMenuItem(title: "Clear Current Chat", action: #selector(clearChat), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        let recentItem = NSMenuItem(title: "Recent Sessions", action: nil, keyEquivalent: "")
        recentItem.submenu = NSMenu(title: "Recent Sessions")
        menu.addItem(recentItem)
        recentSessionsItem = recentItem

        let historyItem = NSMenuItem(title: "Session History…", action: #selector(showSessionHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit RTI", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    func refreshTitle() {
        let running = isRunningProvider?() ?? false
        statusItem?.button?.title = running ? "RTI ●" : "RTI"
        statusItem?.button?.toolTip = running
            ? "RTI — recording in progress"
            : "RTI — click for menu (⌘\\ to toggle overlay)"
    }

    func menuWillOpen(_ menu: NSMenu) {
        sessionMenuItem?.title = (isRunningProvider?() ?? false)
            ? "Stop Session (⌘⇧R)"
            : "Start Session (⌘⇧R)"
        smartModeItem?.title = (smartModeProvider?() ?? false)
            ? "Smart Mode: On"
            : "Smart Mode: Off"
        smartModeItem?.state = (smartModeProvider?() ?? false) ? .on : .off
        rebuildRecentSessionsSubmenu()
        refreshDetailMenuItemEnablement(menu: menu)
    }

    private func rebuildRecentSessionsSubmenu() {
        guard let submenu = recentSessionsItem?.submenu else { return }
        submenu.removeAllItems()

        let sessions = recentSessionsProvider?().prefix(10) ?? []
        if sessions.isEmpty {
            let empty = NSMenuItem(title: "No sessions yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            return
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short

        let currentId = currentSessionIdProvider?()
        for s in sessions {
            let title = "\(formatter.string(from: s.startedAt))\(s.id == currentId ? "  •" : "")"
            let item = NSMenuItem(title: title, action: #selector(openSessionDetail(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s.id
            submenu.addItem(item)
        }
    }

    private func refreshDetailMenuItemEnablement(menu: NSMenu) {
        guard let detailItem = menu.items.first(where: { $0.action == #selector(openCurrentSessionDetail) }) else { return }
        let hasSession = currentSessionIdProvider?() != nil
        detailItem.isEnabled = hasSession
        detailItem.title = hasSession ? "View Session Detail" : "View Session Detail (no active session)"
    }

    @objc private func toggleSession() { onToggleSession?() }
    @objc private func toggleSmartMode() { onToggleSmartMode?() }
    @objc private func toggleInvisibility() { onToggleInvisibility?() }
    @objc private func openCurrentSessionDetail() { onOpenCurrentSessionDetail?() }
    @objc private func showDebugConsole() { onShowDebugConsole?() }
    @objc private func showSettings() { onShowSettings?() }
    @objc private func showAbout() { onShowAbout?() }
    @objc private func showShortcuts() { onShowShortcuts?() }
    @objc private func showOnboarding() { onShowOnboarding?() }
    @objc private func toggleOverlay() { onToggleOverlay?() }
    @objc private func toggleTopWidget() { onToggleTopWidget?() }
    @objc private func clearChat() { onClearChat?() }
    @objc private func showSessionHistory() { onShowSessionHistory?() }
    @objc private func openSessionDetail(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onRecentSessionSelected?(id)
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
