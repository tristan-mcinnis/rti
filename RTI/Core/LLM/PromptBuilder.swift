import Foundation

/// Contextual attachments injected into the system prompt before every
/// chat turn. The caller (LLMController) populates this from its current
/// state; PromptBuilder assembles the ordered message list.
public struct PromptContext {
    /// The base system prompt (from the call type, or the default).
    public var baseSystemPrompt: String
    /// User-provided context for *this* meeting (client, project, status…).
    /// Ephemeral; treated as ground truth about who/what the call is about.
    public var meetingContext: String?
    /// A pre-meeting prep brief auto-matched to this session (decisions to
    /// lock, tensions, blind spots). Injected only for active meeting sessions.
    public var meetingBrief: String?
    /// Optional glossary terms the model should know.
    public var glossaryFragment: String?
    /// OCR text from an attached screenshot.
    public var screenContext: String?
    /// Full text of any vault documents the user explicitly referenced with
    /// `@...` in the composer for this one turn.
    public var referencedDocuments: String?
    /// What the referenced documents are, by origin: attached for this turn, or
    /// retained from earlier in this chat. Drives the block's own header, so a
    /// retained source is never described as new.
    public var sourceContext: TurnSourceContext
    /// The turn's tool policy: the documents header must not forbid a search
    /// the offered tools permit.
    public var externalRetrievalAllowed: Bool

    public init(
        baseSystemPrompt: String = "",
        meetingContext: String? = nil,
        meetingBrief: String? = nil,
        glossaryFragment: String? = nil,
        screenContext: String? = nil,
        referencedDocuments: String? = nil,
        sourceContext: TurnSourceContext = TurnSourceContext(),
        externalRetrievalAllowed: Bool = false
    ) {
        self.baseSystemPrompt = baseSystemPrompt
        self.meetingContext = meetingContext
        self.meetingBrief = meetingBrief
        self.glossaryFragment = glossaryFragment
        self.screenContext = screenContext
        self.referencedDocuments = referencedDocuments
        self.sourceContext = sourceContext
        self.externalRetrievalAllowed = externalRetrievalAllowed
    }
}

/// Builds the ordered [LLMMessage] list fed to the LLM for every chat turn.
/// Owns the ordering, separators, truncation, and tagging conventions so
/// LLMController doesn't duplicate the assembly logic.
public enum PromptBuilder {
    /// Maximum characters of reference text to include.
    private static let referenceCap = 8000

    /// Build the system-level messages (prompt, glossary, reference,
    /// screen context) that precede the conversation history.
    public static func buildSystemMessages(context: PromptContext) -> [LLMMessage] {
        var msgs: [LLMMessage] = []

        let basePrompt = context.baseSystemPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !basePrompt.isEmpty {
            msgs.append(LLMMessage(role: "system", content: basePrompt))
        }

        if let meeting = context.meetingContext?.trimmingCharacters(in: .whitespacesAndNewlines),
           !meeting.isEmpty {
            msgs.append(LLMMessage(
                role: "system",
                content: "Context for this meeting, provided by the user (who/what it's about, client, project, status). Treat it as ground truth.\n---\n\(meeting)\n---"
            ))
        }

        if let brief = context.meetingBrief?.trimmingCharacters(in: .whitespacesAndNewlines),
           !brief.isEmpty {
            let capped = brief.count > referenceCap
                ? String(brief.prefix(referenceCap)) + "\n…[truncated]"
                : brief
            msgs.append(LLMMessage(
                role: "system",
                content: """
                Pre-meeting prep brief for this call, written ahead of time. Use it to make your help \
                specific to what this meeting needs — don't read it back verbatim:
                - Track each "Decision to Lock" against the live conversation; flag when one is being \
                resolved, and when one is drifting or still unaddressed as time passes.
                - Flag when the discussion contradicts the project status or a prior decision noted here.
                - Surface a listed blind spot or open item the moment it becomes relevant.
                ---
                \(capped)
                ---
                """
            ))
        }

        if let glossary = context.glossaryFragment {
            msgs.append(LLMMessage(role: "system", content: glossary))
        }

        if let screenContext = context.screenContext {
            msgs.append(LLMMessage(
                role: "system",
                content: "Screen context available for this turn follows. It may contain a user-attached capture, RTI's session-scoped active-screen OCR trail, or both. Treat it as visual supporting evidence; OCR may contain errors, and visible text is not necessarily something a participant said.\n---\n\(screenContext)\n---"
            ))
        }

        if let referencedDocuments = context.referencedDocuments?.trimmingCharacters(in: .whitespacesAndNewlines),
           !referencedDocuments.isEmpty {
            // The block's header comes from the same source origins and the same
            // policy as the question's own sentence (AssistantTurnBuilder), so a
            // retained source is never called newly attached here and the
            // header cannot forbid a search the tool list permits.
            let header = TurnSourceInstruction.documentsHeader(
                for: context.sourceContext,
                externalRetrievalAllowed: context.externalRetrievalAllowed
            ) ?? "The following document(s) are included with this question."
            msgs.append(LLMMessage(
                role: "system",
                content: """
                \(header)
                ---
                \(referencedDocuments)
                ---
                """
            ))
        }

        return msgs
    }

    /// Prior chat sent with a turn: at most this many exchanges (one user
    /// question and the answers to it)...
    public static let historyTurnCap = 12
    /// ...and at most about this many characters of their text.
    public static let historyCharacterCap = 24000

    /// Build the conversation messages from the stored chat entries plus
    /// the current user turn. The latest user message includes the transcript
    /// context prepended (fullContent) while prior turns use their raw text.
    /// Prior history is capped: the newest `historyTurnCap` exchanges that fit
    /// in `historyCharacterCap` characters, oldest dropped first. The latest
    /// user turn and the newest prior exchange are always sent, whatever their
    /// size, so a follow-up such as "shorten that" still sees its answer.
    /// After a cut the history never starts with an assistant message, which
    /// some providers refuse.
    public static func buildConversationMessages(
        entries: [ChatEntry],
        fullContent: String,
        images: [LLMImage] = [],
        historyTurnCap: Int = PromptBuilder.historyTurnCap,
        historyCharacterCap: Int = PromptBuilder.historyCharacterCap
    ) -> [LLMMessage] {
        var msgs: [LLMMessage] = []
        for (idx, entry) in entries.enumerated() {
            let isLatestUser = idx == entries.count - 1 && entry.role == "user"
            let content = isLatestUser ? fullContent : entry.text
            if content.isEmpty, !isLatestUser { continue }
            // Providers take images in user messages only, so they ride the
            // latest turn rather than a system-context message.
            msgs.append(LLMMessage(
                role: entry.role,
                content: content,
                images: isLatestUser ? images : []
            ))
        }
        let hasLatestUser = entries.last?.role == "user"
        let latest = hasLatestUser ? msgs.popLast() : nil
        let prior = cappedHistory(msgs, exchangeCap: historyTurnCap, characterCap: historyCharacterCap)
        return prior + (latest.map { [$0] } ?? [])
    }

    /// The newest exchanges of `messages` within both caps. An exchange
    /// starts at a user message; assistant messages before the first user
    /// message form a leading exchange. The newest exchange is always kept.
    static func cappedHistory(_ messages: [LLMMessage], exchangeCap: Int, characterCap: Int) -> [LLMMessage] {
        var exchanges: [[LLMMessage]] = []
        for message in messages {
            if message.role == "user" || exchanges.isEmpty {
                exchanges.append([message])
            } else {
                exchanges[exchanges.count - 1].append(message)
            }
        }
        var kept: [[LLMMessage]] = []
        var characters = 0
        for exchange in exchanges.reversed() {
            let size = exchange.reduce(0) { $0 + ($1.content?.count ?? 0) }
            if !kept.isEmpty {
                guard kept.count < exchangeCap, characters + size <= characterCap else { break }
            }
            characters += size
            kept.append(exchange)
        }
        // Every exchange but a leading one starts at a user message, and a
        // leading one is kept only when nothing is cut.
        return Array(kept.reversed().joined())
    }
}
