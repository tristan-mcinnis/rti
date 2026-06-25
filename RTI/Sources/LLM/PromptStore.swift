import Foundation
import Observation
import RTICore

/// User overrides for the prompt registry, layered over `PromptID` defaults.
///
/// Mirrors `GlossaryStore`: an `@Observable @MainActor` singleton backed by a
/// single UserDefaults blob. Every prompt the app sends resolves through
/// `text(_:)` — an override when the user has edited it in Settings, else the
/// shipped default. Composition (recap/assist/summary) is delegated to the pure
/// `PromptComposer` with a resolver that reads this store.
///
/// Override drift: when an override is saved we also record the hash of the
/// default it was based on, so a later app version that ships a better default
/// can flag "the default changed since you edited this" instead of silently
/// pinning your old copy forever.
@Observable @MainActor
final class PromptStore {
    static let shared = PromptStore()

    /// id → edited text. Absent ⇒ use the default.
    private var overrides: [String: String]
    /// id → default hash at the time the override was saved.
    private var baseHashes: [String: String]

    private static let overridesKey = "rti.prompts.overridesV1"
    private static let baseHashesKey = "rti.prompts.baseHashesV1"

    private init() {
        overrides = Self.loadMap(Self.overridesKey)
        baseHashes = Self.loadMap(Self.baseHashesKey)
    }

    // MARK: - Resolution

    /// The effective text for a prompt: the override if set, else the default.
    func text(_ id: PromptID) -> String {
        overrides[id.rawValue] ?? id.defaultText
    }

    func isOverridden(_ id: PromptID) -> Bool {
        overrides[id.rawValue] != nil
    }

    /// True when this prompt is overridden AND the shipped default has changed
    /// since the override was saved — i.e. the user is pinning a stale copy.
    func defaultChangedSinceEdit(_ id: PromptID) -> Bool {
        guard isOverridden(id), let base = baseHashes[id.rawValue] else { return false }
        return base != id.defaultHash
    }

    // MARK: - Mutation

    /// Save an override. Trimmed text equal to the default clears the override
    /// (so "edit back to default" doesn't leave a redundant pin).
    func setOverride(_ id: PromptID, _ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == id.defaultText.trimmingCharacters(in: .whitespacesAndNewlines) {
            reset(id)
            return
        }
        overrides[id.rawValue] = raw
        baseHashes[id.rawValue] = id.defaultHash
        persist()
    }

    func reset(_ id: PromptID) {
        overrides[id.rawValue] = nil
        baseHashes[id.rawValue] = nil
        persist()
    }

    func resetAll() {
        overrides.removeAll()
        baseHashes.removeAll()
        persist()
    }

    var hasAnyOverride: Bool {
        !overrides.isEmpty
    }

    // MARK: - Validation (warn, never block)

    /// Returns human-readable warnings if an in-progress edit drops a token the
    /// downstream parser/format relies on (e.g. the JSON contract). Empty ⇒ ok.
    func warnings(for id: PromptID, candidate: String) -> [String] {
        var out: [String] = []
        for token in id.requiredTokens where !candidate.contains(token) {
            if id.isJSONContract {
                out.append("This prompt's output is parsed as JSON — removing “\(token)” will likely break \(id.title).")
            } else {
                out.append("Removing “\(token)” may break the expected output format.")
            }
        }
        return out
    }

    // MARK: - Composed prompts (override-aware)

    private var resolver: PromptComposer.Resolver {
        { [unowned self] in text($0) }
    }

    var system: String {
        text(.systemDefault)
    }

    var listenerSystemSuffix: String {
        text(.listenerSystemSuffix)
    }

    func assist(listener: Bool) -> String {
        PromptComposer.assist(listener: listener, resolve: resolver)
    }

    func followups(listener: Bool) -> String {
        PromptComposer.followups(listener: listener, resolve: resolver)
    }

    func recap(_ depth: RecapDepth) -> String {
        PromptComposer.recap(depth, resolve: resolver)
    }

    func summary(for kind: ModeKind) -> String {
        PromptComposer.summary(for: kind, resolve: resolver)
    }

    // MARK: - Export (keep the offline prompt-lab in sync)

    /// Writes the shipped DEFAULTS (not overrides) as JSON for `scripts/prompt-lab`
    /// to read, so the Python copy no longer drifts by hand. Returns the bytes
    /// written count on success.
    @discardableResult
    func exportDefaults(to url: URL) throws -> Int {
        let map = PromptDefaults.exportMap()
        let data = try JSONSerialization.data(withJSONObject: map, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        return data.count
    }

    // MARK: - Persistence

    private func persist() {
        UserDefaults.standard.set(overrides, forKey: Self.overridesKey)
        UserDefaults.standard.set(baseHashes, forKey: Self.baseHashesKey)
    }

    private static func loadMap(_ key: String) -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
    }
}
