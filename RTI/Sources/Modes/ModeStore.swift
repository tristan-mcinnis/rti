import Foundation
import Observation
import RTICore

@Observable @MainActor
final class ModeStore {
    static let shared = ModeStore()

    private(set) var modes: [Mode] = []
    /// Where the active-mode choice is remembered. Nil in a memory-only store:
    /// the choice lives in memory and is never written to the user's defaults.
    private let defaults: UserDefaults?
    /// False in a memory-only store: no file is read, written, or resolved.
    private let persistsToDisk: Bool
    /// Failure tests inject a writer without resolving the user's modes file.
    private let persistOverride: (([Mode]) throws -> Void)?

    var activeModeId: String? {
        didSet {
            guard let defaults else { return }
            if let id = activeModeId {
                defaults.set(id, forKey: ModeSettingsDefaults.activeIdKey)
            } else {
                defaults.removeObject(forKey: ModeSettingsDefaults.activeIdKey)
            }
        }
    }

    /// Production: the live modes file and the standard defaults.
    private init() {
        persistsToDisk = true
        persistOverride = nil
        defaults = .standard
        let loaded = Self.fileURL.flatMap { ModeStorage.load(from: $0) } ?? ModeStorage.builtinSeeds()
        // A file that exists but did not decode is about to be overwritten by
        // the seeds below; keep a copy so the user's modes are recoverable.
        if let url = Self.fileURL,
           FileManager.default.fileExists(atPath: url.path),
           ModeStorage.load(from: url) == nil {
            let backup = url.appendingPathExtension("bak-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.copyItem(at: url, to: backup)
            RTILog.log("modes.json could not be decoded; copied to \(backup.lastPathComponent)", category: .modes)
        }
        // Refresh built-in prompts in place each launch so prompt edits ship
        // without a migration; user-added modes are untouched.
        modes = ModeStorage.upgradingBuiltins(in: loaded)
        persist()
        let stored = UserDefaults.standard.string(forKey: ModeSettingsDefaults.activeIdKey)
        self.activeModeId = stored ?? "builtin.meeting"
    }

    /// A memory-only store for tests and render proofs.
    ///
    /// It holds the shipped built-ins (or the caller's modes) in memory, with
    /// an isolated active mode, and touches NOTHING on disk and NO user
    /// default: no `modes.json` read or write, no `activeIdKey` write. Every
    /// mutator stays in memory, so a test or proof can never change the user's
    /// live preferences.
    static func inMemory(
        modes: [Mode]? = nil,
        activeModeId: String? = "builtin.meeting",
        writer: (([Mode]) throws -> Void)? = nil
    ) -> ModeStore {
        ModeStore(inMemory: modes, activeModeId: activeModeId, writer: writer)
    }

    private init(inMemory modes: [Mode]?, activeModeId: String?, writer: (([Mode]) throws -> Void)?) {
        persistsToDisk = false
        persistOverride = writer
        defaults = nil
        self.modes = ModeStorage.upgradingBuiltins(in: modes ?? ModeStorage.builtinSeeds())
        // A fresh in-memory active mode is a plain assignment, not a shared
        // default.
        self.activeModeId = activeModeId
    }

    var activeMode: Mode? {
        guard let id = activeModeId else { return nil }
        return modes.first { $0.id == id }
    }

    /// True for a memory-only store: nothing it does reads or writes a file or
    /// a user default. Exposed so a test can pin the isolation.
    var isMemoryOnly: Bool { !persistsToDisk }

    func reload() {
        guard persistsToDisk, let url = Self.fileURL, let loaded = ModeStorage.load(from: url) else { return }
        modes = loaded
    }

    @discardableResult
    func update(id: String, name: String, systemPrompt: String, referenceText: String?) -> Bool {
        guard let idx = modes.firstIndex(where: { $0.id == id }) else { return false }
        var updated = modes
        updated[idx].name = name
        updated[idx].systemPrompt = systemPrompt
        updated[idx].referenceText = (referenceText?.isEmpty == true) ? nil : referenceText
        guard persist(updated) else { return false }
        modes = updated
        return true
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

    @discardableResult
    private func persist(_ candidate: [Mode]? = nil) -> Bool {
        let values = candidate ?? modes
        do {
            if let persistOverride { try persistOverride(values) }
            else if persistsToDisk {
                guard let url = Self.fileURL else { return false }
                try ModeStorage.save(values, to: url)
            }
            return true
        } catch {
            RTILog.log("ModeStore persist failed: \(error)", category: .modes)
            return false
        }
    }
}
