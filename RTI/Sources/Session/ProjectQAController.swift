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

    func load(_ conversation: ProjectChatEntry) {
        RTILog.log("load chat — id=\(conversation.id.suffix(8)) turns=\(conversation.messages.count)", category: "projects")
        let restored = conversation.messages.map { m in
            CorpusChatEntry(
                role: m.role,
                text: m.text,
                citations: m.citations.map { Citation(sessionId: $0.sessionId, title: $0.title) },
                createdAt: m.createdAt
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

        // Hybrid hits scoped to this project's members, backfilled with the
        // members' most-recent sessions retrieval missed. The hybrid limit is
        // widened (cap × 2) because the scope filter discards out-of-project
        // hits before they reach the candidate list.
        let members = Set(memberIds)
        let assembly = Self.assembleCandidates(
            question: question,
            hybridLimit: Self.candidateCap * 2,
            cap: Self.candidateCap,
            includes: { members.contains($0) }
        )
        RTILog.log(
            "retrieve — hybrid=\(assembly.hybridCount) recency=\(assembly.recencyCount) used=\(assembly.candidates.count)\(assembly.dropped > 0 ? " dropped=\(assembly.dropped)" : "")",
            category: "projects"
        )
        guard !assembly.candidates.isEmpty else {
            RTILog.log("ask aborted — no candidates resolved despite \(memberIds.count) member ids", category: "projects")
            throw CorpusChatError(message: "Could not load any of this project's sessions. Try removing and re-adding them.")
        }
        return assembly.candidates
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
        guard let slug = ProjectStore.shared.slug(forProject: projectId) else {
            RTILog.log("persist skipped — no slug for project \(projectId.suffix(8))", category: "projects")
            return
        }
        let now = Date()
        let entry = ProjectChatEntry(
            id: id,
            projectId: projectId,
            title: conversationTitle ?? "Untitled",
            createdAt: messages.first?.createdAt ?? now,
            updatedAt: now,
            messages: messages.map { m in
                .init(
                    role: m.role,
                    text: m.text,
                    createdAt: m.createdAt,
                    citations: m.citations.map { .init(sessionId: $0.sessionId, title: $0.title) }
                )
            }
        )
        ProjectChatFileStore.save(entry, projectSlug: slug)
    }

    override func didEncounterStreamError(_ message: String) {
        RTILog.log("stream error — \(message)", category: "projects")
    }

    override func didFinishAnswer(body: String, candidateCount: Int, citedCount: Int) {
        RTILog.log("done — chars=\(body.count) candidates=\(candidateCount) cited=\(citedCount)", category: "projects")
    }
}

// MARK: - Legacy JSON shape (migrator-only)

/// Decoded shape of the pre-markdown JSON chat files under
/// `~/Library/Application Support/RTI/projects-chat/`. Read only by
/// `ProjectMigrator` on the upgrade path. New chats are written through
/// `ProjectChatFileStore` to markdown.
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
