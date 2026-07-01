import Foundation
import RTICore

struct LLMProviderOption: Identifiable, Sendable {
    let config: LLMProviderConfig
    let keychainAccount: String
    let apiKeyLabel: String
    let apiKeyPlaceholder: String
    let consoleURL: String

    var id: String { config.id }
    var displayName: String { config.displayName }
    var model: String { config.model }
}

/// Built-in providers + which one is currently active.
///
/// ## Adding a provider
///
/// Append a `LLMProviderConfig` entry below, give it a unique id, then
/// either set `LLMProviders.activeId = "<your-id>"` from code (Settings,
/// launch hook, etc.) or write the `rti.llm.activeProviderId` key in
/// `UserDefaults` directly.
///
/// All providers must speak OpenAI-compatible streaming chat completions
/// (`POST {baseURL}/chat/completions` with SSE `data:` frames).
enum LLMProviders {
    static let deepseek = LLMProviderOption(
        config: LLMProviderConfig(
            id: "deepseek",
            displayName: "DeepSeek",
            baseURL: URL(string: "https://api.deepseek.com/v1")!,
            model: "deepseek-v4-flash",
            supportsThinking: true,
            apiKey: { CredentialStore.deepseek ?? "" }
        ),
        keychainAccount: "deepseek",
        apiKeyLabel: "DeepSeek API key",
        apiKeyPlaceholder: "sk-...",
        consoleURL: "https://platform.deepseek.com"
    )

    static let openai = LLMProviderOption(
        config: LLMProviderConfig(
            id: "openai",
            displayName: "OpenAI",
            baseURL: URL(string: "https://api.openai.com/v1")!,
            model: "gpt-4.1-mini",
            supportsThinking: false,
            apiKey: { CredentialStore.openai ?? "" }
        ),
        keychainAccount: "openai",
        apiKeyLabel: "OpenAI API key",
        apiKeyPlaceholder: "sk-...",
        consoleURL: "https://platform.openai.com/api-keys"
    )

    static let openrouter = LLMProviderOption(
        config: LLMProviderConfig(
            id: "openrouter",
            displayName: "OpenRouter",
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            model: "openai/gpt-4.1-mini",
            supportsThinking: false,
            apiKey: { CredentialStore.openrouter ?? "" }
        ),
        keychainAccount: "openrouter",
        apiKeyLabel: "OpenRouter API key",
        apiKeyPlaceholder: "sk-or-v1-...",
        consoleURL: "https://openrouter.ai/keys"
    )

    static let all: [LLMProviderOption] = [deepseek, openai, openrouter]

    static let activeIdKey = "rti.llm.activeProviderId"

    /// Id of the active provider. Defaults to `deepseek`.
    /// Setting this persists to UserDefaults so it survives relaunch.
    static var activeId: String {
        get { UserDefaults.standard.string(forKey: activeIdKey) ?? deepseek.id }
        set { UserDefaults.standard.set(newValue, forKey: activeIdKey) }
    }

    static var activeOption: LLMProviderOption {
        all.first { $0.id == activeId } ?? deepseek
    }

    /// Resolved config for the active provider, falling back to DeepSeek
    /// if the stored id no longer corresponds to a known provider.
    static var active: LLMProviderConfig {
        activeOption.config
    }

    static var activeHasKey: Bool {
        !active.apiKey().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func option(id: String) -> LLMProviderOption {
        all.first { $0.id == id } ?? deepseek
    }
}
