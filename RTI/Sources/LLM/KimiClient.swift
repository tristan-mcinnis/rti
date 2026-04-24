import Foundation

enum KimiError: Error {
    case httpError(Int, String)
    case unauthorized
    case badResponse
    case missingAPIKey
}

final class KimiClient {
    private let apiKey: String
    private let baseURL: URL

    init(apiKey: String, baseURL: URL) {
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    /// Streams delta.content strings from a Kimi chat completion as they arrive.
    /// The stream terminates on `data: [DONE]` sentinel or on error.
    /// `smart=true` routes to kimi-k2.6 with thinking enabled (deeper, slower).
    /// `smart=false` routes to kimi-k2-turbo-preview (fast default).
    func streamChat(messages: [KimiMessage], smart: Bool = false) -> AsyncThrowingStream<String, Error> {
        let model = smart ? "kimi-k2.6" : "kimi-k2-turbo-preview"
        let temperature = smart ? 1.0 : 0.6
        let thinking: KimiRequest.Thinking? = smart ? KimiRequest.Thinking(type: "enabled") : nil
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if apiKey.isEmpty {
                        throw KimiError.missingAPIKey
                    }
                    let body = KimiRequest(model: model, messages: messages, stream: true, temperature: temperature, thinking: thinking)
                    var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.httpBody = try JSONEncoder().encode(body)
                    request.timeoutInterval = 60

                    NSLog("[RTI] KimiClient: POST \(request.url?.absoluteString ?? "?") model=\(model) messages=\(messages.count)")
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw KimiError.badResponse
                    }
                    NSLog("[RTI] KimiClient: HTTP \(http.statusCode)")
                    guard (200..<300).contains(http.statusCode) else {
                        let errText = try await readAll(bytes)
                        if http.statusCode == 401 {
                            throw KimiError.unauthorized
                        }
                        throw KimiError.httpError(http.statusCode, errText)
                    }

                    let decoder = JSONDecoder()
                    var lineCount = 0
                    var deltaCount = 0
                    for try await line in bytes.lines {
                        lineCount += 1
                        if lineCount <= 3 {
                            NSLog("[RTI] KimiClient line[\(lineCount)]: %@", line.prefix(200) as NSString)
                        }
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" {
                            NSLog("[RTI] KimiClient: [DONE] lines=\(lineCount) deltas=\(deltaCount)")
                            continuation.finish()
                            return
                        }
                        guard let data = payload.data(using: .utf8) else { continue }
                        do {
                            let chunk = try decoder.decode(KimiChatChunk.self, from: data)
                            if let delta = chunk.choices.first?.delta?.content, !delta.isEmpty {
                                deltaCount += 1
                                continuation.yield(delta)
                            }
                        } catch {
                            NSLog("[RTI] KimiClient chunk decode failed: \(error) payload=\(payload.prefix(200))")
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
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > 8192 { break }
        }
        return String(data: data, encoding: .utf8) ?? "<binary>"
    }
}
