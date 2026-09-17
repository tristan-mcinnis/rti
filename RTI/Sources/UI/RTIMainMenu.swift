import AppKit
import Observation
import RTICore
import SwiftUI

// RTI's menu bar (RTI plan section 2; chat-surfaces.md section 7 "Menu
// bar"), built with SwiftUI `.commands` on top of the menus SwiftUI already
// makes (it rebuilds `NSApp.mainMenu`, so RTI never assigns it). The rules
// for what acts and what it is called live in `MainMenuValidation`
// (RTICore); this file only draws them and runs the registry's commands.
//
// Keys: RTI keeps ⌘\ as its global show and hide (a Carbon hotkey, see
// `HotkeyCoordinator`). The house key for a window's list is ⌃⌘S, the macOS
// sidebar key, in the Sessions window too. ⌘1…⌘7 pick an overlay tab only
// while the overlay is key, so the Sessions window keeps them for its rows.

extension Notification.Name {
    /// ⌘F while the overlay is key: open the Assist thread's find bar.
    static let rtiFindInChat = Notification.Name("rti.findInChat")
    /// ⌘F while the Sessions window is key: find in the open session.
    static let rtiFindInSession = Notification.Name("rti.findInSession")
    /// ⌃⌘S while the Sessions window is key: show or hide its session list.
    static let rtiToggleSessionList = Notification.Name("rti.toggleSessionList")
}

// MARK: - Key window

/// Which RTI window is key, for the menu bar's validation. A window says
/// what it is through its `identifier` (`RTIWindowKind.windowIdentifier`).
@Observable @MainActor
final class RTIKeyWindowTracker {
    static let shared = RTIKeyWindowTracker()

    private(set) var keyWindow: RTIWindowKind = .none
    /// The Sessions window reports whether its list is showing, so the View
    /// menu can say Show or Hide.
    var isSessionListVisible = false

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        let names = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
        ]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { RTIKeyWindowTracker.shared.refresh() }
            })
        }
        refresh()
    }

    func refresh() {
        keyWindow = Self.kind(of: NSApp?.keyWindow)
    }

    static func kind(of window: NSWindow?) -> RTIWindowKind {
        guard let window else { return .none }
        return RTIWindowKind(windowIdentifier: window.identifier?.rawValue)
    }
}

/// Runs a registry command from a menu item, as the palette and the status
/// item do, so every surface shares one behaviour per command.
@MainActor
enum RTIMenuAction {
    static func run(_ id: String) {
        guard let command = CommandRegistry.shared.commands.first(where: { $0.id == id }) else { return }
        command.perform()
        CommandRegistry.shared.recordExecution(id)
    }
}

/// The menu context now, from the live state.
@MainActor
private func currentMenuContext(visibleTabs: [OverlayTab] = []) -> MainMenuContext {
    let session = SessionCoordinator.shared
    return MainMenuContext(
        keyWindow: RTIKeyWindowTracker.shared.keyWindow,
        phase: session.phase.livePhase,
        isNoteMode: OverlayInputState.shared.isNoteMode,
        isMicMuted: session.micMuted,
        isKeptOnTop: OverlayWindowChrome.shared.isKeptOnTop,
        isSessionListVisible: RTIKeyWindowTracker.shared.isSessionListVisible,
        visibleTabs: Set(visibleTabs.map(\.rawValue))
    )
}

// MARK: - Commands

/// Every group RTI adds or replaces. The standard items SwiftUI keeps:
/// Hide, Hide Others, Quit (with RTI's recording guard), Undo, Redo, Cut,
/// Copy, Paste, Select All, Minimize, Zoom, Enter Full Screen.
struct RTIMainMenuCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) { AppInfoMenuItems() }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { WindowCoordinator.shared.openSettings() }
                .keyboardShortcut(",", modifiers: .command)
        }
        // Find in Chat or Find in Session, in place of the text-view Find
        // submenu (the house surfaces draw their own find bar).
        CommandGroup(replacing: .textEditing) { FindMenuItem() }
        CommandMenu("Session") { SessionMenuItems() }
        // The overlay's toolbar is an empty spacer for the title-bar row;
        // its Show and Customize items would only break the header's row.
        CommandGroup(replacing: .toolbar) { ViewMenuItems() }
        CommandGroup(after: .windowSize) { WindowMenuItems() }
        CommandGroup(after: .windowArrangement) { WindowListMenuItems() }
    }
}

// MARK: - RTI menu

private struct AppInfoMenuItems: View {
    var body: some View {
        Button("About RTI") { WindowCoordinator.shared.showAbout() }
        Button("Check for Updates…") { UpdateChecker.checkAndReport() }
    }
}

// MARK: - Edit menu

private struct FindMenuItem: View {
    private let tracker = RTIKeyWindowTracker.shared

    var body: some View {
        let context = currentMenuContext()
        Button(MainMenuValidation.title(.find, in: context)) {
            switch tracker.keyWindow {
            case .overlay: NotificationCenter.default.post(name: .rtiFindInChat, object: nil)
            case .sessions: NotificationCenter.default.post(name: .rtiFindInSession, object: nil)
            default: break
            }
        }
        .keyboardShortcut("f", modifiers: .command)
        .disabled(!MainMenuValidation.isEnabled(.find, in: context))
    }
}

// MARK: - Session menu

/// Recording and capture. These act from any window: they drive the one
/// recording. Where a global hotkey holds the same chord, the hotkey fires
/// first; the menu shows the key either way.
private struct SessionMenuItems: View {
    var body: some View {
        let context = currentMenuContext()
        Button(MainMenuValidation.title(.record, in: context)) { RTIMenuAction.run("session.start") }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!MainMenuValidation.isEnabled(.record, in: context))
        Button(MainMenuValidation.title(.pause, in: context)) { RTIMenuAction.run("session.pause") }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(!MainMenuValidation.isEnabled(.pause, in: context))
        Divider()
        Button(MainMenuValidation.title(.addNote, in: context)) { RTIMenuAction.run("note.toggle") }
            .keyboardShortcut("n", modifiers: [.command, .option])
        Toggle(
            MainMenuValidation.title(.muteMicrophone, in: context),
            isOn: Binding(
                get: { MainMenuValidation.isChecked(.muteMicrophone, in: currentMenuContext()) },
                set: { _ in RTIMenuAction.run("mic.mute.toggle") }
            )
        )
        Button(MainMenuValidation.title(.readScreen, in: context)) { RTIMenuAction.run("capture.screen") }
            .keyboardShortcut("h", modifiers: [.command, .shift])
        Button(MainMenuValidation.title(.readWindow, in: context)) { RTIMenuAction.run("capture.window") }
            .keyboardShortcut("j", modifiers: [.command, .shift])
        Divider()
        Button(MainMenuValidation.title(.chooseProject, in: context)) { RTIMenuAction.run("meeting.project") }
    }
}

// MARK: - View menu

private struct ViewMenuItems: View {
    // The opt-in tabs follow Prepare's toggles.
    @AppStorage(AnalysisSettingsDefaults.notesEnabledKey) private var notesEnabled = AnalysisSettingsDefaults.defaultNotesEnabled
    @AppStorage(AnalysisSettingsDefaults.guideEnabledKey) private var guideEnabled = AnalysisSettingsDefaults.defaultGuideEnabled
    @AppStorage(AnalysisSettingsDefaults.findingsEnabledKey) private var findingsEnabled = AnalysisSettingsDefaults.defaultFindingsEnabled
    @AppStorage(AnalysisSettingsDefaults.autoAssistEnabledKey) private var autoAssistEnabled = AnalysisSettingsDefaults.defaultAutoAssistEnabled

    var body: some View {
        let tabs = OverlayTab.visibleTabs(notes: notesEnabled, guide: guideEnabled, findings: findingsEnabled, auto: autoAssistEnabled)
        let context = currentMenuContext(visibleTabs: tabs)
        ForEach(OverlayTab.allCases) { tab in
            Button(tab.title) {
                NotificationCenter.default.post(name: .rtiSelectTab, object: tab.rawValue)
            }
            .keyboardShortcut(KeyEquivalent(Character(String(tab.shortcutNumber))), modifiers: .command)
            .disabled(!MainMenuValidation.isEnabled(.tab(tab.rawValue), in: context))
        }
        Divider()
        Button(MainMenuValidation.title(.sessionList, in: context)) {
            NotificationCenter.default.post(name: .rtiToggleSessionList, object: nil)
        }
        .keyboardShortcut("s", modifiers: [.control, .command])
        .disabled(!MainMenuValidation.isEnabled(.sessionList, in: context))
    }
}

// MARK: - Window menu

private struct WindowMenuItems: View {
    var body: some View {
        let context = currentMenuContext()
        Toggle(
            MainMenuValidation.title(.keepOnTop, in: context),
            isOn: Binding(
                get: { OverlayWindowChrome.shared.isKeptOnTop },
                set: { OverlayWindowChrome.shared.isKeptOnTop = $0 }
            )
        )
        .disabled(!MainMenuValidation.isEnabled(.keepOnTop, in: context))
        Button(MainMenuValidation.title(.close, in: context)) { NSApp.keyWindow?.performClose(nil) }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(!MainMenuValidation.isEnabled(.close, in: context))
    }
}

/// The two RTI windows by name, so each opens even while it is hidden. The
/// overlay keeps itself out of the automatic window list (one entry, not
/// two). ⌘\ is shown for the overlay; the global hotkey owns the chord.
private struct WindowListMenuItems: View {
    var body: some View {
        Divider()
        Button(MainMenuValidation.title(.showOverlay, in: currentMenuContext())) {
            WindowCoordinator.shared.showOverlay()
        }
        .keyboardShortcut("\\", modifiers: .command)
        Button(MainMenuValidation.title(.showSessions, in: currentMenuContext())) {
            RTIMenuAction.run("view.sessions")
        }
    }
}
