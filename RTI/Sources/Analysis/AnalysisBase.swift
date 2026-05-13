import Foundation

/// Shared helpers for `AnalysisController` conformers. Each controller
/// still owns its prompt, persistence, and type-specific result handling;
/// this file consolidates the lifecycle boilerplate that was repeated
/// identically across all four controllers.
extension AnalysisController {
    /// Guard against concurrent generation, run `body`, and manage the
    /// `isGenerating` flag. Returns nil when already busy — callers skip
    /// the tick without advancing the watermark.
    func withGenerationGuard<T>(
        _ body: () async -> T?
    ) async -> T? {
        guard !isGenerating else { return nil }
        isGenerating = true
        defer { isGenerating = false }
        return await body()
    }
}
