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
    /// The active session's discussion guide rendered to text (objectives,
    /// sections, questions, coverage status). Lets the assist panel answer
    /// questions about the guide and what's been covered.
    public var discussionGuide: String?
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

    public init(
        baseSystemPrompt: String = "",
        meetingContext: String? = nil,
        meetingBrief: String? = nil,
        discussionGuide: String? = nil,
        glossaryFragment: String? = nil,
        referenceText: String? = nil,
        referenceModeName: String? = nil,
        screenContext: String? = nil,
        referencedDocuments: String? = nil
    ) {
        self.baseSystemPrompt = baseSystemPrompt
        self.meetingContext = meetingContext
        self.meetingBrief = meetingBrief
        self.discussionGuide = discussionGuide
        self.glossaryFragment = glossaryFragment
        self.referenceText = referenceText
        self.referenceModeName = referenceModeName
        self.screenContext = screenContext
        self.referencedDocuments = referencedDocuments
    }

    public var hasContent: Bool {
        meetingContext != nil
            || meetingBrief != nil
            || discussionGuide != nil
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

        if let guide = context.discussionGuide?.trimmingCharacters(in: .whitespacesAndNewlines),
           !guide.isEmpty {
            let capped = guide.count > referenceCap
                ? String(guide.prefix(referenceCap)) + "\n…[truncated]"
                : guide
            msgs.append(LLMMessage(
                role: "system",
                content: """
                The discussion guide for this session, with live coverage status. Use it to \
                answer the user's questions about the guide — what's left to cover, what a \
                participant has said on a topic so far, what to ask or probe next, and which \
                objective a thread maps to. Don't read it back wholesale; answer what's asked.
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
            msgs.append(LLMMessage(
                role: "system",
                content: """
                The user explicitly attached or @mentioned the following document(s) for this turn. \
                Treat them as the authoritative source material for the question. Do not search the vault or \
                replace them with broader retrieved sources unless the user explicitly asks you to compare, \
                verify, or look beyond these documents.
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
        fullContent: String
    ) -> [LLMMessage] {
        var msgs: [LLMMessage] = []
        for (idx, entry) in entries.enumerated() {
            let isLatestUser = idx == entries.count - 1 && entry.role == "user"
            let content = isLatestUser ? fullContent : entry.text
            if content.isEmpty, !isLatestUser { continue }
            msgs.append(LLMMessage(role: entry.role, content: content))
        }
        return msgs
    }
}
