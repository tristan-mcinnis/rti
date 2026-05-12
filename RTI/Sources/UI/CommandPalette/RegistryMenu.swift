import SwiftUI

/// SwiftUI menu contents built from the shared `CommandRegistry`. Renders
/// every command that has a `menuSection`, grouped in the same order as
/// `MenuSection.allCases`, with dividers between sections.
///
/// Drop this into any `Menu { ... }` or `.contextMenu { ... }` body so the
/// menu stays in lockstep with `MenuCoordinator` (the menubar) — there is
/// no separate hand-coded button list to drift.
///
/// Dynamic extras (Recent Sessions submenu, Modes submenu, Quit) are not
/// registry commands and remain the caller's responsibility to add.
struct RegistryMenuContents: View {
    @ObservedObject private var registry = CommandRegistry.shared

    var body: some View {
        let bySection = Dictionary(grouping: registry.commands) { $0.menuSection }
        let sections = MenuSection.allCases
        ForEach(Array(sections.enumerated()), id: \.element) { idx, section in
            if let group = bySection[section]?.filter({ $0.isAvailable() }), !group.isEmpty {
                ForEach(group) { cmd in
                    if let stateProvider = cmd.menuStateProvider {
                        Toggle(
                            cmd.menuTitleProvider?() ?? cmd.title,
                            isOn: Binding(
                                get: { stateProvider() },
                                set: { _ in
                                    cmd.perform()
                                    CommandRegistry.shared.recordExecution(cmd.id)
                                }
                            )
                        )
                    } else {
                        Button(cmd.menuTitleProvider?() ?? cmd.title) {
                            cmd.perform()
                            CommandRegistry.shared.recordExecution(cmd.id)
                        }
                    }
                }
                if idx < sections.count - 1 {
                    Divider()
                }
            }
        }
    }
}

/// Emit just the registry commands for a single `MenuSection`. Useful when
/// the caller wants to interleave dynamic items (Recent Sessions, Modes)
/// between sections.
struct RegistryMenuSection: View {
    let section: MenuSection
    @ObservedObject private var registry = CommandRegistry.shared

    var body: some View {
        ForEach(registry.commands.filter { $0.menuSection == section && $0.isAvailable() }) { cmd in
            if let stateProvider = cmd.menuStateProvider {
                // Stateful command — render as Toggle so the current
                // state (checkmark) is visible without flipping the
                // title between two actions.
                Toggle(
                    cmd.menuTitleProvider?() ?? cmd.title,
                    isOn: Binding(
                        get: { stateProvider() },
                        set: { _ in
                            cmd.perform()
                            CommandRegistry.shared.recordExecution(cmd.id)
                        }
                    )
                )
            } else {
                Button(cmd.menuTitleProvider?() ?? cmd.title) {
                    cmd.perform()
                    CommandRegistry.shared.recordExecution(cmd.id)
                }
            }
        }
    }
}
