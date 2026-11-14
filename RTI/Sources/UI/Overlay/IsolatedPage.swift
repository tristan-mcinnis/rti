import AppKit
import SwiftUI

/// One Live view in its own `NSHostingView`, so it has its own SwiftUI graph.
/// A switch only flips `isHidden`: a hidden page is neither laid out nor
/// drawn, and an update inside one page never re-measures another.
///
/// The latency climb (2026-11-14, `TabSwitchLatencyTests`) found that keeping
/// views mounted in one ZStack made switches to Transcript and Prepare slower,
/// because every switch re-measured the hidden Markdown thread and notes.
/// Separate graphs remove that coupling.
struct IsolatedPage: NSViewRepresentable {
    let isVisible: Bool
    let content: AnyView

    func makeNSView(context _: Context) -> NSHostingView<AnyView> {
        let view = NSHostingView(rootView: content)
        // No intrinsic size: the page fills the frame it is given, and its
        // content is never measured to size the container.
        view.sizingOptions = []
        view.isHidden = !isVisible
        return view
    }

    final class Coordinator {
        var wasVisible: Bool?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ view: NSHostingView<AnyView>, context: Context) {
        // A hidden page keeps its last root; it observes its own state and
        // catches up when shown. Replacing the root while hidden would rebuild
        // it for nothing, except once, at the moment it is hidden, so the
        // page learns it is no longer active (Transcript stops projecting).
        let changed = context.coordinator.wasVisible != isVisible
        if isVisible || changed { view.rootView = content }
        context.coordinator.wasVisible = isVisible
        if view.isHidden == isVisible { view.isHidden = !isVisible }
    }
}
