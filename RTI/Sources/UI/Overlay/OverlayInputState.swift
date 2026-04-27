import Foundation

/// Shared mode flag for the overlay input bar. Set by `PromptActionRow` (the
/// Note button) and read by `AssistantInputView` so hitting Enter inserts an
/// inline note into the transcript instead of sending to the LLM. Lives as a
/// singleton because the two views are siblings and don't have a parent that
/// can hoist the state for them.
@MainActor
final class OverlayInputState: ObservableObject {
    static let shared = OverlayInputState()

    @Published var isNoteMode: Bool = false

    private init() {}
}
