import Foundation
import Combine

/// One entry in the command palette / menubar / hotkey system. The single
/// source of truth for "what can the user do right now." Menu items and
/// global hotkeys are derived from this same registry — adding a command
/// here registers it everywhere.
struct RTICommand: Identifiable {
    /// Stable id used for recents persistence. Format: `<group>.<verb>`.
    let id: String
    /// Human-readable title shown in the palette, menu, and shortcuts UI.
    let title: String
    /// Optional shortcut hint shown right-aligned in the palette row
    /// (e.g. "⌘⇧R"). Purely informational — no key binding here.
    let subtitle: String?
    /// Free-form match terms in addition to `title`. Lowercased on match.
    let keywords: [String]
    /// Re-evaluated on every keystroke. Returning `false` hides the command
    /// from results and from recents. Default: always available.
    let isAvailable: () -> Bool
    /// Fired on Enter / menu click / hotkey press. Runs on the main actor.
    let perform: () -> Void

    // MARK: - Menu integration

    /// Which section the menu item appears in. `nil` hides it from the
    /// status-item menu (palette-only commands like say-next / followups).
    let menuSection: MenuSection?
    /// When non-nil, the menu item title is re-evaluated on every menu-open
    /// so commands like "Start / Stop Recording" stay in sync.
    let menuTitleProvider: (() -> String)?

    // MARK: - Hotkey integration

    /// Carbon `kVK_*` key code. `nil` means no global hotkey.
    let hotkeyKeyCode: UInt32?
    /// Carbon modifier mask (`cmdKey`, `shiftKey`, `optionKey`).
    let hotkeyModifiers: UInt32?

    init(
        id: String,
        title: String,
        subtitle: String? = nil,
        keywords: [String] = [],
        isAvailable: @escaping () -> Bool = { true },
        perform: @escaping () -> Void,
        menuSection: MenuSection? = nil,
        menuTitleProvider: (() -> String)? = nil,
        hotkeyKeyCode: UInt32? = nil,
        hotkeyModifiers: UInt32? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.isAvailable = isAvailable
        self.perform = perform
        self.menuSection = menuSection
        self.menuTitleProvider = menuTitleProvider
        self.hotkeyKeyCode = hotkeyKeyCode
        self.hotkeyModifiers = hotkeyModifiers
    }
}

/// Sections in the status-item menu, in display order. Commands are
/// grouped by section; sections with no commands are skipped.
enum MenuSection: String, CaseIterable {
    case session
    case navigation
    case actions
    case panels
    case app
}

@MainActor
final class CommandRegistry: ObservableObject {
    static let shared = CommandRegistry()

    /// All registered commands, in their natural order. Filtered by
    /// `isAvailable` at query time.
    private(set) var commands: [RTICommand] = []

    nonisolated private static let recentsKey = "rti.palette.recents"
    nonisolated private static let recentsCap = 5

    private init() {}

    func register(_ commands: [RTICommand]) {
        self.commands.append(contentsOf: commands)
    }

    /// Replace all registered commands. Used when the dynamic mode list
    /// changes (ModeStore re-emits) and we need to rebuild "Switch to <Mode>"
    /// rows.
    func replaceAll(_ commands: [RTICommand]) {
        self.commands = commands
    }

    /// Search the available command set. Empty query returns recents first
    /// (filtered by availability), then everything else in registration
    /// order. Non-empty query returns case-insensitive substring matches on
    /// title or keywords, sorted by match position then registration order.
    func search(_ query: String) -> [RTICommand] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let available = commands.filter { $0.isAvailable() }
        guard !trimmed.isEmpty else {
            return orderByRecency(available)
        }
        let needle = trimmed.lowercased()
        let scored: [(RTICommand, Int)] = available.compactMap { cmd in
            if let pos = matchPosition(cmd, needle: needle) {
                return (cmd, pos)
            }
            return nil
        }
        return scored
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// Push `id` to the front of the persisted recents list. Called when a
    /// command executes successfully.
    func recordExecution(_ id: String) {
        var recents = persistedRecents()
        recents.removeAll { $0 == id }
        recents.insert(id, at: 0)
        if recents.count > Self.recentsCap {
            recents = Array(recents.prefix(Self.recentsCap))
        }
        UserDefaults.standard.set(recents, forKey: Self.recentsKey)
    }

    /// Available commands ordered by recency. Internal helper exposed for
    /// tests; production code uses `search("")`.
    func recents(limit: Int = recentsCap) -> [RTICommand] {
        let ids = persistedRecents()
        let byId = Dictionary(uniqueKeysWithValues: commands.map { ($0.id, $0) })
        return ids.prefix(limit).compactMap { byId[$0] }.filter { $0.isAvailable() }
    }

    // MARK: - private

    private func persistedRecents() -> [String] {
        UserDefaults.standard.array(forKey: Self.recentsKey) as? [String] ?? []
    }

    private func matchPosition(_ cmd: RTICommand, needle: String) -> Int? {
        let title = cmd.title.lowercased()
        if let r = title.range(of: needle) {
            return title.distance(from: title.startIndex, to: r.lowerBound)
        }
        for kw in cmd.keywords {
            if kw.lowercased().contains(needle) {
                // Keyword matches rank below title matches by adding a large
                // base offset.
                return 1_000
            }
        }
        return nil
    }

    private func orderByRecency(_ available: [RTICommand]) -> [RTICommand] {
        let recentIds = persistedRecents()
        guard !recentIds.isEmpty else { return available }
        let recentSet = Set(recentIds)
        let recentInOrder: [RTICommand] = recentIds.compactMap { id in
            available.first(where: { $0.id == id })
        }
        let rest = available.filter { !recentSet.contains($0.id) }
        return recentInOrder + rest
    }
}
