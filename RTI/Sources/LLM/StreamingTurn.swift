import Foundation

/// Reference-type holder for streaming entries, enabling capture by
/// escaping closures in `StreamingTurn`. Replaces the `inout [StreamingEntry]`
/// pattern that fails under Swift 6 concurrency.
@MainActor
final class StreamingEntryCollection {
    var entries: [StreamingEntry] = []

    func appendUser(text: String, action: String? = nil) {
        entries.append(StreamingEntry(role: "user", text: text, action: action))
    }

    func appendAssistant() -> UUID {
        let entry = StreamingEntry(role: "assistant", text: "")
        entries.append(entry)
        return entry.id
    }

    func appendDelta(_ delta: String, for id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].text += delta
    }

    func setText(_ text: String, for id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].text = text
    }

    func removeAssistant(id: UUID) {
        entries.removeAll { $0.id == id }
    }

    func text(for id: UUID) -> String? {
        entries.first(where: { $0.id == id })?.text
    }
}

struct StreamingEntry {
    let id = UUID()
    let role: String
    var text: String
    var action: String?
}

/// Encapsulates the streaming lifecycle for a chat turn: stream deltas into
/// an assistant entry, prune on error, finalize on completion.
@MainActor
enum StreamingTurn {

    enum Outcome {
        case completed(String)
        case failed(String, isAuth: Bool)
        case cancelled
    }

    /// Run a streaming turn with tool support (via ToolLoop).
    static func runWithTools(
        collection: StreamingEntryCollection,
        assistantId: UUID,
        request: LLMRequest,
        messages: [LLMMessage],
        toolsJSON: Data,
        smart: Bool,
        onToolStatus: (@Sendable (String) -> Void)? = nil,
        onToolStatusDone: (@Sendable () -> Void)? = nil,
        onReasoning: (@Sendable () -> Void)? = nil
    ) async -> Outcome {
        let loop = ToolLoop(request: request)
        var outcome: Outcome = .cancelled
        await loop.run(
            conversation: messages,
            toolsJSON: toolsJSON,
            smart: smart,
            onEvent: { event in
                MainActor.assumeIsolated {
                    switch event {
                    case .contentDelta(let delta):
                        collection.appendDelta(delta, for: assistantId)
                    case .reasoningStarted:
                        onReasoning?()
                    case .reasoningEnded:
                        break
                    case .toolStatus(let status):
                        onToolStatus?(status)
                    case .toolStatusDone:
                        onToolStatusDone?()
                    case .done(let finalText):
                        if collection.text(for: assistantId)?.isEmpty != false {
                            collection.setText(finalText, for: assistantId)
                        }
                        outcome = .completed(collection.text(for: assistantId) ?? finalText)
                    case .error(let message, let isAuth):
                        collection.removeAssistant(id: assistantId)
                        outcome = .failed(message, isAuth: isAuth)
                    }
                }
            }
        )
        return outcome
    }

    /// Run a plain (tool-less) streaming turn.
    static func runPlain(
        collection: StreamingEntryCollection,
        assistantId: UUID,
        request: LLMRequest,
        messages: [LLMMessage],
        smart: Bool,
        onReasoning: (@Sendable () -> Void)? = nil
    ) async -> Outcome {
        return await withCheckedContinuation { continuation in
            request.stream(
                messages: messages,
                smart: smart,
                onDelta: { delta in
                    Task { @MainActor in
                        collection.appendDelta(delta, for: assistantId)
                    }
                },
                onError: { message, isAuth in
                    Task { @MainActor in
                        collection.removeAssistant(id: assistantId)
                        continuation.resume(returning: .failed(message, isAuth: isAuth))
                    }
                },
                onComplete: {
                    Task { @MainActor in
                        let finalText = collection.text(for: assistantId) ?? ""
                        continuation.resume(returning: .completed(finalText))
                    }
                },
                onReasoning: { _ in
                    Task { @MainActor in onReasoning?() }
                }
            )
        }
    }
}
