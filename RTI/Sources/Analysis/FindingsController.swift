import Foundation
import Observation

/// Builds the live Findings ledger: each scheduler tick asks the LLM for any
/// genuinely new, significant observations in the latest transcript window and
/// appends them (deduped against what's already logged). Distinct from the
/// one-shot ⌘↵ listener-assist flag — that surfaces a single ephemeral note;
/// this accumulates the running record across the whole session.
///
/// Runs on the same `AnalysisScheduler` rail as Notes/Guide (so it's strictly
/// timer-driven and never touches the per-frame audio path), gated by its own
/// Settings toggle, and owns its own watermark so the manual "Generate" button
/// and the periodic tick can't double-log.
@Observable @MainActor
final class FindingsController {
    static let shared = FindingsController()

    private(set) var findings: [FindingEntry] = []
    var isGenerating = false
    private(set) var lastError: String?
    private(set) var sessionStartedAt: Date?

    private let request = LLMRequest()
    private var sessionId: String?
    /// Watermark: ms of the last transcript covered. Shared by the tick and the
    /// manual button so neither re-covers old ground.
    private var lastFindingMs = 0

    // Prompt default lives in the registry (`PromptID.findingsLedger`), resolved
    // through `PromptStore` so it's editable in Settings.

    private init() {}

    /// Bind to a session and drop any prior findings.
    func reset(for sessionId: String) {
        self.sessionId = sessionId
        lastError = nil
        isGenerating = false
        findings = []
        lastFindingMs = 0
        sessionStartedAt = SessionCoordinator.shared.startedAt
    }

    func clear() {
        sessionId = nil
        findings = []
        lastError = nil
        isGenerating = false
        lastFindingMs = 0
        sessionStartedAt = nil
    }

    /// Generate findings over the transcript since the last pass and append the
    /// new ones. Used by both the periodic scheduler and the manual button.
    @discardableResult
    func generate(sessionId: String) async -> Int? {
        guard !isGenerating else { return nil }
        isGenerating = true
        defer { isGenerating = false }
        lastError = nil

        let windowStartMs = lastFindingMs
        let sinceMs: Int? = windowStartMs == 0 ? nil : windowStartMs

        let priorList: String = findings.isEmpty
            ? "(none yet)"
            : findings.suffix(40).map { "- [\($0.tag.rawValue)] \($0.headline)" }.joined(separator: "\n")
        // Assemble the static head once, with an explicit type, so the closure
        // below stays a trivial 3-string concatenation for the type-checker.
        let promptHead: String = PromptStore.shared.text(.findingsLedger) + "\n\nAlready-logged findings (do NOT repeat):\n" + priorList

        guard let result = await TranscriptAnalysis.runLenientArray(
            sessionId: sessionId,
            sinceMs: sinceMs,
            shape: .timestamped,
            smart: false,
            request: request,
            category: "findings",
            key: "findings",
            as: FindingItem.self,
            buildPrompt: { transcript in
                promptHead + "\n\nTranscript window (with [mm:ss] timestamps):\n" + transcript
            }
        ) else { return nil }

        // Advance the watermark even on an empty batch so we never re-cover.
        lastFindingMs = result.endMs

        let existing = Set(findings.map { Self.norm($0.headline) })
        let fresh: [FindingEntry] = result.payload.compactMap { item in
            let head = item.headline.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !head.isEmpty, !existing.contains(Self.norm(head)) else { return nil }
            return FindingEntry(
                timestamp: Date(),
                rangeMs: item.timestampMs ?? windowStartMs,
                tag: FindingTag(raw: item.tag ?? "FINDING"),
                headline: head,
                matters: (item.matters ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                quote: Self.cleaned(item.quote),
                speaker: Self.cleaned(item.speaker)
            )
        }
        findings.append(contentsOf: fresh)
        if findings.count > 500 { findings.removeFirst(findings.count - 500) }
        return result.endMs
    }

    private static func norm(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleaned(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// Wire shape for one finding. Everything but `headline` is optional so a
    /// slightly-malformed item still decodes; the lenient array decoder drops
    /// only the items that can't (truncated tail, missing headline) and keeps
    /// the rest of the batch.
    private struct FindingItem: Decodable {
        let tag: String?
        let headline: String
        let matters: String?
        let quote: String?
        let speaker: String?
        let timestampMs: Int?
    }
}
