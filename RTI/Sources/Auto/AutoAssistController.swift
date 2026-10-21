import Foundation
import Observation
import RTICore

/// Auto mode: each scheduler tick reads the latest transcript window and, using
/// the meeting's project context (status, brief) and the
/// project's own vault knowledge, proactively surfaces a few high-value cards —
/// something to say, a question to ask, a relevant fact to recall, or a flag.
/// It is the always-on counterpart to the manual Assist panel: instead of
/// waiting to be asked, it watches the conversation and offers help in the
/// moment, grounded in what this project already knows.
///
/// Runs on the `AutoAssistScheduler` rail, gated by its own Settings toggle,
/// owning its own watermark so the manual "Generate" button and the periodic
/// tick can't double-surface. When a project is picked
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

    private let request = LLMRequest(priority: .background)
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

    // Prompt default lives in the registry (`PromptID.autoAssistCards`),
    // resolved through `PromptStore` so it's editable in Settings.

    /// Bumped on reset/clear so a pass still awaiting the LLM from an older
    /// session cannot write into the new one.
    private var generation = 0
    private init() {}

    /// Bind to a session and drop any prior cards.
    func reset(for sessionId: String) {
        generation += 1
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
        generation += 1
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
    /// `currentSessionId` outlives the recording (it is replaced only by the
    /// next start), so "a session runs" is `isRunning`: finals flushed in the
    /// stop window, or a debounce armed just before Stop, otherwise ran one
    /// more paid pass after the scheduler had already stopped.
    func noteActivity() {
        guard UserDefaults.standard.bool(forKey: AutoAssistSettings.enabledKey),
              SessionCoordinator.shared.isRunning else { return }
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: Self.quietWindow, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fireIfDue() }
        }
    }

    /// Run a pass now if the floor since the last one has elapsed; otherwise
    /// re-arm so this content is still covered once the floor passes.
    private func fireIfDue() {
        guard SessionCoordinator.shared.isRunning,
              let sid = SessionCoordinator.shared.currentSessionId else { return }
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

        let passGeneration = generation
        let windowStartMs = lastMs
        let sinceMs: Int? = windowStartMs == 0 ? nil : windowStartMs
        let window = TranscriptContext.text(forSessionId: sessionId, sinceMs: sinceMs)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !window.isEmpty else { return nil }
        // Compute the watermark but DO NOT apply it until the LLM call succeeds.
        // If the request fails or returns empty, we want to retry this window
        // rather than permanently skip it.
        let endMs = TranscriptContext.watermarkEndMs(forSessionId: sessionId, sinceMs: sinceMs) ?? windowStartMs

        // Grounding: who/what the meeting is about.
        let projectContext = MeetingContextStore.shared.combined

        // Project-scoped retrieval: pull what the project's vault knows about
        // what's being discussed right now, so a RECALL card can be real. Only
        // when a project is picked (scope present) — keeps generic meetings cheap.
        var vaultMaterial: String?
        var citations: [VaultSearch.Citation] = []
        if let scope = MeetingContextStore.shared.workstreamScopePath {
            let found = await VaultSearch.retrieve(query: window, scopeRelativePath: scope, citeable: true)
            // Only inject a genuine hit, not the "nothing matched" sentinel.
            if !found.isEmpty {
                vaultMaterial = found.formatted
                citations = found.citations
            }
        }

        let priorList: String = cards.isEmpty
            ? "(none yet)"
            : cards.suffix(30).map { "- [\($0.kind.rawValue)] \($0.text)" }.joined(separator: "\n")

        var prompt = PromptStore.shared.text(.autoAssistCards) + "\n\nAlready-surfaced (do NOT repeat):\n" + priorList
        if let projectContext, !projectContext.isEmpty {
            prompt += "\n\nThis meeting's project context (treat as ground truth):\n---\n\(projectContext)\n---"
        }
        if let vaultMaterial {
            prompt += "\n\nRelevant project vault material for what's being discussed (use for RECALL/FLAG; cite the source; do not fabricate):\n---\n\(vaultMaterial)\n---"
            prompt += "\n\nTo cite one of those documents, set \"sourceId\" on the card to its bracketed ID exactly as shown (for example \"S1\"). Only those IDs are accepted. A card with any other value, or none, shows no citation."
        }
        prompt += "\n\nRecent conversation window:\n\(window)"

        guard let response = await request.collectAsync(
            messages: [LLMMessage(role: "user", content: prompt)], smart: false
        ), !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard passGeneration == generation else { return nil }

        let items = JSONExtractor.decodeArrayLenient(response, key: "cards", as: AutoCardItem.self)
        let existing = Set(cards.map { Self.norm($0.text) })
        let fresh: [AutoAssistCard] = items.compactMap { item in
            guard let card = AutoAssistCard.make(from: item, citations: citations),
                  !existing.contains(Self.norm(card.text)) else { return nil }
            return card
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
}
