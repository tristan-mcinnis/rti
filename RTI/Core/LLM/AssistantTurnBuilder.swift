import Foundation
import RTICore

public enum AssistantTurnBuilder {
    public struct Input {
        public let userInput: String
        public let action: String
        public let transcript: String
        public let fullTranscript: Bool
        /// Nominal minutes the trailing window covers, for the context label
        /// (5 for Quick recap, 15 by default). Ignored when `fullTranscript`.
        public let transcriptWindowMinutes: Int
        public let workstreamScopePath: String?
        public let hasWorkstreamName: Bool
        public let priorSuggestions: String
        /// What this turn carries, by origin: attached now, or retained from
        /// earlier in this chat. Drives the source instruction's wording.
        public let sourceContext: TurnSourceContext
        /// The tool policy's own answer for this turn, so the prompt never
        /// forbids a search the offered tools permit.
        public let externalRetrievalAllowed: Bool
        public let retrievalContext: String?
        public let baseSystemPrompt: String
        public let listenerSystemSuffix: String
        public let listenerMode: Bool
        public let meetingContext: String?
        public let meetingBrief: String?
        public let glossaryFragment: String?
        public let referenceText: String?
        public let referenceModeName: String?
        public let screenContext: String?
        /// Every image this turn carries, from each source's own normalized
        /// bytes (tray files, retained sources, and the screen capture). Rides
        /// the latest user message.
        public let images: [LLMImage]
        public let referencedDocumentsText: String?
        public let existingEntries: [ChatEntry]

        public init(
            userInput: String,
            action: String,
            transcript: String,
            fullTranscript: Bool,
            transcriptWindowMinutes: Int,
            workstreamScopePath: String?,
            hasWorkstreamName: Bool,
            priorSuggestions: String,
            sourceContext: TurnSourceContext,
            externalRetrievalAllowed: Bool,
            retrievalContext: String?,
            baseSystemPrompt: String,
            listenerSystemSuffix: String,
            listenerMode: Bool,
            meetingContext: String?,
            meetingBrief: String?,
            glossaryFragment: String?,
            referenceText: String?,
            referenceModeName: String?,
            screenContext: String?,
            images: [LLMImage],
            referencedDocumentsText: String?,
            existingEntries: [ChatEntry]
        ) {
            self.userInput = userInput
            self.action = action
            self.transcript = transcript
            self.fullTranscript = fullTranscript
            self.transcriptWindowMinutes = transcriptWindowMinutes
            self.workstreamScopePath = workstreamScopePath
            self.hasWorkstreamName = hasWorkstreamName
            self.priorSuggestions = priorSuggestions
            self.sourceContext = sourceContext
            self.externalRetrievalAllowed = externalRetrievalAllowed
            self.retrievalContext = retrievalContext
            self.baseSystemPrompt = baseSystemPrompt
            self.listenerSystemSuffix = listenerSystemSuffix
            self.listenerMode = listenerMode
            self.meetingContext = meetingContext
            self.meetingBrief = meetingBrief
            self.glossaryFragment = glossaryFragment
            self.referenceText = referenceText
            self.referenceModeName = referenceModeName
            self.screenContext = screenContext
            self.images = images
            self.referencedDocumentsText = referencedDocumentsText
            self.existingEntries = existingEntries
        }
    }

    public struct Output {
        public let fullContent: String
        public let promptContext: PromptContext
        public let apiMessages: [LLMMessage]
        public let contextUsed: Bool
        public let screenUsed: Bool

        public init(
            fullContent: String,
            promptContext: PromptContext,
            apiMessages: [LLMMessage],
            contextUsed: Bool,
            screenUsed: Bool
        ) {
            self.fullContent = fullContent
            self.promptContext = promptContext
            self.apiMessages = apiMessages
            self.contextUsed = contextUsed
            self.screenUsed = screenUsed
        }
    }

    public static func build(_ input: Input) -> Output {
        let transcript = input.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let contextUsed = !transcript.isEmpty
        let contextLabel = input.fullTranscript
            ? "Full meeting transcript (diarized)"
            : "Recent conversation (last \(input.transcriptWindowMinutes) minutes, diarized)"
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
        if let instruction = TurnSourceInstruction.text(
            for: input.sourceContext,
            externalRetrievalAllowed: input.externalRetrievalAllowed
        ) {
            fullContent += "\n\n\(instruction)"
        }
        if let retrievalContext = input.retrievalContext?.trimmingCharacters(in: .whitespacesAndNewlines), !retrievalContext.isEmpty {
            fullContent += "\n\n\(retrievalContext)\nUse these retrieved vault results when relevant. Cite the source path briefly when you rely on them. Do not narrate the search process or say you will do another search. If the retrieved results are not relevant enough, say that directly and ask for a project/client selection or a narrower term."
        }
        fullContent += "\n\nFormat for the RTI overlay: answer directly and keep paragraphs short. Never use markdown tables unless the user explicitly asks for a table; when they do ask for a table, use a real markdown table with short cells and 2-4 columns. For ordinary comparisons, prefer compact headings + bullets. When answering about @mentioned files, use readable file names; avoid full paths unless the path itself matters."

        let base = input.baseSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectivePrompt = input.listenerMode
            ? base + "\n\n" + input.listenerSystemSuffix
            : base
        let promptContext = PromptContext(
            baseSystemPrompt: effectivePrompt,
            meetingContext: input.meetingContext,
            meetingBrief: input.listenerMode ? nil : input.meetingBrief,
            glossaryFragment: input.glossaryFragment,
            referenceText: input.referenceText,
            referenceModeName: input.referenceModeName,
            screenContext: input.screenContext,
            referencedDocuments: input.referencedDocumentsText,
            sourceContext: input.sourceContext,
            externalRetrievalAllowed: input.externalRetrievalAllowed
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
        apiMessages.append(contentsOf: PromptBuilder.buildConversationMessages(
            entries: entries,
            fullContent: fullContent,
            images: input.images
        ))

        return Output(
            fullContent: fullContent,
            promptContext: promptContext,
            apiMessages: apiMessages,
            contextUsed: contextUsed,
            screenUsed: input.screenContext != nil
        )
    }
}
