import Combine
import Foundation
import GRDB

@MainActor
final class ModeStore: ObservableObject {
    static let shared = ModeStore()

    @Published private(set) var modes: [Mode] = []
    @Published var activeModeId: String? {
        didSet {
            if let id = activeModeId {
                UserDefaults.standard.set(id, forKey: Self.activeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.activeKey)
            }
        }
    }

    private static let activeKey = "rti.modes.activeId"
    private static let seedFlag = "rti.modes.seededV1"

    private init() {
        seedBuiltinsIfNeeded()
        self.activeModeId = UserDefaults.standard.string(forKey: Self.activeKey)
        reload()
    }

    func reload() {
        do {
            modes = try RTIDatabase.shared.pool.read { db in
                try Mode.order(Column("created_at")).fetchAll(db)
            }
        } catch {
            NSLog("[RTI] ModeStore reload failed: \(error)")
        }
    }

    var activeMode: Mode? {
        guard let id = activeModeId else { return nil }
        return modes.first { $0.id == id }
    }

    func update(id: String, name: String, systemPrompt: String, referenceText: String?) {
        do {
            try RTIDatabase.shared.pool.write { db in
                if var m = try Mode.fetchOne(db, key: id) {
                    m.name = name
                    m.systemPrompt = systemPrompt
                    m.referenceText = referenceText?.isEmpty == true ? nil : referenceText
                    try m.update(db)
                }
            }
            reload()
        } catch {
            NSLog("[RTI] ModeStore update failed: \(error)")
        }
    }

    /// Insert a new user-defined mode. Returns the new id, or nil if the
    /// write failed.
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
        do {
            try RTIDatabase.shared.pool.write { db in try m.insert(db) }
            reload()
            return m.id
        } catch {
            NSLog("[RTI] ModeStore add failed: \(error)")
            return nil
        }
    }

    /// Delete a non-builtin mode. Built-in modes are protected to keep the
    /// seed set always available. If the deleted mode was active, fall
    /// back to the meeting builtin.
    func deleteMode(id: String) {
        guard let mode = modes.first(where: { $0.id == id }), !mode.isBuiltin else { return }
        do {
            _ = try RTIDatabase.shared.pool.write { db in
                try Mode.deleteOne(db, key: id)
            }
            if activeModeId == id { activeModeId = "builtin.meeting" }
            reload()
        } catch {
            NSLog("[RTI] ModeStore delete failed: \(error)")
        }
    }

    private func seedBuiltinsIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.seedFlag) { return }

        let now = Date()
        let seeds: [Mode] = [
            Mode(id: "builtin.meeting", name: "Meeting",
                 systemPrompt: "You are RTI assisting in a live meeting. Keep replies to 2-3 short lines. Focus on action items, decisions, and next steps. Use bullets for lists.",
                 isBuiltin: true, createdAt: now, referenceText: nil),
            Mode(id: "builtin.interview", name: "Interview",
                 systemPrompt: "You are RTI helping the user in an interview. Draft tight, confident replies in the user's voice. Prefer concrete examples over generalities. One short paragraph max.",
                 isBuiltin: true, createdAt: now, referenceText: nil),
            Mode(id: "builtin.coding", name: "Coding",
                 systemPrompt: "You are RTI helping with code. Answer with code-first responses. Explain only when asked. Use fenced code blocks with language tags.",
                 isBuiltin: true, createdAt: now, referenceText: nil),
            Mode(id: "builtin.custom", name: "Custom",
                 systemPrompt: "You are RTI, a real-time intelligence assistant. Keep responses short and actionable.",
                 isBuiltin: false, createdAt: now, referenceText: nil),
        ]
        do {
            try RTIDatabase.shared.pool.write { db in
                for m in seeds {
                    if try Mode.fetchOne(db, key: m.id) == nil {
                        try m.insert(db)
                    }
                }
            }
            defaults.set(true, forKey: Self.seedFlag)
            if defaults.string(forKey: Self.activeKey) == nil {
                defaults.set("builtin.meeting", forKey: Self.activeKey)
            }
        } catch {
            NSLog("[RTI] ModeStore seed failed: \(error)")
        }
    }
}
