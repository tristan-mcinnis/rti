import Foundation

// What `esc` does in the RTI overlay window (design-system
// docs/chat-surfaces.md section 3 "Keys"; RTI plan section 2).
//
// `esc` pops one layer at a time and never hides the window: a stray `esc`
// in the middle of a meeting must not hide the cockpit. Hiding stays on
// ⌘W, the close button, and the global ⌘\ key.

/// What the overlay knows at the moment `esc` is pressed.
public struct OverlayEscapeState: Equatable, Sendable {
    /// An input method (pinyin, for one) is composing. The composition owns
    /// `esc` until it commits.
    public var hasMarkedText: Bool
    /// A floating layer is open over the composer: a chooser or the ⌘K
    /// palette.
    public var isLayerOpen: Bool
    /// The find bar is open over the thread.
    public var isFindOpen: Bool
    /// An answer is streaming.
    public var isStreaming: Bool
    /// The composer has focus and holds typed text.
    public var hasTypedText: Bool

    public init(
        hasMarkedText: Bool = false,
        isLayerOpen: Bool = false,
        isFindOpen: Bool = false,
        isStreaming: Bool = false,
        hasTypedText: Bool = false
    ) {
        self.hasMarkedText = hasMarkedText
        self.isLayerOpen = isLayerOpen
        self.isFindOpen = isFindOpen
        self.isStreaming = isStreaming
        self.hasTypedText = hasTypedText
    }
}

/// The one thing `esc` does. There is deliberately no "hide the window".
public enum OverlayEscapeAction: Equatable, Sendable {
    /// Leave the key to the input method.
    case passToInputMethod
    /// Close the open chooser or palette.
    case closeLayer
    /// Close the find bar.
    case closeFind
    /// Stop the answer. What arrived stays as the answer; a queued draft
    /// stays in the composer.
    case stopStream
    /// Clear the composer's typed text.
    case clearText
    /// Nothing is open: the key does nothing.
    case nothing

    /// True when the overlay acts on the key and no one else should see it.
    public var handlesKey: Bool {
        switch self {
        case .passToInputMethod, .nothing: false
        case .closeLayer, .closeFind, .stopStream, .clearText: true
        }
    }
}

/// The house order: input method, then a layer, then the find bar, then the
/// stream, then typed text, then nothing.
public enum OverlayEscapeOrder {
    public static func action(for state: OverlayEscapeState) -> OverlayEscapeAction {
        if state.hasMarkedText { return .passToInputMethod }
        if state.isLayerOpen { return .closeLayer }
        if state.isFindOpen { return .closeFind }
        if state.isStreaming { return .stopStream }
        if state.hasTypedText { return .clearText }
        return .nothing
    }
}
