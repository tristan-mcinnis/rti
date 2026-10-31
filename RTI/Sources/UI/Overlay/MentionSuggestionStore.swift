import AppKit
import RTICore
import SwiftUI
import UniformTypeIdentifiers
import HouseDesign

@MainActor
final class MentionSuggestionStore: ObservableObject {
    @Published var candidates: [String] = []
    /// The first search after `@` has not answered yet; the chooser draws its
    /// waiting row instead of showing nothing.
    @Published private(set) var isSearching = false

    private var task: Task<Void, Never>?
    private var activeQuery: String?
    private var activeScope: String?
    private var cachedResults: [String: [String]] = [:]
    private var cachedResultKeys: [String] = []

    func update(query: String?, scopeRelativePath: String?) {
        let normalizedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedScope = scopeRelativePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedQuery != activeQuery || normalizedScope != activeScope else { return }

        activeQuery = normalizedQuery
        activeScope = normalizedScope
        task?.cancel()

        guard let normalizedQuery else {
            candidates = []
            isSearching = false
            return
        }

        let cacheKey = Self.cacheKey(query: normalizedQuery, scope: normalizedScope)
        if let cached = cachedResults[cacheKey] {
            candidates = cached
            isSearching = false
        } else {
            // The list is a fresh lookup: say so until it answers.
            isSearching = true
        }

        task = Task { [normalizedQuery, normalizedScope] in
            // `@` alone is the moment the chooser opens, so the first lookup
            // runs at once; only a typed query waits out the keystroke burst.
            if !normalizedQuery.isEmpty {
                try? await Task.sleep(nanoseconds: 35_000_000)
                guard !Task.isCancelled else { return }
            }
            let results = await Task.detached(priority: .userInitiated) {
                VaultFiles.mentionCandidates(normalizedQuery, scopeRelativePath: normalizedScope, limit: 6)
            }.value
            guard !Task.isCancelled else { return }
            candidates = results
            isSearching = false
            remember(results, for: cacheKey)
        }
    }

    func prewarm() {
        Task.detached(priority: .utility) {
            VaultFiles.prewarmMentionIndex()
        }
    }

    private func remember(_ results: [String], for key: String) {
        if cachedResults[key] == nil {
            cachedResultKeys.append(key)
            if cachedResultKeys.count > 40 {
                let stale = cachedResultKeys.removeFirst()
                cachedResults.removeValue(forKey: stale)
            }
        }
        cachedResults[key] = results
    }

    private static func cacheKey(query: String, scope: String?) -> String {
        "\(scope ?? "*")\n\(query)"
    }

    deinit {
        task?.cancel()
    }
}
