import Foundation
import Observation

/// Shared mode flag for the overlay input bar. Toggled from the input bar's
/// "✦" actions menu (Note mode) and read by `AssistantInputView` so hitting
/// Enter inserts an inline note into the transcript instead of sending to the
/// LLM. A singleton so the flag survives view rebuilds.
@Observable @MainActor
final class OverlayInputState {
    static let shared = OverlayInputState()

    var isNoteMode: Bool = false

    private init() {}
}
