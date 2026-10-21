import Foundation

/// The source material one turn carries, by origin: attached for this turn, or
/// retained from earlier turns in the same chat.
public struct TurnSourceContext: Equatable, Sendable {
    /// Sources attached for this turn (tray files, `@` mentions, a dated log).
    public let freshCount: Int
    /// Sources this chat was sent earlier, re-sent for a bare follow-up.
    public let retainedCount: Int

    public init(freshCount: Int = 0, retainedCount: Int = 0) {
        self.freshCount = freshCount
        self.retainedCount = retainedCount
    }

    public var total: Int { freshCount + retainedCount }
    public var hasFresh: Bool { freshCount > 0 }
    public var hasRetained: Bool { retainedCount > 0 }
}

/// The one sentence that tells the model what its sources are and whether it
/// may reach past them.
///
/// Kept pure so the prompt, the tool policy and the receipt can be pinned to
/// the same decision. The sentence names a newly attached source and a source
/// retained from earlier in the chat differently: only the first is "for this
/// turn", and neither may claim the other's origin.
public enum TurnSourceInstruction {
    private static let withheldTail = "Do not search the vault or substitute unrelated sources unless the user explicitly asks for a comparison, broader lookup, or verification."

    public static func text(
        for sources: TurnSourceContext,
        externalRetrievalAllowed: Bool
    ) -> String? {
        guard sources.total > 0 else { return nil }
        if externalRetrievalAllowed {
            // The user widened the search, so the sources and the vault tools
            // are both usable. Never forbid what the tool list permits.
            switch (sources.hasFresh, sources.hasRetained) {
            case (true, true):
                return "Source material is included with this question: newly attached material and material retained from earlier in this chat. Use it when it answers the question; a wider search is allowed, so the vault tools are available too."
            case (true, false):
                return "Source material is included with this question: newly attached for this turn. Use it when it answers the question; a wider search is allowed, so the vault tools are available too."
            default:
                return "Source material retained from earlier in this chat is included with this question. Use it when it answers the question; a wider search is allowed, so the vault tools are available too."
            }
        }
        switch (sources.hasFresh, sources.hasRetained) {
        case (true, true):
            return "This question carries newly attached source material plus source material from earlier in this chat. Answer from both; refer to the earlier material as retained, not newly attached. \(withheldTail)"
        case (true, false):
            return "The user explicitly attached source material for this turn. Answer directly from it. \(withheldTail)"
        default:
            return "This chat's earlier turns carried source material, and it is included with this question. Answer directly from it; it was attached in an earlier turn, so do not describe it as newly attached. \(withheldTail)"
        }
    }

    /// The header of the attached-documents system block, worded from the same
    /// origins and the same policy as `text(for:externalRetrievalAllowed:)`.
    /// A retained source is never called new here either.
    public static func documentsHeader(
        for sources: TurnSourceContext,
        externalRetrievalAllowed: Bool
    ) -> String? {
        guard sources.total > 0 else { return nil }
        let origin: String
        switch (sources.hasFresh, sources.hasRetained) {
        case (true, true):
            origin = "The following documents are this question's newly attached material plus material retained from earlier in this chat. Refer to the earlier ones as retained, not newly attached."
        case (true, false):
            origin = "The user explicitly attached or @mentioned the following document(s) for this turn."
        default:
            origin = "The following document(s) were attached earlier in this chat and are included with this question. They are retained from an earlier turn, not newly attached."
        }
        let guidance = externalRetrievalAllowed
            ? "Treat them as source material for the question. A wider search is allowed, so the vault tools are available too."
            : "Treat them as the authoritative source material for the question. Do not search the vault or replace them with broader retrieved sources unless the user explicitly asks you to compare, verify, or look beyond these documents."
        return "\(origin) \(guidance)"
    }
}
