import Foundation

/// Static configuration for one OpenAI-compatible streaming-chat provider.
/// The client is generic over this; the app's `LLMProviders` registry owns the
/// concrete instances (and resolves the API key from the Keychain).
public struct LLMProviderConfig: Sendable {
    /// Stable id used as the active-provider key in UserDefaults.
    public let id: String
    public let displayName: String
    public let baseURL: URL
    public let model: String
    /// True when the provider accepts the DeepSeek `thinking: { type }`
    /// extension on the chat-completions request. Disabled providers
    /// silently skip the field so smart mode degrades to a normal completion.
    public let supportsThinking: Bool
    /// True when the provider accepts OpenAI-style image content blocks on a
    /// user message (inline `data:` URL). When false, screenshots stay
    /// text-only (OCR + local vision description).
    public let supportsVision: Bool
    /// Closure resolved at call time so a key change in Settings is picked up
    /// without re-instantiating the client.
    public let apiKey: @Sendable () -> String

    public init(
        id: String,
        displayName: String,
        baseURL: URL,
        model: String,
        supportsThinking: Bool,
        supportsVision: Bool = true,
        apiKey: @escaping @Sendable () -> String
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.model = model
        self.supportsThinking = supportsThinking
        self.supportsVision = supportsVision
        self.apiKey = apiKey
    }
}
