import Foundation
import Observation
import RTICore

/// Auto mode: each scheduler tick reads the latest transcript window and, using
/// the meeting's project context (status, brief, discussion guide) and the
/// project's own vault knowledge, proactively surfaces a few high-value cards —
/// something to say, a question to ask, a relevant fact to recall, or a flag.
/// It is the always-on counterpart to the manual Assist panel: instead of
/// waiting to be asked, it watches the conversation and offers help in the
/// moment, grounded in what this project already knows.
///
/// Runs on the same `AnalysisScheduler` rail as Notes/Guide/Findings, gated by
/// its own Settings toggle, owning its own watermark so the manual "Generate"
/// button and the periodic tick can't double-surface. When a project is picked
/// for the meeting, each pass first runs a project-scoped vault search keyed on
/// the live window so a card can cite what a participant actually said or what
/// a report concluded — the "they just asked about X, here's our answer" case.
@Observable @MainActor
final class AutoAssistController {
    static let shared = AutoAssistController()

    private(set) var cards: [AutoAssistCard] = []
    var isGenerating = false
    private(set) var lastError: String?
    /// Cards added while the user wasn't looking at the Auto tab — drives the
    /// tab's unread badge so a proactive suggestion is noticeable.
    private(set) var unseenCount = 0

    private let request = LLMRequest()
    private var sessionId: String?
    /// Watermark: ms of the last transcript covered.
    private var lastMs = 0

    // Proactive triggering: fire a short beat after talk settles, not just on
    // the slow scheduler tick — so a client's question gets answered in seconds.
    private var debounceTimer: Timer?
    private var lastPassAt: Date?
    /// Wait this long after the last new speech before firing, so we act on a
    /// finished thought (a complete question) rather than a half-sentence.
    private static let quietWindow: TimeInterval = 7
    /// Floor between passes — bounds cost during a long monologue.
    private static let minInterval: TimeInterval = 25

    private static let prompt = """
    You are sitting beside the user during a live meeting as their proactive
    assistant. You see the recent conversation, the project this meeting is
    about, and relevant knowledge already in the project's vault. Surface only
    GENUINELY USEFUL, in-the-moment help — a few cards, one, or none.

    Output ONLY JSON, no prose, no markdown fences:
    {
      "cards": [
        {
          "kind": "SAY | ASK | RECALL | FLAG",
          "text": "<=25 words: the suggestion itself — the line to say, the question to ask, the fact to recall, or the thing to flag>",
          "why": "<=15 words: why it's relevant right now>",
          "source": "<the project document/transcript/guide this draws on, or null>"
        }
      ]
    }

    KINDS:
    - SAY: a strong point or line the user could make right now.
    - ASK: a sharp question or follow-up worth raising.
    - RECALL: a relevant fact from the project's vault — what a participant said
      in a research session, a prior finding, a report conclusion, a status
      detail — ESPECIALLY when the other party just asked about that topic.
      Only surface a RECALL when the provided vault material actually supports
      it; cite the source. Never invent a finding or a quote.
    - FLAG: a contradiction with the project record, a claim to verify, a risk.

    Rules:
    - Only NEW cards prompted by THIS window. Do NOT repeat anything in the
      already-surfaced list below.
    - High bar. If nothing in this window genuinely warrants a card, return
      {"cards": []}. Silence beats noise — the user is in a live conversation.
    - Be specific and immediately usable. No generic coaching ("listen
      actively"), no restating what was just said.
    - Ground RECALL/FLAG cards in the project context or vault material given;
      do not fabricate. Write in English.
    """

    private init() {}

    /// Bind to a session and drop any prior cards.
    func reset(for sessionId: String) {
        self.sessionId = sessionId
        lastError = nil
        isGenerating = false
        cards = []
        lastMs = 0
        unseenCount = 0
        debounceTimer?.invalidate()
        debounceTimer = nil
        lastPassAt = nil
    }

    func clear() {
        sessionId = nil
        cards = []
        lastError = nil
        isGenerating = false
        lastMs = 0
        unseenCount = 0
        debounceTimer?.invalidate()
        debounceTimer = nil
        lastPassAt = nil
    }

    /// Mark the surfaced cards as seen (called when the user views the Auto tab).
    func markSeen() {
        unseenCount = 0
    }

    // MARK: - Proactive triggering

    /// Called when new final transcript content lands. Debounces, then fires a
    /// pass once talk has settled — subject to the per-pass floor. Cheap to call
    /// on every committed line; no-ops when Auto is off or no session runs.
    func noteActivity() {
        guard UserDefaults.standard.bool(forKey: AnalysisSettingsDefaults.autoAssistEnabledKey),
              SessionCoordinator.shared.currentSessionId != nil else { return }
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: Self.quietWindow, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fireIfDue() }
        }
    }

    /// Run a pass now if the floor since the last one has elapsed; otherwise
    /// re-arm so this content is still covered once the floor passes.
    private func fireIfDue() {
        guard let sid = SessionCoordinator.shared.currentSessionId else { return }
        if let last = lastPassAt, Date().timeIntervalSince(last) < Self.minInterval {
            debounceTimer?.invalidate()
            debounceTimer = Timer.scheduledTimer(withTimeInterval: Self.minInterval, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.fireIfDue() }
            }
            return
        }
        Task { @MainActor in _ = await self.generate(sessionId: sid) }
    }

    /// Surface cards over the transcript since the last pass. Used by both the
    /// periodic scheduler and the manual button.
    @discardableResult
    func generate(sessionId: String) async -> Int? {
        guard !isGenerating else { return nil }
        isGenerating = true
        defer { isGenerating = false }
        lastError = nil
        // All paths (debounce, scheduler, manual) update the floor so the
        // proactive trigger rate-limits against every kind of pass.
        lastPassAt = Date()

        let windowStartMs = lastMs
        let sinceMs: Int? = windowStartMs == 0 ? nil : windowStartMs
        let window = TranscriptContext.text(forSessionId: sessionId, sinceMs: sinceMs)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !window.isEmpty else { return nil }
        // Compute the watermark but DO NOT apply it until the LLM call succeeds.
        // If the request fails or returns empty, we want to retry this window
        // rather than permanently skip it.
        let endMs = TranscriptContext.watermarkEndMs(forSessionId: sessionId, sinceMs: sinceMs) ?? windowStartMs

        // Grounding: who/what the meeting is about + the live guide state.
        let projectContext = MeetingContextStore.shared.combined
        let guideSummary = DiscussionGuideController.shared.guide?.assistantContextSummary()

        // Project-scoped retrieval: pull what the project's vault knows about
        // what's being discussed right now, so a RECALL card can be real. Only
        // when a project is picked (scope present) — keeps generic meetings cheap.
        var vaultMaterial: String?
        if let scope = MeetingContextStore.shared.workstreamScopePath {
            let found = await VaultSearch.searchFormatted(query: window, scopeRelativePath: scope)
            // Only inject a genuine hit, not the "nothing matched" sentinel.
            if found.hasPrefix("Found ") { vaultMaterial = found }
        }

        let priorList: String = cards.isEmpty
            ? "(none yet)"
            : cards.suffix(30).map { "- [\($0.kind.rawValue)] \($0.text)" }.joined(separator: "\n")

        var prompt = Self.prompt + "\n\nAlready-surfaced (do NOT repeat):\n" + priorList
        if let projectContext, !projectContext.isEmpty {
            prompt += "\n\nThis meeting's project context (treat as ground truth):\n---\n\(projectContext)\n---"
        }
        if let guideSummary, !guideSummary.isEmpty {
            prompt += "\n\nDiscussion guide & live coverage:\n---\n\(guideSummary)\n---"
        }
        if let vaultMaterial {
            prompt += "\n\nRelevant project vault material for what's being discussed (use for RECALL/FLAG; cite the source; do not fabricate):\n---\n\(vaultMaterial)\n---"
        }
        prompt += "\n\nRecent conversation window:\n\(window)"

        guard let response = await request.collectAsync(
            messages: [LLMMessage(role: "user", content: prompt)], smart: false
        ), !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let items = JSONExtractor.decodeArrayLenient(response, key: "cards", as: CardItem.self)
        let existing = Set(cards.map { Self.norm($0.text) })
        let fresh: [AutoAssistCard] = items.compactMap { item in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !existing.contains(Self.norm(text)) else { return nil }
            return AutoAssistCard(
                timestamp: Date(),
                kind: AutoCardKind(raw: item.kind ?? "RECALL"),
                text: text,
                why: (item.why ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                source: Self.cleaned(item.source)
            )
        }
        cards.append(contentsOf: fresh)
        unseenCount += fresh.count
        if cards.count > 300 { cards.removeFirst(cards.count - 300) }
        // Only advance the watermark once the LLM response has been accepted.
        lastMs = endMs
        return endMs
    }

    private static func norm(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleaned(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines),
              !t.isEmpty, t.lowercased() != "null" else { return nil }
        return t
    }

    /// Wire shape for one card. Everything but `text` is optional so a slightly
    /// malformed item still decodes; the lenient array decoder drops only the
    /// items it can't and keeps the rest of the batch.
    private struct CardItem: Decodable {
        let kind: String?
        let text: String
        let why: String?
        let source: String?
    }
}
