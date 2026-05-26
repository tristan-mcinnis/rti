import Foundation

/// One row in the command palette. Ephemeral build: there's no session
/// library to search, so a palette row is always an action (`RTICommand`).
enum PaletteResult: Identifiable {
    case command(RTICommand)

    var id: String {
        switch self {
        case .command(let c): return "cmd:\(c.id)"
        }
    }

    var isCommand: Bool { true }
}

/// Pure composer for the command palette list. Held separate from the view so
/// the ordering rules are unit-testable without spinning up SwiftUI.
enum PaletteSearch {
    /// Compose results from the (already-filtered) command list, preserving
    /// the order the caller passed them in.
    static func compose(commands: [RTICommand]) -> [PaletteResult] {
        commands.map(PaletteResult.command)
    }
}
