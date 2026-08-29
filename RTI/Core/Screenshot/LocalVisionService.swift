import Foundation

/// Configuration for the local vision-model lane, parsed from the
/// `local_vision` object in `~/.config/rti/config.json`.
///
/// An absent block (or `enabled: false`) disables every vision call and every
/// frame save, so RTI behaves exactly like the OCR-only build. The endpoint is
/// the local-models daemon (`POST /v1/vision`, 127.0.0.1 only) — the image
/// never leaves this Mac.
public struct LocalVisionConfiguration: Equatable, Sendable {
    public let enabled: Bool
    public let endpoint: URL
    public let model: String?
    public let maxTokens: Int
    public let timeoutSeconds: Double
    /// Keep a compressed JPEG of each captured frame in the session archive
    /// (`frames/` beside `screen-context.md`) while a session is recording.
    public let saveFrames: Bool
    /// Also describe the ambient 60s trail frames with the vision model.
    /// Off by default: OCR already covers the trail, and a description per
    /// minute is only worth the cycles when explicitly asked for.
    public let ambientDescribe: Bool

    public static let defaultEndpoint = URL(string: "http://127.0.0.1:8078")!

    public init(
        enabled: Bool = false,
        endpoint: URL = LocalVisionConfiguration.defaultEndpoint,
        model: String? = nil,
        maxTokens: Int = 400,
        timeoutSeconds: Double = 45,
        saveFrames: Bool = true,
        ambientDescribe: Bool = false
    ) {
        self.enabled = enabled
        self.endpoint = endpoint
        self.model = model
        self.maxTokens = maxTokens
        self.timeoutSeconds = timeoutSeconds
        self.saveFrames = saveFrames
        self.ambientDescribe = ambientDescribe
    }

    /// Parse the `local_vision` block of the app config dictionary
    /// (`VaultPaths.configDictionary()` shape: untyped JSON).
    public static func from(_ config: [String: Any]) -> LocalVisionConfiguration {
        guard let block = config["local_vision"] as? [String: Any] else {
            return LocalVisionConfiguration()
        }
        let endpoint = (block["endpoint"] as? String)
            .flatMap { URL(string: $0) } ?? defaultEndpoint
        let model = (block["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let timeout: Double = if let value = block["timeout_seconds"] as? Double {
            value
        } else if let value = block["timeout_seconds"] as? Int {
            Double(value)
        } else {
            45
        }
        return LocalVisionConfiguration(
            enabled: block["enabled"] as? Bool ?? false,
            endpoint: endpoint,
            model: model,
            maxTokens: block["max_tokens"] as? Int ?? 400,
            timeoutSeconds: timeout,
            saveFrames: block["save_frames"] as? Bool ?? true,
            ambientDescribe: block["ambient_describe"] as? Bool ?? false
        )
    }
}

public enum LocalVisionError: Error, Equatable {
    case disabled
    case badStatus(Int, String)
    case malformedResponse
}

/// Client for the local-models daemon's `POST /v1/vision` route. Accepts JPEG
/// or PNG bytes (the daemon decodes by content, verified 2026-08-29). One
/// request, one plain-text description back; no streaming, no retries — a
/// capture must never hang on the model, so failures surface fast and the
/// caller degrades to OCR-only.
public enum LocalVisionService {
    /// What OCR cannot carry: layout, imagery, charts, and visual state.
    public static let screenPrompt = """
    This is a screenshot of the user's screen during a work session. In 2-4 \
    short sentences, describe what plain OCR text would miss: which \
    application and layout is visible, any charts, images, diagrams, tables, \
    or visual state, and what the user appears to be doing. Do not transcribe \
    the text itself.
    """

    public static func describe(
        imageData: Data,
        prompt: String = LocalVisionService.screenPrompt,
        configuration: LocalVisionConfiguration,
        session: URLSession = .shared
    ) async throws -> String {
        guard configuration.enabled else { throw LocalVisionError.disabled }
        var request = URLRequest(
            url: configuration.endpoint.appendingPathComponent("v1/vision")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = configuration.timeoutSeconds
        var body: [String: Any] = [
            "prompt": prompt,
            "image_b64": imageData.base64EncodedString(),
            "max_tokens": configuration.maxTokens,
        ]
        if let model = configuration.model {
            body["model"] = model
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LocalVisionError.malformedResponse
        }
        guard http.statusCode == 200 else {
            let detail = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
            let fallback = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw LocalVisionError.badStatus(http.statusCode, detail ?? fallback)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = object["text"] as? String
        else { throw LocalVisionError.malformedResponse }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalVisionError.malformedResponse }
        return trimmed
    }
}
