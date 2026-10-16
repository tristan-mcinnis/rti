import Foundation

/// The deterministic state machine behind the Sessions window's saved-meeting
/// output chooser.
///
/// Pure value type: the model owns one instance and the unit tests drive it
/// directly, so "session switched mid-run" and "user cancelled" have no
/// timing or I/O in them. The async work and the file write live behind the
/// model's injected `generateOutput` closure; this only decides what the
/// chooser shows and whether a run may start.
public struct SessionOutputFlow: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// No recipe has been chosen.
        case idle
        /// A recipe is chosen and ready to generate.
        case ready
        /// A background call is running for the selected recipe.
        case generating
        /// The most recent run saved this artifact.
        case saved(SessionOutputArtifact)
        /// The most recent run failed, with a message for the user.
        case failed(String)
        /// The most recent run was cancelled; nothing was saved.
        case cancelled
    }

    public private(set) var phase: Phase = .idle
    public private(set) var selectedRecipeID: String?

    public init() {}

    public var isGenerating: Bool {
        if case .generating = phase { return true }
        return false
    }

    /// Choose a recipe. Ignored while a run is in flight, so a stray tap
    /// cannot change what the running call will be attributed to. Passing nil
    /// clears the choice back to `.idle`.
    @discardableResult
    public mutating func select(recipeID: String?) -> Bool {
        guard !isGenerating else { return false }
        selectedRecipeID = recipeID
        phase = recipeID == nil ? .idle : .ready
        return true
    }

    /// Begin a run for the selected recipe. False when nothing is selected or
    /// a run is already in flight, so the caller never starts twice.
    @discardableResult
    public mutating func begin() -> Bool {
        guard !isGenerating, let selectedRecipeID, !selectedRecipeID.isEmpty else { return false }
        phase = .generating
        return true
    }

    /// A run succeeded. The artifact is recorded so the chooser can name the
    /// saved file.
    public mutating func succeed(_ artifact: SessionOutputArtifact) {
        phase = .saved(artifact)
    }

    /// A run failed. Empty text falls back to a plain message so the UI never
    /// shows a blank error.
    public mutating func fail(_ message: String) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .failed(text.isEmpty ? "The output could not be generated." : text)
    }

    /// The user cancelled a run. Only meaningful while generating; otherwise
    /// a no-op, so a late cancel cannot erase a saved result.
    public mutating func cancel() {
        guard isGenerating else { return }
        phase = .cancelled
    }

    /// The open session changed: drop the run and the selection. The caller
    /// cancels its Task separately; this only forgets the state.
    public mutating func reset() {
        phase = .idle
        selectedRecipeID = nil
    }

    /// The saved file name from the last successful run, for the status line.
    public var savedFileName: String? {
        if case let .saved(artifact) = phase { return artifact.url.lastPathComponent }
        return nil
    }
}
