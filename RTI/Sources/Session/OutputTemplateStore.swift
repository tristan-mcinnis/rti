import Foundation
import Observation
import RTICore

/// User-saved output templates: the "custom template" half of the saved-meeting
/// output recipes.
///
/// The three shipped recipes are `PromptID`s (editable in Settings); a user
/// template has no shipped default to override, so it is stored here as JSON in
/// the same UserDefaults config surface every other RTI prompt uses. This is
/// not a second index: it holds only the user's own template text, and the
/// generated outputs themselves live in the session archive.
@Observable @MainActor
final class OutputTemplateStore {
    static let shared = OutputTemplateStore()

    static let defaultsKey = "rti.outputs.customTemplates"

    private var templates: [CustomOutputTemplate]

    private init() {
        templates = Self.load()
    }

    var all: [CustomOutputTemplate] { templates }

    /// Every recipe id in use (built-ins plus customs), for collision-free slugs.
    var reservedIDs: Set<String> {
        Set(BuiltInOutputRecipe.allCases.map(\.id) + templates.map(\.id))
    }

    func template(id: String) -> CustomOutputTemplate? {
        templates.first { $0.id == id }
    }

    /// Save a new template, or update one when `existingID` matches. Returns nil
    /// when the name or instruction is blank.
    @discardableResult
    func save(name: String, instruction: String, existingID: String? = nil) -> CustomOutputTemplate? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedInstruction.isEmpty else { return nil }

        if let existingID, let index = templates.firstIndex(where: { $0.id == existingID }) {
            templates[index].name = trimmedName
            templates[index].instruction = trimmedInstruction
            persist()
            return templates[index]
        }

        var reserved = reservedIDs
        let id = SessionOutputID.uniqueSlug(from: trimmedName, existing: reserved)
        reserved.insert(id)
        let template = CustomOutputTemplate(id: id, name: trimmedName, instruction: trimmedInstruction)
        templates.append(template)
        persist()
        return template
    }

    func delete(id: String) {
        guard templates.contains(where: { $0.id == id }) else { return }
        templates.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(templates) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private static func load() -> [CustomOutputTemplate] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([CustomOutputTemplate].self, from: data)
        else { return [] }
        return decoded.filter { SessionOutputID.isValid($0.id) && !$0.instruction.isEmpty && !$0.name.isEmpty }
    }
}
