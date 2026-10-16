import Foundation

/// The three shipped saved-meeting output recipes.
///
/// Each maps to one `PromptID`, so the shipped wording is editable in Settings
/// like every other RTI prompt and its content hash is a stable template
/// version for provenance. The raw value is the filename-safe recipe id.
public enum BuiltInOutputRecipe: String, CaseIterable, Sendable {
    case clientFollowUp = "client-follow-up"
    case decisionLog = "decision-log"
    case researchDebrief = "research-debrief"

    public var id: String { rawValue }

    public var promptID: PromptID {
        switch self {
        case .clientFollowUp: .clientFollowUp
        case .decisionLog: .decisionLog
        case .researchDebrief: .researchDebrief
        }
    }

    public var name: String { promptID.title }

    public var defaultInstruction: String { promptID.defaultText }
}

/// A user-saved output template. Stored (as JSON) by the app-side
/// `OutputTemplateStore`, owned by the same UserDefaults config surface as
/// every other RTI prompt. Pure value type.
public struct CustomOutputTemplate: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var instruction: String

    public init(id: String, name: String, instruction: String) {
        self.id = id
        self.name = name
        self.instruction = instruction
    }
}

/// One reusable, purpose-specific output over a saved transcript.
///
/// Pure value type: no I/O, no UserDefaults, no MainActor. The `instruction`
/// is the resolved text actually sent (a `PromptStore` override for a built-in,
/// or the custom template's own text); `templateHash` is the hash of that text
/// and travels in the artifact's provenance so a reader can tell which wording
/// produced an output.
public struct SessionOutputRecipe: Identifiable, Equatable, Sendable {
    public enum Origin: Equatable, Sendable {
        case builtIn(BuiltInOutputRecipe)
        case custom
    }

    public let id: String
    public let name: String
    public let instruction: String
    public let origin: Origin

    public init(id: String, name: String, instruction: String, origin: Origin) {
        self.id = id
        self.name = name
        self.instruction = instruction
        self.origin = origin
    }

    public var isBuiltIn: Bool {
        if case .builtIn = origin { return true }
        return false
    }

    /// The `PromptID` backing a built-in recipe, nil for a custom template.
    public var promptID: PromptID? {
        if case let .builtIn(builtIn) = origin { return builtIn.promptID }
        return nil
    }

    /// Stable, content-derived template version (FNV-1a of the instruction).
    public var templateHash: String { PromptDefaults.fnv1a(instruction) }

    /// Build a built-in recipe with its instruction resolved by the caller
    /// (app: `PromptStore.shared.text(_:)`, so Settings edits apply).
    public static func builtIn(
        _ builtIn: BuiltInOutputRecipe,
        resolve: (PromptID) -> String = { $0.defaultText }
    ) -> SessionOutputRecipe {
        SessionOutputRecipe(
            id: builtIn.id,
            name: builtIn.name,
            instruction: resolve(builtIn.promptID),
            origin: .builtIn(builtIn)
        )
    }

    public static func custom(_ template: CustomOutputTemplate) -> SessionOutputRecipe {
        SessionOutputRecipe(
            id: template.id,
            name: template.name,
            instruction: template.instruction,
            origin: .custom
        )
    }

    /// The shipped recipes in picker order, then the user's custom templates.
    /// A custom template may not shadow a built-in id.
    public static func catalog(
        builtInResolve: (PromptID) -> String,
        custom: [CustomOutputTemplate]
    ) -> [SessionOutputRecipe] {
        let shipped = BuiltInOutputRecipe.allCases.map { builtIn($0, resolve: builtInResolve) }
        let shippedIDs = Set(shipped.map(\.id))
        let customRecipes = custom
            .filter { !shippedIDs.contains($0.id) }
            .map(SessionOutputRecipe.custom)
        return shipped + customRecipes
    }
}

/// Filename-safe recipe ids. Generated output files are named from the id, so
/// the id is validated before it can ever reach a path.
public enum SessionOutputID {
    public static let maxLength = 64

    /// Lowercase letters, digits and single interior hyphens; no leading or
    /// trailing hyphen. Keeps the id safe as one path component.
    public static func isValid(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= maxLength else { return false }
        var previousWasHyphen = true // rejects a leading hyphen
        for character in id {
            if character == "-" {
                if previousWasHyphen { return false }
                previousWasHyphen = true
            } else if character.isASCII && (character.isLowercase || character.isNumber) {
                previousWasHyphen = false
            } else {
                return false
            }
        }
        return !previousWasHyphen // rejects a trailing hyphen
    }

    /// A best-effort slug from a human name: lowercase ASCII words joined by
    /// hyphens. Never empty (falls back to "output").
    public static func slug(from name: String) -> String {
        var out = ""
        var pendingHyphen = false
        for scalar in name.lowercased().unicodeScalars {
            let isWord = (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57)
            if isWord {
                if pendingHyphen, !out.isEmpty { out.append("-") }
                pendingHyphen = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingHyphen = true
            }
        }
        if out.isEmpty { return "output" }
        if out.count > maxLength { out = String(out.prefix(maxLength)) }
        return isValid(out) ? out : "output"
    }

    /// A slug that does not collide with any existing recipe id.
    public static func uniqueSlug(from name: String, existing: Set<String>) -> String {
        let base = slug(from: name)
        guard existing.contains(base) else { return base }
        var index = 2
        while existing.contains("\(base)-\(index)") { index += 1 }
        return "\(base)-\(index)"
    }
}
