import Foundation
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

    private init() {
        modes = Self.loadFromDisk() ?? Self.builtinSeeds()
        // Refresh built-in prompts in place each launch so prompt edits ship
        // without a migration; user-added modes are untouched.
        upgradeBuiltinPrompts()
        persist()
        let stored = UserDefaults.standard.string(forKey: Self.activeKey)
        self.activeModeId = stored ?? "builtin.meeting"
    }

    var activeMode: Mode? {
        guard let id = activeModeId else { return nil }
        return modes.first { $0.id == id }
    }

    func reload() {
        if let loaded = Self.loadFromDisk() { modes = loaded }
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
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let rti = dir.appendingPathComponent("RTI", isDirectory: true)
        try? FileManager.default.createDirectory(at: rti, withIntermediateDirectories: true)
        return rti.appendingPathComponent("modes.json")
    }

    private static func loadFromDisk() -> [Mode]? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([Mode].self, from: data)
    }

    private func persist() {
        guard let url = Self.fileURL else { return }
        do {
            let data = try JSONEncoder().encode(modes)
            try data.write(to: url, options: .atomic)
        } catch {
            RTILog.log("ModeStore persist failed: \(error)", category: "modes")
        }
    }

    private func upgradeBuiltinPrompts() {
        let upgrades: [String: String] = [
            "builtin.meeting": Self.meetingPrompt,
            "builtin.interview": Self.interviewPrompt,
            "builtin.coding": Self.codingPrompt,
        ]
        // Ensure any newly-shipped builtins exist, then refresh their prompts.
        let existing = Set(modes.map(\.id))
        for seed in Self.builtinSeeds() where !existing.contains(seed.id) {
            modes.append(seed)
        }
        for idx in modes.indices where modes[idx].isBuiltin {
            if let prompt = upgrades[modes[idx].id] {
                modes[idx].systemPrompt = prompt
            }
        }
    }

    private static func builtinSeeds() -> [Mode] {
        let now = Date()
        return [
            Mode(id: "builtin.meeting", name: "Meeting", systemPrompt: meetingPrompt,
                 isBuiltin: true, createdAt: now, referenceText: nil),
            Mode(id: "builtin.interview", name: "Interview", systemPrompt: interviewPrompt,
                 isBuiltin: true, createdAt: now, referenceText: nil),
            Mode(id: "builtin.coding", name: "Coding", systemPrompt: codingPrompt,
                 isBuiltin: true, createdAt: now, referenceText: nil),
            Mode(id: "builtin.custom", name: "Custom", systemPrompt: customPrompt,
                 isBuiltin: false, createdAt: now, referenceText: nil),
        ]
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
