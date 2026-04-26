import Foundation
import GRDB

@MainActor
final class SessionQAController: ObservableObject {
    static let shared = SessionQAController()

    @Published private(set) var isGenerating = false
    @Published private(set) var lastError: String?
    @Published private(set) var messages: [QAEntry] = []

    private let client: KimiClient

    private init() {
        self.client = KimiClient(baseURL: Secrets.kimiBaseURL)
    }

    struct QAEntry: Identifiable {
        let id = UUID()
        let role: String // "user" | "assistant"
        var text: String
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

        let context = await buildContext(sessionId: sessionId)
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

        let kimiMessages = [
            KimiMessage(role: "system", content: systemPrompt),
            KimiMessage(role: "user", content: question)
        ]

        let assistantEntry = QAEntry(role: "assistant", text: "")
        messages.append(assistantEntry)
        let entryId = assistantEntry.id

        defer { isGenerating = false }

        do {
            for try await delta in client.streamChat(messages: kimiMessages, smart: false) {
                if let idx = messages.firstIndex(where: { $0.id == entryId }) {
                    messages[idx].text += delta
                }
            }
        } catch {
            lastError = "Q&A failed: \(error)"
            NSLog("[RTI] SessionQA error: \(error)")
            if let idx = messages.firstIndex(where: { $0.id == entryId }) {
                messages.remove(at: idx)
            }
        }
    }

    private func buildContext(sessionId: String) async -> String {
        do {
            return try await RTIDatabase.shared.pool.read { db in
                var parts: [String] = []

                if let summary = try SessionSummary.filter(Column("session_id") == sessionId).fetchOne(db) {
                    parts.append("## Meeting Summary")
                    parts.append(summary.summaryText)
                }

                let entries = try TranscriptEntry
                    .filter(Column("session_id") == sessionId)
                    .filter(Column("is_final") == 1)
                    .order(Column("start_ms"))
                    .fetchAll(db)

                if !entries.isEmpty {
                    parts.append("## Full Transcript")
                    for e in entries {
                        parts.append("\(e.speakerId): \(e.text)")
                    }
                }

                return parts.joined(separator: "\n\n")
            }
        } catch {
            NSLog("[RTI] SessionQA buildContext failed: \(error)")
            return ""
        }
    }
}
