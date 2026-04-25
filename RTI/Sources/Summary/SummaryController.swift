import Foundation
import GRDB

@MainActor
final class SummaryController: ObservableObject {
    static let shared = SummaryController()

    @Published private(set) var isGenerating = false
    @Published private(set) var lastError: String?

    private let client: KimiClient

    private init() {
        self.client = KimiClient(baseURL: Secrets.kimiBaseURL)
    }

    private static let summaryPrompt = """
    You are an AI meeting assistant. Below is the full transcript of a conversation.

    Produce a structured meeting summary using this exact format:

    ## Action Items
    - List each action item with the person responsible (if identifiable from context).

    ## Key Topics
    - List the main topics discussed, one per bullet.

    ## Decisions
    - List any decisions that were made, one per bullet.

    ## Follow-ups
    - List any follow-up items or next steps needed, one per bullet.

    If a section has no content, write "None." under that heading.

    Transcript:
    """

    func generateSummary(for sessionId: String) async {
        guard !isGenerating else { return }
        isGenerating = true
        lastError = nil

        defer { isGenerating = false }

        let transcript: String
        do {
            transcript = try await RTIDatabase.shared.pool.read { db in
                let entries = try TranscriptEntry
                    .filter(Column("session_id") == sessionId)
                    .filter(Column("is_final") == 1)
                    .order(Column("start_ms"))
                    .fetchAll(db)
                return entries.map { "\($0.speakerId): \($0.text)" }.joined(separator: "\n")
            }
        } catch {
            lastError = "Failed to load transcript: \(error)"
            NSLog("[RTI] SummaryController transcript load failed: \(error)")
            return
        }

        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "No transcript content to summarize."
            return
        }

        let fullPrompt = Self.summaryPrompt + "\n" + transcript
        let messages = [KimiMessage(role: "user", content: fullPrompt)]

        var fullResponse = ""
        do {
            for try await delta in client.streamChat(messages: messages, smart: true) {
                fullResponse += delta
            }
        } catch {
            lastError = "Summary generation failed: \(error)"
            NSLog("[RTI] SummaryController stream error: \(error)")
            return
        }

        guard !fullResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "Summary generation returned empty response."
            return
        }

        let parsed = Self.parseSections(from: fullResponse)
        let responseText = fullResponse

        let summary = SessionSummary(
            id: UUID().uuidString,
            sessionId: sessionId,
            summaryText: responseText,
            actionItems: parsed["Action Items"],
            keyTopics: parsed["Key Topics"],
            decisions: parsed["Decisions"],
            followUps: parsed["Follow-ups"],
            rawResponse: responseText,
            createdAt: Date(),
            regeneratedAt: nil
        )

        do {
            try await RTIDatabase.shared.pool.write { db in
                if let existing = try SessionSummary.fetchOne(db, key: sessionId) {
                    var updated = existing
                    updated.summaryText = responseText
                    updated.actionItems = parsed["Action Items"]
                    updated.keyTopics = parsed["Key Topics"]
                    updated.decisions = parsed["Decisions"]
                    updated.followUps = parsed["Follow-ups"]
                    updated.rawResponse = responseText
                    updated.regeneratedAt = Date()
                    try updated.update(db)
                } else {
                    try summary.insert(db)
                }
            }
        } catch {
            lastError = "Failed to save summary: \(error)"
            NSLog("[RTI] SummaryController save failed: \(error)")
        }
    }

    func loadSummary(for sessionId: String) -> SessionSummary? {
        do {
            return try RTIDatabase.shared.pool.read { db in
                try SessionSummary.fetchOne(db, key: sessionId)
            }
        } catch {
            NSLog("[RTI] SummaryController load failed: \(error)")
            return nil
        }
    }

    func hasSummary(for sessionId: String) -> Bool {
        loadSummary(for: sessionId) != nil
    }

    static func parseSections(from markdown: String) -> [String: String] {
        var result: [String: String] = [:]
        let lines = markdown.components(separatedBy: "\n")
        var currentSection: String?
        var currentContent: [String] = []

        for line in lines {
            if line.hasPrefix("## ") {
                if let section = currentSection {
                    result[section] = currentContent.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                currentSection = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                currentContent = []
            } else {
                currentContent.append(line)
            }
        }

        if let section = currentSection {
            result[section] = currentContent.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return result
    }
}
