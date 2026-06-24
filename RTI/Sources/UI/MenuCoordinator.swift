import AppKit

/// Owns the status-item menu and its dynamic state. Builds menu items from
/// the shared `[RTICommand]` registry — no per-action closure properties.
/// Only the recent-sessions submenu and the Logs item remain as direct
/// wiring because they're dynamically populated, not static commands.
@MainActor
final class MenuCoordinator: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?

    /// Commands keyed by id for fast lookup during menu-open refresh.
    private var commandsByID: [String: RTICommand] = [:]
    /// Every built menu item (top-level and submenu children) keyed by command
    /// id, so menu-open can refresh titles and checkmark state generically.
    private var itemsByID: [String: NSMenuItem] = [:]

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
        if let button = item.button {
            button.image = Self.statusImage(running: false)
            button.imagePosition = .imageOnly
        }
        item.button?.toolTip = "RTI — click for menu (⌘\\ to toggle overlay)"
        let menu = NSMenu()
        menu.delegate = self

        // Group commands by section, preserving declaration order. Within a
        // section, commands sharing a `menuParent` collapse into one submenu
        // (built at the parent's first occurrence) instead of going flat.
        let grouped = Dictionary(grouping: commands) { $0.menuSection }
        for section in MenuSection.allCases {
            guard let group = grouped[section] else { continue }
            var builtSubmenus = Set<String>()
            for cmd in group {
                if let parent = cmd.menuParent {
                    guard !builtSubmenus.contains(parent) else { continue }
                    builtSubmenus.insert(parent)
                    let parentItem = NSMenuItem(title: parent, action: nil, keyEquivalent: "")
                    let sub = NSMenu()
                    for child in group where child.menuParent == parent {
                        sub.addItem(makeItem(child))
                    }
                    parentItem.submenu = sub
                    menu.addItem(parentItem)
                } else {
                    menu.addItem(makeItem(cmd))
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
        statusItem?.button?.image = Self.statusImage(running: running)
        statusItem?.button?.toolTip = running
            ? "RTI — recording in progress"
            : "RTI — click for menu (⌘\\ to toggle overlay)"
    }

    /// Menubar glyph: an "R" in a circle (RTI's mark). Idle is a hollow ring
    /// drawn as a template so macOS tints it for light/dark menubars; while a
    /// session is live the ring fills and turns red, so "recording" reads at a
    /// glance.
    private static func statusImage(running: Bool) -> NSImage? {
        let symbol = running ? "r.circle.fill" : "r.circle"
        let base = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)

        if running {
            // Red badge with a white "R" knocked out — palette order is
            // [letter, circle]. Explicitly NOT a template so the colour shows.
            let red = base.applying(.init(paletteColors: [.white, .systemRed]))
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "RTI recording")?
                .withSymbolConfiguration(red)
            image?.isTemplate = false
            return image
        }

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "RTI")?
            .withSymbolConfiguration(base)
        image?.isTemplate = true
        return image
    }

    /// Build one menu item from a command, recording it for menu-open refresh
    /// and seeding its checkmark from the current state.
    private func makeItem(_ cmd: RTICommand) -> NSMenuItem {
        let mi = NSMenuItem(
            title: cmd.menuTitleProvider?() ?? cmd.title,
            action: #selector(fireCommand(_:)),
            keyEquivalent: ""
        )
        mi.target = self
        mi.representedObject = cmd.id
        if let state = cmd.menuStateProvider { mi.state = state() ? .on : .off }
        itemsByID[cmd.id] = mi
        return mi
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Refresh every item's dynamic title + checkmark state generically.
        // Submenu children are refreshed here too (they're in itemsByID), so
        // they're current by the time the user hovers into a submenu.
        for (id, mi) in itemsByID {
            guard let cmd = commandsByID[id] else { continue }
            if let title = cmd.menuTitleProvider { mi.title = title() }
            if let state = cmd.menuStateProvider { mi.state = state() ? .on : .off }
        }
    }

    @objc private func fireCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let cmd = commandsByID[id] else { return }
        cmd.perform()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}