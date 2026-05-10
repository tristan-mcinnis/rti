import Foundation

enum EntityType: String, Codable, CaseIterable {
    case person
    case brand
    case organization
    case concept

    var displayName: String {
        switch self {
        case .person: return "Person"
        case .brand: return "Brand"
        case .organization: return "Organization"
        case .concept: return "Concept"
        }
    }

    var icon: String {
        switch self {
        case .person: return "person.fill"
        case .brand: return "tag.fill"
        case .organization: return "building.2.fill"
        case .concept: return "lightbulb.fill"
        }
    }
}

struct EntityDossier: Identifiable, Equatable {
    let id: UUID
    let name: String
    let type: EntityType
    let description: String
    var mentions: Int
    let firstMentionedMs: Int

    var normalizedName: String {
        name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
