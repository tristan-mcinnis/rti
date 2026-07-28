import Foundation
import RTICore

enum AssistantTurnBuilder {
    struct Input {
        let userInput: String
        let action: String
        let transcript: String
        let fullTranscript: Bool
        let workstreamScopePath: String?
        let hasWorkstreamName: Bool
        let priorSuggestions: String
        let hasReferencedDocuments: Bool
        let retrievalContext: String?
        let guideCoverage: String
        let baseSystemPrompt: String
        let listenerSystemSuffix: String
        let listenerMode: Bool
        let meetingContext: String?
        let meetingBrief: String?
        let discussionGuide: String?
        let glossaryFragment: String?
        let referenceText: String?
        let referenceModeName: String?
        let screenContext: String?
        let referencedDocumentsText: String?
        let existingEntries: [ChatEntry]
    }

    struct Output {
        let fullContent: String
        let promptContext: PromptContext
        let apiMessages: [LLMMessage]
        let contextUsed: Bool
        let screenUsed: Bool
    }

    static func build(_ input: Input) -> Output {
        let transcript = input.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let contextUsed = !transcript.isEmpty
        let contextLabel = input.fullTranscript
            ? "Full meeting transcript (diarized)"
            : "Recent conversation (last 15 minutes, diarized)"
        var fullContent = contextUsed
            ? "\(contextLabel):\n\(transcript)\n\nUser question: \(input.userInput)"
            : input.userInput

        if let scope = input.workstreamScopePath {
            fullContent += "\n\nProject scope is set to `\(scope)`. For any question that asks about prior decisions, prior research, project facts, what a participant said in an earlier session, or anything not fully answered by the live transcript, use the vault tools before answering. For questions only about the current live conversation, answer from the transcript."
        } else if input.hasWorkstreamName {
            fullContent += "\n\nA meeting context is selected. Use it to ground the answer. If the user asks about prior knowledge or documents, use the vault tools."
        } else {
            fullContent += "\n\nNo project or client is selected. For any question that asks about prior decisions, prior research, project facts, what someone said in an earlier session, or anything not fully answered by the live transcript, use the vault tools across the entire vault before answering. For questions only about the current live conversation, answer from the transcript."
        }

        let prior = input.priorSuggestions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prior.isEmpty {
            fullContent += "\n\nYou already suggested the following earlier in this session — do NOT repeat or rephrase these; build on the newest conversation instead:\n\(prior)"
        }
        if input.hasReferencedDocuments {
            fullContent += "\n\nThe user explicitly attached source material for this turn. Answer directly from it. Do not search the vault or substitute unrelated sources unless the user explicitly asks for a comparison, broader lookup, or verification."
        }
        if let retrievalContext = input.retrievalContext?.trimmingCharacters(in: .whitespacesAndNewlines), !retrievalContext.isEmpty {
            fullContent += "\n\n\(retrievalContext)\nUse these retrieved vault results when relevant. Cite the source path briefly when you rely on them. Do not narrate the search process or say you will do another search. If the retrieved results are not relevant enough, say that directly and ask for a project/client selection or a narrower term."
        }
        fullContent += "\n\nFormat for the RTI overlay: answer directly and keep paragraphs short. Never use markdown tables unless the user explicitly asks for a table; when they do ask for a table, use a real markdown table with short cells and 2-4 columns. For ordinary comparisons, prefer compact headings + bullets. When answering about @mentioned files, use readable file names; avoid full paths unless the path itself matters."
        if ["Assist", "Follow-ups", "Probe"].contains(input.action),
           !input.guideCoverage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fullContent += "\n\n\(input.guideCoverage)"
        }

        let base = input.baseSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectivePrompt = input.listenerMode
            ? base + "\n\n" + input.listenerSystemSuffix
            : base
        let promptContext = PromptContext(
            baseSystemPrompt: effectivePrompt,
            meetingContext: input.meetingContext,
            meetingBrief: input.listenerMode ? nil : input.meetingBrief,
            discussionGuide: input.discussionGuide,
            glossaryFragment: input.glossaryFragment,
            referenceText: input.referenceText,
            referenceModeName: input.referenceModeName,
            screenContext: input.screenContext,
            referencedDocuments: input.referencedDocumentsText
        )

        var entries = input.existingEntries
        entries.append(ChatEntry(
            role: "user",
            text: input.userInput,
            action: input.action,
            contextUsed: contextUsed,
            screenContextUsed: input.screenContext != nil
        ))
        var apiMessages = PromptBuilder.buildSystemMessages(context: promptContext)
        apiMessages.append(contentsOf: PromptBuilder.buildConversationMessages(entries: entries, fullContent: fullContent))

        return Output(
            fullContent: fullContent,
            promptContext: promptContext,
            apiMessages: apiMessages,
            contextUsed: contextUsed,
            screenUsed: input.screenContext != nil
        )
    }
}
