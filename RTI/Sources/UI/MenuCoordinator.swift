import AppKit

/// Owns the status-item menu and its dynamic state. Builds menu items from
/// the shared `[RTICommand]` registry — no per-action closure properties.
/// Only the recent-sessions submenu and the Logs item remain as direct
/// wiring because they're dynamically populated, not static commands.
@MainActor
final class MenuCoordinator: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var sessionMenuItem: NSMenuItem?
    private var smartModeItem: NSMenuItem?
    private var invisibilityItem: NSMenuItem?

    /// Commands keyed by id for fast lookup during menu-open refresh.
    private var commandsByID: [String: RTICommand] = [:]

    var onToggleSession: (() -> Void)?
    var onToggleSmartMode: (() -> Void)?
    var onToggleInvisibility: (() -> Void)?
    var currentSessionIdProvider: (() -> String?)?
    var isRunningProvider: (() -> Bool)?
    var smartModeProvider: (() -> Bool)?
    var invisibilityProvider: (() -> Bool)?

    /// Build the status-item menu from the shared command registry.
    /// Commands are grouped by `MenuSection` and rendered in declaration
    /// order within each section. Commands without a `menuSection` are
    /// skipped. The "Recent Sessions" submenu and the "Logs" item are
    /// added after the navigation section.
    func install(commands: [RTICommand]) {
        for cmd in commands { commandsByID[cmd.id] = cmd }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "RTI"
        item.button?.toolTip = "RTI — click for menu (⌘\\ to toggle overlay)"
        let menu = NSMenu()
        menu.delegate = self

        // Group commands by section, preserving declaration order.
        let grouped = Dictionary(grouping: commands) { $0.menuSection }
        for section in MenuSection.allCases {
            guard let group = grouped[section] else { continue }
            for cmd in group {
                let mi = NSMenuItem(title: cmd.title, action: #selector(fireCommand(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = cmd.id
                menu.addItem(mi)

                // Capture dynamic items for menu-open refresh.
                switch cmd.id {
                case "session.start":
                    sessionMenuItem = mi
                case "smart.toggle":
                    smartModeItem = mi
                case "invisibility.toggle":
                    invisibilityItem = mi
                default:
                    break
                }
            }

            // Add separator between sections (except after the last).
            if section != MenuSection.allCases.last {
                menu.addItem(NSMenuItem.separator())
            }
        }

        // Quit item at the bottom.
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
        // Refresh dynamic titles.
        if let cmd = commandsByID["session.start"], let mi = sessionMenuItem {
            mi.title = cmd.menuTitleProvider?() ?? cmd.title
        }
        if let cmd = commandsByID["smart.toggle"], let mi = smartModeItem {
            mi.title = cmd.menuTitleProvider?() ?? cmd.title
            mi.state = (smartModeProvider?() ?? false) ? .on : .off
        }
        if let cmd = commandsByID["invisibility.toggle"], let mi = invisibilityItem {
            mi.title = cmd.menuTitleProvider?() ?? cmd.title
            mi.state = (invisibilityProvider?() ?? true) ? .on : .off
        }
    }

    @objc private func fireCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let cmd = commandsByID[id] else { return }
        cmd.perform()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}