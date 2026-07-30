import AppKit

/// Owns the deliberately small status-item menu. The overlay is RTI's work
/// surface; the menubar is only for opening it, controlling the recording,
/// and reaching settings.
@MainActor
final class MenuCoordinator: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?

    /// Commands keyed by id for fast lookup during menu-open refresh.
    private var commandsByID: [String: RTICommand] = [:]
    /// Every built menu item (top-level and submenu children) keyed by command
    /// id, so menu-open can refresh titles and checkmark state generically.
    private var itemsByID: [String: NSMenuItem] = [:]

    var isRunningProvider: (() -> Bool)?

    /// Build the small, stable menu from the shared command registry. The full
    /// registry remains available to the command palette and global hotkeys.
    func install(commands: [RTICommand]) {
        for cmd in commands { commandsByID[cmd.id] = cmd }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        applyStatusAppearance(to: item.button, running: false)
        item.button?.toolTip = "RTI — click for menu (⌘\\ to toggle overlay)"
        let menu = NSMenu()
        menu.delegate = self

        addCommand("overlay.toggle", to: menu)
        addCommand("meeting.project", to: menu)
        addCommand("sentinel.record", to: menu)
        addCommand("session.start", to: menu)
        addCommand("session.pause", to: menu)
        addCommand("meeting.import", to: menu)

        menu.addItem(NSMenuItem.separator())
        addCommand("settings.open", to: menu)

        // Quit item remains native rather than going through the registry.
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit RTI", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    func refreshTitle() {
        let running = isRunningProvider?() ?? false
        applyStatusAppearance(to: statusItem?.button, running: running)
        statusItem?.button?.toolTip = running
            ? "RTI — recording in progress"
            : "RTI — click for menu (⌘\\ to toggle overlay)"
    }

    private func applyStatusAppearance(to button: NSStatusBarButton?, running: Bool) {
        button?.image = Self.statusImage()
        button?.imagePosition = .imageOnly
        button?.contentTintColor = running ? .systemRed : nil
    }

    /// Generated mirrored conversation waves, used as a template image so
    /// macOS supplies the correct light/dark menubar colour. A red tint is the
    /// single recording state signal; the mark itself never changes shape.
    private static func statusImage() -> NSImage? {
        let source = NSImage(named: NSImage.Name("MenuBarMark"))
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "RTI")
        guard let image = source?.copy() as? NSImage else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 14)
        return image
    }

    private func addCommand(_ id: String, to menu: NSMenu) {
        guard let command = commandsByID[id] else { return }
        menu.addItem(makeItem(command))
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
            mi.isHidden = !cmd.isAvailable()
        }
    }

    @objc private func fireCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let cmd = commandsByID[id] else { return }
        cmd.perform()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
