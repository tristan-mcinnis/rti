import Foundation
import RTICore
import Observation

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

    /// Menus and palettes describe the same current action, including toggles.
    var currentTitle: String { menuTitleProvider?() ?? title }

    // MARK: - Menu integration

    /// Which section the menu item appears in. `nil` hides it from the
    /// status-item menu (palette-only commands like say-next / followups).
    let menuSection: MenuSection?
    /// When set, the menu item is nested inside a submenu with this title
    /// (within its section) instead of appearing flat. Commands sharing the
    /// same `menuParent` in the same section collect under one submenu — used
    /// to keep families like "Set ⌘⏎ to: …" and provider switches from
    /// flooding the top-level menu.
    let menuParent: String?
    /// When non-nil, the menu item title is re-evaluated on every menu-open
    /// so commands like "Start / Stop Recording" stay in sync.
    let menuTitleProvider: (() -> String)?
    /// When non-nil, the command is rendered as a stateful toggle in the
    /// SwiftUI menu (with a native checkmark) and as an `.on/.off` menu
    /// item in the NSMenu. Used for ON/OFF commands like Smart Mode and
    /// Hide-from-Screen-Capture where "current state" matters more than
    /// "what clicking will do". `nil` → render as a plain Button/MenuItem.
    let menuStateProvider: (() -> Bool)?

    // MARK: - Hotkey integration

    /// Carbon `kVK_*` key code. `nil` means no global hotkey.
    let hotkeyKeyCode: UInt32?
    /// Carbon modifier mask (`cmdKey`, `shiftKey`, `optionKey`).
    let hotkeyModifiers: UInt32?
    /// When true, the global hotkey is held only while a session is
    /// recording. Outside a session the chord (e.g. ⌘⏎) belongs to
    /// whatever app the user is in — RTI must not steal it all day.
    let hotkeySessionScoped: Bool

    init(
        id: String,
        title: String,
        subtitle: String? = nil,
        keywords: [String] = [],
        isAvailable: @escaping () -> Bool = { true },
        perform: @escaping () -> Void,
        menuSection: MenuSection? = nil,
        menuParent: String? = nil,
        menuTitleProvider: (() -> String)? = nil,
        menuStateProvider: (() -> Bool)? = nil,
        hotkeyKeyCode: UInt32? = nil,
        hotkeyModifiers: UInt32? = nil,
        hotkeySessionScoped: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.isAvailable = isAvailable
        self.perform = perform
        self.menuSection = menuSection
        self.menuParent = menuParent
        self.menuTitleProvider = menuTitleProvider
        self.menuStateProvider = menuStateProvider
        self.hotkeyKeyCode = hotkeyKeyCode
        self.hotkeyModifiers = hotkeyModifiers
        self.hotkeySessionScoped = hotkeySessionScoped
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

@Observable @MainActor
final class CommandRegistry {
    static let shared = CommandRegistry()

    /// All registered commands, in their natural order. Filtered by
    /// `isAvailable` at query time.
    private(set) var commands: [RTICommand] = []

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
    /// order. Non-empty queries fuzzy-match titles and keywords.
    func search(_ query: String) -> [RTICommand] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let available = commands.filter { $0.isAvailable() }
        guard !trimmed.isEmpty else {
            return orderByRecency(available)
        }
        return Self.matching(available, query: trimmed)
    }

    /// Shared by registry commands and a composer's contextual commands.
    static func matching(_ commands: [RTICommand], query: String) -> [RTICommand] {
        let needle = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let available = commands.filter { $0.isAvailable() }
        guard !needle.isEmpty else { return available }
        return available.enumerated().compactMap { index, command -> (RTICommand, Int, Int)? in
            guard let score = matchScore(query: needle, title: command.currentTitle, keywords: command.keywords) else { return nil }
            return (command, score, index)
        }
        .sorted { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 > $1.1 }
        .map(\.0)
    }

    /// One scorer for every command palette, including session actions.
    nonisolated static func matchScore(query: String, title: String, keywords: [String] = []) -> Int? {
        let needle = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return 0 }
        let titleScore = fuzzyScore(needle, candidate: fold(title)).map { $0 + 10_000 }
        let keywordScore = keywords.compactMap { fuzzyScore(needle, candidate: fold($0)) }.max()
        return [titleScore, keywordScore].compactMap { $0 }.max()
    }

    private nonisolated static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private nonisolated static func fuzzyScore(_ query: String, candidate: String) -> Int? {
        if let range = candidate.range(of: query) {
            return (candidate == query ? 2_000 : 1_000) - candidate.distance(from: candidate.startIndex, to: range.lowerBound)
        }
        let needle = Array(query.filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        var next = 0
        var previous: Int?
        var score = 0
        for (index, character) in candidate.enumerated() where next < needle.count {
            guard character == needle[next] else { continue }
            score += 10 - min(index, 12)
            if previous == index - 1 { score += 5 }
            previous = index
            next += 1
        }
        return next == needle.count ? score - candidate.count : nil
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
        UserDefaults.standard.set(recents, forKey: UISettingsDefaults.paletteRecentsKey)
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
        UserDefaults.standard.array(forKey: UISettingsDefaults.paletteRecentsKey) as? [String] ?? []
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
