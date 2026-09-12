import AppKit
import RTICore

/// Owns the deliberately small status-item menu. The overlay is RTI's work
/// surface; the menubar is only for opening it, controlling the recording,
/// and reaching settings.
@MainActor
final class MenuCoordinator: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    /// Drives the once-a-second elapsed readout in the status item. It exists
    /// ONLY while a session is recording (`MenuStatusTick`) — an idle RTI holds
    /// no repeating timer at all. Readable (not writable) from outside so a
    /// test can prove that, and that a recording session holds exactly one.
    private(set) var elapsedTimer: Timer?

    /// Commands keyed by id for fast lookup during menu-open refresh.
    private var commandsByID: [String: RTICommand] = [:]
    /// Every built menu item (top-level and submenu children) keyed by command
    /// id, so menu-open can refresh titles and checkmark state generically.
    private var itemsByID: [String: NSMenuItem] = [:]

    var isRunningProvider: (() -> Bool)?

    /// ⌘\ is RTI's global show and hide.
    private static let idleToolTip = "RTI. Click for the menu. ⌘\\ shows or hides RTI."

    /// Build the small, stable menu from the shared command registry. The full
    /// registry remains available to the command palette and global hotkeys.
    func install(commands: [RTICommand]) {
        for cmd in commands { commandsByID[cmd.id] = cmd }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        applyStatusAppearance(to: item.button, running: false)
        item.button?.toolTip = Self.idleToolTip
        let menu = NSMenu()
        menu.delegate = self

        addCommand("overlay.toggle", to: menu)
        addCommand("meeting.project", to: menu)
        addCommand("session.start", to: menu)
        addCommand("session.pause", to: menu)
        addCommand("view.sessions", to: menu)

        menu.addItem(NSMenuItem.separator())
        addCommand("settings.open", to: menu)

        // Quit item remains native rather than going through the registry.
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit RTI", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item

        // Draws the current state and, only if a session is already recording,
        // starts the tick.
        refreshTitle()
    }

    /// Called by AppDelegate's session-phase observation, and once a second by
    /// the elapsed timer while recording. While a session runs, the status item
    /// shows the recording symbol plus a monospaced-digit elapsed readout
    /// ("3:07"). Every call re-decides whether the tick should be running, so
    /// the phase observation alone is enough to start and stop it.
    func refreshTitle() {
        let running = isRunningProvider?() ?? false
        let button = statusItem?.button
        button?.image = Self.statusImage(running: running)
        button?.toolTip = running
            ? "RTI is recording"
            : Self.idleToolTip

        let session = SessionCoordinator.shared
        let phase = session.phase
        syncElapsedTimer(for: phase)
        if MenuStatusTick.showsElapsed(phase) {
            button?.imagePosition = .imageLeading
            button?.attributedTitle = NSAttributedString(
                string: " " + TimeFormat.elapsed(session.elapsed(at: Date())),
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: House.TypeToken.Size.meta, weight: .regular)]
            )
        } else {
            button?.attributedTitle = NSAttributedString(string: "")
            button?.imagePosition = .imageOnly
        }
    }

    /// Own the 1 Hz tick from the phase, not from app launch. A recording
    /// session gets exactly one timer: a second call while one is already
    /// scheduled keeps it rather than stacking another. Every other phase —
    /// idle, paused, finishing, summarizing, done — has a still readout, so the
    /// timer is invalidated and the reference cleared in the same step, which
    /// is what makes a double invalidate or a leak impossible.
    private func syncElapsedTimer(for phase: SessionCoordinator.Phase) {
        guard MenuStatusTick.needsRepeatingTimer(phase) else {
            elapsedTimer?.invalidate()
            elapsedTimer = nil
            return
        }
        guard elapsedTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: MenuStatusTick.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshTitle() }
        }
        // Let the OS coalesce this wakeup with others instead of forcing its
        // own; a quarter-second of slack is invisible in a M:SS readout.
        timer.tolerance = MenuStatusTick.tolerance
        elapsedTimer = timer
    }

    private func applyStatusAppearance(to button: NSStatusBarButton?, running: Bool) {
        button?.image = Self.statusImage(running: running)
        button?.imagePosition = .imageOnly
        button?.contentTintColor = nil
    }

    private static func statusImage(running: Bool) -> NSImage? {
        let symbol = StatusItemSymbol.name(running: running)
        let description = StatusItemSymbol.accessibilityDescription(running: running)
        let base = NSImage.SymbolConfiguration(pointSize: StatusItemSymbol.pointSize, weight: .medium)
        if running {
            // Ring in ink, centre in `danger`. `labelColor` is the ink the menu
            // bar itself uses, so the ring tracks the menu bar's appearance
            // rather than the app's chosen theme.
            let palette = base.applying(.init(paletteColors: [.labelColor, House.NSColorToken.danger]))
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
                .withSymbolConfiguration(palette)
            image?.isTemplate = false
            return image
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(base)
        image?.isTemplate = true
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
