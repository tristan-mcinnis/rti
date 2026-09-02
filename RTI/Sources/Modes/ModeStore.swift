import Foundation
import Observation
import RTICore

@Observable @MainActor
final class ModeStore {
    static let shared = ModeStore()

    private(set) var modes: [Mode] = []
    var activeModeId: String? {
        didSet {
            if let id = activeModeId {
                UserDefaults.standard.set(id, forKey: ModeSettingsDefaults.activeIdKey)
            } else {
                UserDefaults.standard.removeObject(forKey: ModeSettingsDefaults.activeIdKey)
            }
        }
    }

    private init() {
        let loaded = Self.fileURL.flatMap { ModeStorage.load(from: $0) } ?? ModeStorage.builtinSeeds()
        // Refresh built-in prompts in place each launch so prompt edits ship
        // without a migration; user-added modes are untouched.
        modes = ModeStorage.upgradingBuiltins(in: loaded)
        persist()
        let stored = UserDefaults.standard.string(forKey: ModeSettingsDefaults.activeIdKey)
        self.activeModeId = stored ?? "builtin.meeting"
    }

    var activeMode: Mode? {
        guard let id = activeModeId else { return nil }
        return modes.first { $0.id == id }
    }

    func reload() {
        if let url = Self.fileURL, let loaded = ModeStorage.load(from: url) { modes = loaded }
    }

    func update(id: String, name: String, systemPrompt: String, referenceText: String?) {
        guard let idx = modes.firstIndex(where: { $0.id == id }) else { return }
        modes[idx].name = name
        modes[idx].systemPrompt = systemPrompt
        modes[idx].referenceText = (referenceText?.isEmpty == true) ? nil : referenceText
        persist()
    }

    /// Insert a new user-defined mode. Returns the new id, or nil if invalid.
    @discardableResult
    func addMode(name: String, systemPrompt: String) -> String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        let m = Mode(
            id: "user.\(UUID().uuidString)",
            name: trimmedName,
            systemPrompt: systemPrompt,
            isBuiltin: false,
            createdAt: Date(),
            referenceText: nil
        )
        modes.append(m)
        persist()
        return m.id
    }

    /// Delete a non-builtin mode. Built-in modes are protected. If the deleted
    /// mode was active, fall back to the meeting builtin.
    func deleteMode(id: String) {
        guard let mode = modes.first(where: { $0.id == id }), !mode.isBuiltin else { return }
        modes.removeAll { $0.id == id }
        if activeModeId == id { activeModeId = "builtin.meeting" }
        persist()
    }

    // MARK: - Persistence

    private static var fileURL: URL? {
        AppSupportPaths.file("modes.json")
    }

    private func persist() {
        guard let url = Self.fileURL else { return }
        do {
            try ModeStorage.save(modes, to: url)
        } catch {
            RTILog.log("ModeStore persist failed: \(error)", category: .modes)
        }
    }
}
