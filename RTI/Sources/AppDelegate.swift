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
    private var hotkey: GlobalHotkey?
    private var sessionMenuItem: NSMenuItem?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()

        let controller = OverlayWindowController()
        controller.show()
        overlayController = controller

        let top = TopWidgetWindowController { [weak self] in
            self?.overlayController?.toggle()
        }
        top.show()
        topWidget = top

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
        hotkey = hk

        SessionCoordinator.shared.$isRunning
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshStatusItemTitle() }
            }
            .store(in: &cancellables)
    }

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

        menu.addItem(NSMenuItem.separator())

        let overlayItem = NSMenuItem(title: "Toggle Overlay (⌘\\)", action: #selector(toggleOverlay), keyEquivalent: "")
        overlayItem.target = self
        menu.addItem(overlayItem)

        let widgetItem = NSMenuItem(title: "Toggle Top Widget", action: #selector(toggleTopWidget), keyEquivalent: "")
        widgetItem.target = self
        menu.addItem(widgetItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit RTI", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshSessionMenuItemTitle()
    }

    private func refreshSessionMenuItemTitle() {
        sessionMenuItem?.title = SessionCoordinator.shared.isRunning ? "Stop Session (⌘⇧R)" : "Start Session (⌘⇧R)"
    }

    private func refreshStatusItemTitle() {
        statusItem?.button?.title = SessionCoordinator.shared.isRunning ? "RTI ●" : "RTI"
    }

    @objc private func toggleSession() { SessionCoordinator.shared.toggleSession() }
    @objc private func showDebugConsole() { debugConsole?.show() }
    @objc private func toggleOverlay() { overlayController?.toggle() }
    @objc private func toggleTopWidget() { topWidget?.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }
}
