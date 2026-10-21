import Foundation
import HouseChatCore

/// The sources one turn actually carries, and the context decision resolved
/// from that exact set.
///
/// One composition point. The controller composes the wire set here, then uses
/// the same value for the request, the tool policy, the composer preview and
/// the receipt. A fresh source is answered from itself; a bare follow-up reads
/// the chat's retained archive; an explicit comparison reads both. Because the
/// decision is resolved on the set that will be sent, the receipt can never
/// describe a source set the request did not carry.
public struct ChatWireSources: Equatable, Sendable {
    public enum Choice: String, Equatable, Sendable {
        /// No source reaches the model.
        case none
        /// This turn's own attachments only.
        case fresh
        /// The chat's retained archive only: a bare follow-up.
        case retained
        /// This turn's attachments plus the retained archive.
        case freshAndRetained
    }

    public let choice: Choice
    public let freshCount: Int
    public let retainedCount: Int
    public let decision: ContextDecision

    public init(
        choice: Choice,
        freshCount: Int,
        retainedCount: Int,
        decision: ContextDecision
    ) {
        self.choice = choice
        self.freshCount = freshCount
        self.retainedCount = retainedCount
        self.decision = decision
    }

    /// How many sources the wire carries, before deduplication.
    public var wireSourceCount: Int {
        switch choice {
        case .none: 0
        case .fresh: freshCount
        case .retained: retainedCount
        case .freshAndRetained: freshCount + retainedCount
        }
    }

    public var carriesSources: Bool { wireSourceCount > 0 }
    /// True when this turn's own attachments are on the wire.
    public var carriesFreshSources: Bool { choice == .fresh || choice == .freshAndRetained }
    /// True when the chat's retained archive is on the wire.
    public var carriesRetainedSources: Bool { choice == .retained || choice == .freshAndRetained }

    /// Compose the wire set and its decision together.
    ///
    /// The count the policy is told about is what the turn will carry whatever
    /// the wording: a fresh source, or the retained archive when nothing new
    /// came. So "no current source" can only mean no source on the wire, which
    /// is what keeps the decision, the request and the receipt in agreement.
    public static func compose(
        question: String,
        freshSourceCount: Int,
        retainedSourceCount: Int,
        historyTurnCount: Int,
        historyHasSources: Bool,
        broaderToggleOn: Bool
    ) -> ChatWireSources {
        let carryable = freshSourceCount > 0 ? freshSourceCount : retainedSourceCount
        let decision = ContextPolicy.standard.resolve(ChatContextRequestBuilder.request(
            question: question,
            currentSourceCount: carryable,
            historyTurnCount: historyTurnCount,
            historyHasSources: historyHasSources,
            broaderToggleOn: broaderToggleOn
        ))
        let choice: Choice
        if freshSourceCount > 0 {
            choice = decision.includesHistory ? .freshAndRetained : .fresh
        } else {
            choice = retainedSourceCount > 0 ? .retained : .none
        }
        return ChatWireSources(
            choice: choice,
            freshCount: freshSourceCount,
            retainedCount: retainedSourceCount,
            decision: decision
        )
    }
}
