import RTICore
import XCTest

/// Pins the menu-bar rules: items act against the key window, titles follow
/// the session, and the list key is ⌃⌘S territory (never ⌘\, which stays
/// RTI's global show and hide).
final class MenuValidationTests: XCTestCase {
    private func context(_ key: RTIWindowKind, phase: OverlayLivePhase = .idle) -> MainMenuContext {
        MainMenuContext(keyWindow: key, phase: phase)
    }

    // MARK: App and window items

    func test_appItemsAlwaysAct() {
        for key in [RTIWindowKind.overlay, .sessions, .settings, .other, .none] {
            for item in [MainMenuItem.about, .settings, .checkForUpdates, .showOverlay, .showSessions] {
                XCTAssertTrue(MainMenuValidation.isEnabled(item, in: context(key)), "\(item) with \(key) key")
            }
        }
    }

    func test_closeNeedsAKeyWindow() {
        XCTAssertFalse(MainMenuValidation.isEnabled(.close, in: context(.none)))
        for key in [RTIWindowKind.overlay, .sessions, .settings, .other] {
            XCTAssertTrue(MainMenuValidation.isEnabled(.close, in: context(key)), "close with \(key) key")
        }
    }

    func test_keepOnTopActsOnlyOnTheOverlay_andShowsItsState() {
        XCTAssertTrue(MainMenuValidation.isEnabled(.keepOnTop, in: context(.overlay)))
        XCTAssertFalse(MainMenuValidation.isEnabled(.keepOnTop, in: context(.sessions)))

        var ctx = context(.overlay)
        XCTAssertFalse(MainMenuValidation.isChecked(.keepOnTop, in: ctx))
        ctx.isKeptOnTop = true
        XCTAssertTrue(MainMenuValidation.isChecked(.keepOnTop, in: ctx))
    }

    // MARK: Find

    func test_findFollowsTheKeyWindow() {
        XCTAssertEqual(MainMenuValidation.title(.find, in: context(.overlay)), "Find in Chat")
        XCTAssertEqual(MainMenuValidation.title(.find, in: context(.sessions)), "Find in Session")
        XCTAssertTrue(MainMenuValidation.isEnabled(.find, in: context(.overlay)))
        XCTAssertTrue(MainMenuValidation.isEnabled(.find, in: context(.sessions)))
        XCTAssertFalse(MainMenuValidation.isEnabled(.find, in: context(.settings)))
        XCTAssertFalse(MainMenuValidation.isEnabled(.find, in: context(.none)))
    }

    // MARK: Session

    func test_recordTitleAndState() {
        XCTAssertEqual(MainMenuValidation.title(.record, in: context(.none, phase: .idle)), "Start Recording")
        XCTAssertEqual(MainMenuValidation.title(.record, in: context(.none, phase: .recording)), "Finish Recording")
        XCTAssertEqual(MainMenuValidation.title(.record, in: context(.none, phase: .paused)), "Finish Recording")
        XCTAssertEqual(MainMenuValidation.title(.record, in: context(.none, phase: .done)), "Start Recording")
        XCTAssertFalse(MainMenuValidation.isEnabled(.record, in: context(.none, phase: .finishing)))
        // The session items act from any window: they drive the recording.
        XCTAssertTrue(MainMenuValidation.isEnabled(.record, in: context(.none, phase: .idle)))
        XCTAssertTrue(MainMenuValidation.isEnabled(.record, in: context(.settings, phase: .recording)))
    }

    func test_pauseActsOnlyWhileLive() {
        for phase in OverlayLivePhase.allCases {
            XCTAssertEqual(MainMenuValidation.isEnabled(.pause, in: context(.overlay, phase: phase)), phase.isLive, "\(phase)")
        }
        XCTAssertEqual(MainMenuValidation.title(.pause, in: context(.overlay, phase: .recording)), "Pause Recording")
        XCTAssertEqual(MainMenuValidation.title(.pause, in: context(.overlay, phase: .paused)), "Resume Recording")
    }

    func test_noteAndMuteTitles() {
        var ctx = context(.overlay)
        XCTAssertEqual(MainMenuValidation.title(.addNote, in: ctx), "Add Note")
        ctx.isNoteMode = true
        XCTAssertEqual(MainMenuValidation.title(.addNote, in: ctx), "End Note")

        XCTAssertFalse(MainMenuValidation.isChecked(.muteMicrophone, in: ctx))
        ctx.isMicMuted = true
        XCTAssertTrue(MainMenuValidation.isChecked(.muteMicrophone, in: ctx))
    }

    // MARK: View

    func test_tabKeysAreFixedOneToSeven() {
        XCTAssertEqual(OverlayTabShortcut.order.count, 7)
        XCTAssertEqual(OverlayTabShortcut.number(forTab: "setup"), 1)
        XCTAssertEqual(OverlayTabShortcut.number(forTab: "assist"), 2)
        XCTAssertEqual(OverlayTabShortcut.number(forTab: "findings"), 7)
        XCTAssertNil(OverlayTabShortcut.number(forTab: "sessions"))
    }

    func test_tabItemsActOnlyOnTheOverlay_andOnlyForShowingTabs() {
        var ctx = context(.overlay)
        ctx.visibleTabs = ["assist", "transcript"]
        XCTAssertTrue(MainMenuValidation.isEnabled(.tab("assist"), in: ctx))
        XCTAssertTrue(MainMenuValidation.isEnabled(.tab("setup"), in: ctx), "Prepare is always there")
        XCTAssertFalse(MainMenuValidation.isEnabled(.tab("guide"), in: ctx), "an opt-in tab that is off")
        XCTAssertFalse(MainMenuValidation.isEnabled(.tab("unknown"), in: ctx))

        // In the Sessions window the same ⌘ digits belong to its rows.
        ctx.keyWindow = .sessions
        XCTAssertFalse(MainMenuValidation.isEnabled(.tab("assist"), in: ctx))
    }

    func test_sessionListActsOnlyInTheSessionsWindow() {
        var ctx = context(.sessions)
        XCTAssertTrue(MainMenuValidation.isEnabled(.sessionList, in: ctx))
        XCTAssertEqual(MainMenuValidation.title(.sessionList, in: ctx), "Show Session List")
        ctx.isSessionListVisible = true
        XCTAssertEqual(MainMenuValidation.title(.sessionList, in: ctx), "Hide Session List")
        XCTAssertFalse(MainMenuValidation.isEnabled(.sessionList, in: context(.overlay)))
    }

    // MARK: Window identity

    func test_windowIdentifiersRoundTrip() {
        for kind in [RTIWindowKind.overlay, .sessions, .settings] {
            XCTAssertEqual(RTIWindowKind(windowIdentifier: kind.windowIdentifier), kind)
        }
        XCTAssertEqual(RTIWindowKind(windowIdentifier: nil), .other)
        XCTAssertEqual(RTIWindowKind(windowIdentifier: "com.apple.about"), .other)
    }
}
