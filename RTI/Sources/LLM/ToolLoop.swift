import Foundation

/// Extracted from `LLMController`. Orchestrates a single chat turn that
/// may involve multiple streaming + tool-execution iterations. Callers
/// observe events to update UI; this module owns no `@Published` state.
///
/// The loop:
/// 1. Stream assistant response (content + optional tool_calls)
/// 2. If no tool_calls → stop (`.done`)
/// 3. If tool_calls → execute each, append results to conversation
/// 4. Loop (max 4 iterations)
@MainActor
struct ToolLoop {

    /// Events emitted during the loop. Callers observe these to update UI.
    enum Event {
        case contentDelta(String)
        case reasoningStarted
        case reasoningEnded
        case toolStatus(String)
        case toolStatusDone
        case done(String)   // final assistant text
        case error(String, isAuth: Bool)
    }

    private let request: LLMRequest

    init(request: LLMRequest = LLMRequest()) {
        self.request = request
    }

    /// Run the tool loop to completion. Emits events via `onEvent` on each
    /// content delta, tool execution, or error.
    func run(
        conversation: [LLMMessage],
        toolsJSON: Data?,
        smart: Bool,
        onEvent: @escaping @Sendable (Event) -> Void
    ) async {
        var messages = conversation
        let maxIterations = 4

        for _ in 0..<maxIterations {
            let turnBuffer = TurnBuffer()

            let result: LLMClient.ToolAwareStreamResult
            do {
                result = try await request.streamWithTools(
                    messages: messages,
                    toolsJSON: toolsJSON,
                    smart: smart,
                    onContent: { delta in
                        turnBuffer.append(delta)
                        Task { @MainActor in onEvent(.contentDelta(delta)) }
                    },
                    onReasoning: { _ in
                        Task { @MainActor in onEvent(.reasoningStarted) }
                    }
                )
            } catch is CancellationError {
                return
            } catch {
                let llmError = error as? LLMError
                onEvent(.error(llmError?.userMessage ?? "\(error)", isAuth: llmError?.isAuth ?? false))
                return
            }

            // No tools → terminal turn.
            guard !result.toolCalls.isEmpty else {
                onEvent(.done(turnBuffer.snapshot()))
                return
            }

            // Append assistant message with tool_calls to wire history.
            messages.append(LLMMessage(
                role: "assistant",
                content: turnBuffer.snapshot().nilIfEmpty,
                tool_calls: result.toolCalls
            ))

            // Execute each tool, append results.
            for call in result.toolCalls {
                guard let tool = LLMToolRegistry.tool(named: call.function.name) else {
                    let resultText = "Tool '\(call.function.name)' is not available."
                    messages.append(LLMMessage(role: "tool", content: resultText, tool_call_id: call.id, name: call.function.name))
                    continue
                }
                onEvent(.toolStatus(tool.runningStatus ?? "Running \(tool.name)…"))
                let resultText: String
                do {
                    resultText = try await tool.execute(call.function.arguments)
                } catch {
                    resultText = "Tool '\(tool.name)' failed: \(error.localizedDescription)"
                }
                onEvent(.toolStatusDone)
                messages.append(LLMMessage(role: "tool", content: resultText, tool_call_id: call.id, name: call.function.name))
            }
            // Loop back: model sees its tool results and may emit more content or more tools.
        }

        // Hit iteration cap — emit what we have.
        onEvent(.done(messages.last(where: { $0.role == "assistant" })?.content ?? ""))
    }
}

/// Thread-safe string buffer for accumulating content deltas during a
/// streaming turn. Used by the tool loop so the onContent closure (which
/// is @Sendable) can accumulate text without actor isolation.
private final class TurnBuffer: @unchecked Sendable {
    private var text: String = ""
    private let lock = NSLock()
    func append(_ s: String) { lock.lock(); text += s; lock.unlock() }
    func snapshot() -> String { lock.lock(); defer { lock.unlock() }; return text }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}