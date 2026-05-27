import Foundation

/// Shared helpers for `AnalysisController` conformers. Each controller
/// still owns its prompt and type-specific result handling; this file
/// consolidates the lifecycle boilerplate repeated across controllers.
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
