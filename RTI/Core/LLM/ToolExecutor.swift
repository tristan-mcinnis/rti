import Foundation
import HouseChatCore

@MainActor
public struct ToolExecutor {
    public struct SearchLimits: Sendable {
        public let maxCallsPerTurn: Int
        public let timeLimit: Duration

        public init(maxCallsPerTurn: Int, timeLimit: Duration) {
            self.maxCallsPerTurn = maxCallsPerTurn
            self.timeLimit = timeLimit
        }
    }

    public struct ExecutionResult: Equatable {
        public let toolName: String
        public let status: String?
        /// How the call ended, so a receipt never claims a success that did
        /// not happen.
        public let outcome: ToolRoundStatus
        public let resultText: String
        public let elapsedMS: Int
        public let executed: Bool

        public init(
            toolName: String,
            status: String?,
            outcome: ToolRoundStatus,
            resultText: String,
            elapsedMS: Int,
            executed: Bool
        ) {
            self.toolName = toolName
            self.status = status
            self.outcome = outcome
            self.resultText = resultText
            self.elapsedMS = elapsedMS
            self.executed = executed
        }
    }

    private let tools: [String: LLMToolDefinition]
    private let maxCallsPerTurn: [String: Int]
    /// What a live call allows the search tools, together; nil is no limit.
    private let searchLimits: SearchLimits?
    private var searchCalls = 0
    /// Tools that reach outside the conversation. When the turn's context
    /// policy withheld external retrieval, a call to one of these is refused
    /// even if the model asks for it: the offered list is not the only gate.
    private let allowsExternalRetrieval: Bool
    /// The screen tools' separate permission: a source-first turn may still
    /// look at the screen when the user's question asked for it.
    private let allowsScreenTools: Bool
    private var callCounts: [String: Int] = [:]

    public init(
        tools: [LLMToolDefinition],
        maxCallsPerTurn: [String: Int] = [:],
        searchLimits: SearchLimits? = nil,
        allowsExternalRetrieval: Bool = true,
        allowsScreenTools: Bool = false
    ) {
        self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        self.maxCallsPerTurn = maxCallsPerTurn
        self.searchLimits = searchLimits
        self.allowsExternalRetrieval = allowsExternalRetrieval
        self.allowsScreenTools = allowsScreenTools
    }

    public mutating func execute(_ call: LLMToolCall) async -> ExecutionResult {
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

        let limits = ChatToolPolicy.searchToolNames.contains(tool.name) ? searchLimits : nil
        if let limits {
            searchCalls += 1
            if searchCalls > limits.maxCallsPerTurn {
                return ExecutionResult(
                    toolName: tool.name,
                    status: nil,
                    outcome: .refused,
                    resultText: "This turn's searches are used up. Do not search again; answer the user now from the tool results and the transcript.",
                    elapsedMS: 0,
                    executed: false
                )
            }
        }

        let start = Date()
        var outcome: ToolRoundStatus = .succeeded
        let resultText: String
        switch await Self.run(tool, call.function.arguments, timeLimit: limits?.timeLimit) {
        case let .finished(text):
            resultText = text
        case let .threw(error):
            outcome = .failed
            resultText = "Tool '\(tool.name)' failed: \(error.localizedDescription)"
        case .timedOut:
            outcome = .failed
            resultText = "\(tool.name) did not finish in time. Do not search again; answer the user now from the transcript, and say the search did not finish."
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

    private enum RunEnd {
        case finished(String)
        case threw(any Error)
        case timedOut
    }

    /// Runs the tool, and with a limit stops waiting when it runs out. A scan
    /// that cannot be interrupted finishes on its own and is ignored.
    private static func run(_ tool: LLMToolDefinition, _ arguments: String, timeLimit: Duration?) async -> RunEnd {
        func attempt() async -> RunEnd {
            do { return .finished(try await tool.execute(arguments)) } catch { return .threw(error) }
        }
        guard let timeLimit else { return await attempt() }
        return await withCheckedContinuation { continuation in
            var resumed = false
            func finish(_ end: RunEnd) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: end)
            }
            let work = Task { @MainActor in finish(await attempt()) }
            Task { @MainActor in
                try? await Task.sleep(for: timeLimit)
                work.cancel()
                finish(.timedOut)
            }
        }
    }
}
