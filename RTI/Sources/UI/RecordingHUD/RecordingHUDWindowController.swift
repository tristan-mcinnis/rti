import AppKit
import SwiftUI

@MainActor
final class RecordingHUDWindowController {
    private let panel: NSPanel
    private var hideTask: Task<Void, Never>?

    init() {
        let size = NSSize(width: 230, height: 46)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.sharingType = .none
        panel.contentView = NSHostingView(rootView: RecordingHUDView())
    }

    func sync(with phase: SessionCoordinator.Phase) {
        hideTask?.cancel()
        hideTask = nil
        switch phase {
        case .idle:
            panel.orderOut(nil)
        case .recording, .paused, .finishing, .summarizing:
            positionOnActiveScreen()
            panel.orderFrontRegardless()
        case .done:
            positionOnActiveScreen()
            panel.orderFrontRegardless()
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, SessionCoordinator.shared.phase == .done else { return }
                self?.panel.orderOut(nil)
            }
        }
    }

    func setSharingInvisible(_ invisible: Bool) {
        panel.sharingType = invisible ? .none : .readOnly
    }

    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let frame = panel.frame
        panel.setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.minY + 18))
    }
}
