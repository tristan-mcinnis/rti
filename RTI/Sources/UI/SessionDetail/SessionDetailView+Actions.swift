import GRDB
import SwiftUI

extension SessionDetailView {
    // MARK: - Actions

    func copySummary() {
        guard let text = summary?.summaryText else { return }
        NSPasteboard.copyMarkdownRich(text)
        toast.show("Summary copied")
    }

    func copyTranscript() {
        let text = transcripts.map { "\(SpeakerLabels.displayName(for: $0.speakerId)): \($0.text)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        toast.show("Transcript copied")
    }

    func regenerateSummary() {
        Task {
            await generateSummary()
            toast.show("Summary regenerated")
        }
    }

    func regenerateTranscript() {
        regenerator.regenerate(sessionId: sessionId)
        // Completion toast fires from the regenerator state observer above.
    }

    func exportSession() {
        SessionExport.exportToFile(sessionId: sessionId)
    }

    func generateSummary() async {
        _ = await SummaryController.shared.generateSummary(for: sessionId)
        summary = SummaryController.shared.loadSummary(for: sessionId)
    }

    func submitQA() {
        let question = qaInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        let capped = question.count > 4000 ? String(question.prefix(4000)) : question
        qaInput = ""
        if selectedTab != .qa {
            withAnimation(.easeInOut(duration: 0.18)) { selectedTab = .qa }
        }
        Task {
            qaController.ask(question: capped, sessionId: sessionId)
        }
    }

    func resumeSession() {
        SessionCoordinator.shared.resumeSession(id: sessionId)
    }

    func loadData() {
        // Corpus-backed reads: session metadata + transcript come from
        // markdown (or live JSONL for an in-flight session); chat history
        // remains in SQLite as the interaction log.
        session = CorpusBackedStore.session(id: sessionId)
        transcripts = CorpusBackedStore.transcripts(forSessionId: sessionId)
        summary = CorpusBackedStore.summary(forSessionId: sessionId)
            ?? SummaryController.shared.loadSummary(for: sessionId)
        do {
            chatMessages = try RTIDatabase.shared.pool.read { db in
                try ChatMessage
                    .filter(Column("session_id") == sessionId)
                    .order(Column("created_at"))
                    .fetchAll(db)
            }
        } catch {
            NSLog("[RTI] SessionDetail chat load failed: \(error)")
        }
        notes = NotesGenerationController.loadNotes(forSessionId: sessionId)
        dossiers = DossierController.loadDossiers(forSessionId: sessionId)
    }

    func timeLabel(ms: Int) -> String {
        TimeFormat.stampMs(ms)
    }

    func formatDuration(_ interval: TimeInterval) -> String {
        TimeFormat.duration(interval)
    }

    /// Insert paragraph breaks every ~3 sentences so a long monologue
    /// renders as readable paragraphs instead of one dense wall of text.
    /// Sentence boundaries are detected on `.`, `?`, `!` followed by a
    /// space and a capital/digit. Short text (< ~3 sentences) is left
    /// unchanged.
    static func paragraphSplit(_ text: String, sentencesPerParagraph: Int = 3) -> String {
        guard text.count > 240 else { return text }
        var sentences: [String] = []
        var current = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            current.append(c)
            if (c == "." || c == "?" || c == "!"),
               i + 2 < chars.count,
               chars[i + 1] == " ",
               chars[i + 2].isLetter || chars[i + 2].isNumber {
                sentences.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                i += 2
                continue
            }
            i += 1
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }
        guard sentences.count > sentencesPerParagraph else { return text }
        var paragraphs: [String] = []
        var buf: [String] = []
        for s in sentences {
            buf.append(s)
            if buf.count >= sentencesPerParagraph {
                paragraphs.append(buf.joined(separator: " "))
                buf = []
            }
        }
        if !buf.isEmpty { paragraphs.append(buf.joined(separator: " ")) }
        return paragraphs.joined(separator: "\n\n")
    }
}
