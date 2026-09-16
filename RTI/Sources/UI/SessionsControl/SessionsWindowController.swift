// Window chrome copied from quick-launch@8ee19aa Sources/App/AIChatWindowController.swift
// (prepareWindow, AIChatWindow key routing), without the accessory-policy dance:
// RTI is always a regular Dock app.
import AppKit
import RTICore
import SwiftUI

/// Owns the Sessions window: archived meetings in the house AI Chat window
/// shape (design-system docs/chat-surfaces.md section 7). Opened from the
/// menu bar, the status item, the command palette, the "Notes ready"
/// control, and the summary notification. The model outlives the window, so
/// a transcript upgrade keeps going after `⌘W`.
@MainActor
final class SessionsWindowController: NSObject, NSWindowDelegate {
    let model = SessionsWindowModel()
    private var window: SessionsWindow?

    static let frameAutosaveName = "rti.sessions"

    /// Show the window. With `folder`, open that session with the list
    /// hidden (a deep link); without, keep the last session and list state.
    func show(folder: String? = nil) {
        let window = self.window ?? makeWindow()
        self.window = window
        model.isWindowVisible = true
        if let folder {
            model.open(folder: folder)
        }
        Task { await model.reload() }
        keepOnScreen(window)
        RTIActivation.bringToFront(window)
    }

    private func makeWindow() -> SessionsWindow {
        let size = NSSize(width: House.Layout.chatWidth, height: House.Layout.chatHeight)
        let window = SessionsWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Sessions"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An empty unified toolbar makes the title-bar row as tall as the
        // 52 pt header, so the traffic lights centre on it.
        window.toolbar = NSToolbar(identifier: "rti.sessions.toolbar")
        window.toolbarStyle = .unified
        // Selecting text must not move the window; the header drags it.
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenPrimary]
        window.contentMinSize = NSSize(width: House.Layout.chatMinWidth, height: House.Layout.chatMinHeight)
        window.backgroundColor = House.NSColorToken.surface
        window.appearance = OverlayAppearanceDefaults.nsAppearance()
        window.model = model
        window.delegate = self

        let hosting = NSHostingView(rootView: SessionsBrowserView(model: model))
        // The window sizes the view, not the other way round.
        hosting.sizingOptions = []
        window.contentView = hosting

        window.center()
        window.setFrameAutosaveName(Self.frameAutosaveName)
        // A saved frame smaller than the minimum resets to the standard size.
        if window.frame.width < House.Layout.chatMinWidth || window.frame.height < House.Layout.chatMinHeight {
            window.setContentSize(size)
            window.center()
        }
        return window
    }

    /// A frame saved on a display that is gone comes back on the main one.
    private func keepOnScreen(_ window: NSWindow) {
        let frame = window.frame
        guard !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }),
              let visible = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame
        else { return }
        window.setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2))
    }

    // MARK: - NSWindowDelegate

    func windowDidEnterFullScreen(_ notification: Notification) {
        model.isWindowFullScreen = true
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        model.isWindowFullScreen = false
    }

    func windowWillClose(_ notification: Notification) {
        model.isCommandHeld = false
        model.isWindowVisible = false
        model.closeActions()
    }
}

/// The Sessions window. Takes its keys before the text views and menus do
/// (`SessionsWindowKeys`): ⌃⌘S the list, ⌘F find, ⌘K actions, ⌘J ask,
/// ⌘1…⌘9 rows, and esc, ↩, ↑, ↓ while a layer wants them. Marked text (an
/// input method composing, as with pinyin) keeps its own keys.
final class SessionsWindow: NSWindow {
    weak var model: SessionsWindowModel?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !hasMarkedText, let model,
           let command = SessionsWindowKeys.command(
               characters: event.charactersIgnoringModifiers ?? "",
               modifiers: Self.modifiers(of: event)
           ) {
            if command == .close {
                performClose(nil)
                return true
            }
            if model.handle(command) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            model?.isCommandHeld = Self.modifiers(of: event) == .command
        case .keyDown:
            if !hasMarkedText, let model,
               let command = SessionsWindowKeys.plainKey(keyCode: event.keyCode, modifiers: Self.modifiers(of: event)),
               model.handle(command) {
                return
            }
        default:
            break
        }
        super.sendEvent(event)
    }

    private var hasMarkedText: Bool {
        (firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false
    }

    static func modifiers(of event: NSEvent) -> SessionsWindowKeys.Modifiers {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: SessionsWindowKeys.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        return modifiers
    }
}
