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
        /// The draft starts with `/` but names no command: send the words
        /// literally instead of running anything. Nothing leaves the app as
        /// a command, which is what "unknown commands stay local" means, and
        /// only this explicit action sends them — `↩` does nothing.
        case sendAsText
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
        /// Attachments must finish reading or be removed before sending.
        case blocked
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

public enum ComposerAttachmentStatus: Equatable, Sendable {
    case ready, reading, failed

    public var notice: String? {
        switch self {
        case .ready: nil
        case .reading: "Reading attachments. Your draft is kept."
        case .failed: "Remove failed attachments or attach them again before sending."
        }
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
    public var attachmentStatus: ComposerAttachmentStatus
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
        primaryActionLabel: String = "Assist",
        attachmentStatus: ComposerAttachmentStatus = .ready
    ) {
        self.draft = draft
        self.hasAttachments = hasAttachments
        self.attachmentStatus = attachmentStatus
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
        if attachmentStatus != .ready {
            return ComposerAction(kind: .blocked, label: attachmentStatus == .reading ? "Reading…" : "Review", keys: [])
        }
        if isDraftEmpty && !hasAttachments {
            return ComposerAction(kind: .runPrimary, label: primaryActionLabel, keys: ["⌘", "↩"])
        }
        if isUnknownSlashCommand {
            // Words, not a command. Nothing leaves the app until the user
            // chooses the explicit action, so the label carries no key: `↩`
            // does not send them.
            return ComposerAction(kind: .sendAsText, label: "Send as Text", keys: [])
        }
        if trimmedDraft.hasPrefix("/") {
            return ComposerAction(kind: .ask, label: "Run", keys: ["↩"])
        }
        return ComposerAction(kind: .ask, label: "Ask", keys: ["↩"])
    }

    /// The draft is a slash line that names no command ("/deploy now"). It
    /// stays local: nothing runs as a command, `↩` does nothing, and only the
    /// explicit Send as Text action sends the words.
    ///
    /// The command set is `ComposerSlashCommand.all`, the same catalogue the
    /// shared `ChatCommandParser` is built from (`LLMController`), so the verb
    /// the field draws and the command the composer runs cannot disagree.
    public var isUnknownSlashCommand: Bool {
        let text = trimmedDraft
        guard text.hasPrefix("/"), let word = Self.leadingCommandWord(in: text) else { return false }
        return ComposerSlashCommand.command(named: word) == nil
    }

    /// The word right after a leading `/`, without its slash. Nil when the
    /// draft does not start with `/` or has no word after it.
    public static func leadingCommandWord(in draft: String) -> String? {
        guard draft.hasPrefix("/") else { return nil }
        let word = draft.dropFirst().prefix { !$0.isWhitespace }
        guard !word.isEmpty else { return nil }
        return String(word)
    }

    /// `↩` would send something: typed text, or chips on their own in chat.
    /// An unknown slash line is never sent by `↩`; it stays in the field
    /// until the explicit Send as Text action.
    public var canSubmit: Bool {
        if isNoteMode { return !isDraftEmpty }
        guard attachmentStatus == .ready else { return false }
        if isUnknownSlashCommand { return false }
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

// MARK: - Mentions

/// The one grammar `@` in the field and the `+` Add Context pane share: what
/// is being typed after the `@`, and what a chosen path is written as.
/// Quoted mentions keep working — `@"a file with spaces.md"` is a path, not a
/// search, which is why a typed quote closes the chooser instead of opening
/// one.
public enum ComposerMention {
    /// The words after the `@` being typed, or nil when no mention is open.
    /// A `@"` (a quoted mention typed by hand) closes the chooser: what
    /// follows is the path itself.
    public static func query(in draft: String) -> String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        let after = draft[draft.index(after: at)...]
        guard !after.contains("@"),
              !after.contains("\n"),
              after.first != "\"" else { return nil }
        return String(after).trimmingCharacters(in: .whitespaces)
    }

    /// True while a mention is being typed, whatever the vault has answered.
    public static func isOpen(in draft: String) -> Bool { query(in: draft) != nil }

    /// How a path is written into a question, quoted so a space or a quote in
    /// the path cannot break the mention.
    public static func token(for path: String) -> String { "@\"\(path)\"" }

    /// The question with the chosen paths in front of it, in the one form the
    /// assistant resolves.
    public static func line(paths: [String], text: String) -> String {
        guard !paths.isEmpty else { return text }
        let mentions = paths.map(token(for:)).joined(separator: " ")
        return text.isEmpty ? mentions : "\(mentions) \(text)"
    }
}

// MARK: - Sources, before Send

/// A source whose text was cut to fit a cap, as the strip names it.
public struct ComposerPartialSource: Equatable, Sendable {
    public let name: String
    /// The extractor's own truncation line, when it gave one.
    public let limit: String?

    public init(name: String, limit: String? = nil) {
        self.name = name
        self.limit = limit
    }

    /// "Launch plan.pdf was cut to fit: 200,000 characters kept".
    public var line: String {
        guard let limit, !limit.isEmpty else { return "\(name) was cut to fit" }
        return "\(name) was cut to fit: \(limit)"
    }
}

/// The three facts the composer shows about its sources before Send: whether
/// they are ready to send, whether a read was cut short, and whether this chat
/// is being saved. The image destination rides the same line, because it is a
/// fact about the same turn.
public struct ComposerSourcesStatus: Equatable, Sendable {
    public var readiness: ComposerAttachmentStatus
    public var partial: [ComposerPartialSource]
    /// A saved source this chat's store can no longer rehydrate, in the
    /// controller's own words.
    public var retainedNotice: String?
    /// "Images go to DeepSeek (cloud)"; empty when the draft carries no image.
    public var imageRouteLabel: String
    /// The last vault answer's retrieval state ("found nothing", "fell back to
    /// the keyword scan", "unavailable"), in the controller's own words.
    public var retrievalNotice: String?
    /// False when the app has no vault configured: chat works, nothing is written.
    public var savesToVault: Bool

    public init(
        readiness: ComposerAttachmentStatus = .ready,
        partial: [ComposerPartialSource] = [],
        retainedNotice: String? = nil,
        imageRouteLabel: String = "",
        retrievalNotice: String? = nil,
        savesToVault: Bool = true
    ) {
        self.readiness = readiness
        self.partial = partial
        self.retainedNotice = retainedNotice
        self.imageRouteLabel = imageRouteLabel
        self.retrievalNotice = retrievalNotice
        self.savesToVault = savesToVault
    }

    /// One quiet line above the strip, or nil when there is nothing to say.
    public var notice: String? {
        var lines: [String] = []
        if let readinessNotice = readiness.notice { lines.append(readinessNotice) }
        lines.append(contentsOf: partial.map(\.line))
        if let retainedNotice, !retainedNotice.isEmpty { lines.append(retainedNotice) }
        if !imageRouteLabel.isEmpty { lines.append(imageRouteLabel) }
        if let retrievalNotice, !retrievalNotice.isEmpty { lines.append(retrievalNotice) }
        if !savesToVault { lines.append("Not saved: no vault configured") }
        return lines.isEmpty ? nil : lines.joined(separator: " · ")
    }
}

// MARK: - The route, before Send

/// The route the composer names before Send: the per-chat provider, model and
/// reasoning, and where a pending image would go. Resolved through the same
/// `ChatRouteResolver` the turn freezes with, so the label can never describe
/// a route other than the one about to run.
public struct ComposerRoutePreview: Equatable, Sendable {
    /// The chosen route in words: provider · model · reasoning.
    public let label: String
    /// A short reason for the bar when the turn cannot run as chosen.
    public let blockerLabel: String?
    /// The blocker's own sentence, with the fix, for the composer's error line.
    public let blockerMessage: String?
    /// True when the fix is a missing API key, so the error line offers the way
    /// to Settings.
    public let blockerNeedsSettings: Bool
    /// "Images go to DeepSeek (cloud)", or where the image stays instead.
    /// Empty when the draft carries no image.
    public let imageRouteLabel: String
    /// True when the turn would run on a labelled vision fallback instead of
    /// the model the user picked.
    public let usesVisionFallback: Bool

    public init(
        label: String,
        blockerLabel: String? = nil,
        blockerMessage: String? = nil,
        blockerNeedsSettings: Bool = false,
        imageRouteLabel: String = "",
        usesVisionFallback: Bool = false
    ) {
        self.label = label
        self.blockerLabel = blockerLabel
        self.blockerMessage = blockerMessage
        self.blockerNeedsSettings = blockerNeedsSettings
        self.imageRouteLabel = imageRouteLabel
        self.usesVisionFallback = usesVisionFallback
    }

    public var isBlocked: Bool { blockerMessage != nil }

    /// What the bar prints: the chosen route, or the short reason it cannot
    /// run. Never a route that will not run.
    public var barLabel: String { isBlocked ? (blockerLabel ?? label) : label }

    /// `chosenLabel` is the controller's own `chatRouteLabel`, so the chosen
    /// line is the one the app already shows. A vision fallback, when one ever
    /// exists, prints the effective route instead.
    public static func resolve(
        selection: ChatModelSelection,
        provider: LLMProviderConfig,
        imageCount: Int = 0,
        chosenLabel: String
    ) -> ComposerRoutePreview {
        // The default options are the controller's: a provider's own model is
        // image-capable exactly when the provider says so, and there is no
        // fallback model to switch to behind the user's back.
        switch ChatRouteResolver.resolve(
            selection: selection,
            provider: provider,
            imageCount: imageCount
        ) {
        case let .success(route):
            return ComposerRoutePreview(
                label: route.isVisionFallback ? route.routeLabel : chosenLabel,
                imageRouteLabel: route.imageRouteLabel,
                usesVisionFallback: route.isVisionFallback
            )
        case let .failure(blocker):
            let short: String
            var needsSettings = false
            switch blocker {
            case let .missingCredential(providerName):
                short = "No API key for \(providerName)"
                needsSettings = true
            case let .imagesUnsupported(providerName, model):
                short = "\(providerName) · \(model) cannot read images"
            }
            return ComposerRoutePreview(
                label: chosenLabel,
                blockerLabel: short,
                blockerMessage: blocker.message,
                blockerNeedsSettings: needsSettings
            )
        }
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
        case .pdf, .image, .text:
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
        case .pdf, .image, .text:
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
