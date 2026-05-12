import AppKit
import SwiftUI

/// Shared NSPanel-setup invariants for every RTI floating panel.
/// Centralises the sharing-type / level / chrome flags so the
/// "invisibility" guarantee can't drift between the built-in panels
/// (`FloatingPanelWindowController`) and the user-spawned ones
/// (`UserPanelWindowController`). Any new panel kind should route
/// through `apply(to:)` so a single audit point covers them all.
@MainActor
enum RTIPanelDefaults {

    /// Apply the shared chrome flags. The caller still owns the panel
    /// (so subclasses of NSPanel like `EscapeAwareNSPanel` keep working)
    /// and supplies the SwiftUI root view.
    static func apply(to panel: NSPanel, rootView: AnyView) {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: rootView)
    }

    /// Fade-in animation used by every RTI floating panel.
    static func fadeIn(_ window: NSWindow) {
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            window.animator().alphaValue = 1
        }
    }

    /// Fade-out + orderOut. Caller passes the window (alphaValue reset to
    /// 1 after orderOut so a subsequent `fadeIn` starts from the same state).
    static func fadeOut(_ window: NSWindow, duration: Double = 0.15) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            window.animator().alphaValue = 0
        }, completionHandler: { [window] in
            window.orderOut(nil)
            window.alphaValue = 1
        })
    }

    /// Persist a panel's frame under a UserDefaults key. Debounced by
    /// caller (FloatingPanelWindowController uses a 0.2s DispatchWorkItem;
    /// UserPanelWindowController writes directly on each notification).
    static func saveFrame(_ frame: NSRect, key: String) {
        let dict: [String: CGFloat] = ["x": frame.origin.x, "y": frame.origin.y, "w": frame.width, "h": frame.height]
        UserDefaults.standard.set(dict, forKey: key)
    }

    /// Load a previously-persisted frame, rejecting any rect that no
    /// longer intersects a visible screen (e.g. external monitor
    /// disconnected since last launch).
    static func loadFrame(key: String) -> NSRect? {
        guard let dict = UserDefaults.standard.dictionary(forKey: key) as? [String: CGFloat],
              let x = dict["x"], let y = dict["y"], let w = dict["w"], let h = dict["h"] else { return nil }
        let frame = NSRect(x: x, y: y, width: w, height: h)
        guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return nil }
        return frame
    }
}
