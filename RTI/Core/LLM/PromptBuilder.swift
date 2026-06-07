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
    /// Optional glossary terms the model should know.
    public var glossaryFragment: String?
    /// Reference text attached to the active mode.
    public var referenceText: String?
    /// Name of the mode providing the reference.
    public var referenceModeName: String?
    /// OCR text from an attached screenshot.
    public var screenContext: String?

    public init(
        baseSystemPrompt: String = "",
        meetingContext: String? = nil,
        glossaryFragment: String? = nil,
        referenceText: String? = nil,
        referenceModeName: String? = nil,
        screenContext: String? = nil
    ) {
        self.baseSystemPrompt = baseSystemPrompt
        self.meetingContext = meetingContext
        self.glossaryFragment = glossaryFragment
        self.referenceText = referenceText
        self.referenceModeName = referenceModeName
        self.screenContext = screenContext
    }

    public var hasContent: Bool {
        meetingContext != nil
            || glossaryFragment != nil
            || referenceText != nil
            || screenContext != nil
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
                content: "User attached a screenshot. OCR text from the screen follows. Treat it as what the user is looking at.\n---\n\(screenContext)\n---"
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
