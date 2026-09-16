import AppKit
import RTICore
import SwiftUI
import XCTest

/// The `⌘K` palette must own the keys from the moment it is up: typing goes
/// into its search field, and the composer must not pull them back.
///
/// The regression (2026-09-14): `⌘K` drew the palette, but the window's
/// own "became key" notification (posted one runloop turn after `⌘K`, and
/// again 50 ms after `show()`) asked the composer for the keys. That focus
/// request landed *after* the palette claimed focus, so the composer kept
/// first responder: typing landed in the draft, the palette's query stayed
/// on its placeholder, and `↑↓` did nothing.
///
/// This is the strongest seam a host-less bundle can reach: the live
/// `AssistantInputView` hosted in a real, key panel. The panel is
/// non-activating and held far off screen (`OffscreenPanel`), so it never
/// appears and never takes focus from another app.
@MainActor
final class CommandPaletteFocusProofTests: XCTestCase {
    private var window: OffscreenPanel!

    override func setUp() async throws {
        try await super.setUp()
        try RenderProofHarness.prepare()
        OverlayInputState.shared.mode = .chat
        window = makeWindow()
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        assertNoOnscreenWindow("after the panel is closed")
        window = nil
        OverlayInputState.shared.mode = .chat
        try await super.tearDown()
    }

    /// `⌘K` opens the palette and it keeps the keys, even when the overlay's
    /// become-key notification arrives right after.
    func test_paletteKeepsTheKeysWhenTheOverlayBecomesKeyJustAfterItOpens() throws {
        let composer = try mountComposer()

        try key("k", keyCode: 40, modifiers: .command)
        settle()
        XCTAssertTrue(
            isPaletteSearchField(window.firstResponder),
            "⌘K must move the keys to the palette, was \(String(describing: window.firstResponder))"
        )

        // The window's key notification arrives now, as it does in the app.
        NotificationCenter.default.post(name: .rtiOverlayDidBecomeKey, object: nil)
        settle()

        XCTAssertFalse(
            window.firstResponder === composer,
            "the composer must not take the keys back from the palette"
        )
        XCTAssertTrue(
            isPaletteSearchField(window.firstResponder),
            "first responder must stay the palette's search field, was \(String(describing: window.firstResponder))"
        )

        try type("who")
        XCTAssertEqual(composer.string, "", "nothing may land in the composer draft")
        XCTAssertEqual(
            (window.firstResponder as? NSTextView)?.string, "who",
            "typing must fill the palette's search field"
        )
    }

    /// Down Arrow then Return runs the second row. The palette is mounted on
    /// its own with three injected, harmless commands and a query that matches
    /// only them, so no registry row can take the selection and no command
    /// touches the app.
    func test_downArrowThenReturnRunsTheSecondRow() throws {
        let probe = PaletteProbe()
        let host = NSHostingView(rootView: PaletteTestHost(probe: probe))
        host.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(host)
        settle()
        assertNoOnscreenWindow("while the palette is live")

        XCTAssertTrue(
            isPaletteSearchField(window.firstResponder),
            "the palette claims the keys after it appears, was \(String(describing: window.firstResponder))"
        )

        try type("zzz")
        XCTAssertEqual(probe.query, "zzz", "typing must reach the palette's query")

        // ↓ then ↩, through the window, exactly as a user presses them.
        try specialKey(0xF701, keyCode: 125)
        try key("\r", keyCode: 36, modifiers: [])

        XCTAssertEqual(probe.ran, ["test.harmless.two"], "↓ then ↩ must run the second row")

        // ⌘K and Esc must still close while the field editor holds the keys.
        // A command chord is a key equivalent: AppKit routes it through the
        // window's key-equivalent path, not through `sendEvent` into the
        // field editor, so the test enters there.
        let handled = try keyEquivalent("k", keyCode: 40, modifiers: .command)
        XCTAssertTrue(handled, "⌘K must be handled as a key equivalent")
        XCTAssertEqual(probe.closeCount, 1, "⌘K must close the palette")
        try specialKey(0x1B, keyCode: 53)
        XCTAssertEqual(probe.closeCount, 2, "Escape must close the palette")
    }

    // MARK: - Helpers

    func test_shiftCommandAOpensAttachAndKeepsTheDraft() throws {
        let composer = try mountComposer()
        try type("Synthetic draft")
        let original = composer.string
        XCTAssertTrue(try keyEquivalent("a", keyCode: 0, modifiers: [.command, .shift]))
        settle()
        XCTAssertEqual(composer.string, original)
        // Escape closes Add Context; it must not clear the text behind it.
        try specialKey(0x1B, keyCode: 53)
        XCTAssertEqual(composer.string, original)
    }

    /// Hosts the live composer and leaves it holding the keys, as the overlay
    /// leaves it.
    private func mountComposer() throws -> NSTextView {
        let host = NSHostingView(rootView: AssistantInputView(seed: ComposerRenderSeed()))
        host.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(host)
        settle()
        assertNoOnscreenWindow("while the composer is live")

        let composer = try XCTUnwrap(composerTextView(), "the composer field is mounted")
        window.makeFirstResponder(composer)
        XCTAssertTrue(window.firstResponder === composer, "the composer starts with the keys")
        return composer
    }

    /// A far-off-screen, non-activating panel. It is never ordered front, so
    /// it is never drawn and never takes focus from another app; AppKit still
    /// gives its views a window, which is all the field focus needs.
    private func makeWindow() -> OffscreenPanel {
        let panel = OffscreenPanel(
            contentRect: NSRect(x: -20000, y: -20000, width: 620, height: 460),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.hasShadow = false
        panel.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 460))
        // The panel's initializer puts a new window on a visible screen; the
        // override above only takes effect from here on.
        panel.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        return panel
    }

    /// No window of this process is on a screen. On-screen-only CG window
    /// info is keyed by owner pid and needs no screen-recording grant.
    private func assertNoOnscreenWindow(_ context: String) {
        let onScreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let ours = onScreen.filter {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == getpid()
        }
        XCTAssertTrue(ours.isEmpty, "\(context): a test window reached the screen: \(ours)")
        if let window {
            XCTAssertFalse(
                NSScreen.screens.contains { $0.frame.intersects(window.frame) },
                "\(context): the test panel sits on a screen"
            )
        }
    }

    /// An `NSPanel` whose frame is never constrained onto a screen. AppKit
    /// moves a fully offscreen window into view when one is ordered front
    /// (its default `constrainFrameRect`), which is how an earlier version of
    /// this test put a real panel on screen at 10:34.
    private final class OffscreenPanel: NSPanel {
        override func constrainFrameRect(_ frameRect: NSRect, to _: NSScreen?) -> NSRect {
            frameRect
        }
    }

    /// A SwiftUI `TextField`'s first responder is the window's field editor,
    /// whose delegate is its `NSTextField`; the composer's own text view has
    /// no such delegate.
    private func isPaletteSearchField(_ responder: NSResponder?) -> Bool {
        (responder as? NSTextView)?.delegate is NSTextField
    }

    private func composerTextView() -> NSTextView? {
        guard let root = window.contentView else { return nil }
        return collectTextViews(in: root).first { !$0.isFieldEditor }
    }

    private func collectTextViews(in view: NSView) -> [NSTextView] {
        var found: [NSTextView] = []
        if let textView = view as? NSTextView {
            found.append(textView)
        }
        for subview in view.subviews {
            found.append(contentsOf: collectTextViews(in: subview))
        }
        return found
    }

    private func settle() {
        for _ in 0 ..< 6 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
    }

    private func type(_ text: String) throws {
        for character in text {
            try key(String(character), keyCode: 0, modifiers: [])
        }
    }

    private func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) throws {
        try send(characters, keyCode: keyCode, modifiers: modifiers)
    }

    /// A key that has no text, like Down Arrow, sent with its function-key
    /// character so AppKit and SwiftUI read it as that key.
    private func specialKey(_ scalar: UInt32, keyCode: UInt16) throws {
        let characters = String(Character(UnicodeScalar(scalar)!))
        try send(characters, keyCode: keyCode, modifiers: [])
    }

    private func send(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) throws {
        try window.sendEvent(keyEvent(characters, keyCode: keyCode, modifiers: modifiers))
        settle()
    }

    /// A command chord, entered the way `NSApplication` enters it: the key
    /// window's key-equivalent path, which reaches the palette's field.
    private func keyEquivalent(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) throws -> Bool {
        let handled = try window.performKeyEquivalent(with: keyEvent(characters, keyCode: keyCode, modifiers: modifiers))
        settle()
        return handled
    }

    private func keyEvent(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    /// Holds the palette's query binding for a test that mounts it directly.
    @MainActor
    private final class PaletteProbe {
        var query = ""
        var ran: [String] = []
        var closeCount = 0
    }

    /// Mounts `CommandPaletteView` the way the composer does, on a real
    /// `@State` query (a plain object would not drive `.onChange`), over three
    /// harmless injected commands and nothing the registry can match.
    private struct PaletteTestHost: View {
        let probe: PaletteProbe
        @State private var query = ""

        var body: some View {
            CommandPaletteView(
                query: Binding(
                    get: { query },
                    set: {
                        query = $0
                        probe.query = $0
                    }
                ),
                onRun: { probe.ran.append($0.id) },
                onClose: { probe.closeCount += 1 },
                leadingCommands: [
                    RTICommand(id: "test.harmless.one", title: "Zzz one", keywords: ["zzz"], perform: {}),
                    RTICommand(id: "test.harmless.two", title: "Zzz two", keywords: ["zzz"], perform: {}),
                    RTICommand(id: "test.harmless.three", title: "Zzz three", keywords: ["zzz"], perform: {}),
                ]
            )
            .background(House.ColorToken.surface)
        }
    }
}
