import Foundation

/// Project-scoped Q&A. Mirrors `AskCorpusController` but restricts
/// retrieval to a single project's member sessions and prepends the
/// project's instructions to the system prompt. One controller per live
/// project chat — instantiated by the projects view as the user
/// navigates between projects.
///
/// All streaming/state/citation logic lives in `CorpusChatController`.
/// This subclass only supplies project-scoped retrieval, the prompt,
/// and per-project conversation persistence.
@MainActor
final class ProjectQAController: CorpusChatController {
    typealias Entry = CorpusChatEntry
    typealias Citation = CorpusChatCitation

    let projectId: String

    /// Hard upper bound on candidates fed to the LLM. Each candidate
    /// contributes a summary (≤1500 chars) plus an FTS snippet, so 12 keeps
    /// us well under provider context budgets while widening recall vs the
    /// original cap of 8. Member count beyond this falls back to a recency
    /// slice — the alternative (summary-of-summaries) is a follow-up.
    private static let candidateCap = 12

    init(projectId: String) {
        self.projectId = projectId
        super.init()
    }

    func load(_ conversation: ProjectChatConversation) {
        RTILog.log("load chat — id=\(conversation.id.suffix(8)) turns=\(conversation.messages.count)", category: "projects")
        let restored = conversation.messages.map { stored in
            CorpusChatEntry(
                role: stored.role,
                text: stored.text,
                citations: stored.citations.map { Citation(sessionId: $0.sessionId, title: $0.title) },
                createdAt: stored.createdAt
            )
        }
        adoptRestoredConversation(id: conversation.id, title: conversation.title, messages: restored)
    }

    // MARK: - Strategy

    override func retrieve(forQuestion question: String) throws -> [CorpusChatCandidate] {
        let memberIds = ProjectStore.shared.sessionIds(forProject: projectId)
        let project = ProjectStore.shared.projects.first { $0.id == projectId }
        let projectName = project?.name ?? "(unknown)"
        let instructions = project?.instructions.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !memberIds.isEmpty else {
            RTILog.log("ask blocked — project=\"\(projectName)\" has no member sessions", category: "projects")
            throw CorpusChatError(message: "Add sessions to the project before asking questions.")
        }

        RTILog.log("ask — project=\"\(projectName)\" members=\(memberIds.count) instr=\(instructions.count) q=\"\(question.prefix(80))\"", category: "projects")

        let members = Set(memberIds)
        var seen = Set<String>()
        var out: [CorpusChatCandidate] = []

        // 1) Hybrid hits (BM25 + dense, RRF-merged) scoped to this
        //    project's members. HybridRetriever falls back to FTS-only
        //    if the dense index isn't ready.
        for hit in HybridRetriever.retrieve(query: question, limit: Self.candidateCap * 2)
            where members.contains(hit.session.id)
        {
            guard !seen.contains(hit.session.id) else { continue }
            seen.insert(hit.session.id)
            out.append(CorpusChatCandidate(
                session: hit.session,
                title: Self.displayTitle(for: hit.session),
                snippet: hit.bestSnippet,
                summary: CorpusBackedStore.summary(forSessionId: hit.session.id)?.summaryText
            ))
        }
        let hybridHits = out.count

        // 2) Fill remaining slots with the most recent member sessions FTS
        //    missed — recency biases toward "what did we just discuss".
        let allMembers = CorpusBackedStore.allMarkdownSessions()
            .filter { members.contains($0.id) }
            .sorted { $0.startedAt > $1.startedAt }
        for s in allMembers where !seen.contains(s.id) {
            seen.insert(s.id)
            out.append(CorpusChatCandidate(
                session: s,
                title: Self.displayTitle(for: s),
                snippet: nil,
                summary: CorpusBackedStore.summary(forSessionId: s.id)?.summaryText
            ))
        }

        let final = Array(out.prefix(Self.candidateCap))
        let dropped = max(0, out.count - Self.candidateCap)
        RTILog.log(
            "retrieve — hybrid=\(hybridHits) recency=\(out.count - hybridHits) used=\(final.count)\(dropped > 0 ? " dropped=\(dropped)" : "")",
            category: "projects"
        )
        guard !final.isEmpty else {
            RTILog.log("ask aborted — no candidates resolved despite \(memberIds.count) member ids", category: "projects")
            throw CorpusChatError(message: "Could not load any of this project's sessions. Try removing and re-adding them.")
        }
        return final
    }

    override func makeSystemPrompt(context: String) -> String {
        let project = ProjectStore.shared.projects.first { $0.id == projectId }
        let instructions = project?.instructions.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var prompt = """
        You are RTI, the user's project assistant. The user is asking a question about a specific project ("\(project?.name ?? "Project")") that groups several past meetings.
        Use ONLY the meeting excerpts provided below — they are scoped to this project. If the answer isn't there, say so plainly.

        Cite sources inline using the EXACT bracket notation `[Session Title]` whenever you reference content from a specific meeting. Use the title verbatim from the excerpt headers. Multiple citations OK.

        Format with light markdown (bold for emphasis, bullets/numbers for lists). Keep paragraphs short.
        """
        if !instructions.isEmpty {
            prompt += "\n\nProject instructions from the user — follow these alongside the rules above:\n\(instructions)"
        }
        prompt += "\n\nMeeting excerpts:\n\(context)"
        return prompt
    }

    override func persistConversation() {
        guard let id = conversationId, !messages.isEmpty else { return }
        let now = Date()
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

    override func didEncounterStreamError(_ message: String) {
        RTILog.log("stream error — \(message)", category: "projects")
    }

    override func didFinishAnswer(body: String, candidateCount: Int, citedCount: Int) {
        RTILog.log("done — chars=\(body.count) candidates=\(candidateCount) cited=\(citedCount)", category: "projects")
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
