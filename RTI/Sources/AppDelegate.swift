import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var overlayController: OverlayWindowController?
    private var topWidget: TopWidgetWindowController?
    private var debugConsole: DebugConsoleWindowController?
    private var settingsWindow: SettingsWindowController?
    private var sessionDetailWindow: NSWindow?
    private var sessionHistory: SessionHistoryWindowController?
    private var onboarding: OnboardingWindowController?
    private var hotkey: GlobalHotkey?
    private var shortcutsController: ShortcutsWindowController?
    private var commandPalette: CommandPaletteWindowController?
    private var sessionMenuItem: NSMenuItem?
    private var smartModeItem: NSMenuItem?
    private var invisibilityItem: NSMenuItem?
    private var recentSessionsItem: NSMenuItem?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ensureSingleInstance() else { return }

        CrashLog.install()
        CredentialStore.migrateLegacyIfNeeded()

        // Bootstrap first so currentSessionId is set before normalize/prune run —
        // they consult it to avoid touching the active session.
        SessionCoordinator.shared.bootstrapChatSession()
        SessionCoordinator.shared.normalizeLegacySessions()
        SessionCoordinator.shared.pruneOldSessions(days: 30)
        _ = ModeStore.shared
        LLMController.shared.loadHistoryForCurrentSession()
        CorpusManager.shared.recoverOrphans()

        installStatusItem()

        settingsWindow = SettingsWindowController()
        shortcutsController = ShortcutsWindowController()

        let controller = OverlayWindowController { [weak self] in
            self?.openSettings()
        }
        controller.show()
        overlayController = controller

        let top = TopWidgetWindowController(onTap: { [weak self] in
            guard let self, let overlay = self.overlayController else { return }
            if overlay.isVisible {
                overlay.hide()
            } else {
                overlay.showBelow(pillFrame: self.topWidget?.windowFrame ?? .zero)
            }
        })
        top.show()
        topWidget = top

        let invisible = UserDefaults.standard.object(forKey: Self.invisibleKey) as? Bool ?? true
        overlayController?.setSharingInvisible(invisible)
        top.setSharingInvisible(invisible)

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
        hk.register(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.debugConsole?.toggle()
        }
        hk.register(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.commandPalette?.toggle()
        }
        hotkey = hk

        commandPalette = CommandPaletteWindowController()
        registerPaletteCommands()

        SessionCoordinator.shared.$isRunning
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshStatusItemTitle() }
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenSessionDetailNotification(_:)),
            name: .openSessionDetail,
            object: nil
        )
        // Posted from the overlay's ellipsis menu so AppDelegate stays the
        // single owner of the OverlayWindowController and the clear-chat
        // confirmation flow.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(toggleOverlay),
            name: .rtiToggleOverlay,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clearChat),
            name: .rtiClearChat,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showDebugConsole),
            name: .rtiShowLiveTranscript,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showSessionHistory),
            name: .rtiShowSessionHistory,
            object: nil
        )

        // Show the 3-step onboarding once on first launch (and when the user
        // hasn't completed it yet). Falls back to opening Settings directly if
        // the onboarding flow has already been dismissed but keys are missing.
        if !OnboardingDefaults.hasCompleted {
            let controller = OnboardingWindowController()
            controller.showIfNeeded()
            onboarding = controller
        } else if CredentialStore.deepseek == nil || CredentialStore.soniox == nil {
            settingsWindow?.show()
        }
    }

    @objc private func handleOpenSessionDetailNotification(_ notification: Notification) {
        guard let id = notification.object as? String else { return }
        openSessionDetail(for: id)
    }

    func openSettings() { settingsWindow?.show() }

    private func installStatusItem() {
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

    func menuWillOpen(_ menu: NSMenu) {
        refreshSessionMenuItemTitle()
        refreshSmartModeTitle()
        rebuildRecentSessionsSubmenu()
        refreshDetailMenuItemEnablement(menu: menu)
    }

    private func refreshDetailMenuItemEnablement(menu: NSMenu) {
        guard let detailItem = menu.items.first(where: { $0.action == #selector(openCurrentSessionDetail) }) else { return }
        let hasSession = SessionCoordinator.shared.currentSessionId != nil
        detailItem.isEnabled = hasSession
        detailItem.title = hasSession ? "View Session Detail" : "View Session Detail (no active session)"
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
            let item = NSMenuItem(title: title, action: #selector(openSessionDetail(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s.id
            submenu.addItem(item)
        }
    }

    @objc private func openSessionDetail(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        openSessionDetail(for: id)
    }

    @objc private func openCurrentSessionDetail() {
        guard let id = SessionCoordinator.shared.currentSessionId else { return }
        openSessionDetail(for: id)
    }

    private func registerPaletteCommands() {
        let coord: () -> SessionCoordinator = { SessionCoordinator.shared }
        let llm: () -> LLMController = { LLMController.shared }
        let modes: () -> ModeStore = { ModeStore.shared }

        var cmds: [RTICommand] = [
            // MARK: - Session
            RTICommand(
                id: "session.start",
                title: "Start Session",
                subtitle: "⌘⇧R",
                keywords: ["record", "begin", "transcribe"],
                isAvailable: { !coord().isRunning },
                perform: { coord().toggleSession() }
            ),
            RTICommand(
                id: "session.stop",
                title: "Stop Session",
                subtitle: "⌘⇧R",
                keywords: ["end", "finish"],
                isAvailable: { coord().isRunning },
                perform: { coord().toggleSession() }
            ),
            RTICommand(
                id: "session.detail",
                title: "Open Current Session Detail",
                keywords: ["view", "transcript"],
                isAvailable: { coord().currentSessionId != nil },
                perform: { [weak self] in self?.openCurrentSessionDetail() }
            ),

            // MARK: - Overlay
            RTICommand(
                id: "overlay.toggle",
                title: "Toggle Overlay",
                subtitle: "⌘\\",
                keywords: ["panel", "show", "hide"],
                perform: { [weak self] in self?.overlayController?.toggle() }
            ),
            RTICommand(
                id: "widget.top.toggle",
                title: "Toggle Top Widget",
                keywords: ["pill", "bar"],
                perform: { [weak self] in self?.topWidget?.toggle() }
            ),
            RTICommand(
                id: "invisibility.toggle",
                title: "Toggle Invisibility",
                keywords: ["sharing", "screencap", "hide from screen"],
                perform: { [weak self] in self?.toggleInvisibility() }
            ),
            RTICommand(
                id: "smart.toggle",
                title: "Toggle Smart Mode",
                keywords: ["reasoning", "deep"],
                perform: { llm().smartMode.toggle() }
            ),

            // MARK: - Chat
            RTICommand(
                id: "chat.assist",
                title: "Assist (suggest what to say)",
                subtitle: "⌘⏎",
                keywords: ["help", "suggestion"],
                perform: { llm().sendAssist() }
            ),
            RTICommand(
                id: "chat.saynext",
                title: "Say Next (one-line draft reply)",
                keywords: ["respond", "reply"],
                perform: { llm().sendSaySomething() }
            ),
            RTICommand(
                id: "chat.followups",
                title: "Follow-up Questions",
                keywords: ["questions", "ask"],
                perform: { llm().sendFollowupQuestions() }
            ),
            RTICommand(
                id: "chat.recap",
                title: "Recap so far",
                keywords: ["summary", "review"],
                perform: { llm().sendRecap() }
            ),
            RTICommand(
                id: "chat.clear",
                title: "Clear Current Chat",
                keywords: ["delete", "reset"],
                perform: { [weak self] in self?.clearChat() }
            ),

            // MARK: - Capture
            RTICommand(
                id: "capture.screen",
                title: "Capture Screen for AI",
                subtitle: "⌘H",
                keywords: ["screenshot", "ocr"],
                perform: { ScreenshotManager.shared.captureAndAttach() }
            ),
            RTICommand(
                id: "view.live",
                title: "Show Live Transcript",
                subtitle: "⌘⌥T",
                keywords: ["console", "debug"],
                perform: { [weak self] in self?.debugConsole?.toggle() }
            ),

            // MARK: - Other
            RTICommand(
                id: "view.history",
                title: "Session History…",
                keywords: ["past", "old", "meetings"],
                perform: { [weak self] in self?.showSessionHistory() }
            ),
            RTICommand(
                id: "settings.open",
                title: "Open Settings…",
                subtitle: "⌘,",
                keywords: ["preferences", "config"],
                perform: { [weak self] in self?.openSettings() }
            ),
            RTICommand(
                id: "settings.shortcuts",
                title: "Keyboard Shortcuts…",
                keywords: ["hotkeys", "bindings"],
                perform: { [weak self] in self?.showShortcuts() }
            ),
            RTICommand(
                id: "app.quit",
                title: "Quit RTI",
                subtitle: "⌘Q",
                perform: { NSApp.terminate(nil) }
            )
        ]

        // Mode switching: one entry per registered mode. Marked unavailable
        // when the mode is already active so we don't surface a no-op.
        for mode in modes().modes {
            let modeId = mode.id
            let modeName = mode.name
            cmds.append(RTICommand(
                id: "mode.switch.\(modeId)",
                title: "Switch to: \(modeName)",
                keywords: ["mode", "preset"],
                isAvailable: { modes().activeMode?.id != modeId },
                perform: { modes().activeModeId = modeId }
            ))
        }

        CommandRegistry.shared.replaceAll(cmds)
    }

    private func openSessionDetail(for id: String) {
        if let window = sessionDetailWindow {
            window.contentView = NSHostingView(rootView: SessionDetailView(sessionId: id))
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = "Session"
        w.titlebarAppearsTransparent = true
        w.setFrameAutosaveName("rti.sessiondetail")
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 720, height: 480)
        w.backgroundColor = NSColor(red: 0.969, green: 0.969, blue: 0.973, alpha: 1)
        // RTIDesign tokens are calibrated for light mode (textPrimary near
        // black on textBackground near white). Force aqua so dark-mode users
        // don't end up with invisible dark text on dark List rows.
        w.appearance = NSAppearance(named: .aqua)
        w.contentView = NSHostingView(rootView: SessionDetailView(sessionId: id))
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        sessionDetailWindow = w
    }

    private func ensureSingleInstance() -> Bool {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.tristan.rti"
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        if instances.count > 1 {
            instances.first(where: { $0 != NSRunningApplication.current })?.activate(options: .activateIgnoringOtherApps)
            NSApp.terminate(nil)
            return false // unreachable in practice; quiets the compiler
        }
        return true
    }

    private func refreshSessionMenuItemTitle() {
        sessionMenuItem?.title = SessionCoordinator.shared.isRunning ? "Stop Session (⌘⇧R)" : "Start Session (⌘⇧R)"
    }

    private func refreshSmartModeTitle() {
        smartModeItem?.title = LLMController.shared.smartMode ? "Smart Mode: On" : "Smart Mode: Off"
        smartModeItem?.state = LLMController.shared.smartMode ? .on : .off
    }

    private func refreshStatusItemTitle() {
        let running = SessionCoordinator.shared.isRunning
        statusItem?.button?.title = running ? "RTI ●" : "RTI"
        statusItem?.button?.toolTip = running
            ? "RTI — recording in progress"
            : "RTI — click for menu (⌘\\ to toggle overlay)"
    }

    @objc private func toggleSession() { SessionCoordinator.shared.toggleSession() }
    @objc private func toggleSmartMode() { LLMController.shared.smartMode.toggle() }
    private static let invisibleKey = "rti.invisible"

    @objc private func toggleInvisibility() {
        let isInvisible = invisibilityItem?.state == .on
        let newState: NSControl.StateValue = isInvisible ? .off : .on
        invisibilityItem?.state = newState
        invisibilityItem?.title = newState == .on ? "Invisible: On" : "Invisible: Off"
        let invisible = newState == .on
        UserDefaults.standard.set(invisible, forKey: Self.invisibleKey)
        overlayController?.setSharingInvisible(invisible)
        topWidget?.setSharingInvisible(invisible)
    }
    @objc private func showShortcuts() { shortcutsController?.show() }
    @objc private func showDebugConsole() { debugConsole?.show() }
    @objc private func showSettings() { settingsWindow?.show() }
    @objc private func showSessionHistory() {
        if sessionHistory == nil {
            sessionHistory = SessionHistoryWindowController()
        }
        sessionHistory?.show()
    }
    @objc private func toggleOverlay() { overlayController?.toggle() }
    @objc private func toggleTopWidget() { topWidget?.toggle() }
    @objc private func clearChat() {
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

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showAbout() {
        let credits = NSMutableAttributedString(
            string: "Real-time meeting intelligence.\nAll session data stays on this Mac.\n\nhttps://github.com/tristan-mcinnis/rti",
            attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: 11)
            ]
        )
        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 Tristan McInnis"
        ]
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: options)
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
        // Synchronously flush an in-flight session so we don't truncate the WAV
        // header or leave ended_at = NULL after a ⌘Q. Soniox is dropped without
        // its 1.5s finalize wait; remaining audio is already on disk.
        SessionCoordinator.shared.emergencyShutdown()
    }
}
