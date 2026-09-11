import Foundation
import Observation

/// Shared state for the overlay composer (`AssistantInputView`). A singleton
/// so it survives view rebuilds and so commands, menus, and the window can
/// reach the composer without holding the view.
///
/// - `mode`: note mode. Toggled by `⌘⌥N`, `/note`, the `⌘K` palette, and
///   Add Context; while it is on, `↩` inserts a note (into the transcript
///   during a session, the prep note before one) instead of asking.
/// - `focusRequest`: bump it to put the keys in the composer field (the
///   house `FocusRequest` pattern; the window posts `rtiOverlayDidBecomeKey`
///   and the composer bumps it too).
/// - `paletteRequest`: bump it to open the `⌘K` action palette from outside
///   the field (a menu item, a header button).
/// - `lastQuestion`: the last question typed and sent, which `↑` in an empty
///   field puts back. Memory only, like the chat.
@Observable @MainActor
final class OverlayInputState {
    enum Mode {
        case chat
        case liveNote
    }

    static let shared = OverlayInputState()

    var mode: Mode = .chat

    var isNoteMode: Bool { mode != .chat }

    var lastQuestion: String?

    private(set) var focusRequest = 0
    private(set) var paletteRequest = 0

    func requestFocus() { focusRequest &+= 1 }

    func requestPalette() { paletteRequest &+= 1 }

    private init() {}
}
