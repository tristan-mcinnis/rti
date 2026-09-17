import Foundation
import HouseChatCore
import RTICore

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
        case toolStarted(name: String, status: String)
        case toolFinished(id: String, round: Int, name: String, arguments: String, elapsedMS: Int, result: String, status: ToolRoundStatus)
        case toolStatusDone
        case done(String)   // final assistant text
        case error(String, isAuth: Bool)
    }

    private let request: LLMRequest
    private let makeToolExecutor: @MainActor (Bool, Bool) -> ToolExecutor

    init(
        request: LLMRequest = LLMRequest(),
        makeToolExecutor: @escaping @MainActor (Bool, Bool) -> ToolExecutor = { allowsExternalRetrieval, allowsScreenTools in
            ToolExecutor.production(
                allowsExternalRetrieval: allowsExternalRetrieval,
                allowsScreenTools: allowsScreenTools
            )
        }
    ) {
        self.request = request
        self.makeToolExecutor = makeToolExecutor
    }

    /// Run the tool loop to completion. Emits events via `onEvent` on each
    /// content delta, tool execution, or error.
    ///
    /// `allowsExternalRetrieval` comes from the turn's `ContextDecision`: the
    /// loop passes it to the executor so a withheld tool is refused, not just
    /// left out of the request.
    func run(
        conversation: [LLMMessage],
        toolsJSON: Data?,
        smart: Bool,
        route: ChatRouteConfiguration? = nil,
        allowsExternalRetrieval: Bool = true,
        allowsScreenTools: Bool = true,
        onEvent: @escaping @Sendable (Event) -> Void
    ) async {
        var messages = conversation
        let maxIterations = 4
        var latestAssistantText = ""
        var toolExecutor = makeToolExecutor(allowsExternalRetrieval, allowsScreenTools)

        for iteration in 0..<maxIterations {
            // A `/new` or Stop cancels the whole send task. Without this check
            // the NEXT round would start a fresh provider call and fresh tools
            // after the current stream was cancelled.
            if Task.isCancelled { return }
            let turnBuffer = TurnBuffer()

            let result: LLMClient.StreamResult
            do {
                result = try await request.streamWithTools(
                    messages: messages,
                    toolsJSON: toolsJSON,
                    smart: smart,
                    route: route,
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
                let finalText = turnBuffer.snapshot()
                onEvent(.done(finalText.isEmpty ? latestAssistantText : finalText))
                return
            }

            let assistantText = turnBuffer.snapshot()
            if !assistantText.isEmpty {
                latestAssistantText = assistantText
            }

            // Append assistant message with tool_calls to wire history.
            messages.append(LLMMessage(
                role: "assistant",
                content: assistantText.nilIfEmpty,
                tool_calls: result.toolCalls
            ))

            // Execute each tool, append results.
            for call in result.toolCalls {
                // Cancellation between rounds must not run the next tool.
                if Task.isCancelled { return }
                let result = await toolExecutor.execute(call)
                if result.executed, let status = result.status {
                    onEvent(.toolStatus(status))
                    onEvent(.toolStarted(name: result.toolName, status: status))
                }
                // Every call is reported with how it actually ended, including
                // a refusal or a failure, so the turn's receipt never claims a
                // success that did not run.
                onEvent(.toolFinished(
                    id: call.id,
                    round: iteration,
                    name: result.toolName,
                    arguments: call.function.arguments,
                    elapsedMS: result.elapsedMS,
                    result: result.resultText,
                    status: result.outcome
                ))
                if result.executed {
                    onEvent(.toolStatusDone)
                }
                messages.append(LLMMessage(role: "tool", content: result.resultText, tool_call_id: call.id, name: result.toolName))
            }
            // Loop back: model sees its tool results and may emit more content or more tools.
        }

        // A tool-call-only assistant message has no text. Never surface a
        // blank reply after visible tool activity when the iteration cap hits.
        let fallback = "I reached RTI's tool limit before a final answer. Please try a narrower question."
        onEvent(.done(latestAssistantText.isEmpty ? fallback : latestAssistantText))
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
