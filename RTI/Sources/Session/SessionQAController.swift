import Foundation

@MainActor
final class SessionQAController: ObservableObject {
    static let shared = SessionQAController()

    @Published private(set) var isGenerating = false
    @Published private(set) var lastError: String?
    @Published private(set) var messages: [QAEntry] = []

    private let request: LLMRequest

    init(request: LLMRequest = LLMRequest()) {
        self.request = request
    }

    struct QAEntry: Identifiable {
        let id = UUID()
        let role: String // "user" | "assistant"
        var text: String
        let createdAt: Date = Date()
    }

    func clear() {
        messages = []
        lastError = nil
        isGenerating = false
    }

    func ask(question: String, sessionId: String) {
        guard !isGenerating else { return }
        isGenerating = true
        lastError = nil

        let context = buildContext(sessionId: sessionId)
        guard !context.isEmpty else {
            lastError = "No transcript or summary available for this session."
            isGenerating = false
            return
        }

        messages.append(QAEntry(role: "user", text: question))

        let systemPrompt = """
        You are RTI, the user's meeting assistant. Answer questions based ONLY on the provided session transcript and summary below.
        If the answer isn't in the transcript, say so briefly. Be concise and helpful.

        If the context contains a "## User notes" block, treat those notes as authoritative corrections
        from the user (e.g. name spellings, identity clarifications, factual fixes). Prefer them over
        anything in the raw transcript.

        Session context:
        \(context)
        """

        let apiMessages = [
            LLMMessage(role: "system", content: systemPrompt),
            LLMMessage(role: "user", content: question)
        ]

        let assistantEntry = QAEntry(role: "assistant", text: "")
        messages.append(assistantEntry)
        let entryId = assistantEntry.id

        request.stream(
            messages: apiMessages,
            smart: false,
            onDelta: { [weak self] delta in
                Task { @MainActor [weak self] in
                    if let idx = self?.messages.firstIndex(where: { $0.id == entryId }) {
                        self?.messages[idx].text += delta
                    }
                }
            },
            onError: { [weak self] errorMessage, _ in
                Task { @MainActor [weak self] in
                    self?.lastError = errorMessage
                    if let idx = self?.messages.firstIndex(where: { $0.id == entryId }) {
                        self?.messages.remove(at: idx)
                    }
                }
            },
            onComplete: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.isGenerating = false
                }
            }
        )
    }

    private func buildContext(sessionId: String) -> String {
        var parts: [String] = []
        if let summary = CorpusBackedStore.summary(forSessionId: sessionId) {
            parts.append("## Meeting Summary")
            parts.append(summary.summaryText)
        }
        let transcript = TranscriptContext.text(forSessionId: sessionId)
        if !transcript.isEmpty {
            parts.append("## Full Transcript")
            parts.append(transcript)
        }
        return parts.joined(separator: "\n\n")
    }
}
