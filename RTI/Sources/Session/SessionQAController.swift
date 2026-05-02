import Foundation

@MainActor
final class SessionQAController: ObservableObject {
    static let shared = SessionQAController()

    @Published private(set) var isGenerating = false
    @Published private(set) var lastError: String?
    @Published private(set) var messages: [QAEntry] = []

    private let client = DeepSeekClient.shared

    private init() {}

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

    func ask(question: String, sessionId: String) async {
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

        Session context:
        \(context)
        """

        let apiMessages = [
            DeepSeekMessage(role: "system", content: systemPrompt),
            DeepSeekMessage(role: "user", content: question)
        ]

        let assistantEntry = QAEntry(role: "assistant", text: "")
        messages.append(assistantEntry)
        let entryId = assistantEntry.id

        defer { isGenerating = false }

        do {
            for try await delta in client.streamChat(messages: apiMessages, smart: false) {
                if let idx = messages.firstIndex(where: { $0.id == entryId }) {
                    messages[idx].text += delta
                }
            }
        } catch {
            lastError = (error as? DeepSeekError)?.userMessage ?? "Q&A failed: \(error)"
            NSLog("[RTI] SessionQA error: \(error)")
            if let idx = messages.firstIndex(where: { $0.id == entryId }) {
                messages.remove(at: idx)
            }
        }
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
