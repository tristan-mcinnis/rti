import Foundation

/// What `/new` (alias `/clear`) clears, as data.
///
/// The one rule that matters: starting a new chat never ends the recording and
/// never discards the thread that was already recorded. It clears the pending
/// context around the field — draft, chips, a queued follow-up, a screen read
/// waiting to be sent — and starts the composer fresh. The thread stays
/// available through the saved turns and the session archive.
public struct ChatResetPlan: Equatable, Sendable {
    /// The command as typed, without its slash ("new", "clear").
    public let command: String
    /// The typed text.
    public let clearsDraft: Bool
    /// Attachment chips, `@` mentions, and their loaded text.
    public let clearsAttachments: Bool
    /// A screen read captured for the next message.
    public let clearsPendingScreenContext: Bool
    /// A follow-up held until the streaming answer finished.
    public let clearsQueuedFollowUp: Bool
    /// The answer that is streaming, if any.
    public let cancelsStream: Bool
    /// Back to the app default model and reasoning for the new chat.
    public let resetsModelSelection: Bool
    /// Back to source-first for the new chat.
    public let resetsBroaderSearch: Bool

    // Invariants. These are `true` on every plan and are asserted in tests so
    // a later edit cannot quietly drop them.
    public let preservesSavedThread: Bool
    public let preservesRecording: Bool
    public let preservesLiveNotes: Bool

    public init(
        command: String,
        clearsDraft: Bool = true,
        clearsAttachments: Bool = true,
        clearsPendingScreenContext: Bool = true,
        clearsQueuedFollowUp: Bool = true,
        cancelsStream: Bool = true,
        resetsModelSelection: Bool = true,
        resetsBroaderSearch: Bool = true,
        preservesSavedThread: Bool = true,
        preservesRecording: Bool = true,
        preservesLiveNotes: Bool = true
    ) {
        self.command = command
        self.clearsDraft = clearsDraft
        self.clearsAttachments = clearsAttachments
        self.clearsPendingScreenContext = clearsPendingScreenContext
        self.clearsQueuedFollowUp = clearsQueuedFollowUp
        self.cancelsStream = cancelsStream
        self.resetsModelSelection = resetsModelSelection
        self.resetsBroaderSearch = resetsBroaderSearch
        self.preservesSavedThread = preservesSavedThread
        self.preservesRecording = preservesRecording
        self.preservesLiveNotes = preservesLiveNotes
    }

    /// `/new` and `/clear` are one behaviour with two names.
    public static func plan(forCommand word: String) -> ChatResetPlan? {
        let key = word.hasPrefix("/") ? String(word.dropFirst()) : word
        switch key.lowercased() {
        case "new", "clear":
            return ChatResetPlan(command: key.lowercased())
        default:
            return nil
        }
    }

    public static let forNewChat = ChatResetPlan(command: "new")
}
