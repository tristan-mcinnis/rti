import Foundation
import HouseChatCore
import RTICore

@MainActor
struct ToolExecutor {
    struct ExecutionResult: Equatable {
        let toolName: String
        let status: String?
        /// How the call ended, so a receipt never claims a success that did
        /// not happen.
        let outcome: ToolRoundStatus
        let resultText: String
        let elapsedMS: Int
        let executed: Bool
    }

    private let tools: [String: LLMToolDefinition]
    private let maxCallsPerTurn: [String: Int]
    /// Tools that reach outside the conversation. When the turn's context
    /// policy withheld external retrieval, a call to one of these is refused
    /// even if the model asks for it: the offered list is not the only gate.
    private let allowsExternalRetrieval: Bool
    /// The screen tools' separate permission: a source-first turn may still
    /// look at the screen when the user's question asked for it.
    private let allowsScreenTools: Bool
    private var callCounts: [String: Int] = [:]

    init(
        tools: [LLMToolDefinition],
        maxCallsPerTurn: [String: Int] = [:],
        allowsExternalRetrieval: Bool = true,
        allowsScreenTools: Bool = false
    ) {
        self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        self.maxCallsPerTurn = maxCallsPerTurn
        self.allowsExternalRetrieval = allowsExternalRetrieval
        self.allowsScreenTools = allowsScreenTools
    }

    mutating func execute(_ call: LLMToolCall) async -> ExecutionResult {
        guard let tool = tools[call.function.name] else {
            return ExecutionResult(
                toolName: call.function.name,
                status: nil,
                outcome: .failed,
                resultText: "Tool '\(call.function.name)' is not available.",
                elapsedMS: 0,
                executed: false
            )
        }

        if !allowsExternalRetrieval, ChatToolPolicy.discoveryToolNames.contains(tool.name) {
            return ExecutionResult(
                toolName: tool.name,
                status: nil,
                outcome: .refused,
                resultText: "\(tool.name) is not available for this turn: the question is answered from the sources in front of you. Answer now from what you already have.",
                elapsedMS: 0,
                executed: false
            )
        }

        // The screen tools have their own gate: source-first withholds them
        // unless the user's own question asked for the screen.
        if !allowsExternalRetrieval, !allowsScreenTools, ChatToolPolicy.screenToolNames.contains(tool.name) {
            return ExecutionResult(
                toolName: tool.name,
                status: nil,
                outcome: .refused,
                resultText: "\(tool.name) is not available for this turn: the question is answered from the sources in front of you. Answer now from what you already have.",
                elapsedMS: 0,
                executed: false
            )
        }

        callCounts[tool.name, default: 0] += 1
        if let maxCalls = maxCallsPerTurn[tool.name], callCounts[tool.name, default: 0] > maxCalls {
            return ExecutionResult(
                toolName: tool.name,
                status: nil,
                outcome: .refused,
                resultText: "You already used \(tool.name) this turn. Do not call it again; answer the user now from the tool results already returned above.",
                elapsedMS: 0,
                executed: false
            )
        }

        let start = Date()
        let resultText: String
        var outcome: ToolRoundStatus = .succeeded
        do {
            resultText = try await tool.execute(call.function.arguments)
        } catch {
            outcome = .failed
            resultText = "Tool '\(tool.name)' failed: \(error.localizedDescription)"
        }
        let elapsedMS = Int(Date().timeIntervalSince(start) * 1000)
        return ExecutionResult(
            toolName: tool.name,
            status: tool.runningStatus ?? "Running \(tool.name)…",
            outcome: outcome,
            resultText: resultText,
            elapsedMS: elapsedMS,
            executed: true
        )
    }
}
