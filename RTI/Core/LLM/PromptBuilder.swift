import Foundation

/// Contextual attachments injected into the system prompt before every
/// chat turn. The caller (LLMController) populates this from its current
/// state; PromptBuilder assembles the ordered message list.
public struct PromptContext {
    /// The base system prompt (from the active mode, or the default).
    public var baseSystemPrompt: String
    /// User-provided context for *this* meeting (client, project, status…).
    /// Ephemeral; treated as ground truth about who/what the call is about.
    public var meetingContext: String?
    /// A pre-meeting prep brief auto-matched to this session (decisions to
    /// lock, tensions, blind spots). Injected only for active meeting sessions.
    public var meetingBrief: String?
    /// Optional glossary terms the model should know.
    public var glossaryFragment: String?
    /// Reference text attached to the active mode.
    public var referenceText: String?
    /// Name of the mode providing the reference.
    public var referenceModeName: String?
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
        referenceText: String? = nil,
        referenceModeName: String? = nil,
        screenContext: String? = nil,
        referencedDocuments: String? = nil,
        sourceContext: TurnSourceContext = TurnSourceContext(),
        externalRetrievalAllowed: Bool = false
    ) {
        self.baseSystemPrompt = baseSystemPrompt
        self.meetingContext = meetingContext
        self.meetingBrief = meetingBrief
        self.glossaryFragment = glossaryFragment
        self.referenceText = referenceText
        self.referenceModeName = referenceModeName
        self.screenContext = screenContext
        self.referencedDocuments = referencedDocuments
        self.sourceContext = sourceContext
        self.externalRetrievalAllowed = externalRetrievalAllowed
    }

    public var hasContent: Bool {
        meetingContext != nil
            || meetingBrief != nil
            || glossaryFragment != nil
            || referenceText != nil
            || screenContext != nil
            || referencedDocuments != nil
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

        if let reference = context.referenceText, !reference.isEmpty {
            let capped = reference.count > referenceCap
                ? String(reference.prefix(referenceCap)) + "\n…[truncated]"
                : reference
            let modeName = context.referenceModeName ?? "active mode"
            msgs.append(LLMMessage(
                role: "system",
                content: "Reference material attached to the active mode '\(modeName)'. Use it when relevant.\n---\n\(capped)\n---"
            ))
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

    /// Build the conversation messages from the stored chat entries plus
    /// the current user turn. The latest user message includes the transcript
    /// context prepended (fullContent) while prior turns use their raw text.
    public static func buildConversationMessages(
        entries: [ChatEntry],
        fullContent: String,
        images: [LLMImage] = []
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
        return msgs
    }
}
