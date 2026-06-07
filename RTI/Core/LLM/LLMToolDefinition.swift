import Foundation

/// A function tool the model can invoke during a chat turn. Carries a
/// JSON-schema for its parameters (sent to the provider) and an async
/// `execute` block that runs locally and returns a string the model sees as
/// the tool's result. The app's `LLMToolRegistry` owns the concrete tools;
/// the core tool loop is handed definitions to run.
public struct LLMToolDefinition {
    public let name: String
    public let description: String
    /// JSON-schema for the function's parameters, as a Foundation dictionary.
    /// Serialised once when building the request body.
    public let parameters: [String: Any]
    /// Locally executes the tool. Returns the result text the model will see
    /// in the next turn. Throwing converts to an error string the model can
    /// recover from.
    public let execute: @Sendable @MainActor (_ argumentsJSON: String) async throws -> String
    /// Optional human-readable status shown in the UI while the tool runs
    /// (e.g. "📷 Looking at your screen…"). Falls back to the tool name.
    public let runningStatus: String?

    public init(
        name: String,
        description: String,
        parameters: [String: Any],
        execute: @escaping @Sendable @MainActor (_ argumentsJSON: String) async throws -> String,
        runningStatus: String?
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.execute = execute
        self.runningStatus = runningStatus
    }
}
