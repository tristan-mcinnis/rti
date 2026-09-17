import Foundation

// The composer's keyboard contract, pure (design-system docs/chat-surfaces.md
// section 3 "Keys", section 4 "Keys"; RTI plan section 2 `esc`). The field's
// text view asks the router before it handles a key; the router answers from
// plain values, so the rules are tested without AppKit.
//
// Order that matters:
// - IME composition (marked text) owns every key until it commits. Return
//   that should commit a pinyin syllable must never send the draft.
// - `esc` pops one layer at a time: a chooser or the palette, then the
//   stream (a queued draft stays, unsent), then typed text, then nothing.
//   A stray `esc` mid-meeting never hides the cockpit.

/// A key the composer routes. Everything else is the text view's.
public enum ComposerKey: Equatable, Sendable {
    case returnKey
    case escape
    case tab
    /// Shift-Tab (AppKit's backtab).
    case backTab
    case upArrow
    case downArrow
    case leftArrow
    case rightArrow
    /// Backspace (delete backward).
    case backspace
    /// The K key; with `⌘` it opens the action palette.
    case k
    /// Shift-Command-A opens the composer's attachment menu.
    case a
    /// Shift-Command-S opens the same attachment menu. Quick Launch binds its
    /// capture/attach chooser to this key, so the hand reaches for it here.
    case s
    /// Any other key.
    case other
}

/// Modifier keys held with a key.
public struct ComposerKeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = ComposerKeyModifiers(rawValue: 1 << 0)
    public static let command = ComposerKeyModifiers(rawValue: 1 << 1)
    public static let option = ComposerKeyModifiers(rawValue: 1 << 2)
    public static let control = ComposerKeyModifiers(rawValue: 1 << 3)
}

/// What the composer does with a key.
public enum ComposerKeyResult: Equatable, Sendable {
    /// The text view handles it (a new line, an IME commit, the caret).
    case passThrough
    /// Taken, and nothing happens.
    case consume
    /// Send the draft (or write the note).
    case submit
    /// Hold the draft until the streaming answer ends.
    case queue
    /// Run the bound primary action (`⌘↩`).
    case runPrimary
    /// Pick the highlighted chooser row.
    case acceptChooser
    /// Move the chooser highlight by this many rows.
    case moveChooser(Int)
    /// Close the open chooser or palette.
    case closeLayer
    /// Stop the stream; a queued draft stays in the field, unsent.
    case stopStream
    /// Clear what is typed.
    case clearDraft
    /// Put back the last question typed.
    case recallLastQuestion
    /// Open or close the `⌘K` palette.
    case togglePalette
    case toggleAttachments
    /// Move the keys into the chip strip (on the newest chip).
    case enterStrip
    /// Move the strip's highlight by this many chips.
    case moveStrip(Int)
    /// Remove the highlighted chip.
    case removeFocusedChip
    /// Remove the newest chip (Backspace in an empty field).
    case removeNewestChip
    /// Leave the strip; the key then goes on as usual (`passThrough`) when
    /// `alsoPassThrough` is set.
    case leaveStrip(alsoPassThrough: Bool)
    /// Move focus to the next or previous control in the window.
    case moveFocus(forward: Bool)
}

/// What the router needs to know about the composer when a key lands.
public struct ComposerKeyContext: Equatable, Sendable {
    /// The field holds IME text that has not committed yet.
    public var hasMarkedText: Bool
    public var layer: ComposerLayer
    public var isStreaming: Bool
    public var isQueued: Bool
    public var isNoteMode: Bool
    public var draft: String
    /// Chips that `↩` sends (vault files, read documents).
    public var hasAttachments: Bool
    /// Chips that are not sent on their own (a screen read, a document
    /// still reading or failed): the strip keys still reach them.
    public var hasOtherChips: Bool
    /// A chip in the strip has the keys.
    public var isStripFocused: Bool
    public var attachmentStatus: ComposerAttachmentStatus

    public init(
        hasMarkedText: Bool = false,
        layer: ComposerLayer = .none,
        isStreaming: Bool = false,
        isQueued: Bool = false,
        isNoteMode: Bool = false,
        draft: String = "",
        hasAttachments: Bool = false,
        hasOtherChips: Bool = false,
        isStripFocused: Bool = false,
        attachmentStatus: ComposerAttachmentStatus = .ready
    ) {
        self.hasMarkedText = hasMarkedText
        self.layer = layer
        self.isStreaming = isStreaming
        self.isQueued = isQueued
        self.isNoteMode = isNoteMode
        self.draft = draft
        self.hasAttachments = hasAttachments
        self.hasOtherChips = hasOtherChips
        self.isStripFocused = isStripFocused
        self.attachmentStatus = attachmentStatus
    }

    var hasChips: Bool { hasAttachments || hasOtherChips }

    var isDraftEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The same values as the composer's words see them.
    var state: ComposerState {
        ComposerState(
            draft: draft,
            hasAttachments: hasAttachments,
            isStreaming: isStreaming,
            isQueued: isQueued,
            isNoteMode: isNoteMode,
            layer: layer,
            attachmentStatus: attachmentStatus
        )
    }
}

public enum ComposerKeyRouter {
    public static func route(
        _ key: ComposerKey,
        modifiers: ComposerKeyModifiers = [],
        context: ComposerKeyContext
    ) -> ComposerKeyResult {
        // IME composition owns the keys until it commits.
        if context.hasMarkedText { return .passThrough }

        if key == .k {
            return modifiers == .command ? .togglePalette : .passThrough
        }
        if key == .a || key == .s {
            return modifiers == [.command, .shift] ? .toggleAttachments : .passThrough
        }

        if context.isStripFocused {
            return stripKey(key)
        }

        switch key {
        case .returnKey:
            return returnKey(modifiers: modifiers, context: context)
        case .escape:
            return escapeKey(context: context)
        case .upArrow, .downArrow:
            let delta = key == .upArrow ? -1 : 1
            if context.layer.routesKeysFromField, modifiers.isEmpty { return .moveChooser(delta) }
            if key == .upArrow, modifiers.isEmpty, context.layer == .none, context.draft.isEmpty {
                return .recallLastQuestion
            }
            return .passThrough
        case .tab:
            if context.layer == .mention || context.layer == .slash { return .acceptChooser }
            return .moveFocus(forward: true)
        case .backTab:
            if context.layer == .none, context.hasChips { return .enterStrip }
            return .moveFocus(forward: false)
        case .backspace:
            if context.draft.isEmpty, context.hasChips, modifiers.isEmpty { return .removeNewestChip }
            return .passThrough
        case .leftArrow, .rightArrow, .k, .a, .s, .other:
            return .passThrough
        }
    }

    private static func returnKey(modifiers: ComposerKeyModifiers, context: ComposerKeyContext) -> ComposerKeyResult {
        if modifiers.contains(.command) { return .runPrimary }
        // Shift-Return (and Option-Return) start a new line.
        if modifiers.contains(.shift) || modifiers.contains(.option) { return .passThrough }
        if context.layer.routesKeysFromField { return .acceptChooser }
        let state = context.state
        if state.returnQueues { return .queue }
        // Return during a stream with nothing to hold does nothing; it
        // never adds a stray line.
        if context.isStreaming, !context.isNoteMode { return .consume }
        return state.canSubmit ? .submit : .consume
    }

    private static func escapeKey(context: ComposerKeyContext) -> ComposerKeyResult {
        if context.layer != .none { return .closeLayer }
        if context.isStreaming { return .stopStream }
        if !context.draft.isEmpty { return .clearDraft }
        return .consume
    }

    private static func stripKey(_ key: ComposerKey) -> ComposerKeyResult {
        switch key {
        case .leftArrow: .moveStrip(-1)
        case .rightArrow: .moveStrip(1)
        case .backspace: .removeFocusedChip
        case .escape, .tab, .backTab: .leaveStrip(alsoPassThrough: false)
        default: .leaveStrip(alsoPassThrough: true)
        }
    }
}
