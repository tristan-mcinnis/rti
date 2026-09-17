import Foundation
import HouseChatCore

/// RTI's tool gate for one turn: which of RTI's own tools reach outside this
/// conversation.
///
/// The decision is the shared `ContextPolicy`'s: `ContextDecision
/// .allowsExternalRetrieval` says whether anything outside the conversation may
/// be reached at all. This type only names which of RTI's tools are the
/// external ones, so the offered list and the executed call cannot disagree.
///
/// `execution` / `offered` stay what they are in the package: they govern the
/// prior conversation's scope, not the outside world.
public struct ChatToolPolicy: Sendable, Equatable {
    /// RTI's tools that reach outside the conversation: the vault, past
    /// sessions, and the file system. These are withheld, both from the
    /// offered list and at execution, when the turn's context policy is
    /// source-first.
    public static let discoveryToolNames: Set<String> = [
        "search_vault",
        "grep_vault",
        "recent_meetings",
        "list_files",
        "read_document",
    ]

    /// The screen tools. They reach outside the conversation too, but a
    /// source-first turn may still use them when the user's own question asks
    /// for the screen. A document question never opens the display.
    public static let screenToolNames: Set<String> = [
        "capture_screen",
        "highlight_screen_text",
    ]

    /// True when the user's own wording asks to look at the screen. Narrow and
    /// explicit: a named display, not a generic question.
    public static func questionRequestsScreen(_ question: String) -> Bool {
        let lowered = question.lowercased()
        let tokens = lowercasedTokens(lowered)
        if !tokens.isDisjoint(with: ["screen", "screens", "display", "displays", "monitor", "monitors"])
        {
            return true
        }
        for term in ["屏幕", "显示器", "画面上", "这个窗口", "这个界面"] where lowered.contains(term) {
            return true
        }
        return false
    }

    private static func lowercasedTokens(_ text: String) -> Set<String> {
        var words: Set<String> = []
        var current = ""
        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.insert(current)
                current = ""
            }
        }
        if !current.isEmpty { words.insert(current) }
        return words
    }

    /// True only when the shared policy allowed retrieval outside the
    /// conversation.
    public var allowsExternalRetrieval: Bool
    /// True when the user's question explicitly asks for the screen, so the
    /// screen tools stay available on a source-first turn.
    public var allowsScreenTools: Bool
    /// The decision's own words, for a log line or the composer.
    public var rationale: String
    /// True when the policy recorded history the user could still be offered.
    public var offersHistory: Bool

    public init(decision: ContextDecision, allowsScreenTools: Bool = false) {
        self.allowsExternalRetrieval = decision.allowsExternalRetrieval
        self.allowsScreenTools = allowsScreenTools
        self.rationale = decision.rationale
        self.offersHistory = decision.offered.contains { $0 == .history || $0 == .currentSourceAndHistory }
    }

    public init(
        allowsExternalRetrieval: Bool,
        allowsScreenTools: Bool = true,
        rationale: String = "",
        offersHistory: Bool = false
    ) {
        self.allowsExternalRetrieval = allowsExternalRetrieval
        self.allowsScreenTools = allowsScreenTools
        self.rationale = rationale
        self.offersHistory = offersHistory
    }

    /// Kept for callers that only have the boolean (the offered and executed
    /// gates both read it).
    public var allowsDiscovery: Bool { allowsExternalRetrieval }

    public func allowsTool(named name: String) -> Bool {
        if Self.screenToolNames.contains(name) {
            // Ordinary chat already allows the screen tools; source-first only
            // when the question itself asks for the screen.
            return allowsExternalRetrieval || allowsScreenTools
        }
        return allowsExternalRetrieval || !Self.discoveryToolNames.contains(name)
    }
}

/// Builds the shared request from RTI's own state. RTI's history lives in the
/// in-memory thread, so the counts come from the chat entries rather than from a
/// store.
public enum ChatContextRequestBuilder {
    public static func request(
        question: String,
        currentSourceCount: Int,
        historyTurnCount: Int,
        historyHasSources: Bool,
        broaderToggleOn: Bool
    ) -> ContextRequest {
        ContextRequest(
            hasCurrentSource: currentSourceCount > 0,
            currentSourceCount: currentSourceCount,
            historyTurnCount: historyTurnCount,
            historyHasSources: historyHasSources,
            question: question,
            override: broaderToggleOn ? .broader : nil
        )
    }
}
