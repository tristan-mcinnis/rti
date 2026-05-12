import Foundation
import Observation

/// Project-level intelligence layered on top of the per-session corpus:
///
///  - `ProjectPulse`: pure-compute snapshot of a project's state (member
///    count, recency, summary coverage, recommended next action). Mirrors
///    the vault's `project-pulse` skill — read-only, fast.
///
///  - `ProjectInsightsController`: streaming one-shot LLM operations
///    scoped to a project's member sessions. Two modes today:
///      • `recall`  — stitched "where we left off" briefing across the
///        most recent member sessions (vault `recall` skill).
///      • `synthesize` — cross-session findings → tensions → insights →
///        implications → recommendations (vault `analysis-op` skill).
///
/// Both controllers reuse `ProjectStore` membership and
/// `CorpusBackedStore.summary` — no new persistence beyond an optional
/// synthesis.md written alongside project chat history.

// MARK: - Pulse

struct ProjectPulse {
    let projectId: String
    let memberCount: Int
    let firstSessionAt: Date?
    let lastSessionAt: Date?
    let summarizedCount: Int           // sessions in this project that have a summary
    let totalTranscriptWords: Int      // crude size signal
    let suggestion: Suggestion

    enum Suggestion: Equatable {
        case empty                     // no member sessions yet
        case noSummaries               // members exist but none have summaries
        case partialSummaries(missing: Int)
        case readyForRecall            // healthy, has recent activity
        case readyForSynthesis         // healthy, enough material to synthesize across
        case stale(daysSinceLast: Int) // hasn't seen activity in a while

        var headline: String {
            switch self {
            case .empty: return "Add sessions to get started"
            case .noSummaries: return "No summaries yet — regenerate to enable insights"
            case .partialSummaries(let n): return "\(n) session\(n == 1 ? "" : "s") missing summaries"
            case .readyForRecall: return "Recall where you left off"
            case .readyForSynthesis: return "Ready to synthesize across sessions"
            case .stale(let d): return "Last activity \(d) day\(d == 1 ? "" : "s") ago"
            }
        }
    }

    @MainActor
    static func compute(projectId: String) -> ProjectPulse {
        let memberIds = ProjectStore.shared.sessionIds(forProject: projectId)
        let all = CorpusBackedStore.allMarkdownSessions()
        let members = all.filter { memberIds.contains($0.id) }

        guard !members.isEmpty else {
            return ProjectPulse(
                projectId: projectId,
                memberCount: 0,
                firstSessionAt: nil,
                lastSessionAt: nil,
                summarizedCount: 0,
                totalTranscriptWords: 0,
                suggestion: .empty
            )
        }

        let sorted = members.sorted { $0.startedAt < $1.startedAt }
        var summarized = 0
        var words = 0
        for s in members {
            if let summary = CorpusBackedStore.summary(forSessionId: s.id),
               !summary.summaryText.isEmpty {
                summarized += 1
            }
            // Rough word count: we don't need exactness, just a "how much
            // material is in here" signal. Pull transcripts lazily.
            let entries = CorpusBackedStore.transcripts(forSessionId: s.id)
            for e in entries {
                words += e.text.split(whereSeparator: { $0.isWhitespace }).count
            }
        }

        let missing = members.count - summarized
        let last = sorted.last!.startedAt
        let daysSinceLast = Int(Date().timeIntervalSince(last) / 86_400)

        let suggestion: Suggestion = {
            if summarized == 0 { return .noSummaries }
            if missing > 0 { return .partialSummaries(missing: missing) }
            if daysSinceLast > 14 { return .stale(daysSinceLast: daysSinceLast) }
            if members.count >= 3 { return .readyForSynthesis }
            return .readyForRecall
        }()

        return ProjectPulse(
            projectId: projectId,
            memberCount: members.count,
            firstSessionAt: sorted.first?.startedAt,
            lastSessionAt: last,
            summarizedCount: summarized,
            totalTranscriptWords: words,
            suggestion: suggestion
        )
    }
}

// MARK: - Insights controller

@Observable @MainActor
final class ProjectInsightsController {
    enum Mode: String { case synthesize }

    private(set) var isRunning = false
    private(set) var mode: Mode?
    private(set) var output: String = ""
    private(set) var lastError: String?

    let projectId: String
    private let request = LLMRequest()

    init(projectId: String) {
        self.projectId = projectId
    }

    func stop() {
        request.cancel()
        isRunning = false
    }

    func reset() {
        request.cancel()
        isRunning = false
        mode = nil
        output = ""
        lastError = nil
    }

    // MARK: Synthesize — cross-source analysis-op pipeline

    func synthesize() {
        guard !isRunning else { return }
        let project = ProjectStore.shared.projects.first { $0.id == projectId }
        guard let project else {
            lastError = "Project not found."
            return
        }
        let memberIds = ProjectStore.shared.sessionIds(forProject: projectId)
        let members = CorpusBackedStore.allMarkdownSessions()
            .filter { memberIds.contains($0.id) }
            .sorted { $0.startedAt < $1.startedAt }
        let blocks = members.compactMap { Self.summaryBlock(for: $0) }
        guard blocks.count >= 2 else {
            lastError = "Synthesis needs at least two summarized sessions."
            return
        }

        let system = """
        You are RTI's project analyst for "\(project.name)". Produce a cross-session synthesis of the \
        meeting summaries below using this five-part structure (each as its own H2):

        ## Findings
        Concrete observations grounded in the meetings. 6–10 bullets. Cite meetings with [Title].

        ## Tensions
        Where the sources disagree, where stated goals collide, or where decisions conflict across meetings. \
        3–6 bullets, each naming the meetings in tension.

        ## Insights
        Non-obvious patterns that only show up when you read these meetings together. 3–5 bullets. \
        Push beyond restating findings.

        ## Implications
        What follows from the insights — second-order consequences, risks, opportunities. 3–5 bullets.

        ## Recommendations
        Concrete next actions, prioritized. 3–6 bullets, each one verb-led and specific.

        Be honest about thin evidence — say "only one meeting touched this" when applicable. \
        Don't invent material that isn't in the sources.
        """
        let context = blocks.joined(separator: "\n---\n")
        let user = """
        Meeting summaries (chronological):

        \(context)
        """
        run(mode: .synthesize, system: system + Self.instructionsAppendix(project), user: user)
    }

    /// Persist the most recent synthesis output to disk so it survives a
    /// tab switch / app restart. Writes `<corpus>/projects/<slug>/synthesis.md`
    /// — the artifact rides with the corpus, syncs over iCloud, and is
    /// readable by the MCP server alongside the project's sessions.
    func saveSynthesisToDisk() {
        guard mode == .synthesize, !output.isEmpty else { return }
        guard let slug = ProjectStore.shared.slug(forProject: projectId) else { return }
        ProjectSynthesisFileStore.write(projectSlug: slug, projectId: projectId, body: output)
    }

    static func loadSavedSynthesis(projectId: String) -> ProjectSynthesisArtifact? {
        guard let slug = ProjectStore.shared.slug(forProject: projectId) else { return nil }
        return ProjectSynthesisFileStore.read(projectSlug: slug)
    }

    // MARK: - Internals

    private func run(mode: Mode, system: String, user: String) {
        self.mode = mode
        output = ""
        lastError = nil
        isRunning = true

        var apiMessages: [LLMMessage] = [LLMMessage(role: "system", content: system)]
        if let glossary = GlossaryStore.shared.systemPromptFragment {
            apiMessages.append(LLMMessage(role: "system", content: glossary))
        }
        apiMessages.append(LLMMessage(role: "user", content: user))

        request.stream(
            messages: apiMessages,
            smart: false,
            onDelta: { [weak self] delta in
                Task { @MainActor [weak self] in
                    self?.output += delta
                }
            },
            onError: { [weak self] msg, _ in
                Task { @MainActor [weak self] in
                    self?.lastError = msg
                    self?.isRunning = false
                    RTILog.log("insights \(mode.rawValue) stream error — \(msg)", category: "projects")
                }
            },
            onComplete: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isRunning = false
                    if mode == .synthesize { self.saveSynthesisToDisk() }
                    RTILog.log("insights \(mode.rawValue) done — chars=\(self.output.count)", category: "projects")
                }
            }
        )
    }

    private static func instructionsAppendix(_ project: Project) -> String {
        let trimmed = project.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return "\n\nProject instructions from the user — follow these alongside the rules above:\n\(trimmed)"
    }

    private static func summaryBlock(for session: Session) -> String? {
        guard let summary = CorpusBackedStore.summary(forSessionId: session.id),
              !summary.summaryText.isEmpty else { return nil }
        let title = displayTitle(for: session)
        return """
        ### [\(title)]
        Date: \(session.startedAt.formatted(date: .abbreviated, time: .shortened))
        \(summary.summaryText.prefix(2000))
        """
    }

    private static func displayTitle(for session: Session) -> String {
        if let t = session.calendarTitle, !t.isEmpty { return t }
        if let t = session.title, !t.isEmpty { return t }
        return "Session \(session.startedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private static func synthesisDir(for projectId: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base
            .appendingPathComponent("RTI/projects-insights", isDirectory: true)
            .appendingPathComponent(projectId, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
