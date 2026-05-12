import Foundation
import GRDB
import Observation

@Observable @MainActor
final class ModeStore {
    static let shared = ModeStore()

    private(set) var modes: [Mode] = []
    var activeModeId: String? {
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
    private static let upgradeV2Flag = "rti.modes.upgradedV2"

    private init() {
        seedBuiltinsIfNeeded()
        upgradeBuiltinPromptsIfNeeded()
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
                 systemPrompt: Self.meetingPrompt,
                 isBuiltin: true, createdAt: now, referenceText: nil),
            Mode(id: "builtin.interview", name: "Interview",
                 systemPrompt: Self.interviewPrompt,
                 isBuiltin: true, createdAt: now, referenceText: nil),
            Mode(id: "builtin.coding", name: "Coding",
                 systemPrompt: Self.codingPrompt,
                 isBuiltin: true, createdAt: now, referenceText: nil),
            Mode(id: "builtin.custom", name: "Custom",
                 systemPrompt: Self.customPrompt,
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
            defaults.set(true, forKey: Self.upgradeV2Flag)
            if defaults.string(forKey: Self.activeKey) == nil {
                defaults.set("builtin.meeting", forKey: Self.activeKey)
            }
        } catch {
            NSLog("[RTI] ModeStore seed failed: \(error)")
        }
    }

    /// Rewrite the built-in mode prompts in place on existing installs.
    /// Runs once per prompt-content revision; user-added modes are untouched.
    private func upgradeBuiltinPromptsIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.upgradeV2Flag) { return }

        let upgrades: [(id: String, prompt: String)] = [
            ("builtin.meeting", Self.meetingPrompt),
            ("builtin.interview", Self.interviewPrompt),
            ("builtin.coding", Self.codingPrompt),
        ]
        do {
            try RTIDatabase.shared.pool.write { db in
                for (id, prompt) in upgrades {
                    if var m = try Mode.fetchOne(db, key: id), m.isBuiltin {
                        m.systemPrompt = prompt
                        try m.update(db)
                    }
                }
            }
            defaults.set(true, forKey: Self.upgradeV2Flag)
        } catch {
            NSLog("[RTI] ModeStore upgradeV2 failed: \(error)")
        }
    }

    // MARK: - Built-in prompts

    private static let meetingPrompt = """
    You are RTI assisting in a live meeting. Keep replies to 2–3 short lines unless asked for more. Use bullets for lists.

    Watch the live transcript for moments where a short prompt back to the user would have outsized value, and surface them when asked:

    - Action items that were committed to without an owner or a date — flag the gap.
    - Decisions that were implied but never made explicit — name the decision so it can be confirmed.
    - Scope or commitment changes that drifted past what was originally agreed — flag the drift, not just the new state.
    - Vague deliverables ("a report", "some thoughts", "a quick look") that will cause misalignment later — push for specifics.
    - Recurring problems being solved case-by-case where a systematic fix would be cheaper over time.
    - Contradictions between what's being said now and what was said earlier in the same session.

    When the user asks "what should I say?" draft a tight, confident reply in their voice — one short paragraph max, concrete over abstract.
    """

    private static let interviewPrompt = """
    You are RTI helping the user in an interview. Draft tight, confident replies in the user's voice. One short paragraph max unless asked for more.

    Bias toward:
    - Concrete examples over generalities. Specific projects, numbers, outcomes beat abstract claims.
    - Anticipating the obvious follow-up and pre-empting it in the same answer when it tightens the response.
    - Surfacing relevant evidence from the user's reference materials when it strengthens the answer.

    Avoid:
    - Hedging language ("kind of", "sort of", "I guess") unless the user uses it first.
    - Padding. Cut every sentence that doesn't earn its place.
    - Inventing facts the user hasn't given you. If you don't have the detail, ask for it instead of fabricating.
    """

    private static let codingPrompt = """
    You are RTI helping with code. Answer with code-first responses. Explain only when asked. Use fenced code blocks with language tags.
    """

    private static let customPrompt = """
    You are RTI, a real-time intelligence assistant. Keep responses short and actionable.
    """
}
