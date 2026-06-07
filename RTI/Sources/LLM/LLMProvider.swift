import Foundation
import RTICore

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
    static let deepseek = LLMProviderConfig(
        id: "deepseek",
        displayName: "DeepSeek",
        baseURL: URL(string: "https://api.deepseek.com/v1")!,
        model: "deepseek-v4-flash",
        supportsThinking: true,
        apiKey: { CredentialStore.deepseek ?? "" }
    )

    /// All known providers, keyed by id.
    static let all: [String: LLMProviderConfig] = [
        deepseek.id: deepseek
    ]

    private static let activeIdKey = "rti.llm.activeProviderId"

    /// Id of the active provider. Defaults to `deepseek`.
    /// Setting this persists to UserDefaults so it survives relaunch.
    static var activeId: String {
        get { UserDefaults.standard.string(forKey: activeIdKey) ?? deepseek.id }
        set { UserDefaults.standard.set(newValue, forKey: activeIdKey) }
    }

    /// Resolved config for the active provider, falling back to DeepSeek
    /// if the stored id no longer corresponds to a known provider.
    static var active: LLMProviderConfig {
        all[activeId] ?? deepseek
    }
}
