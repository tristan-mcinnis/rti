import Foundation

/// A global hotkey for an assistant action, expressed semantically (a letter +
/// modifier flags) so the catalogue stays free of Carbon/AppKit. The app layer
/// translates `key` into a virtual key code at registration time; `display`
/// renders the menu hint (e.g. "⌘⌥R").
public struct ActionHotkey: Sendable, Equatable {
    public struct Modifiers: OptionSet, Sendable, Equatable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
    }

    /// Single uppercase letter, e.g. "R". The app maps this to a `kVK_ANSI_*`.
    public let key: String
    public let modifiers: Modifiers

    public init(key: String, modifiers: Modifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Menu hint string, modifiers in the conventional order, e.g. "⌘⌥R".
    public var display: String {
        var s = ""
        if modifiers.contains(.command) { s += "⌘" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        return s + key
    }
}

/// The single source of truth for an assistant action (Assist, Recap, Say next,
/// the listener-research actions, …). Previously the same action was described
/// four times over — a `PrimaryAction` enum case, a `QuickAction` entry, an
/// `RTICommand`, and a `hotkeyHints` string — so adding one action meant editing
/// four registries and the labels drifted apart. Here it is described once; the
/// ✦ menu, command palette, global hotkeys, and ⌘⏎ remap all project from it.
///
/// Pure data: the dispatch (which `LLMController.send…` to call) lives app-side,
/// keyed by `id`, because that is @MainActor behaviour, not data.
public struct AssistantAction: Identifiable, Sendable {
    /// Stable identifier; also the persisted value for the ⌘⏎ binding and the
    /// key the app's dispatch switches on. Unprefixed (e.g. "recap").
    public let id: String
    /// Canonical label — the ✦-menu chip and the "⌘⏎ runs:" submenu.
    public let label: String
    /// Command-palette title (often richer than `label`, e.g. with a hint).
    public let paletteTitle: String
    /// SF Symbol for the ✦ menu.
    public let symbol: String
    /// Command-palette search terms.
    public let keywords: [String]
    /// Optional global hotkey.
    public let hotkey: ActionHotkey?
    /// Whether this action may be bound to ⌘⏎ (and appears in the remap submenu).
    public let primaryEligible: Bool
    /// Visibility gate by listener state: nil = always, true = listener-only,
    /// false = speaker-only (hidden when observing).
    public let listenerOnly: Bool?
    /// Visibility gate by mode family; nil = all modes.
    public let modes: Set<ModeKind>?

    public init(
        id: String,
        label: String,
        paletteTitle: String,
        symbol: String,
        keywords: [String],
        hotkey: ActionHotkey? = nil,
        primaryEligible: Bool = true,
        listenerOnly: Bool? = nil,
        modes: Set<ModeKind>? = nil
    ) {
        self.id = id
        self.label = label
        self.paletteTitle = paletteTitle
        self.symbol = symbol
        self.keywords = keywords
        self.hotkey = hotkey
        self.primaryEligible = primaryEligible
        self.listenerOnly = listenerOnly
        self.modes = modes
    }
}

public extension AssistantAction {
    private static let cmdOpt: ActionHotkey.Modifiers = [.command, .option]

    /// The catalogue, in ✦-menu display order. Every surface derives from this.
    static let all: [AssistantAction] = [
        AssistantAction(
            id: "assist", label: "Assist",
            paletteTitle: "Assist (suggest what to say)",
            symbol: "sparkles", keywords: ["help", "suggestion"]
        ),
        AssistantAction(
            id: "sayNext", label: "Say next",
            paletteTitle: "Say Next (one-line draft reply)",
            symbol: "wand.and.rays", keywords: ["respond", "reply"],
            hotkey: ActionHotkey(key: "S", modifiers: cmdOpt),
            listenerOnly: false
        ),
        AssistantAction(
            id: "followups", label: "Follow-ups",
            paletteTitle: "Follow-up Questions",
            symbol: "bubble.left.and.text.bubble.right", keywords: ["questions", "ask"],
            hotkey: ActionHotkey(key: "F", modifiers: cmdOpt)
        ),
        AssistantAction(
            id: "keyTensions", label: "Key tensions",
            paletteTitle: "Key Tensions",
            symbol: "bolt.horizontal",
            keywords: ["tension", "disagree", "split", "observe", "listener"],
            hotkey: ActionHotkey(key: "T", modifiers: cmdOpt),
            listenerOnly: true, modes: [.interview, .meeting, .other]
        ),
        AssistantAction(
            id: "probe", label: "What's unsaid / probe",
            paletteTitle: "What's Unsaid / Probe",
            symbol: "magnifyingglass",
            keywords: ["probe", "unsaid", "explore", "deepen", "listener"],
            hotkey: ActionHotkey(key: "U", modifiers: cmdOpt),
            listenerOnly: true, modes: [.interview, .meeting, .other]
        ),
        AssistantAction(
            id: "themes", label: "Emerging themes",
            paletteTitle: "Emerging Themes",
            symbol: "square.stack.3d.up",
            keywords: ["theme", "pattern", "synthesis", "listener"],
            hotkey: ActionHotkey(key: "E", modifiers: cmdOpt),
            listenerOnly: true, modes: [.interview, .meeting, .other]
        ),
        AssistantAction(
            id: "recap", label: "Recap",
            paletteTitle: "Recap so far",
            symbol: "arrow.clockwise",
            keywords: ["summary", "review", "depth", "length"],
            hotkey: ActionHotkey(key: "R", modifiers: cmdOpt)
        ),
        AssistantAction(
            id: "summary", label: "Session summary",
            paletteTitle: "Meeting Summary (full transcript)",
            symbol: "doc.text",
            keywords: ["granola", "summarize", "minutes", "wrap"],
            hotkey: ActionHotkey(key: "M", modifiers: cmdOpt)
        ),
    ]

    /// Look up an action by id.
    static func byID(_ id: String) -> AssistantAction? {
        all.first { $0.id == id }
    }

    /// Actions eligible to be bound to ⌘⏎, in catalogue order.
    static var primaryEligibleActions: [AssistantAction] {
        all.filter(\.primaryEligible)
    }
}
