import AppKit

@MainActor
enum ScreenHighlightOverlay {
    private static var activeWindow: NSWindow?

    static func flash(rect: CGRect) {
        activeWindow?.orderOut(nil)

        let padded = rect.insetBy(dx: -8, dy: -6)
        let window = NSWindow(
            contentRect: padded,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hasShadow = false
        window.sharingType = .none
        window.contentView = HighlightView(frame: NSRect(origin: .zero, size: padded.size))
        window.alphaValue = 0
        window.orderFrontRegardless()
        activeWindow = window

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            window.animator().alphaValue = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard activeWindow === window else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                window.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    window.orderOut(nil)
                    if activeWindow === window {
                        activeWindow = nil
                    }
                }
            })
        }
    }
}

private final class HighlightView: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSColor.systemBlue.withAlphaComponent(0.16).setFill()
        path.fill()
        NSColor.systemBlue.withAlphaComponent(0.92).setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}
