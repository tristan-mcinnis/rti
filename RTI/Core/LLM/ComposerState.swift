import Foundation

// The composer's rules, pure (design-system docs/chat-surfaces.md section 3,
// RTI plan section 4 "Composer"): what the field's placeholder says, what
// `↩` does right now (drawn inside the field as a label and its key caps),
// the slash command catalogue, and the words on an attachment chip.
// Shaped after Quick Launch's `QuickViewModel.quickAIComposerAction` and
// `quickAIComposerPlaceholder`, cut to RTI's states.

/// What `↩` (or the key it names) does from the composer right now.
public struct ComposerAction: Equatable, Sendable {
    /// What the action does, so a click on the label does the same thing.
    public enum Kind: Equatable, Sendable {
        /// Send the typed question (or run the typed slash command).
        case ask
        /// Run the bound primary action (`⌘↩`, "Assist" by default).
        case runPrimary
        /// Stop the answer that is streaming.
        case stop
        /// A follow-up waits for the stream to end.
        case queued
        /// Put the typed note into the transcript or the prep note.
        case addNote
        /// Pick the highlighted row of the open chooser.
        case acceptChooser
    }

    public let kind: Kind
    public let label: String
    public let keys: [String]

    public init(kind: Kind, label: String, keys: [String]) {
        self.kind = kind
        self.label = label
        self.keys = keys
    }
}

/// The floating layer over the composer, if any.
public enum ComposerLayer: Equatable, Sendable {
    case none
    /// `@` typed: vault files that match.
    case mention
    /// `/` typed: slash commands that match.
    case slash
    /// The plus circle: Add Context.
    case addContext
    /// The `⌘K` circle: the action palette.
    case palette

    /// A chooser that keeps the keys in the field (arrows, `↩`, Tab).
    public var routesKeysFromField: Bool {
        switch self {
        case .mention, .slash, .addContext: true
        case .none, .palette: false
        }
    }
}

/// Everything the composer's words depend on, as plain values.
public struct ComposerState: Equatable, Sendable {
    /// The typed text, as it stands.
    public var draft: String
    /// Chips in the strip (vault files, documents, a screen read).
    public var hasAttachments: Bool
    /// An answer is streaming.
    public var isStreaming: Bool
    /// `↩` was pressed during the stream; the draft sends when it ends.
    public var isQueued: Bool
    /// The next `↩` writes a note instead of asking.
    public var isNoteMode: Bool
    /// A session records (or is paused): notes go to the transcript and
    /// questions are about this meeting.
    public var isRecording: Bool
    public var layer: ComposerLayer
    /// The bound primary action's name ("Assist", "Recap").
    public var primaryActionLabel: String

    public init(
        draft: String = "",
        hasAttachments: Bool = false,
        isStreaming: Bool = false,
        isQueued: Bool = false,
        isNoteMode: Bool = false,
        isRecording: Bool = false,
        layer: ComposerLayer = .none,
        primaryActionLabel: String = "Assist"
    ) {
        self.draft = draft
        self.hasAttachments = hasAttachments
        self.isStreaming = isStreaming
        self.isQueued = isQueued
        self.isNoteMode = isNoteMode
        self.isRecording = isRecording
        self.layer = layer
        self.primaryActionLabel = primaryActionLabel
    }

    // MARK: Words

    public static let idlePlaceholder = "Ask the vault, @ a file, or / for commands…"
    public static let recordingPlaceholder = "Ask about this meeting…"
    public static let transcriptNotePlaceholder = "Note to the transcript…"
    public static let prepNotePlaceholder = "Prep note for this meeting…"
    public static let streamingPlaceholder = "Type a follow-up; it sends when this answer ends"

    /// The draft with its outer white space gone.
    public var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isDraftEmpty: Bool { trimmedDraft.isEmpty }

    /// What the empty field says: what typing and `↩` will do.
    public var placeholder: String {
        if isNoteMode {
            return isRecording ? Self.transcriptNotePlaceholder : Self.prepNotePlaceholder
        }
        if isStreaming { return Self.streamingPlaceholder }
        return isRecording ? Self.recordingPlaceholder : Self.idlePlaceholder
    }

    /// What `↩` does, drawn inside the field. A chooser's own verb wins, so
    /// two `↩` hints on one screen never disagree.
    public var action: ComposerAction {
        switch layer {
        case .mention, .addContext:
            return ComposerAction(kind: .acceptChooser, label: "Add", keys: ["↩"])
        case .slash, .palette:
            return ComposerAction(kind: .acceptChooser, label: "Run", keys: ["↩"])
        case .none:
            break
        }
        // A note never waits on an answer: it is not a question.
        if isNoteMode {
            return ComposerAction(kind: .addNote, label: "Add Note", keys: ["↩"])
        }
        if isStreaming {
            if isQueued { return ComposerAction(kind: .queued, label: "Queued", keys: ["↩"]) }
            return ComposerAction(kind: .stop, label: "Stop", keys: ["esc"])
        }
        if isDraftEmpty && !hasAttachments {
            return ComposerAction(kind: .runPrimary, label: primaryActionLabel, keys: ["⌘", "↩"])
        }
        if trimmedDraft.hasPrefix("/") {
            return ComposerAction(kind: .ask, label: "Run", keys: ["↩"])
        }
        return ComposerAction(kind: .ask, label: "Ask", keys: ["↩"])
    }

    /// `↩` would send something: typed text, or chips on their own in chat.
    public var canSubmit: Bool {
        if isNoteMode { return !isDraftEmpty }
        return !isDraftEmpty || hasAttachments
    }

    /// `↩` during a stream holds the draft instead of sending it. A note
    /// goes at once; an empty draft has nothing to hold.
    public var returnQueues: Bool {
        isStreaming && !isNoteMode && canSubmit
    }
}

// MARK: - Slash commands

/// One slash command: what `/` offers in its chooser, with the aliases that
/// run it when typed in full.
public struct ComposerSlashCommand: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let symbol: String
    public let help: String
    /// Other words that run it ("/latest" runs "/answer").
    public let aliases: [String]

    public init(id: String, label: String, symbol: String, help: String, aliases: [String] = []) {
        self.id = id
        self.label = label
        self.symbol = symbol
        self.help = help
        self.aliases = aliases
    }

    /// Every slash command, in chooser order.
    public static let all: [ComposerSlashCommand] = [
        ComposerSlashCommand(id: "assist", label: "Assist", symbol: "sparkles", help: "Suggest what to do next"),
        ComposerSlashCommand(id: "answer", label: "Answer latest", symbol: "quote.bubble",
                             help: "Answer the latest live question using project context", aliases: ["latest"]),
        ComposerSlashCommand(id: "say", label: "Say next", symbol: "wand.and.rays", help: "Draft a quick reply",
                             aliases: ["saynext"]),
        ComposerSlashCommand(id: "followups", label: "Follow-ups", symbol: "bubble.left.and.text.bubble.right",
                             help: "Generate follow-up questions", aliases: ["followup"]),
        ComposerSlashCommand(id: "recap", label: "Recap", symbol: "arrow.clockwise", help: "Recap the recent conversation"),
        ComposerSlashCommand(id: "summary", label: "Summary", symbol: "doc.text", help: "Summarize the full session",
                             aliases: ["summarize"]),
        ComposerSlashCommand(id: "note", label: "Note", symbol: "note.text",
                             help: "Turn note mode on or off, or use /note <text>"),
        ComposerSlashCommand(id: "chat", label: "Chat", symbol: "text.bubble", help: "Leave note mode and go back to chat"),
        ComposerSlashCommand(id: "screen", label: "Screen", symbol: "camera.viewfinder",
                             help: "Read the screen once for the next message"),
        ComposerSlashCommand(id: "recent", label: "Recent", symbol: "calendar", help: "Ask about recent project meetings"),
        ComposerSlashCommand(id: "search", label: "Search", symbol: "magnifyingglass",
                             help: "Search the vault or the chosen project or client", aliases: ["grep", "rag"]),
        ComposerSlashCommand(id: "sources", label: "Sources", symbol: "text.page",
                             help: "Show source hits for a query or the last question", aliases: ["source"]),
        ComposerSlashCommand(id: "project", label: "Project", symbol: "folder",
                             help: "Show, set, or clear the project or client", aliases: ["client", "context"]),
        ComposerSlashCommand(id: "help", label: "Help", symbol: "questionmark.circle", help: "Show slash commands",
                             aliases: ["?"]),
        ComposerSlashCommand(id: "new", label: "New chat", symbol: "square.and.pencil", help: "Clear the current chat",
                             aliases: ["clear"]),
    ]

    /// The chooser shows while the draft is one word that starts with `/`.
    public static func isChooserDraft(_ draft: String) -> Bool {
        draft.hasPrefix("/") && !draft.contains(" ") && !draft.contains("\n")
    }

    /// Commands that match what follows the `/`: the id, an alias, or the
    /// label. Empty after the `/` lists them all.
    public static func matches(_ draft: String) -> [ComposerSlashCommand] {
        let query = draft.drop(while: { $0 == "/" }).lowercased()
        guard !query.isEmpty else { return all }
        return all.filter { command in
            command.id.contains(query)
                || command.aliases.contains { $0.hasPrefix(query) }
                || command.label.lowercased().contains(query)
        }
    }

    /// The command a typed word runs (the id or an alias), if any.
    public static func command(named word: String) -> ComposerSlashCommand? {
        let key = word.lowercased()
        return all.first { $0.id == key || $0.aliases.contains(key) }
    }
}

// MARK: - Attachment words

/// The words on an attachment chip: size and units the way the spec writes
/// them ("12 pp · 84 KB · cut"), and the same read aloud ("12 pages").
public enum ComposerAttachmentDetail {
    /// "12 pp · 84 KB" for a PDF, "18 KB" for a text file, "" for a vault
    /// file (its path is the tooltip). `wasCut` adds " · cut".
    public static func detail(for ref: ChatAttachmentRef) -> String {
        var parts: [String] = []
        switch ref.kind {
        case .screen:
            parts.append("once")
        case .vaultFile:
            break
        case .pdf, .text:
            if ref.kind == .pdf, let pages = ref.pageCount { parts.append("\(pages) pp") }
            if let bytes = ref.byteCount { parts.append(byteText(bytes)) }
        }
        if ref.wasCut { parts.append("cut") }
        return parts.joined(separator: " · ")
    }

    /// The detail for VoiceOver: pages, not "pp".
    public static func spokenDetail(for ref: ChatAttachmentRef) -> String {
        var parts: [String] = []
        switch ref.kind {
        case .screen:
            parts.append("read once")
        case .vaultFile:
            if let path = ref.path { parts.append(path) }
        case .pdf, .text:
            if ref.kind == .pdf, let pages = ref.pageCount { parts.append(pages == 1 ? "1 page" : "\(pages) pages") }
            if let bytes = ref.byteCount { parts.append(byteText(bytes)) }
        }
        if ref.wasCut { parts.append("cut to fit") }
        return parts.joined(separator: ", ")
    }

    /// A file size the way Finder writes it, in decimal units: "18 KB",
    /// "1.2 MB". The same on every Mac.
    public static func byteText(_ bytes: Int) -> String {
        let units = ["KB", "MB", "GB"]
        guard bytes >= 1_000 else { return bytes == 1 ? "1 byte" : "\(bytes) bytes" }
        var value = Double(bytes) / 1_000
        var unit = 0
        while value >= 999.5, unit < units.count - 1 {
            value /= 1_000
            unit += 1
        }
        let digits = unit == 0 || value >= 10 ? 0 : 1
        let number = value.formatted(.number.precision(.fractionLength(digits)).locale(Locale(identifier: "en_US")))
        return "\(number) \(units[unit])"
    }
}
