import AppKit

/// Owns the deliberately small status-item menu. The overlay is RTI's work
/// surface; the menubar is only for opening it, controlling the recording,
/// and reaching settings. Status item = `MinimalStatusItemView`'s dot +
/// monospaced-digit elapsed title; menu = exactly Start/Finish Recording,
/// Open RTI, Settings…, Quit — built from `Commands.menuItems()`.
@MainActor
final class MenuCoordinator: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var menuItems: [Commands.MenuItem] = []
    private var itemsInOrder: [NSMenuItem] = []
    private var elapsedTimer: Timer?

    func install() {
        menuItems = Commands.menuItems()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageLeft
        item.button?.toolTip = "RTI — click for menu (⌘\\ to toggle overlay)"

        let menu = NSMenu()
        menu.delegate = self
        itemsInOrder = menuItems.map { entry in
            let mi = NSMenuItem(title: entry.title(), action: #selector(fire(_:)), keyEquivalent: "")
            mi.target = self
            menu.addItem(mi)
            return mi
        }

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit RTI", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item

        refreshTitle()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshTitle() }
        }
    }

    /// Called by AppDelegate's session-phase observation loop, and once a
    /// second by the elapsed timer while a session is running.
    func refreshTitle() {
        let session = SessionCoordinator.shared
        statusItem?.button?.image = MinimalStatusItemView.dotImage(
            phase: session.phase,
            hasError: session.lastError != nil
        )
        statusItem?.button?.title = session.phase == .idle || session.phase == .done
            ? ""
            : " " + MinimalStatusItemView.elapsedTitle(session.elapsed(at: Date()))
    }

    func menuWillOpen(_ menu: NSMenu) {
        for (item, mi) in zip(menuItems, itemsInOrder) {
            mi.title = item.title()
        }
    }

    @objc private func fire(_ sender: NSMenuItem) {
        guard let index = itemsInOrder.firstIndex(of: sender) else { return }
        menuItems[index].action()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
