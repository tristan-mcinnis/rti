import AppKit
import RTICore
import SwiftUI
import UniformTypeIdentifiers

// The overlay's composer: the house composer row (`HouseComposer`), its
// attachment strip, and the layers that float over it (`@` vault files,
// `/` commands, Add Context, the `⌘K` palette). This file is the adapter:
// it reads `LLMController`, `SessionCoordinator`, and `OverlayInputState`,
// works out the composer's words through `ComposerState`, routes keys
// through `ComposerKeyRouter`, and hands plain values to the views.
//
// Kept from before: the multi-line NSTextView field, `↩` sends and `⇧↩`
// adds a line, the draft clears when a session stops, the Sessions window
// seeds an @mention (`rtiSeedChatMention`), the mention cache and prewarm,
// the 512 KB and 24,000-character document limits, and no document is ever
// copied into the vault.

@MainActor
private final class MentionSuggestionStore: ObservableObject {
    @Published var candidates: [String] = []
    /// The first search after `@` has not answered yet; the chooser draws its
    /// waiting row instead of showing nothing.
    @Published private(set) var isSearching = false

    private var task: Task<Void, Never>?
    private var activeQuery: String?
    private var activeScope: String?
    private var cachedResults: [String: [String]] = [:]
    private var cachedResultKeys: [String] = []

    func update(query: String?, scopeRelativePath: String?) {
        let normalizedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedScope = scopeRelativePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedQuery != activeQuery || normalizedScope != activeScope else { return }

        activeQuery = normalizedQuery
        activeScope = normalizedScope
        task?.cancel()

        guard let normalizedQuery else {
            candidates = []
            isSearching = false
            return
        }

        let cacheKey = Self.cacheKey(query: normalizedQuery, scope: normalizedScope)
        if let cached = cachedResults[cacheKey] {
            candidates = cached
            isSearching = false
        } else {
            // The list is a fresh lookup: say so until it answers.
            isSearching = true
        }

        task = Task { [normalizedQuery, normalizedScope] in
            // `@` alone is the moment the chooser opens, so the first lookup
            // runs at once; only a typed query waits out the keystroke burst.
            if !normalizedQuery.isEmpty {
                try? await Task.sleep(nanoseconds: 35_000_000)
                guard !Task.isCancelled else { return }
            }
            let results = await Task.detached(priority: .userInitiated) {
                VaultFiles.mentionCandidates(normalizedQuery, scopeRelativePath: normalizedScope, limit: 6)
            }.value
            guard !Task.isCancelled else { return }
            candidates = results
            isSearching = false
            remember(results, for: cacheKey)
        }
    }

    func prewarm() {
        Task.detached(priority: .utility) {
            VaultFiles.prewarmMentionIndex()
        }
    }

    private func remember(_ results: [String], for key: String) {
        if cachedResults[key] == nil {
            cachedResultKeys.append(key)
            if cachedResultKeys.count > 40 {
                let stale = cachedResultKeys.removeFirst()
                cachedResults.removeValue(forKey: stale)
            }
        }
        cachedResults[key] = results
    }

    private static func cacheKey(query: String, scope: String?) -> String {
        "\(scope ?? "*")\n\(query)"
    }

    deinit {
        task?.cancel()
    }
}

// MARK: - Documents in the strip

/// One document chosen for the next question: reading, read, or failed.
struct ComposerDocument: Identifiable, Equatable {
    enum Phase: Equatable {
        case reading
        case ready(ExternalDocumentAttachment)
        case failed(String)
    }

    let id: UUID
    let name: String
    let sourceURL: URL?
    var phase: Phase

    init(id: UUID = UUID(), name: String, phase: Phase, sourceURL: URL? = nil) {
        self.id = id
        self.name = name
        self.phase = phase
        self.sourceURL = sourceURL?.standardizedFileURL
    }

    var attachment: ExternalDocumentAttachment? {
        if case .ready(let attachment) = phase { return attachment }
        return nil
    }

    var isReading: Bool { phase == .reading }

    func isSameSource(as url: URL) -> Bool {
        sourceURL == url.standardizedFileURL
    }

    var chip: AttachmentChipModel {
        switch phase {
        case .ready(let attachment):
            return AttachmentChipModel(ref: attachment.ref, id: id.uuidString)
        case .reading:
            return AttachmentChipModel(id: id.uuidString, kind: Self.chipKind(forName: name), name: name, phase: .reading)
        case .failed(let reason):
            return AttachmentChipModel(id: id.uuidString, kind: Self.chipKind(forName: name), name: name, phase: .failed(reason))
        }
    }

    /// A reading or failed chip still names the right kind: an image file is
    /// not a text file, even before its bytes are read.
    private static func chipKind(forName name: String) -> ChatAttachmentRef.Kind {
        let lower = name.lowercased()
        if lower.hasSuffix(".pdf") { return .pdf }
        if [".png", ".jpg", ".jpeg", ".heic", ".gif", ".tiff", ".webp"].contains(where: { lower.hasSuffix($0) }) {
            return .image
        }
        return .text
    }
}

/// Render-proof seam: a composer state set up front, so a proof can draw a
/// state the live controllers cannot be put in (a stream, an open layer).
/// Nil in the app.
struct ComposerRenderSeed {
    enum Layer {
        case none, addContext, searchScope, palette
    }

    var draft = ""
    /// Overrides `LLMController.streaming`.
    var isStreaming: Bool?
    var isQueued = false
    var layer: Layer = .none
    /// Stands in for the vault's mention search.
    var mentionCandidates: [String]?
    /// The rows the `@` chooser draws, when a proof needs RTI's project,
    /// meeting and file rows without a vault read.
    var mentionRows: [AddContextRow]?
    /// Stands in for `LLMController.pendingScreenImage`, so a proof can draw
    /// the image route.
    var pendingImage: Bool?
    /// Stands in for the store's own answer: false is "no vault configured".
    var savesToVault: Bool?
    /// Stands in for `LLMController.broaderSearchEnabled`.
    var isBroaderSearch: Bool?
    /// Stands in for `LLMController.retainedSourceNotice`, so a proof can draw
    /// the state without a vault write.
    var retainedNotice: String?
    /// Stands in for `LLMController.retrievalDiagnostic`.
    var retrievalNotice: String?
    /// Stands in for the resolved route, so a proof does not depend on the
    /// machine's credential store.
    var route: ComposerRoutePreview?
    /// Stands in for `LLMController.pendingDatedSourceName`: a dated log handed
    /// over from the Chats library, which grounds the next turn.
    var pendingDatedSourceName: String?
    var mentionPaths: [String] = []
    var documents: [ComposerDocument] = []
    var isDropTargeted = false
    var focusedChipID: String?
    var chooserIndex = 0
}

// MARK: - The shared context space

/// One row of the searchable context space `@` and `+` share: the row a
/// chooser draws, plus the vault path a mention carries and any extra words
/// the search should match.
private struct ComposerContextRow: Equatable {
    let row: AddContextRow
    var path: String?
    var keywords: [String] = []
}

/// The `@` chooser: the same rows the `+` pane searches — RTI's projects and
/// clients, the recent meetings, the vault files the mention index matched,
/// and the composer's own actions — filtered by the words typed after the
/// `@`. The vault search is a separate lookup from the typed words, so with
/// no answer yet the chooser says it is looking instead of drawing nothing.
private struct ContextChooserPane: View {
    let rows: [ComposerContextRow]
    let selectedIndex: Int
    var isSearching = false
    let onPick: (ComposerContextRow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            ChooserHeader(title: "Add Context", hints: [
                ("Move", ["↑", "↓"]), ("Add", ["↩"]), ("Close", ["esc"]),
            ])
            if rows.isEmpty {
                ChooserList(items: [0], selectedIndex: -1, rowHeight: House.Control.railRow) { _, _ in
                    ChooserRow(
                        symbol: "magnifyingglass",
                        title: isSearching ? "Searching the vault…" : "No match",
                        detail: isSearching
                            ? "Projects, meetings and files as you type"
                            : "Keep typing to narrow it",
                        height: House.Control.railRow
                    ) {}
                }
            } else {
                ChooserList(items: rows, selectedIndex: selectedIndex, rowHeight: House.Control.railRow) { index, row in
                    ChooserRow(
                        symbol: row.row.symbol,
                        title: row.row.title,
                        detail: row.row.detail,
                        isSelected: index == selectedIndex,
                        height: House.Control.railRow
                    ) { onPick(row) } trailing: {
                        if row.row.isCurrent {
                            Image(systemName: "checkmark")
                                .font(House.TypeToken.meta)
                                .foregroundStyle(House.ColorToken.textPrimary)
                                .accessibilityLabel("Current")
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Add Context")
    }
}

// MARK: - Source and route bar

/// The two choices the next Send is made of, drawn above the field
/// (design-system components.json, composer: "source-only versus broader
/// retrieval and the effective image destination remain visible before
/// Send"). Both controls are live: the source choice writes
/// `LLMController.broaderSearchEnabled`, and the route reads the same values
/// the turn freezes with and opens the per-chat model chooser the header uses.
///
/// Internal, not file-private, so the render proofs can measure the row they
/// must leave room for.
struct ComposerSourceRouteBar: View {
    /// `Control.chip` plus the inset above it: what the floating layers must
    /// leave room for, on top of the composer row's own height.
    static let height = House.Control.chip + House.Spacing.xs

    let isBroaderSearch: Bool
    let onSelectSourceMode: (Bool) -> Void
    let savedLabel: String
    let savedHelp: String
    let route: ComposerRoutePreview
    let onChangeRoute: () -> Void

    var body: some View {
        HStack(spacing: House.Spacing.xs) {
            sourceModeChip("Attached sources", symbol: "paperclip", isBroader: false)
            sourceModeChip("Broader search", symbol: "globe", isBroader: true)
            routeButton
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(savedLabel)
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textTertiary)
                .lineLimit(1)
                .fixedSize()
                .help(savedHelp)
                .accessibilityLabel("Save state")
                .accessibilityValue(savedHelp)
        }
        .padding(.horizontal, House.Spacing.xs + House.Spacing.xxs)
        .frame(height: Self.height)
    }

    /// One half of the source choice. `emphasised` marks the selected one the
    /// way the project picker marks the current project, and the mark is never
    /// colour alone: the selected chip also carries a checkmark, at a fixed
    /// width so the row does not shift when the choice changes.
    private func sourceModeChip(_ title: String, symbol: String, isBroader: Bool) -> some View {
        let isSelected = isBroader == isBroaderSearch
        return Button {
            onSelectSourceMode(isBroader)
        } label: {
            SlateChip(stroked: true, emphasised: isSelected) {
                Image(systemName: symbol)
                    .font(House.TypeToken.meta)
                Text(title)
                    .lineLimit(1)
                Image(systemName: "checkmark")
                    .font(House.TypeToken.meta)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityHint(sourceModeHint(isBroader: isBroader))
        .help(sourceModeHint(isBroader: isBroader))
    }

    private func sourceModeHint(isBroader: Bool) -> String {
        isBroader
            ? "Broader search: the vault, the web and earlier turns"
            : "Attached sources only: no vault search, no web"
    }

    /// The chosen route in words, or the short reason it cannot run. The full
    /// reason, with its fix, is the composer's own error line.
    private var routeButton: some View {
        Button(action: onChangeRoute) {
            HStack(spacing: House.Spacing.xxs) {
                if route.isBlocked {
                    Image(systemName: "exclamationmark.triangle")
                        .font(House.TypeToken.meta)
                }
                Text(route.barLabel)
                    .font(House.TypeToken.meta)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(route.isBlocked ? House.ColorToken.danger : House.ColorToken.textTertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Route for this question")
        .accessibilityValue(route.isBlocked ? (route.blockerMessage ?? route.barLabel) : route.label)
        .accessibilityHint("Change the model and reasoning for this chat")
        .help(routeHelp)
    }

    private var routeHelp: String {
        if let blocker = route.blockerMessage { return blocker }
        let fallback = route.usesVisionFallback ? " on a labelled vision fallback" : ""
        return "\(route.label)\(fallback). Change the model and reasoning for this chat"
    }
}

/// How tall the composer may grow in a short window.
///
/// The house lets the field grow to eight lines. The source and route bar adds
/// a row above it, and the floating palette is drawn over the thread above the
/// composer, so at the window's minimum height eight lines plus the bar would
/// push the palette's own search row off the top of the panel. In a short
/// window the field therefore gives back as many lines as the bar costs, and
/// never fewer than one. In a normal window nothing changes.
///
/// Internal, not file-private, so the render proofs measure the same budget the
/// composer uses.
enum ComposerFieldBudget {
    /// The field's own line limit here: the house's eight whenever there is
    /// room, fewer when there is not. `extraChrome` is any composer row above
    /// the field beyond the source and route bar (the dated-source chip row).
    static func maxLines(availableHeight: CGFloat, fontSize: CGFloat, extraChrome: CGFloat = 0) -> Int {
        let house = HouseComposerMetrics.maxLines
        guard availableHeight > 0 else { return house }
        let line = HouseComposerMetrics.lineHeight(fontSize: fontSize)
        // What has to fit under the field's growth: the palette at its
        // smallest (its search row, one result, its footer), the field's own
        // insets, the gaps between them, and the composer chrome above it.
        let floor = House.Control.input + House.Control.row + House.Control.chip
            + 2 * HouseComposerMetrics.textInset(fontSize: fontSize)
            + 3 * House.Spacing.xs
        let room = availableHeight - ComposerSourceRouteBar.height - extraChrome - floor
        guard room > 0, line > 0 else { return 1 }
        return max(1, min(house, Int(room / line)))
    }

    /// The field's height cap at that limit.
    static func maxHeight(availableHeight: CGFloat, fontSize: CGFloat, extraChrome: CGFloat = 0) -> CGFloat {
        HouseComposerMetrics.lineHeight(fontSize: fontSize)
            * CGFloat(maxLines(availableHeight: availableHeight, fontSize: fontSize, extraChrome: extraChrome))
    }
}

// MARK: - The field

/// The composer's text field: a growing, multi-line NSTextView. It asks
/// `onKey` about each key first; marked text (IME composition) always goes
/// to the text system, so Return that commits a pinyin syllable never sends.
private struct ComposerTextView: NSViewRepresentable {
    enum KeyOutcome {
        case handled
        case passThrough
        case moveFocus(forward: Bool)
    }

    @Binding var text: String
    var fontSize: CGFloat
    /// Bump to put the keys in this field.
    var focusToken: Int
    var accessibilityName: String
    var onKey: (ComposerKey, ComposerKeyModifiers, Bool) -> KeyOutcome

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, focusToken: focusToken)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .automatic

        let textView = RoutingTextView()
        textView.delegate = context.coordinator
        textView.onKey = onKey
        textView.string = text
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = House.NSColorToken.textPrimary
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = .zero
        textView.insertionPointColor = House.NSColorToken.textPrimary
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setAccessibilityLabel(accessibilityName)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? RoutingTextView else { return }
        context.coordinator.text = $text
        textView.onKey = onKey
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
        }
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = House.NSColorToken.textPrimary
        textView.setAccessibilityLabel(accessibilityName)
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            // One hop, so the focus change lands after the window finishes
            // its becomeKey transition and SwiftUI finishes this update.
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var focusToken: Int

        init(text: Binding<String>, focusToken: Int) {
            self.text = text
            self.focusToken = focusToken
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }

    final class RoutingTextView: NSTextView {
        var onKey: ((ComposerKey, ComposerKeyModifiers, Bool) -> KeyOutcome)?

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let (key, modifiers) = Self.map(event)
            if !hasMarkedText(), key == .a || key == .s, modifiers == [.command, .shift],
               let result = onKey?(key, modifiers, false), case .handled = result {
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        override func keyDown(with event: NSEvent) {
            // IME composition owns every key until it commits.
            guard !hasMarkedText(), let onKey else {
                super.keyDown(with: event)
                return
            }
            let (key, modifiers) = Self.map(event)
            switch onKey(key, modifiers, hasMarkedText()) {
            case .handled:
                return
            case .passThrough:
                super.keyDown(with: event)
            case .moveFocus(let forward):
                if forward {
                    window?.selectNextKeyView(self)
                } else {
                    window?.selectPreviousKeyView(self)
                }
            }
        }

        static func map(_ event: NSEvent) -> (ComposerKey, ComposerKeyModifiers) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var modifiers: ComposerKeyModifiers = []
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.control) { modifiers.insert(.control) }

            let key: ComposerKey
            switch event.keyCode {
            case 36, 76: key = .returnKey
            case 53: key = .escape
            case 48: key = modifiers.contains(.shift) ? .backTab : .tab
            case 126: key = .upArrow
            case 125: key = .downArrow
            case 123: key = .leftArrow
            case 124: key = .rightArrow
            case 51: key = .backspace
            default:
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "k": key = .k
                case "a": key = .a
                case "s": key = .s
                default: key = .other
                }
            }
            if key == .backTab { modifiers.remove(.shift) }
            return (key, modifiers)
        }
    }
}

// MARK: - Composer

struct AssistantInputView: View {
    private enum AddContextPage { case root, scope }

    /// A project or client on the Search Scope page.
    struct ScopeItem {
        let item: VaultItem
        let isClient: Bool
    }

    @State private var input: String
    @State private var isDropTargeted: Bool
    @State private var isQueued: Bool
    @State private var chooserIndex: Int
    @State private var selectedMentionPaths: [String]
    @State private var documents: [ComposerDocument]
    @State private var focusedChipID: String?
    @State private var isPaletteOpen: Bool
    @State private var paletteQuery = ""
    @State private var isAddContextOpen: Bool
    @State private var addContextPage: AddContextPage
    /// The Add Context pane's own search. Typing there narrows the rows and
    /// never touches the draft.
    @State private var addContextQuery = ""
    /// Bumped to put the keys in the pane's search field when it opens or
    /// changes page.
    @State private var addContextFocusToken = 0
    @State private var scopeItems: [ScopeItem] = []
    /// The meetings and sessions the unified context chooser can reach, read
    /// once when a chooser opens.
    @State private var contextMeetings: [VaultMeetings.Meeting] = []
    /// `esc` closed the `@` or `/` chooser for this exact draft; typing
    /// brings it back.
    @State private var dismissedChooserDraft: String?
    @State private var fileImporterPresented = false
    @State private var inputFieldWidth: CGFloat = 360
    @State private var focusToken = 0
    @StateObject private var mentionSuggestions = MentionSuggestionStore()
    /// The `+` pane's own vault search, so its rows and the `@` chooser's do
    /// not fight over one cache while both are open.
    @StateObject private var paneMentionSuggestions = MentionSuggestionStore()
    @AppStorage(OverlayAppearanceDefaults.uiFontSizeKey) private var uiFontSize: Double = OverlayAppearanceDefaults.defaultUIFontSize
    private let llm = LLMController.shared
    private let session = SessionCoordinator.shared
    private let inputState = OverlayInputState.shared
    private let streamingOverride: Bool?
    private let seededCandidates: [String]?
    private let seededMentionRows: [AddContextRow]?
    private let pendingImageOverride: Bool?
    private let savesToVaultOverride: Bool?
    private let broaderSearchOverride: Bool?
    private let routeOverride: ComposerRoutePreview?
    private let retainedNoticeOverride: String?
    private let retrievalNoticeOverride: String?
    private let datedSourceNameOverride: String?
    private let availableHeight: CGFloat

    init(availableHeight: CGFloat = CGFloat(OverlayAppearanceDefaults.defaultHeight)) {
        self.init(seed: nil, availableHeight: availableHeight)
    }

    /// The composer in a state set up front. Render proofs only; the app
    /// uses `init()`.
    init(seed: ComposerRenderSeed?, availableHeight: CGFloat = CGFloat(OverlayAppearanceDefaults.defaultHeight)) {
        self.availableHeight = availableHeight
        let seed = seed ?? ComposerRenderSeed()
        _input = State(initialValue: seed.draft)
        _isDropTargeted = State(initialValue: seed.isDropTargeted)
        _isQueued = State(initialValue: seed.isQueued)
        _chooserIndex = State(initialValue: seed.chooserIndex)
        _selectedMentionPaths = State(initialValue: seed.mentionPaths)
        _documents = State(initialValue: seed.documents)
        _focusedChipID = State(initialValue: seed.focusedChipID)
        _isPaletteOpen = State(initialValue: seed.layer == .palette)
        _isAddContextOpen = State(initialValue: seed.layer == .addContext || seed.layer == .searchScope)
        _addContextPage = State(initialValue: seed.layer == .searchScope ? .scope : .root)
        if seed.layer == .searchScope {
            _scopeItems = State(initialValue: Self.loadScopeItems())
        }
        streamingOverride = seed.isStreaming
        seededCandidates = seed.mentionCandidates
        seededMentionRows = seed.mentionRows
        pendingImageOverride = seed.pendingImage
        savesToVaultOverride = seed.savesToVault
        broaderSearchOverride = seed.isBroaderSearch
        routeOverride = seed.route
        retainedNoticeOverride = seed.retainedNotice
        retrievalNoticeOverride = seed.retrievalNotice
        datedSourceNameOverride = seed.pendingDatedSourceName
    }

    // MARK: Derived state

    private var isStreaming: Bool { streamingOverride ?? llm.streaming }

    /// The field's text size: `bodySmall` at the default text size, scaled
    /// with the user's text size setting (meeting legibility).
    private var fieldFontSize: CGFloat {
        House.TypeToken.Size.bodySmall * CGFloat(uiFontSize / OverlayAppearanceDefaults.defaultUIFontSize)
    }

    private var readyAttachments: [ExternalDocumentAttachment] {
        documents.compactMap(\.attachment)
    }

    /// Images this turn would carry, derived with the SAME fresh-vs-retained
    /// choice the controller makes: a fresh source turn counts only its own
    /// images, a bare follow-up counts the retained archive, and an explicit
    /// comparison counts both. The preview route and the frozen route agree.
    private var pendingImageCount: Int {
        let tray = readyAttachments
        let freshImageCount = tray.filter { $0.normalizedImage?.data.isEmpty == false }.count
        let screen = (pendingImageOverride ?? (llm.pendingScreenImage != nil)) ? 1 : 0
        let freshSourceCount = tray.count + selectedMentionPaths.count + (datedSourceName != nil ? 1 : 0)
        return llm.chosenImageCount(
            question: input,
            freshSourceCount: freshSourceCount,
            freshImageCount: freshImageCount,
            screenImageCount: screen
        )
    }

    /// Whether this chat is being written down. The store's own answer, so the
    /// composer never claims a save the app cannot make.
    private var savesToVault: Bool {
        savesToVaultOverride ?? (ChatThreadStore.applicationRoots() != nil)
    }

    /// The route named before Send: the per-chat provider, model and reasoning
    /// (`chatRouteLabel`), and the image destination
    /// (`ChatRouteConfiguration.imageRouteLabel`), or the reason the turn is
    /// blocked.
    private var routePreview: ComposerRoutePreview {
        routeOverride ?? ComposerRoutePreview.resolve(
            selection: llm.chatSelection,
            provider: LLMProviders.option(id: llm.chatSelection.providerId).config,
            imageCount: pendingImageCount,
            chosenLabel: llm.chatRouteLabel
        )
    }

    /// The visible source choice. A click always writes the controller's own
    /// value; the seed only stands in for it in a proof.
    private var isBroaderSearch: Bool { broaderSearchOverride ?? llm.broaderSearchEnabled }

    /// The dated log a Chats-library hand-over left for the next turn. It is
    /// shown as a ready chip, so a request the log already grounds never looks
    /// like a request with no source (the strip's own chips are what the
    /// composer sends; this one is the controller's premise for the turn).
    private var datedSourceName: String? {
        datedSourceNameOverride ?? llm.pendingDatedSourceName
    }

    /// The dated source as a chip. `AttachmentChip` draws no remove button when
    /// there is nothing to remove, and the composer cannot drop this one: it is
    /// the premise of the chat the library just started, and `/new` is how a
    /// chat starts without it.
    private var datedSourceChip: AttachmentChipModel? {
        guard let name = datedSourceName else { return nil }
        var chip = AttachmentChipModel(
            ref: ChatAttachmentRef(kind: .vaultFile, name: name, path: name),
            id: Self.datedSourceChipID
        )
        chip.detail = "dated log"
        chip.tooltip = "The dated log this chat is grounded on. /new starts a chat without it."
        return chip
    }

    /// The room the dated chip row takes, when it is there.
    private var datedSourceChipHeight: CGFloat {
        datedSourceChip == nil ? 0 : Self.datedSourceChipRowHeight
    }

    /// Readiness, cuts, the controller's own notices about saved and retrieved
    /// sources, and the save state, in one quiet line.
    private var sourcesStatus: ComposerSourcesStatus {
        ComposerSourcesStatus(
            readiness: attachmentStatus,
            partial: documents.compactMap { document in
                guard case let .ready(attachment) = document.phase, attachment.wasCut else { return nil }
                return ComposerPartialSource(name: document.name, limit: attachment.limitSummary)
            },
            retainedNotice: retainedNoticeOverride ?? llm.retainedSourceNotice,
            imageRouteLabel: pendingImageCount > 0 ? routePreview.imageRouteLabel : "",
            retrievalNotice: retrievalNoticeOverride ?? llm.retrievalDiagnostic,
            savesToVault: savesToVault
        )
    }

    /// Chips `↩` sends: vault files and read documents.
    private var hasSendableChips: Bool {
        !selectedMentionPaths.isEmpty || !readyAttachments.isEmpty
    }

    private var attachmentStatus: ComposerAttachmentStatus {
        if chips.contains(where: { if case .failed = $0.phase { return true }; return false }) { return .failed }
        if chips.contains(where: { $0.phase == .reading }) { return .reading }
        return .ready
    }

    private var composerState: ComposerState {
        ComposerState(
            draft: input,
            hasAttachments: hasSendableChips,
            isStreaming: isStreaming,
            isQueued: isQueued,
            isNoteMode: inputState.isNoteMode,
            isRecording: session.isRunning,
            layer: layer,
            primaryActionLabel: AssistantAction.byID(llm.primaryActionID)?.label ?? "Quick recap",
            attachmentStatus: attachmentStatus
        )
    }

    private var mentionCandidates: [String] {
        seededCandidates ?? mentionSuggestions.candidates
    }

    /// The words after the `@` being typed (nil when no mention is open).
    private var currentMentionQuery: String? { ComposerMention.query(in: input) }

    /// A mention is being typed: the chooser opens on the `@` itself, before
    /// the vault list answers.
    private var isMentionQueryActive: Bool { currentMentionQuery != nil }

    private var visibleMentionCandidates: [String] {
        currentMentionQuery == nil ? [] : mentionCandidates
    }

    private var visibleSlashCommands: [ComposerSlashCommand] {
        ComposerSlashCommand.isChooserDraft(input) ? ComposerSlashCommand.matches(input) : []
    }

    private var layer: ComposerLayer {
        if isPaletteOpen { return .palette }
        if isAddContextOpen { return .addContext }
        guard dismissedChooserDraft != input else { return .none }
        if isMentionQueryActive { return .mention }
        if !visibleSlashCommands.isEmpty { return .slash }
        return .none
    }

    // MARK: Body

    /// The source and route bar: what the next Send will use. Above the row,
    /// so it is read before the Send it describes.
    private var sourceRouteBar: some View {
        let sources = sourcesStatus
        return ComposerSourceRouteBar(
            isBroaderSearch: isBroaderSearch,
            onSelectSourceMode: { llm.broaderSearchEnabled = $0 },
            savedLabel: sources.saveLabel,
            savedHelp: sources.saveHelp,
            route: routePreview,
            onChangeRoute: { OverlayShellModel.shared.toggle(.model) }
        )
    }

    /// The house composer row, its chips and its layers, wired to the app's
    /// state. Broken out of `body` so the type checker has one expression at a
    /// time to solve.
    private var composerRow: some View {
        let state = composerState
        return HouseComposer(
            action: state.action,
            placeholder: state.placeholder,
            showsPlaceholder: input.isEmpty,
            fontSize: fieldFontSize,
            error: errorLine,
            notice: sourcesStatus.notice,
            chips: chips,
            focusedChipID: focusedChipID,
            isAddContextOpen: isAddContextOpen,
            isPaletteOpen: isPaletteOpen,
            isDropTargeted: isDropTargeted,
            onFix: { SettingsWindowController.shared.show(pane: .providers) },
            onAddContext: toggleAddContext,
            onAction: { performAction(state.action) },
            onPalette: togglePalette,
            onRemoveChip: removeChip,
            onClearChips: clearChips
        ) {
            field
        }
    }

    /// The field itself: the multi-line `NSTextView`, grown to its content.
    private var field: some View {
        ComposerTextView(
            text: $input,
            fontSize: fieldFontSize,
            focusToken: focusToken,
            accessibilityName: "Message",
            onKey: handleKey
        )
        .frame(height: fieldHeight)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { updateInputFieldWidth(proxy.size.width) }
                    .onChange(of: proxy.size.width) { _, width in updateInputFieldWidth(width) }
            }
        )
    }

    /// The row, its layers, and what can be dropped or picked into it.
    private var composerSurface: some View {
        VStack(spacing: 0) {
            sourceRouteBar
            datedSourceRow
            composerRow
        }
        .overlay(alignment: .bottom) { floatingLayer }
        // Drop a file to attach it for the next question; drop an image and
        // it is read on-device (OCR) as context, the same path as ⌘⇧H. No
        // image is sent to the model, only the text read from it.
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .fileImporter(
            isPresented: $fileImporterPresented,
            allowedContentTypes: [.pdf, .plainText, .utf8PlainText, .text, .image,
                                  UTType(filenameExtension: "md") ?? .plainText,
                                  UTType(filenameExtension: "markdown") ?? .plainText],
            allowsMultipleSelection: true,
            onCompletion: handleFileImport
        )
    }

    /// The dated source the next turn is grounded on, as a chip beside the
    /// composer's own. No remove button: see `datedSourceChip`.
    @ViewBuilder
    private var datedSourceRow: some View {
        if let datedSourceChip {
            HStack(spacing: 0) {
                AttachmentChip(model: datedSourceChip)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, House.Spacing.xs + House.Spacing.xxs)
            .frame(height: Self.datedSourceChipRowHeight)
        }
    }

    var body: some View {
        composerSurface
        // A draft typed during one meeting must not survive into the next:
        // an accidental ↩ would send stale text into the wrong conversation.
        .onReceive(NotificationCenter.default.publisher(for: .rtiSessionDidStop)) { _ in
            input = ""
            documents = []
            selectedMentionPaths = []
            focusedChipID = nil
            isQueued = false
            if inputState.mode == .liveNote {
                inputState.mode = .chat
            }
        }
        // "Ask about this session" (Sessions window) hands us a vault-relative
        // path to seed as an @mention, the same as picking one from the list.
        .onReceive(NotificationCenter.default.publisher(for: .rtiSeedChatMention)) { notif in
            guard let path = notif.object as? String, !selectedMentionPaths.contains(path) else { return }
            selectedMentionPaths.append(path)
            inputState.mode = .chat
            focusField()
        }
        .onReceive(NotificationCenter.default.publisher(for: .rtiOverlayDidBecomeKey)) { _ in
            focusField()
            mentionSuggestions.prewarm()
            refreshMentionSuggestions()
        }
        .onChange(of: inputState.focusRequest) { _, _ in focusField() }
        .onChange(of: addContextQuery) { _, query in
            chooserIndex = 0
            // An empty pane search asks for nothing, not for every file in the
            // vault: the mention store treats nil as "no query".
            paneMentionSuggestions.update(
                query: query.isEmpty ? nil : query,
                scopeRelativePath: MeetingContextStore.shared.fileAccessScopePath
            )
        }
        // A chooser opens on the space it can reach: RTI's projects, clients
        // and recent meetings are read once, not on every keystroke.
        .onChange(of: layer) { _, newLayer in
            guard newLayer == .mention || newLayer == .addContext else { return }
            if scopeItems.isEmpty { scopeItems = Self.loadScopeItems() }
            if contextMeetings.isEmpty { contextMeetings = Self.loadContextMeetings() }
        }
        .onChange(of: inputState.paletteRequest) { _, _ in openPalette() }
        .onChange(of: input) { _, newValue in
            chooserIndex = 0
            if dismissedChooserDraft != nil, dismissedChooserDraft != newValue { dismissedChooserDraft = nil }
            // Clearing the field unqueues it.
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !hasSendableChips {
                isQueued = false
            }
            refreshMentionSuggestions()
        }
        .onChange(of: llm.pendingDraftRestore) { _, restored in
            // A question that could not be saved, or a prompt handed over from
            // the Chats library, comes back to the field: a failed send never
            // loses what was typed, and a hand-over is editable before it is
            // sent. Nothing is submitted here.
            guard let restored, !restored.isEmpty else { return }
            input = restored
            llm.clearPendingDraftRestore()
            focusField()
        }
        .onChange(of: llm.streaming) { _, streaming in
            // The queued follow-up goes when the answer ends.
            guard !streaming, isQueued else { return }
            isQueued = false
            submit()
        }
        .onAppear {
            guard seededCandidates == nil else { return }
            mentionSuggestions.prewarm()
            refreshMentionSuggestions()
        }
    }

    // MARK: Field height

    /// The dated-source chip row's height: a chip plus the gap above it.
    static let datedSourceChipRowHeight = House.Control.chip + House.Spacing.xs

    /// The id the dated-source chip carries. It is never in the strip, so no
    /// chip key, no strip selection and no clear-all ever reaches it.
    static let datedSourceChipID = "dated-source"

    /// The composer's own height: the bar, the dated chip row when one is
    /// pending, and the row itself. What the floating layers must leave room
    /// for, and what the field's own line budget is measured against.
    private var composerChromeHeight: CGFloat {
        composerRowHeight + ComposerSourceRouteBar.height + datedSourceChipHeight
    }

    private var composerRowHeight: CGFloat {
        HouseComposerMetrics.rowHeight(fieldHeight: fieldHeight, fontSize: fieldFontSize)
    }

    private var fieldHeight: CGFloat {
        let line = HouseComposerMetrics.lineHeight(fontSize: fieldFontSize)
        var text = input.isEmpty ? " " : input
        if text.hasSuffix("\n") { text += " " }
        let width = max(line, inputFieldWidth)
        let rect = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: fieldFontSize)]
        ).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let maxHeight = ComposerFieldBudget.maxHeight(
            availableHeight: availableHeight,
            fontSize: fieldFontSize,
            extraChrome: datedSourceChipHeight
        )
        return min(max(line, ceil(rect.height)), maxHeight)
    }

    private func updateInputFieldWidth(_ width: CGFloat) {
        guard abs(inputFieldWidth - width) > 1 else { return }
        inputFieldWidth = width
    }

    private func focusField() {
        // While a pane owns the keys, it keeps them. The overlay asks for the
        // composer a runloop turn after the window becomes key, and again
        // 50 ms after `show()`, so an ungated request lands after the pane has
        // claimed focus and pulls typing out of its search field.
        guard !isPaletteOpen, !isAddContextOpen else { return }
        focusToken &+= 1
    }

    // MARK: Error above the row

    /// Errors that belong to no turn: a capture error, a missing or bad
    /// key (with the fix-it), or a route that cannot run as chosen. Turn
    /// errors stay in the thread.
    private var errorLine: ComposerErrorLine? {
        if let message = session.lastError, !message.isEmpty {
            return .init(message: message, fixTitle: session.lastErrorIsAuth ? "Open Settings" : nil)
        }
        if llm.lastErrorIsAuth, let message = llm.lastError, !message.isEmpty {
            return .init(message: message, fixTitle: "Open Settings")
        }
        // The route's own reason, in its own words: a turn that cannot run is
        // named before Send, with the fix that resolves it.
        if let blocker = routePreview.blockerMessage {
            return .init(message: blocker, fixTitle: routePreview.blockerNeedsSettings ? "Open Settings" : nil)
        }
        return nil
    }

    // MARK: Chips

    private static let screenChipID = "screen"
    private static let vaultChipPrefix = "vault:"

    private var chips: [AttachmentChipModel] {
        var chips = selectedMentionPaths.map { path in
            AttachmentChipModel(
                ref: ChatAttachmentRef(kind: .vaultFile, name: MentionChooserPane.fileName(path), path: path),
                id: Self.vaultChipPrefix + path
            )
        }
        chips += documents.map(\.chip)
        if let screen = screenChip { chips.append(screen) }
        return chips
    }

    /// One screen or window read: the chip carries the captured screenshot as
    /// a thumbnail, so the attachment is visible before it is sent.
    private var screenChip: AttachmentChipModel? {
        if llm.pendingScreenContext != nil, llm.screenCaptureStatus?.isEmpty != false {
            var chip = AttachmentChipModel(ref: ChatAttachmentRef(kind: .screen, name: "Screenshot"), id: Self.screenChipID)
            chip.thumbnail = llm.pendingScreenPreview
            return chip
        }
        guard let status = llm.screenCaptureStatus, !status.isEmpty else { return nil }
        // The capture posts its steps ("Reading all screens…") and, on a
        // failure, the reason; a step ends with an ellipsis.
        let isStep = status.hasSuffix("…")
        return AttachmentChipModel(
            id: Self.screenChipID,
            kind: .screen,
            name: "Screenshot",
            phase: isStep ? .reading : .failed(status),
            detail: isStep ? status : ""
        )
    }

    private func removeChip(_ id: String) {
        if id == Self.screenChipID {
            llm.clearPendingScreenContext()
        } else if id.hasPrefix(Self.vaultChipPrefix) {
            let path = String(id.dropFirst(Self.vaultChipPrefix.count))
            selectedMentionPaths.removeAll { $0 == path }
        } else {
            documents.removeAll { $0.id.uuidString == id }
        }
        if focusedChipID == id {
            focusedChipID = nil
        }
        focusField()
    }

    private func clearChips() {
        selectedMentionPaths = []
        documents = []
        llm.clearPendingScreenContext()
        focusedChipID = nil
        focusField()
    }

    private func moveStrip(_ delta: Int) {
        let ids = chips.map(\.id)
        guard !ids.isEmpty else { return }
        let current = focusedChipID.flatMap { ids.firstIndex(of: $0) } ?? ids.count - 1
        focusedChipID = ids[min(max(current + delta, 0), ids.count - 1)]
    }

    // MARK: Keys

    private func handleKey(_ key: ComposerKey, _ modifiers: ComposerKeyModifiers, _ hasMarkedText: Bool) -> ComposerTextView.KeyOutcome {
        let chipIDs = chips.map(\.id)
        let context = ComposerKeyContext(
            hasMarkedText: hasMarkedText,
            layer: layer,
            isStreaming: isStreaming,
            isQueued: isQueued,
            isNoteMode: inputState.isNoteMode,
            draft: input,
            hasAttachments: hasSendableChips,
            hasOtherChips: !chipIDs.isEmpty,
            isStripFocused: focusedChipID.map { id in chipIDs.contains(id) } ?? false,
            attachmentStatus: attachmentStatus
        )
        switch ComposerKeyRouter.route(key, modifiers: modifiers, context: context) {
        case .passThrough:
            return .passThrough
        case .consume:
            return .handled
        case .submit:
            submit()
        case .queue:
            isQueued = true
        case .runPrimary:
            llm.sendPrimary()
        case .acceptChooser:
            acceptChooser()
        case .moveChooser(let delta):
            moveChooser(delta)
        case .closeLayer:
            closeLayer()
        case .stopStream:
            stopStream()
        case .clearDraft:
            input = ""
        case .recallLastQuestion:
            guard let last = inputState.lastQuestion, !last.isEmpty else { return .passThrough }
            input = last
        case .togglePalette:
            togglePalette()
        case .toggleAttachments:
            toggleAddContext()
        case .enterStrip:
            focusedChipID = chipIDs.last
        case .moveStrip(let delta):
            moveStrip(delta)
        case .removeFocusedChip:
            if let id = focusedChipID {
                let index = chipIDs.firstIndex(of: id) ?? 0
                removeChip(id)
                let remaining = chips.map(\.id)
                focusedChipID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)]
            }
        case .removeNewestChip:
            if let id = chipIDs.last { removeChip(id) }
        case .leaveStrip(let alsoPassThrough):
            focusedChipID = nil
            return alsoPassThrough ? .passThrough : .handled
        case .moveFocus(let forward):
            return .moveFocus(forward: forward)
        }
        return .handled
    }

    private func performAction(_ action: ComposerAction) {
        switch action.kind {
        case .ask, .addNote: submit()
        case .sendAsText: sendAsText()
        case .runPrimary: llm.sendPrimary()
        case .stop: stopStream()
        case .queued, .blocked: break
        case .acceptChooser: acceptChooser()
        }
        focusField()
    }

    private func stopStream() {
        llm.cancel()
        // The queued draft stays in the field, unsent.
        isQueued = false
    }

    // MARK: Layers

    private func closeLayer() {
        switch layer {
        case .palette:
            closePalette()
        case .addContext:
            if addContextPage == .scope {
                addContextPage = .root
                addContextQuery = ""
                chooserIndex = 0
                addContextFocusToken &+= 1
            } else {
                isAddContextOpen = false
                focusField()
            }
        case .mention, .slash:
            dismissedChooserDraft = input
        case .none:
            break
        }
    }

    private func toggleAddContext() {
        if isAddContextOpen {
            isAddContextOpen = false
            focusField()
        } else {
            isPaletteOpen = false
            focusedChipID = nil
            addContextPage = .root
            addContextQuery = ""
            chooserIndex = 0
            isAddContextOpen = true
            // The pane's search field takes the keyboard; the composer keeps
            // its draft untouched behind it.
            addContextFocusToken &+= 1
        }
    }

    private func togglePalette() {
        if isPaletteOpen { closePalette() } else { openPalette() }
    }

    private func openPalette() {
        isAddContextOpen = false
        paletteQuery = ""
        isPaletteOpen = true
    }

    private func closePalette() {
        isPaletteOpen = false
        focusField()
    }

    private func moveChooser(_ delta: Int) {
        let count: Int
        switch layer {
        case .mention: count = visibleMentionRows.count
        case .slash: count = visibleSlashCommands.count
        case .addContext: count = visibleAddContextRows.count
        case .palette, .none: count = 0
        }
        guard count > 0 else { return }
        chooserIndex = (chooserIndex + delta + count) % count
    }

    private func acceptChooser() {
        switch layer {
        case .mention:
            if let row = visibleMentionRows[safe: chooserIndex] { activate(row) }
        case .slash:
            if let command = visibleSlashCommands[safe: chooserIndex] {
                input = ""
                runSlashCommand(command.id)
            }
        case .addContext:
            if let row = visibleAddContextRows[safe: chooserIndex] { activate(row) }
        case .palette, .none:
            break
        }
    }

    @ViewBuilder
    private var floatingLayer: some View {
        switch layer {
        case .palette:
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                CommandPaletteView(
                    query: $paletteQuery,
                    onRun: runPaletteCommand,
                    onClose: closePalette,
                    leadingCommands: paletteLeadingCommands,
                    hiddenRegistryIDs: ["note.toggle", "capture.screen", "capture.window"],
                    maxVisibleRows: HouseComposerMetrics.paletteRows(availableHeight: availableHeight, composerHeight: composerChromeHeight)
                )
                .frame(maxWidth: HouseChatMetrics.paletteWidth)
                .panelGlass(radius: House.Radius.lg)
                .panelShadows()
            }
            .padding(.trailing, House.Spacing.sm)
            .padding(.bottom, composerRowHeight)
            .fixedSize(horizontal: false, vertical: true)
        case .addContext:
            HouseFloatingChooser {
                AddContextPane(
                    rows: visibleAddContextRows.map(\.row),
                    selectedIndex: chooserIndex,
                    query: $addContextQuery,
                    focusToken: addContextFocusToken,
                    title: addContextPage == .scope ? "Search Scope" : "Add Context",
                    isSubpage: addContextPage == .scope,
                    footnote: addContextPage == .root ? contextFootnote : nil,
                    searchPlaceholder: addContextPage == .scope ? "Search scopes" : "Search context",
                    maxRows: HouseComposerMetrics.addContextRows(
                        availableHeight: availableHeight,
                        composerHeight: composerChromeHeight
                    ),
                    onMove: { moveChooser($0) },
                    onSubmit: { acceptChooser() },
                    onClose: { closeLayer() },
                    // `⌘K` here means the action palette, as it does in Quick
                    // Launch's Attach pane, rather than just closing the menu.
                    onCommandK: openPalette,
                    onActivate: activate
                )
            }
            .padding(.bottom, composerRowHeight)
            .fixedSize(horizontal: false, vertical: true)
        case .mention:
            HouseFloatingChooser {
                // The same rows the `+` pane searches, filtered by the words
                // typed after the `@`. The chooser opens on the `@` itself, so
                // with no answer yet it says it is looking.
                ContextChooserPane(
                    rows: visibleMentionRows,
                    selectedIndex: chooserIndex,
                    isSearching: mentionSuggestions.isSearching,
                    onPick: activate
                )
            }
            .padding(.bottom, composerRowHeight)
            .fixedSize(horizontal: false, vertical: true)
        case .slash:
            HouseFloatingChooser {
                SlashChooserPane(commands: visibleSlashCommands, selectedIndex: chooserIndex) { command in
                    input = ""
                    runSlashCommand(command.id)
                    focusField()
                }
            }
            .padding(.bottom, composerRowHeight)
            .fixedSize(horizontal: false, vertical: true)
        case .none:
            EmptyView()
        }
    }

    // MARK: Add Context

    /// The root page's actions. `@` and `+` offer the same ones: they are the
    /// ways into the context space that are not a name.
    private var contextActionRows: [AddContextRow] {
        let scope = MeetingContextStore.shared.workstreamName ?? "Whole vault"
        return [
            AddContextRow(kind: .attachFile, symbol: "paperclip", title: "Attach File…",
                          detail: "PDF, Markdown, text, or an image, for the next question"),
            AddContextRow(kind: .vaultFile, symbol: "at", title: "Vault File",
                          detail: "Type @ and the vault list filters as you type"),
            AddContextRow(kind: .readScreen, symbol: "camera.viewfinder", title: "Screenshot Screen",
                          detail: "Whole screen; sent to the model and kept with the session", keys: ["⌘", "⇧", "H"]),
            AddContextRow(kind: .readWindow, symbol: "macwindow", title: "Screenshot Window",
                          detail: "Frontmost window; sent to the model and kept with the session", keys: ["⌘", "⇧", "J"]),
            AddContextRow(kind: .searchScope, symbol: "scope", title: "Search Scope", detail: scope),
            AddContextRow(
                kind: .noteMode,
                symbol: "note.text",
                title: inputState.isNoteMode ? "Back to Chat" : "Note Mode",
                detail: session.isRunning ? "↩ adds a note to the transcript" : "↩ adds a prep note",
                keys: ["⌘", "⌥", "N"]
            ),
        ]
    }

    /// RTI's own projects and clients, the rows that make this a context
    /// chooser rather than a file list.
    private var scopeItemRows: [ComposerContextRow] {
        let current = MeetingContextStore.shared.workstreamName
        return scopeItems.map { scope in
            ComposerContextRow(row: AddContextRow(
                kind: .scope(id: scope.item.id),
                symbol: scope.isClient ? "person.2" : "folder",
                title: scope.item.name,
                detail: scope.isClient ? "Client" : "Project",
                isCurrent: current == scope.item.name
            ))
        }
    }

    /// The scope page: the whole vault, then the projects and clients.
    private var scopePageRows: [ComposerContextRow] {
        let current = MeetingContextStore.shared.workstreamName
        let whole = AddContextRow(kind: .scope(id: nil), symbol: "archivebox", title: "Whole vault",
                                  detail: "Search every note", isCurrent: current == nil)
        return [ComposerContextRow(row: whole)] + scopeItemRows
    }

    /// The meetings and sessions already on disk: RTI's second addition to the
    /// context space, so `@` can reach a meeting and not only a file.
    private var meetingRows: [ComposerContextRow] {
        contextMeetings.map { meeting in
            ComposerContextRow(
                row: AddContextRow(
                    kind: .vaultFile,
                    symbol: meeting.kind == "session" ? "waveform" : "calendar",
                    title: meeting.title,
                    detail: "\(meeting.displayDate) · \(meeting.kind)"
                ),
                path: meeting.relativePath,
                keywords: [meeting.relativePath]
            )
        }
    }

    /// The vault files the mention index matched, as rows that carry their
    /// path so a pick can become a chip.
    private static func vaultFileRows(_ paths: [String]) -> [ComposerContextRow] {
        paths.map { path in
            ComposerContextRow(
                row: AddContextRow(
                    kind: .vaultFile,
                    symbol: "doc.text",
                    title: MentionChooserPane.fileName(path),
                    detail: MentionChooserPane.folder(path)
                ),
                path: path,
                // The title is only the file's name; the path is what the
                // search matched, so it has to be searchable too.
                keywords: [path]
            )
        }
    }

    /// The one search over the shared context space, for `@` and for `+`.
    /// `includeAtRest` adds RTI's meetings, projects and clients even with an
    /// empty query: the `@` chooser opens on them, while the `+` pane keeps its
    /// short action list and reaches them by typing or through its scope page.
    ///
    /// The vault's own matches come first, as they always have in the `@`
    /// chooser, then RTI's rows, then the actions. Typing re-ranks all of it
    /// together, so this order is only what the chooser opens on.
    private func contextRows(query: String, vaultCandidates: [String], includeAtRest: Bool) -> [ComposerContextRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows = Self.vaultFileRows(vaultCandidates)
        if includeAtRest || !needle.isEmpty {
            rows += meetingRows
            rows += scopeItemRows
        }
        rows += contextActionRows.map { ComposerContextRow(row: $0) }
        return Self.rankContext(rows, query: needle)
    }

    /// The Add Context pane's rows: the root page, or the scope page. Typing in
    /// the pane narrows the same list `@` searches; the composer draft is
    /// never touched. The highlight always indexes this list, so the keys and
    /// the drawn rows agree.
    private var visibleAddContextRows: [ComposerContextRow] {
        switch addContextPage {
        case .root:
            return contextRows(query: addContextQuery, vaultCandidates: paneMentionSuggestions.candidates, includeAtRest: false)
        case .scope:
            return Self.rankContext(scopePageRows, query: addContextQuery)
        }
    }

    /// The `@` chooser's rows: the same space, searched with the words typed
    /// after the `@`.
    private var visibleMentionRows: [ComposerContextRow] {
        if let seededMentionRows { return seededMentionRows.map { ComposerContextRow(row: $0) } }
        return contextRows(
            query: currentMentionQuery ?? "",
            vaultCandidates: visibleMentionCandidates,
            includeAtRest: true
        )
    }

    /// Ranked the way every house chooser ranks: title first, then the row's
    /// own detail and any extra words as keywords, with the same fuzzy scorer
    /// the `⌘K` palette uses. A row that does not match is dropped.
    private static func rankContext(_ rows: [ComposerContextRow], query: String) -> [ComposerContextRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return rows }
        return rows.enumerated()
            .compactMap { index, row -> (ComposerContextRow, Int, Int)? in
                guard let score = CommandRegistry.matchScore(
                    query: needle,
                    title: row.row.title,
                    keywords: [row.row.detail] + row.keywords
                ) else { return nil }
                return (row, score, index)
            }
            .sorted { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 > $1.1 }
            .map(\.0)
    }

    /// "Next answer uses: Live transcript, Northwind app, Glossary".
    private var contextPreviewLabels: [String] {
        var labels = llm.contextPreviewLabels().filter { $0 != "Screen OCR" }
        // A dated hand-over grounds the next turn even though it is not one of
        // the composer's own chips, so the preview names it first.
        if let datedSourceName { labels.insert(datedSourceName, at: 0) }
        return labels
    }

    private var contextFootnote: String? {
        let labels = contextPreviewLabels
        guard !labels.isEmpty else { return nil }
        return "Next answer uses: " + labels.joined(separator: ", ")
    }

    /// Projects (8) then clients (6), read once when a chooser opens.
    private static func loadScopeItems() -> [ScopeItem] {
        VaultWorkstreamStore.projects().prefix(8).map { ScopeItem(item: $0, isClient: false) }
            + VaultWorkstreamStore.clients().prefix(6).map { ScopeItem(item: $0, isClient: true) }
    }

    /// The recent meetings and sessions for the current scope, newest first.
    private static func loadContextMeetings() -> [VaultMeetings.Meeting] {
        VaultMeetings.recent(scopeRelativePath: MeetingContextStore.shared.fileAccessScopePath, limit: 6)
    }

    /// The pane draws plain rows, so the one it hands back is looked up by
    /// value to reach the path and the keywords the search used.
    private func activate(_ row: AddContextRow) {
        guard let context = visibleAddContextRows.first(where: { $0.row == row }) else { return }
        activate(context)
    }

    private func activate(_ context: ComposerContextRow) {
        // The `@` chooser is a function of what is typed after the `@`: taking
        // those words out of the draft is what closes it, whichever row was
        // chosen.
        if layer == .mention { input = Self.draftWithoutMentionQuery(input) }
        if let path = context.path {
            addMention(path)
            return
        }
        switch context.row.kind {
        case .attachFile:
            isAddContextOpen = false
            fileImporterPresented = true
        case .vaultFile:
            // The action row: the hand-off to `@`, which searches the vault.
            isAddContextOpen = false
            if !input.hasSuffix("@") {
                input += (input.isEmpty || input.hasSuffix(" ") ? "" : " ") + "@"
            }
        case .readScreen:
            isAddContextOpen = false
            ScreenshotManager.shared.captureAndAttach()
        case .readWindow:
            isAddContextOpen = false
            ScreenshotManager.shared.captureFocusedWindowAndAttach()
        case .searchScope:
            scopeItems = Self.loadScopeItems()
            contextMeetings = Self.loadContextMeetings()
            addContextPage = .scope
            addContextQuery = ""
            chooserIndex = 0
            addContextFocusToken &+= 1
            isAddContextOpen = true
            return
        case .noteMode:
            isAddContextOpen = false
            toggleNoteMode()
        case .scope(let id):
            if let id, let scope = scopeItems.first(where: { $0.item.id == id }) {
                MeetingContextStore.shared.selectWorkstream(scope.item)
            } else {
                MeetingContextStore.shared.clearWorkstream()
            }
            refreshMentionSuggestions()
            addContextPage = .root
            isAddContextOpen = false
        }
        focusField()
    }

    // MARK: ⌘K palette

    /// The composer's own rows, ahead of the registry: the mode's quick
    /// actions (the primary one carries ⌘↩), then note mode, attach, the two
    /// screen reads, and the sticky recap depth (the old ✦ menu's items).
    private var paletteLeadingCommands: [RTICommand] {
        let llm = llm
        var rows: [RTICommand] = llm.availableQuickActions().map { action in
            RTICommand(
                id: "chat.\(action.id)",
                title: action.label,
                subtitle: action.id == llm.primaryActionID ? "⌘↩" : action.hotkey?.display,
                keywords: action.keywords + [action.paletteTitle.lowercased()],
                perform: { llm.perform(actionID: action.id) }
            )
        }
        rows.append(RTICommand(
            id: "composer.note",
            title: inputState.isNoteMode ? "Back to Chat" : "Note Mode",
            subtitle: "⌘⌥N",
            keywords: ["note", "annotate", "transcript", "prep"],
            perform: toggleNoteMode
        ))
        rows.append(RTICommand(
            id: "composer.attach",
            title: "Attach…",
            subtitle: "⇧⌘A",
            keywords: ["pdf", "document", "file", "attach", "markdown", "context"],
            perform: toggleAddContext
        ))
        rows.append(RTICommand(
            id: "composer.screen",
            title: "Screenshot Screen",
            subtitle: "⌘⇧H",
            keywords: ["screen", "ocr", "capture", "screenshot", "display"],
            perform: { ScreenshotManager.shared.captureAndAttach() }
        ))
        rows.append(RTICommand(
            id: "composer.window",
            title: "Screenshot Window",
            subtitle: "⌘⇧J",
            keywords: ["window", "ocr", "capture", "screenshot", "frontmost", "focused"],
            perform: { ScreenshotManager.shared.captureFocusedWindowAndAttach() }
        ))
        rows += RecapDepth.allCases.map { depth in
            RTICommand(
                id: "composer.recap.\(depth.rawValue)",
                title: "Recap Depth: \(depth.label)",
                keywords: ["recap", "length", "depth", "brief", "detailed"],
                perform: { llm.recapDepth = depth },
                menuStateProvider: { llm.recapDepth == depth }
            )
        }
        return rows
    }

    private func runPaletteCommand(_ command: RTICommand) {
        closePalette()
        command.perform()
        if !command.id.hasPrefix("composer.") {
            CommandRegistry.shared.recordExecution(command.id)
        }
    }

    private func toggleNoteMode() {
        inputState.mode = inputState.isNoteMode ? .chat : .liveNote
        focusField()
    }

    // MARK: Mentions

    private func refreshMentionSuggestions() {
        guard seededCandidates == nil else { return }
        mentionSuggestions.update(
            query: currentMentionQuery,
            scopeRelativePath: MeetingContextStore.shared.fileAccessScopePath
        )
    }

    /// A file or a meeting picked in either chooser becomes a chip.
    private func addMention(_ path: String) {
        if !selectedMentionPaths.contains(path) {
            selectedMentionPaths.append(path)
        }
        mentionSuggestions.update(query: nil, scopeRelativePath: nil)
        focusField()
    }

    /// The draft with the `@…` being typed taken out of it: what closes the
    /// `@` chooser.
    private static func draftWithoutMentionQuery(_ draft: String) -> String {
        guard ComposerMention.query(in: draft) != nil, let at = draft.lastIndex(of: "@") else { return draft }
        return String(draft[..<at]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The question with its chosen vault files in front of it, in the one
    /// quoted form the assistant resolves.
    private func inputWithSelectedMentions(_ text: String) -> String {
        ComposerMention.line(paths: selectedMentionPaths, text: text)
    }

    // MARK: Drop and import

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var took = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                took = true
                let pending = ComposerDocument(name: provider.suggestedName ?? "File", phase: .reading)
                documents.append(pending)
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    Task { @MainActor in
                        guard let index = documents.firstIndex(where: { $0.id == pending.id }) else { return }
                        guard let url else {
                            documents[index].phase = .failed("Could not read the dropped file")
                            return
                        }
                        documents.remove(at: index)
                        dropFile(url)
                    }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                took = true
                let pending = ComposerDocument(name: provider.suggestedName ?? "Image", phase: .reading)
                documents.append(pending)
                provider.loadObject(ofClass: NSImage.self) { object, _ in
                    let image = object as? NSImage
                    Task { @MainActor in
                        guard let index = documents.firstIndex(where: { $0.id == pending.id }) else { return }
                        guard let image else {
                            documents[index].phase = .failed("Could not read the dropped image")
                            return
                        }
                        documents.remove(at: index)
                        ScreenshotManager.shared.attachDroppedImage(image)
                    }
                }
            }
        }
        return took
    }

    /// An image file is read on-device like a screen; any other file loads
    /// as a document.
    private func dropFile(_ url: URL) {
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
           let image = NSImage(contentsOf: url) {
            ScreenshotManager.shared.attachDroppedImage(image)
        } else {
            addDocument(url)
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result else { return }
        // `dropFile` routes an image to the screenshot lane and everything else
        // to the document lane, so picking a saved screenshot here behaves the
        // same as dropping it on the composer.
        urls.forEach(dropFile)
    }

    /// Reads the file off the main thread; the chip says "Reading…" until
    /// then, and the reason if it fails.
    private func addDocument(_ url: URL) {
        let name = url.lastPathComponent
        // The same file twice is one chip; a failed read may be tried again.
        guard !documents.contains(where: { $0.isSameSource(as: url) && !isFailed($0) }) else { return }
        documents.removeAll { $0.isSameSource(as: url) }
        let item = ComposerDocument(name: name, phase: .reading, sourceURL: url)
        documents.append(item)
        Task {
            let phase: ComposerDocument.Phase
            do {
                let attachment = try await Task.detached(priority: .userInitiated) {
                    try await ExternalDocumentLoader.load(url: url)
                }.value
                phase = .ready(attachment)
            } catch let error as ExternalDocumentLoader.LoadError {
                phase = .failed(error.chipReason)
            } catch {
                phase = .failed("Could not be read")
            }
            guard let index = documents.firstIndex(where: { $0.id == item.id }) else { return }
            documents[index].phase = phase
        }
    }

    private func isFailed(_ document: ComposerDocument) -> Bool {
        if case .failed = document.phase { return true }
        return false
    }

    // MARK: Submit

    /// What a typed slash line turned out to be.
    private enum SlashLineOutcome {
        /// Not a command at all: send the words as an ordinary question.
        case notACommand
        /// A command ran. The field's business is done.
        case ran
        /// No such command: it stays local, in the field, until the explicit
        /// Send as Text action.
        case staysLocal
    }

    private func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        switch inputState.mode {
        case .liveNote:
            guard !text.isEmpty else { return }
            if submitLiveNote(text) {
                input = ""
                inputState.mode = .chat
                focusField()
            }
        case .chat:
            guard !text.isEmpty || hasSendableChips else { return }
            // A document still reading would be left behind; wait for it.
            guard attachmentStatus == .ready else { return }
            if text.hasPrefix("/") {
                switch submitSlashLine(text) {
                case .notACommand:
                    break
                case .ran:
                    input = ""
                    focusField()
                    return
                case .staysLocal:
                    // The words stay in the field: the local reason is shown,
                    // and only Send as Text sends them.
                    focusField()
                    return
                }
            }
            if !text.isEmpty { inputState.lastQuestion = text }
            llm.sendAskAnything(inputWithSelectedMentions(text), attachments: readyAttachments)
            input = ""
            selectedMentionPaths = []
            documents = []
            focusedChipID = nil
        }
    }

    /// The one path that turns a refused slash line into a message: the user
    /// chose the explicit action, so the typed words go verbatim as an
    /// ordinary question. Chips stay for the next question, the way a
    /// `/recap` line leaves them.
    private func sendAsText() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, attachmentStatus == .ready else { return }
        inputState.lastQuestion = text
        llm.sendAsText(text)
        input = ""
        focusField()
    }

    /// Run a command picked from the `/` chooser.
    private func runSlashCommand(_ id: String) {
        _ = submitSlashLine("/" + id)
    }

    /// A slash line, through the one shared `ChatCommandParser` (the product
    /// RTICore and Quick Launch both link), so the command set the composer
    /// recognizes is the same one the assistant runs. Builtins precede
    /// aliases inside the parser, so `/clear` can never be shadowed.
    private func submitSlashLine(_ text: String) -> SlashLineOutcome {
        switch LLMController.composerCommandParser.parse(text) {
        case .empty, .notACommand:
            return .notACommand
        case .unknown:
            // Stays local. The controller posts the reason in the thread;
            // nothing is sent and nothing runs.
            _ = llm.handleComposerCommand(text)
            return .staysLocal
        case let .command(command):
            let argument = command.arguments.joined(separator: " ")
            switch command.name {
            case .new, .clear:
                startNewChat()
                return .ran
            case let .known(name):
                let id = name.hasPrefix("/") ? String(name.dropFirst()) : name
                switch id {
                case "note":
                    // The composer owns the mode switch, so it keeps the
                    // argument's words: `/note off` leaves note mode, and
                    // `/note pricing agreed` writes that note.
                    if argument.isEmpty {
                        inputState.mode = inputState.isNoteMode ? .chat : .liveNote
                    } else if !applyNoteModeArgument(argument) {
                        _ = submitLiveNote(argument)
                    }
                    return .ran
                case "chat":
                    inputState.mode = .chat
                    return .ran
                default:
                    if llm.runComposerCommand(id: id, argument: argument) { return .ran }
                    // A catalogue entry no handler owns: show it locally and
                    // never send it as prompt text.
                    _ = llm.handleComposerCommand(text)
                    return .staysLocal
                }
            }
        }
    }

    /// `/new` and `/clear`: the controller clears the chat and its pending
    /// context without ending the recording and without discarding the saved
    /// thread; the composer clears what it owns — the draft, the chips, the
    /// queued follow-up — and starts fresh.
    private func startNewChat() {
        llm.newChat()
        input = ""
        selectedMentionPaths = []
        documents = []
        focusedChipID = nil
        isQueued = false
    }

    @discardableResult
    private func applyNoteModeArgument(_ argument: String) -> Bool {
        switch argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "meeting", "meet", "live", "transcript", "on", "prep":
            inputState.mode = .liveNote
        case "off", "exit", "cancel", "chat":
            inputState.mode = .chat
        default:
            return false
        }
        return true
    }

    private func submitLiveNote(_ text: String) -> Bool {
        if session.isRunning {
            return session.insertNote(text)
        }
        return MeetingContextStore.shared.appendPrepNote(text)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
