import Foundation
import RTICore

@MainActor
struct ToolExecutor {
    struct ExecutionResult: Equatable {
        let toolName: String
        let status: String?
        let resultText: String
        let elapsedMS: Int
        let executed: Bool
    }

    private let tools: [String: LLMToolDefinition]
    private let maxCallsPerTurn: [String: Int]
    private var callCounts: [String: Int] = [:]

    init(tools: [LLMToolDefinition], maxCallsPerTurn: [String: Int] = [:]) {
        self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        self.maxCallsPerTurn = maxCallsPerTurn
    }

    mutating func execute(_ call: LLMToolCall) async -> ExecutionResult {
        guard let tool = tools[call.function.name] else {
            return ExecutionResult(
                toolName: call.function.name,
                status: nil,
                resultText: "Tool '\(call.function.name)' is not available.",
                elapsedMS: 0,
                executed: false
            )
        }

        callCounts[tool.name, default: 0] += 1
        if let maxCalls = maxCallsPerTurn[tool.name], callCounts[tool.name, default: 0] > maxCalls {
            return ExecutionResult(
                toolName: tool.name,
                status: nil,
                resultText: "You already used \(tool.name) this turn. Do not call it again; answer the user now from the tool results already returned above.",
                elapsedMS: 0,
                executed: false
            )
        }

        let start = Date()
        let resultText: String
        do {
            resultText = try await tool.execute(call.function.arguments)
        } catch {
            resultText = "Tool '\(tool.name)' failed: \(error.localizedDescription)"
        }
        let elapsedMS = Int(Date().timeIntervalSince(start) * 1000)
        return ExecutionResult(
            toolName: tool.name,
            status: tool.runningStatus ?? "Running \(tool.name)…",
            resultText: resultText,
            elapsedMS: elapsedMS,
            executed: true
        )
    }
}
