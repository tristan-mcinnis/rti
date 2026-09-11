import Foundation

// The rules behind RTI's menu bar (RTI plan section 2; chat-surfaces.md
// section 7 "Menu bar"): which item acts, and what it is called, for the
// window that is key. Pure values, so the rules are tested without AppKit,
// as Quick Launch's `AIChatMenu.validateMenuItem` is.
//
// Keys: RTI keeps ⌘\ as its global show and hide. The house key for a
// window's list is ⌃⌘S (the macOS sidebar key), in the Sessions window too.

/// Which RTI window is key.
public enum RTIWindowKind: String, Sendable {
    /// The overlay: the live cockpit and Assist chat.
    case overlay
    /// The Sessions window (the archive reader).
    case sessions
    /// The settings window.
    case settings
    /// Any other titled window (onboarding, the brief, the About panel).
    case other
    /// No window of RTI's is key.
    case none

    /// The raw value an RTI window carries as its `NSWindow.identifier`.
    public var windowIdentifier: String { "rti.window.\(rawValue)" }

    /// The kind for a window's identifier; `other` for an unknown one.
    public init(windowIdentifier: String?) {
        switch windowIdentifier {
        case RTIWindowKind.overlay.windowIdentifier: self = .overlay
        case RTIWindowKind.sessions.windowIdentifier: self = .sessions
        case RTIWindowKind.settings.windowIdentifier: self = .settings
        default: self = .other
        }
    }
}

/// The overlay tabs in their fixed order, which is also their ⌘1…⌘7 keys.
/// The raw values are `OverlayTab`'s.
public enum OverlayTabShortcut {
    public static let order = ["setup", "assist", "auto", "transcript", "notes", "guide", "findings"]

    /// The ⌘ digit for a tab, 1 to 7, or nil for an unknown tab. Fixed
    /// whether or not an opt-in tab is showing, so the keys never shift.
    public static func number(forTab rawValue: String) -> Int? {
        order.firstIndex(of: rawValue).map { $0 + 1 }
    }
}

/// What the menu needs to know right now.
public struct MainMenuContext: Equatable, Sendable {
    public var keyWindow: RTIWindowKind
    public var phase: OverlayLivePhase
    public var isNoteMode: Bool
    public var isMicMuted: Bool
    public var isKeptOnTop: Bool
    /// The Sessions window's list is showing.
    public var isSessionListVisible: Bool
    /// Raw values of the overlay tabs now showing (Prepare always is).
    public var visibleTabs: Set<String>

    public init(
        keyWindow: RTIWindowKind = .none,
        phase: OverlayLivePhase = .idle,
        isNoteMode: Bool = false,
        isMicMuted: Bool = false,
        isKeptOnTop: Bool = false,
        isSessionListVisible: Bool = false,
        visibleTabs: Set<String> = ["setup", "assist", "transcript", "notes"]
    ) {
        self.keyWindow = keyWindow
        self.phase = phase
        self.isNoteMode = isNoteMode
        self.isMicMuted = isMicMuted
        self.isKeptOnTop = isKeptOnTop
        self.isSessionListVisible = isSessionListVisible
        self.visibleTabs = visibleTabs
    }
}

/// Every item RTI adds to the menu bar. The standard ones SwiftUI keeps
/// (Undo, Cut, Copy, Paste, Select All, Hide, Quit, Minimize, Zoom) are
/// not listed.
public enum MainMenuItem: Hashable, Sendable {
    // RTI
    case about, settings, checkForUpdates
    // Edit
    case find
    // Session
    case record, pause, addNote, muteMicrophone, readScreen, chooseProject
    // View
    case tab(String)
    case sessionList
    // Window
    case keepOnTop, close, showOverlay, showSessions
}

public enum MainMenuValidation {
    /// Whether `item` acts in `context`. A disabled item leaves its key to
    /// the window, so the Sessions window can take ⌘1…⌘9 for its rows.
    public static func isEnabled(_ item: MainMenuItem, in context: MainMenuContext) -> Bool {
        switch item {
        case .about, .settings, .checkForUpdates, .showOverlay, .showSessions:
            return true
        case .find:
            return context.keyWindow == .overlay || context.keyWindow == .sessions
        case .record:
            return context.phase != .finishing
        case .pause:
            return context.phase.isLive
        case .addNote, .muteMicrophone, .readScreen, .chooseProject:
            return true
        case let .tab(rawValue):
            guard context.keyWindow == .overlay, OverlayTabShortcut.number(forTab: rawValue) != nil else { return false }
            return rawValue == "setup" || context.visibleTabs.contains(rawValue)
        case .sessionList:
            return context.keyWindow == .sessions
        case .keepOnTop:
            return context.keyWindow == .overlay
        case .close:
            return context.keyWindow != .none
        }
    }

    /// The item's title in `context`. Tabs take their names from
    /// `OverlayTab`; this returns the raw value for them.
    public static func title(_ item: MainMenuItem, in context: MainMenuContext) -> String {
        switch item {
        case .about: return "About RTI"
        case .settings: return "Settings…"
        case .checkForUpdates: return "Check for Updates…"
        case .find:
            switch context.keyWindow {
            case .overlay: return "Find in Chat"
            case .sessions: return "Find in Session"
            default: return "Find"
            }
        case .record:
            return context.phase.isLive ? "Finish Recording" : "Start Recording"
        case .pause:
            return context.phase == .paused ? "Resume Recording" : "Pause Recording"
        case .addNote:
            return context.isNoteMode ? "End Note" : "Add Note"
        case .muteMicrophone: return "Mute Microphone"
        case .readScreen: return "Read Screen"
        case .chooseProject: return "Choose Project…"
        case let .tab(rawValue): return rawValue
        case .sessionList:
            return context.isSessionListVisible ? "Hide Session List" : "Show Session List"
        case .keepOnTop: return "Keep on Top"
        case .close: return "Close"
        case .showOverlay: return "RTI"
        case .showSessions: return "Sessions"
        }
    }

    /// Whether a toggle item shows a check mark.
    public static func isChecked(_ item: MainMenuItem, in context: MainMenuContext) -> Bool {
        switch item {
        case .muteMicrophone: return context.isMicMuted
        case .keepOnTop: return context.isKeptOnTop
        default: return false
        }
    }
}
