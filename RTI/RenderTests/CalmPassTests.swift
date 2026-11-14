import AppKit
import SwiftUI
import XCTest

/// The 2026-11-14 calm pass: rules that are not pixels.
@MainActor
final class CalmPassTests: XCTestCase {
    /// A follow-up queued during a turn is sent only when that turn finished
    /// its answer. A new turn starts as not completed, so Esc, Stop, a
    /// failure or a screen-policy cancel never count as finished.
    func testANewTurnStartsNotCompleted() {
        let llm = LLMController.shared
        let wasStreaming = llm.streaming
        defer { llm.streaming = wasStreaming }
        llm.streaming = false
        llm.lastTurnCompleted = true
        llm.streaming = true
        XCTAssertFalse(llm.lastTurnCompleted)
        llm.streaming = false
        XCTAssertFalse(llm.lastTurnCompleted, "ending without finishing the answer is not completed")
    }

    func testGuideSectionCountsAreWords() {
        XCTAssertEqual(GuideSectionSummary.text(["Answered", "Answered", "Lightly covered", "Pending"]),
                       "2 answered · 1 thin · 1 to ask")
        XCTAssertEqual(GuideSectionSummary.text([]), "")
    }

    func testSidebarIsIconsOnlyBesideAnotherListOrWhenNarrow() {
        XCTAssertFalse(WorkspaceSidebarSettings.isCompact(page: .live, windowWidth: 1200))
        XCTAssertTrue(WorkspaceSidebarSettings.isCompact(page: .live, windowWidth: 800))
        for page in [WorkspaceModel.Page.sessions, .chats, .settings] {
            XCTAssertTrue(WorkspaceSidebarSettings.isCompact(page: page, windowWidth: 1400))
        }
    }
}

/// Keyboard ownership with the Live views kept in their own hosting views
/// (2026-11-15 SwiftUI review): a hidden composer must never hold or take
/// the keyboard.
@MainActor
final class HiddenComposerFocusTests: RenderProofTestCase {
    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override func constrainFrameRect(_ frameRect: NSRect, to _: NSScreen?) -> NSRect { frameRect }
    }

    private func composers(in view: NSView) -> [NSTextView] {
        var found: [NSTextView] = []
        if let text = view as? NSTextView, String(describing: type(of: text)).contains("RoutingTextView") { found.append(text) }
        for sub in view.subviews { found += composers(in: sub) }
        return found
    }

    private func settle(_ window: NSWindow) {
        for _ in 0 ..< 4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    func testSwitchingAwayFromAssistTakesTheKeyboardFromItsComposer() throws {
        let panel = KeyPanel(contentRect: NSRect(x: -20000, y: -20000, width: 1080, height: 720),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: OverlayPanelView(callTypes: CallTypeStore.inMemory())
            .environment(\.isWorkspaceEmbedded, true))
        panel.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        panel.orderBack(nil)
        defer {
            panel.orderOut(nil)
            panel.close()
            LiveTabState.shared.selected = .assist
        }
        LiveTabState.shared.selected = .assist
        settle(panel)
        let composer = try XCTUnwrap(composers(in: XCTUnwrap(panel.contentView)).first, "the Assist composer")
        XCTAssertTrue(panel.makeFirstResponder(composer))
        XCTAssertTrue(panel.firstResponder === composer)

        LiveTabState.shared.selected = .transcript
        settle(panel)
        XCTAssertFalse(panel.firstResponder === composer, "the hidden composer kept the keyboard")
        XCTAssertFalse(composer.isEditable, "the hidden composer still takes text")

        LiveTabState.shared.selected = .assist
        settle(panel)
        XCTAssertTrue(composer.isEditable, "back on Assist the composer takes text again")
    }
}
