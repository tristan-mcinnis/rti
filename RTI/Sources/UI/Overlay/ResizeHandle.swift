import SwiftUI
import AppKit

/// A small bottom-right resize grip for the borderless overlay panel.
/// Dragging it resizes the window from the bottom-right corner while
/// keeping the top-left origin fixed.
struct ResizeHandle: View {
    var body: some View {
        ResizeHandleView()
            .frame(width: 20, height: 20)
            .overlay(alignment: .bottomTrailing) {
                ResizeGripVisual()
                    .padding([.bottom, .trailing], 4)
            }
    }
}

// MARK: - Visual grip

private struct ResizeGripVisual: View {
    var body: some View {
        VStack(alignment: .trailing, spacing: 1.5) {
            HStack(spacing: 1.5) {
                Spacer()
                Circle().frame(width: 2, height: 2)
            }
            HStack(spacing: 1.5) {
                Spacer()
                Circle().frame(width: 2, height: 2)
                Circle().frame(width: 2, height: 2)
            }
            HStack(spacing: 1.5) {
                Spacer()
                Circle().frame(width: 2, height: 2)
                Circle().frame(width: 2, height: 2)
                Circle().frame(width: 2, height: 2)
            }
        }
        .foregroundColor(.white.opacity(0.25))
    }
}

// MARK: - Mouse-tracking NSView

private struct ResizeHandleView: NSViewRepresentable {
    func makeNSView(context: Context) -> ResizeHandleNSView {
        ResizeHandleNSView()
    }

    func updateNSView(_ nsView: ResizeHandleNSView, context: Context) {}
}

private final class ResizeHandleNSView: NSView {
    private var initialMouseLocation: NSPoint = .zero
    private var initialWindowFrame: NSRect = .zero

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: NSCursor.crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        initialMouseLocation = NSEvent.mouseLocation
        initialWindowFrame = window.frame
        // The clear-background panel has no fixed content shape, so AppKit
        // recomputes the window shadow mask on every setFrame during the drag.
        // Suppress it for the duration of the live resize; restored on mouseUp.
        window.hasShadow = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let currentLocation = NSEvent.mouseLocation
        let deltaX = currentLocation.x - initialMouseLocation.x
        let deltaY = initialMouseLocation.y - currentLocation.y

        var newWidth = initialWindowFrame.width + deltaX
        var newHeight = initialWindowFrame.height + deltaY

        newWidth = max(OverlayAppearanceDefaults.widthRange.lowerBound,
                       min(OverlayAppearanceDefaults.widthRange.upperBound, newWidth))
        newHeight = max(OverlayAppearanceDefaults.heightRange.lowerBound,
                        min(OverlayAppearanceDefaults.heightRange.upperBound, newHeight))

        // Anchor to top-left: keep origin.x and maxY stable.
        let newOriginY = initialWindowFrame.maxY - newHeight
        let newFrame = NSRect(
            x: initialWindowFrame.origin.x,
            y: newOriginY,
            width: newWidth,
            height: newHeight
        )

        // display: false — don't force a synchronous full-tree SwiftUI relayout
        // on every drag event. AppKit coalesces the redraw on the next run-loop
        // tick instead, which is what makes the live resize feel smooth.
        window.setFrame(newFrame, display: false)
    }

    override func mouseUp(with event: NSEvent) {
        guard let window else { return }
        // Restore the shadow suppressed in mouseDown and do one final synchronous
        // display pass so the panel settles cleanly at its new size.
        window.hasShadow = true
        window.invalidateShadow()
        window.displayIfNeeded()

        let frame = window.frame

        // Sync size defaults so Settings sliders reflect the new size.
        UserDefaults.standard.set(frame.width, forKey: OverlayAppearanceDefaults.widthKey)
        UserDefaults.standard.set(frame.height, forKey: OverlayAppearanceDefaults.heightKey)

        // Persist full frame.
        let dict: [String: CGFloat] = [
            "x": frame.origin.x,
            "y": frame.origin.y,
            "w": frame.width,
            "h": frame.height
        ]
        UserDefaults.standard.set(dict, forKey: "rti.overlay.savedFrame")

        // Notify other listeners (e.g. Settings UI) that the overlay size changed.
        NotificationCenter.default.post(name: .rtiOverlaySizeChanged, object: nil)
    }
}
