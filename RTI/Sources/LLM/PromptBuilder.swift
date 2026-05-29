import Foundation

/// Contextual attachments injected into the system prompt before every
/// chat turn. The caller (LLMController) populates this from its current
/// state; PromptBuilder assembles the ordered message list.
struct PromptContext {
    /// The base system prompt (from the active mode, or the default).
    var baseSystemPrompt: String = ""
    /// Optional glossary terms the model should know.
    var glossaryFragment: String? = nil
    /// Name + instructions of the active project (both nil if none).
    var projectName: String? = nil
    var projectInstructions: String? = nil
    /// Reference text attached to the active mode.
    var referenceText: String? = nil
    /// Name of the mode providing the reference.
    var referenceModeName: String? = nil
    /// OCR text from an attached screenshot.
    var screenContext: String? = nil

    var hasContent: Bool {
        glossaryFragment != nil
            || projectName != nil
            || referenceText != nil
            || screenContext != nil
    }
}

/// Builds the ordered [LLMMessage] list fed to the LLM for every chat turn.
/// Owns the ordering, separators, truncation, and tagging conventions so
/// LLMController doesn't duplicate the assembly logic.
enum PromptBuilder {
    /// Maximum characters of reference text to include.
    private static let referenceCap = 8000

    /// Build the system-level messages (prompt, glossary, project, reference,
    /// screen context) that precede the conversation history.
    static func buildSystemMessages(context: PromptContext) -> [LLMMessage] {
        var msgs: [LLMMessage] = []

        let basePrompt = context.baseSystemPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !basePrompt.isEmpty {
            msgs.append(LLMMessage(role: "system", content: basePrompt))
        }

        if let glossary = context.glossaryFragment {
            msgs.append(LLMMessage(role: "system", content: glossary))
        }

        if let projectName = context.projectName {
            let instructions = (context.projectInstructions ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var content = "This session belongs to the user's project \"\(projectName)\"."
            if !instructions.isEmpty {
                content += " Project instructions follow — follow these alongside the rules above:\n---\n\(instructions)\n---"
            }
            msgs.append(LLMMessage(role: "system", content: content))
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
    static func buildConversationMessages(
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
