import Foundation

enum DeepSeekError: Error {
    case httpError(Int, String)
    case unauthorized
    case badResponse
    case missingAPIKey
}

final class DeepSeekClient {
    private let baseURL: URL
    private let session: URLSession

    /// Fires on the main thread for every reasoning_content chunk in smart
    /// mode. Callers that don't care can leave this nil. Used by
    /// LLMController to drive the "reasoning…" indicator.
    var onReasoning: ((String) -> Void)?

    init(baseURL: URL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        // Per-request timeout is set on the URLRequest below; resource timeout
        // is the upper bound on the entire transfer including the SSE stream,
        // so it must be long enough to cover smart-mode reasoning + content.
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    private var apiKey: String { Secrets.deepseekAPIKey }

    /// Streams delta.content strings from a DeepSeek chat completion as they
    /// arrive. The stream terminates on `data: [DONE]` sentinel or on error.
    /// Routes to deepseek-v4-flash with `thinking.type=enabled` (smart=true,
    /// slower with reasoning) or `disabled` (smart=false, fast).
    func streamChat(messages: [DeepSeekMessage], smart: Bool = false) -> AsyncThrowingStream<String, Error> {
        let model = "deepseek-v4-flash"
        // Thinking mode ignores sampling params; only send temperature when
        // thinking is disabled.
        let temperature: Double? = smart ? nil : 0.6
        let thinking = DeepSeekRequest.Thinking(type: smart ? "enabled" : "disabled")
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if apiKey.isEmpty {
                        throw DeepSeekError.missingAPIKey
                    }
                    let body = DeepSeekRequest(model: model, messages: messages, stream: true, temperature: temperature, thinking: thinking)
                    var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.httpBody = try JSONEncoder().encode(body)
                    // Smart mode runs reasoning before any content, so the
                    // first byte can take much longer to arrive than chat.
                    request.timeoutInterval = smart ? 120 : 60

                    NSLog("[RTI] DeepSeekClient: POST \(request.url?.absoluteString ?? "?") model=\(model) messages=\(messages.count)")
                    RTILog.log("POST model=\(model) messages=\(messages.count) smart=\(smart)", category: "deepseek")
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw DeepSeekError.badResponse
                    }
                    NSLog("[RTI] DeepSeekClient: HTTP \(http.statusCode)")
                    RTILog.log("HTTP \(http.statusCode)", category: "deepseek")
                    guard (200..<300).contains(http.statusCode) else {
                        let errText = try await readAll(bytes)
                        if http.statusCode == 401 {
                            throw DeepSeekError.unauthorized
                        }
                        throw DeepSeekError.httpError(http.statusCode, errText)
                    }

                    let decoder = JSONDecoder()
                    var lineCount = 0
                    var deltaCount = 0
                    for try await line in bytes.lines {
                        lineCount += 1
                        if lineCount <= 3 {
                            NSLog("[RTI] DeepSeekClient line[\(lineCount)]: %@", line.prefix(200) as NSString)
                        }
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" {
                            NSLog("[RTI] DeepSeekClient: [DONE] lines=\(lineCount) deltas=\(deltaCount)")
                            RTILog.log("done — lines=\(lineCount) deltas=\(deltaCount)", category: "deepseek")
                            continuation.finish()
                            return
                        }
                        guard let data = payload.data(using: .utf8) else { continue }
                        // Some servers send {"error": {...}} mid-stream instead of [DONE].
                        // Surface that to the caller instead of silently swallowing it.
                        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let err = obj["error"] {
                            throw DeepSeekError.httpError(0, "DeepSeek stream error: \(err)")
                        }
                        do {
                            let chunk = try decoder.decode(DeepSeekChatChunk.self, from: data)
                            if let reasoning = chunk.choices.first?.delta?.reasoning_content, !reasoning.isEmpty {
                                let cb = self.onReasoning
                                DispatchQueue.main.async { cb?(reasoning) }
                            }
                            if let delta = chunk.choices.first?.delta?.content, !delta.isEmpty {
                                deltaCount += 1
                                continuation.yield(delta)
                            }
                        } catch {
                            NSLog("[RTI] DeepSeekClient chunk decode failed: \(error) payload=\(payload.prefix(200))")
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func readAll(_ bytes: URLSession.AsyncBytes) async throws -> String {
        let data = try await Data(collecting: bytes, upTo: 8192)
        return String(data: data, encoding: .utf8) ?? "<binary>"
    }
}
