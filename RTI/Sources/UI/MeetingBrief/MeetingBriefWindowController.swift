import AppKit
import SwiftUI

/// Owns the single Meeting Brief window, in the AI Chat window's chrome
/// (chat-surfaces.md section 7): a transparent title bar whose row the
/// header shares, an opaque `surface` ground, `Layout.chatWidth` ×
/// `chatHeight` (at least `chatMinWidth` × `chatMinHeight`), the frame
/// kept between launches. RTI is always a regular app, so none of Quick
/// Launch's activation-policy switching comes with it.
@MainActor
final class MeetingBriefWindowController {
    static let autosaveName = "rti.meetingbrief"
    static let standardSize = NSSize(width: House.Layout.chatWidth, height: House.Layout.chatHeight)
    static let minimumSize = NSSize(width: House.Layout.chatMinWidth, height: House.Layout.chatMinHeight)

    private var window: NSWindow?
    private let model = MeetingBriefModel()

    /// Bring the window forward, reloading the list from the vault.
    func show() {
        model.reload()
        RTIActivation.bringToFront(window ?? makeWindow())
    }

    /// Bring the window forward on the brief at `url` (the Prepare tab's
    /// "Brief" link), with the list hidden.
    func show(brief url: URL) {
        model.reload()
        model.open(url: url)
        model.isRailVisible = false
        RTIActivation.bringToFront(window ?? makeWindow())
    }

    private func makeWindow() -> NSWindow {
        let window = MeetingBriefWindow(
            contentRect: NSRect(origin: .zero, size: Self.standardSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.model = model
        window.title = "Meeting Brief"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An empty unified toolbar makes the title-bar row as tall as the
        // header, so the traffic lights centre on the header's row.
        window.toolbar = NSToolbar(identifier: "MeetingBriefWindow")
        window.toolbarStyle = .unified
        // Selecting text in a brief must not drag the window; the header
        // carries the drag.
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenPrimary]
        window.contentMinSize = Self.minimumSize
        window.backgroundColor = House.NSColorToken.surface

        let hosting = NSHostingController(rootView: MeetingBriefView(model: model))
        // The window sizes the view: the frame is the user's, from the
        // minimum up.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(Self.standardSize)

        if !window.setFrameUsingName(Self.autosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.autosaveName)
        // A frame saved smaller than today's minimum, or off every screen,
        // comes back at the standard size, centred.
        let content = window.contentRect(forFrameRect: window.frame).size
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame) }
        if content.width < Self.minimumSize.width || content.height < Self.minimumSize.height || !onScreen {
            window.setContentSize(Self.standardSize)
            window.center()
        }

        self.window = window
        return window
    }
}

/// `esc` pops one layer (the search, then the list) and never closes the
/// window; `⌘W` and the close button do that.
private final class MeetingBriefWindow: NSWindow {
    weak var model: MeetingBriefModel?

    override func cancelOperation(_ sender: Any?) {
        _ = model?.escape()
    }
}
