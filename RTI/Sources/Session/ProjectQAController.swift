import Foundation

/// Project-scoped Q&A. Mirrors `AskCorpusController` but restricts
/// retrieval to a single project's member sessions and prepends the
/// project's instructions to the system prompt. One controller per live
/// project chat — instantiated by the projects view as the user
/// navigates between projects.
@MainActor
final class ProjectQAController: ObservableObject {
    @Published private(set) var isGenerating = false
    @Published private(set) var lastError: String?
    @Published private(set) var messages: [Entry] = []
    @Published private(set) var citationsForLast: [Citation] = []
    @Published private(set) var conversationId: String?
    @Published private(set) var conversationTitle: String?

    let projectId: String

    private let request = LLMRequest()

    struct Entry: Identifiable {
        let id = UUID()
        let role: String
        var text: String
        var citations: [Citation] = []
        var createdAt: Date = Date()
    }

    struct Citation: Identifiable, Hashable {
        var id: String { sessionId }
        let sessionId: String
        let title: String
    }

    init(projectId: String) {
        self.projectId = projectId
    }

    func newChat() {
        request.cancel()
        messages = []
        lastError = nil
        citationsForLast = []
        isGenerating = false
        conversationId = nil
        conversationTitle = nil
    }

    func stop() {
        request.cancel()
        isGenerating = false
    }

    func load(_ conversation: ProjectChatConversation) {
        request.cancel()
        isGenerating = false
        lastError = nil
        conversationId = conversation.id
        conversationTitle = conversation.title
        RTILog.log("load chat — id=\(conversation.id.suffix(8)) turns=\(conversation.messages.count)", category: "projects")
        messages = conversation.messages.map { stored in
            Entry(
                role: stored.role,
                text: stored.text,
                citations: stored.citations.map { Citation(sessionId: $0.sessionId, title: $0.title) },
                createdAt: stored.createdAt
            )
        }
        citationsForLast = messages.last?.citations ?? []
    }

    func ask(question: String) {
        guard !isGenerating else { return }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let memberIds = ProjectStore.shared.sessionIds(forProject: projectId)
        let project = ProjectStore.shared.projects.first { $0.id == projectId }
        let projectName = project?.name ?? "(unknown)"
        guard !memberIds.isEmpty else {
            lastError = "Add sessions to the project before asking questions."
            RTILog.log("ask blocked — project=\"\(projectName)\" has no member sessions", category: "projects")
            return
        }
        let instructions = project?.instructions.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        RTILog.log("ask — project=\"\(projectName)\" members=\(memberIds.count) instr=\(instructions.count) q=\"\(trimmed.prefix(80))\"", category: "projects")

        isGenerating = true
        lastError = nil
        messages.append(Entry(role: "user", text: trimmed))

        let candidates = retrieve(forQuestion: trimmed, memberIds: Set(memberIds))
        guard !candidates.isEmpty else {
            lastError = "Could not load any of this project's sessions. Try removing and re-adding them."
            RTILog.log("ask aborted — no candidates resolved despite \(memberIds.count) member ids", category: "projects")
            isGenerating = false
            messages.removeLast()
            return
        }

        let context = buildContext(candidates)
        let candidateCitations = candidates.map { Citation(sessionId: $0.session.id, title: $0.title) }

        var systemPrompt = """
        You are RTI, the user's project assistant. The user is asking a question about a specific project ("\(project?.name ?? "Project")") that groups several past meetings.
        Use ONLY the meeting excerpts provided below — they are scoped to this project. If the answer isn't there, say so plainly.

        Cite sources inline using the EXACT bracket notation `[Session Title]` whenever you reference content from a specific meeting. Use the title verbatim from the excerpt headers. Multiple citations OK.

        Format with light markdown (bold for emphasis, bullets/numbers for lists). Keep paragraphs short.
        """
        if !instructions.isEmpty {
            systemPrompt += "\n\nProject instructions from the user — follow these alongside the rules above:\n\(instructions)"
        }
        systemPrompt += "\n\nMeeting excerpts:\n\(context)"

        var apiMessages: [LLMMessage] = [LLMMessage(role: "system", content: systemPrompt)]
        if let glossary = GlossaryStore.shared.systemPromptFragment {
            apiMessages.append(LLMMessage(role: "system", content: glossary))
        }
        let priorTurns = messages.dropLast().suffix(6)
        for turn in priorTurns {
            apiMessages.append(LLMMessage(role: turn.role, content: turn.text))
        }
        apiMessages.append(LLMMessage(role: "user", content: trimmed))

        var assistantEntry = Entry(role: "assistant", text: "")
        assistantEntry.citations = []
        messages.append(assistantEntry)
        let entryId = assistantEntry.id

        request.stream(
            messages: apiMessages,
            smart: false,
            onDelta: { [weak self] delta in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let idx = self.messages.firstIndex(where: { $0.id == entryId }) {
                        self.messages[idx].text += delta
                    }
                }
            },
            onError: { [weak self] errorMessage, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.lastError = errorMessage
                    RTILog.log("stream error — \(errorMessage)", category: "projects")
                    if let idx = self.messages.firstIndex(where: { $0.id == entryId }) {
                        self.messages.remove(at: idx)
                    }
                    self.isGenerating = false
                }
            },
            onComplete: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isGenerating = false
                    if let idx = self.messages.firstIndex(where: { $0.id == entryId }) {
                        let body = self.messages[idx].text
                        let cited = Self.actualCitations(from: body, candidates: candidateCitations)
                        self.messages[idx].citations = cited
                        self.citationsForLast = cited
                        RTILog.log("done — chars=\(body.count) candidates=\(candidateCitations.count) cited=\(cited.count)", category: "projects")
                    }
                    self.persistToHistory()
                }
            }
        )
    }

    // MARK: - Persistence

    private func persistToHistory() {
        guard !messages.isEmpty else { return }
        let now = Date()
        if conversationId == nil {
            conversationId = UUID().uuidString
            conversationTitle = Self.deriveTitle(from: messages)
        }
        guard let id = conversationId else { return }
        let conversation = ProjectChatConversation(
            id: id,
            projectId: projectId,
            title: conversationTitle ?? "Untitled",
            createdAt: messages.first?.createdAt ?? now,
            updatedAt: now,
            messages: messages.map { entry in
                ProjectChatConversation.StoredEntry(
                    role: entry.role,
                    text: entry.text,
                    createdAt: entry.createdAt,
                    citations: entry.citations.map {
                        ProjectChatConversation.StoredCitation(sessionId: $0.sessionId, title: $0.title)
                    }
                )
            }
        )
        ProjectChatHistoryStore.save(conversation)
    }

    private static func deriveTitle(from messages: [Entry]) -> String {
        guard let firstUser = messages.first(where: { $0.role == "user" })?.text else {
            return "Untitled"
        }
        let trimmed = firstUser.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 60 { return trimmed }
        let cut = trimmed.prefix(60)
        if let lastSpace = cut.lastIndex(of: " ") {
            return String(trimmed[..<lastSpace]) + "…"
        }
        return String(cut) + "…"
    }

    // MARK: - Citation parsing

    private static func actualCitations(from body: String, candidates: [Citation]) -> [Citation] {
        var cited: [Citation] = []
        var seen = Set<String>()
        for c in candidates {
            if body.contains("[\(c.title)]"), !seen.contains(c.sessionId) {
                cited.append(c)
                seen.insert(c.sessionId)
            }
        }
        if cited.isEmpty { return Array(candidates.prefix(3)) }
        return cited
    }

    // MARK: - Retrieval

    private struct Candidate {
        let session: Session
        let title: String
        let snippet: String?
        let summary: String?
    }

    /// Project-scoped retrieval. FTS hits are filtered down to the project's
    /// member set; anything left over comes from the member set itself
    /// (so questions about less-textual sessions still hit context).
    /// Hard upper bound on candidates fed to the LLM. Each candidate
    /// contributes a summary (≤1500 chars) plus an FTS snippet, so 12 keeps
    /// us well under provider context budgets while widening recall vs the
    /// original cap of 8. Member count beyond this falls back to a recency
    /// slice — the alternative (summary-of-summaries) is a follow-up.
    private static let candidateCap = 12

    private func retrieve(forQuestion question: String, memberIds: Set<String>) -> [Candidate] {
        var seen = Set<String>()
        var out: [Candidate] = []

        // 1) FTS hits scoped to this project's members — these win first
        //    because BM25 already ranked them by relevance.
        for hit in SessionSearch.search(query: question, limit: Self.candidateCap * 2)
            where memberIds.contains(hit.session.id)
        {
            guard !seen.contains(hit.session.id) else { continue }
            seen.insert(hit.session.id)
            out.append(Candidate(
                session: hit.session,
                title: displayTitle(hit.session),
                snippet: hit.snippet,
                summary: CorpusBackedStore.summary(forSessionId: hit.session.id)?.summaryText
            ))
        }
        let ftsHits = out.count

        // 2) Fill remaining slots with the most recent member sessions that
        //    FTS missed. Recency biases toward "what did we just discuss" —
        //    the typical project-chat use case.
        let allMembers = CorpusBackedStore.allMarkdownSessions()
            .filter { memberIds.contains($0.id) }
            .sorted { $0.startedAt > $1.startedAt }
        for s in allMembers where !seen.contains(s.id) {
            seen.insert(s.id)
            out.append(Candidate(
                session: s,
                title: displayTitle(s),
                snippet: nil,
                summary: CorpusBackedStore.summary(forSessionId: s.id)?.summaryText
            ))
        }

        let final = Array(out.prefix(Self.candidateCap))
        let dropped = max(0, out.count - Self.candidateCap)
        RTILog.log(
            "retrieve — fts=\(ftsHits) fallback=\(out.count - ftsHits) used=\(final.count)\(dropped > 0 ? " dropped=\(dropped)" : "")",
            category: "projects"
        )
        return final
    }

    private func displayTitle(_ session: Session) -> String {
        if let t = session.calendarTitle, !t.isEmpty { return t }
        if let t = session.title, !t.isEmpty { return t }
        return "Session \(session.startedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private func buildContext(_ candidates: [Candidate]) -> String {
        var parts: [String] = []
        for c in candidates {
            var block = "### [\(c.title)]\n"
            block += "Date: \(c.session.startedAt.formatted(date: .abbreviated, time: .shortened))\n"
            if let summary = c.summary, !summary.isEmpty {
                block += "Summary:\n\(summary.prefix(1500))\n"
            }
            if let snippet = c.snippet, !snippet.isEmpty {
                block += "Match: \(snippet)\n"
            }
            parts.append(block)
        }
        return parts.joined(separator: "\n---\n")
    }
}

// MARK: - Persistence model

struct ProjectChatConversation: Codable, Identifiable {
    let id: String
    let projectId: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [StoredEntry]

    struct StoredEntry: Codable {
        let role: String
        var text: String
        let createdAt: Date
        var citations: [StoredCitation]
    }

    struct StoredCitation: Codable {
        let sessionId: String
        let title: String
    }
}

enum ProjectChatHistoryStore {

    static var rootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("RTI/projects-chat", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func directory(for projectId: String) -> URL {
        let dir = rootDirectory.appendingPathComponent(projectId, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func list(projectId: String) -> [ProjectChatConversation] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory(for: projectId),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [ProjectChatConversation] = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let conv = try? decoder.decode(ProjectChatConversation.self, from: data)
            else { continue }
            out.append(conv)
        }
        return out.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func save(_ conversation: ProjectChatConversation) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(conversation) else { return }
        let url = directory(for: conversation.projectId).appendingPathComponent("\(conversation.id).json")
        try? data.write(to: url, options: .atomic)
    }

    static func delete(projectId: String, conversationId: String) {
        let url = directory(for: projectId).appendingPathComponent("\(conversationId).json")
        try? FileManager.default.removeItem(at: url)
    }
}
