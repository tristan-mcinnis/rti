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
            return
        }

        let cacheKey = Self.cacheKey(query: normalizedQuery, scope: normalizedScope)
        if let cached = cachedResults[cacheKey] {
            candidates = cached
        }

        task = Task { [normalizedQuery, normalizedScope] in
            try? await Task.sleep(nanoseconds: 35_000_000)
            guard !Task.isCancelled else { return }
            let results = await Task.detached(priority: .userInitiated) {
                VaultFiles.mentionCandidates(normalizedQuery, scopeRelativePath: normalizedScope, limit: 6)
            }.value
            guard !Task.isCancelled else { return }
            candidates = results
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
    var phase: Phase

    init(id: UUID = UUID(), name: String, phase: Phase) {
        self.id = id
        self.name = name
        self.phase = phase
    }

    var attachment: ExternalDocumentAttachment? {
        if case .ready(let attachment) = phase { return attachment }
        return nil
    }

    var isReading: Bool { phase == .reading }

    var chip: AttachmentChipModel {
        switch phase {
        case .ready(let attachment):
            return AttachmentChipModel(ref: attachment.ref, id: id.uuidString)
        case .reading:
            let kind: ChatAttachmentRef.Kind = name.lowercased().hasSuffix(".pdf") ? .pdf : .text
            return AttachmentChipModel(id: id.uuidString, kind: kind, name: name, phase: .reading)
        case .failed(let reason):
            let kind: ChatAttachmentRef.Kind = name.lowercased().hasSuffix(".pdf") ? .pdf : .text
            return AttachmentChipModel(id: id.uuidString, kind: kind, name: name, phase: .failed(reason))
        }
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
    var mentionPaths: [String] = []
    var documents: [ComposerDocument] = []
    var isDropTargeted = false
    var focusedChipID: String?
    var chooserIndex = 0
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
                key = event.charactersIgnoringModifiers?.lowercased() == "k" ? .k : .other
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
    @State private var scopeItems: [ScopeItem] = []
    /// `esc` closed the `@` or `/` chooser for this exact draft; typing
    /// brings it back.
    @State private var dismissedChooserDraft: String?
    @State private var fileImporterPresented = false
    @State private var inputFieldWidth: CGFloat = 360
    @State private var focusToken = 0
    @StateObject private var mentionSuggestions = MentionSuggestionStore()
    @AppStorage(OverlayAppearanceDefaults.uiFontSizeKey) private var uiFontSize: Double = OverlayAppearanceDefaults.defaultUIFontSize
    private let llm = LLMController.shared
    private let session = SessionCoordinator.shared
    private let inputState = OverlayInputState.shared
    private let streamingOverride: Bool?
    private let seededCandidates: [String]?

    init() {
        self.init(seed: nil)
    }

    /// The composer in a state set up front. Render proofs only; the app
    /// uses `init()`.
    init(seed: ComposerRenderSeed?) {
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

    /// Chips `↩` sends: vault files and read documents.
    private var hasSendableChips: Bool {
        !selectedMentionPaths.isEmpty || !readyAttachments.isEmpty
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
            primaryActionLabel: AssistantAction.byID(llm.primaryActionID)?.label ?? "Assist"
        )
    }

    private var mentionCandidates: [String] {
        seededCandidates ?? mentionSuggestions.candidates
    }

    private var currentMentionQuery: String? {
        guard let at = input.lastIndex(of: "@") else { return nil }
        let after = input[input.index(after: at)...]
        guard !after.contains("@"),
              !after.contains("\n"),
              after.first != "\"" else { return nil }
        return String(after).trimmingCharacters(in: .whitespaces)
    }

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
        if !visibleMentionCandidates.isEmpty { return .mention }
        if !visibleSlashCommands.isEmpty { return .slash }
        return .none
    }

    // MARK: Body

    var body: some View {
        let state = composerState
        HouseComposer(
            action: state.action,
            placeholder: state.placeholder,
            showsPlaceholder: input.isEmpty,
            fontSize: fieldFontSize,
            error: errorLine,
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
        .overlay(alignment: .bottom) { floatingLayer }
        // Drop a file to attach it for the next question; drop an image and
        // it is read on-device (OCR) as context, the same path as ⌘⇧H. No
        // image is sent to the model, only the text read from it.
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .fileImporter(
            isPresented: $fileImporterPresented,
            allowedContentTypes: [.pdf, .plainText, .utf8PlainText, .text,
                                  UTType(filenameExtension: "md") ?? .plainText,
                                  UTType(filenameExtension: "markdown") ?? .plainText],
            allowsMultipleSelection: true,
            onCompletion: handleFileImport
        )
        // A draft typed during one meeting must not survive into the next:
        // an accidental ↩ would send stale text into the wrong conversation.
        .onReceive(NotificationCenter.default.publisher(for: .rtiSessionDidStop)) { _ in
            input = ""
            documents = []
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
        let maxHeight = line * CGFloat(HouseComposerMetrics.maxLines)
        return min(max(line, ceil(rect.height)), maxHeight)
    }

    private func updateInputFieldWidth(_ width: CGFloat) {
        guard abs(inputFieldWidth - width) > 1 else { return }
        inputFieldWidth = width
    }

    private func focusField() {
        // While the palette is open it owns the keys. The overlay asks for the
        // composer a runloop turn after the window becomes key, and again
        // 50 ms after `show()`, so an ungated request lands after the palette
        // has claimed focus and pulls typing out of its search field.
        guard !isPaletteOpen else { return }
        focusToken &+= 1
    }

    // MARK: Error above the row

    /// Errors that belong to no turn: a capture error, or a missing or bad
    /// key (with the fix-it). Turn errors stay in the thread.
    private var errorLine: ComposerErrorLine? {
        if let message = session.lastError, !message.isEmpty {
            return .init(message: message, fixTitle: session.lastErrorIsAuth ? "Open Settings" : nil)
        }
        if llm.lastErrorIsAuth, let message = llm.lastError, !message.isEmpty {
            return .init(message: message, fixTitle: "Open Settings")
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

    /// One read of the screen: ready ("Screen · once"), reading, or failed.
    private var screenChip: AttachmentChipModel? {
        if llm.pendingScreenContext != nil {
            return AttachmentChipModel(ref: ChatAttachmentRef(kind: .screen, name: "Screen"), id: Self.screenChipID)
        }
        guard let status = llm.screenCaptureStatus, !status.isEmpty else { return nil }
        // The capture posts its steps ("Reading all screens…") and, on a
        // failure, the reason; a step ends with an ellipsis.
        let isStep = status.hasSuffix("…")
        return AttachmentChipModel(
            id: Self.screenChipID,
            kind: .screen,
            name: "Screen",
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
            isStripFocused: focusedChipID.map { id in chipIDs.contains(id) } ?? false
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
        case .runPrimary: llm.sendPrimary()
        case .stop: stopStream()
        case .queued: break
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
                chooserIndex = 0
            } else {
                isAddContextOpen = false
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
        } else {
            isPaletteOpen = false
            addContextPage = .root
            chooserIndex = 0
            isAddContextOpen = true
        }
        focusField()
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
        case .mention: count = visibleMentionCandidates.count
        case .slash: count = visibleSlashCommands.count
        case .addContext: count = addContextRows.count
        case .palette, .none: count = 0
        }
        guard count > 0 else { return }
        chooserIndex = (chooserIndex + delta + count) % count
    }

    private func acceptChooser() {
        switch layer {
        case .mention:
            if let path = visibleMentionCandidates[safe: chooserIndex] { applyMention(path) }
        case .slash:
            if let command = visibleSlashCommands[safe: chooserIndex] {
                input = ""
                performSlashCommand(command.id)
            }
        case .addContext:
            if let row = addContextRows[safe: chooserIndex] { activate(row) }
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
                    hiddenRegistryIDs: ["note.toggle", "capture.screen"],
                    maxVisibleRows: 5
                )
                .frame(maxWidth: HouseChatMetrics.paletteWidth)
                .panelGlass(radius: House.Radius.lg)
                .panelShadows()
            }
            .padding(.trailing, House.Spacing.sm)
            .padding(.bottom, HouseComposerMetrics.rowHeight)
            .fixedSize(horizontal: false, vertical: true)
        case .addContext:
            HouseFloatingChooser {
                AddContextPane(
                    rows: addContextRows,
                    selectedIndex: chooserIndex,
                    title: addContextPage == .scope ? "Search Scope" : "Add Context",
                    isSubpage: addContextPage == .scope,
                    footnote: addContextPage == .root ? contextFootnote : nil,
                    onActivate: activate
                )
            }
            .padding(.bottom, HouseComposerMetrics.rowHeight)
            .fixedSize(horizontal: false, vertical: true)
        case .mention:
            HouseFloatingChooser {
                MentionChooserPane(candidates: visibleMentionCandidates, selectedIndex: chooserIndex, onPick: applyMention)
            }
            .padding(.bottom, HouseComposerMetrics.rowHeight)
            .fixedSize(horizontal: false, vertical: true)
        case .slash:
            HouseFloatingChooser {
                SlashChooserPane(commands: visibleSlashCommands, selectedIndex: chooserIndex) { command in
                    input = ""
                    performSlashCommand(command.id)
                    focusField()
                }
            }
            .padding(.bottom, HouseComposerMetrics.rowHeight)
            .fixedSize(horizontal: false, vertical: true)
        case .none:
            EmptyView()
        }
    }

    // MARK: Add Context

    private var addContextRows: [AddContextRow] {
        switch addContextPage {
        case .root:
            let scope = MeetingContextStore.shared.workstreamName ?? "Whole vault"
            return [
                AddContextRow(kind: .attachFile, symbol: "paperclip", title: "Attach File…",
                              detail: "PDF, Markdown, or text, for the next question"),
                AddContextRow(kind: .vaultFile, symbol: "at", title: "Vault File",
                              detail: "Type @ and part of a name"),
                AddContextRow(kind: .readScreen, symbol: "camera.viewfinder", title: "Read Screen Once",
                              detail: "Text read on this Mac; no image leaves it", keys: ["⌘", "⇧", "H"]),
                AddContextRow(kind: .searchScope, symbol: "scope", title: "Search Scope", detail: scope),
                AddContextRow(
                    kind: .noteMode,
                    symbol: "note.text",
                    title: inputState.isNoteMode ? "Back to Chat" : "Note Mode",
                    detail: session.isRunning ? "↩ adds a note to the transcript" : "↩ adds a prep note",
                    keys: ["⌘", "⌥", "N"]
                ),
            ]
        case .scope:
            let current = MeetingContextStore.shared.workstreamName
            let whole = AddContextRow(kind: .scope(id: nil), symbol: "archivebox", title: "Whole vault",
                                      detail: "Search every note", isCurrent: current == nil)
            return [whole] + scopeItems.map { scope in
                AddContextRow(
                    kind: .scope(id: scope.item.id),
                    symbol: scope.isClient ? "person.2" : "folder",
                    title: scope.item.name,
                    detail: scope.isClient ? "Client" : "Project",
                    isCurrent: current == scope.item.name
                )
            }
        }
    }

    /// "Next answer uses: Live transcript, Northwind app, Glossary".
    private var contextFootnote: String? {
        let labels = llm.contextPreviewLabels().filter { $0 != "Screen OCR" }
        guard !labels.isEmpty else { return nil }
        return "Next answer uses: " + labels.joined(separator: ", ")
    }

    /// Projects (8) then clients (6), read once when the page opens.
    private static func loadScopeItems() -> [ScopeItem] {
        VaultWorkstreamStore.projects().prefix(8).map { ScopeItem(item: $0, isClient: false) }
            + VaultWorkstreamStore.clients().prefix(6).map { ScopeItem(item: $0, isClient: true) }
    }

    private func activate(_ row: AddContextRow) {
        switch row.kind {
        case .attachFile:
            isAddContextOpen = false
            fileImporterPresented = true
        case .vaultFile:
            isAddContextOpen = false
            if !input.hasSuffix("@") {
                input += (input.isEmpty || input.hasSuffix(" ") ? "" : " ") + "@"
            }
        case .readScreen:
            isAddContextOpen = false
            ScreenshotManager.shared.captureAndAttach()
        case .searchScope:
            scopeItems = Self.loadScopeItems()
            addContextPage = .scope
            chooserIndex = 0
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
    /// actions (the primary one carries ⌘↩), then note mode, attach, one
    /// screen read, and the sticky recap depth (the old ✦ menu's items).
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
            title: "Attach File…",
            keywords: ["pdf", "document", "file", "attach", "markdown"],
            perform: { fileImporterPresented = true }
        ))
        rows.append(RTICommand(
            id: "composer.screen",
            title: "Read Screen Once",
            subtitle: "⌘⇧H",
            keywords: ["screen", "ocr", "capture", "screenshot"],
            perform: { ScreenshotManager.shared.captureAndAttach() }
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

    private func applyMention(_ path: String) {
        guard let at = input.lastIndex(of: "@") else { return }
        let prefix = input[..<at]
        input = String(prefix).trimmingCharacters(in: .whitespacesAndNewlines)
        if !selectedMentionPaths.contains(path) {
            selectedMentionPaths.append(path)
        }
        mentionSuggestions.update(query: nil, scopeRelativePath: nil)
        focusField()
    }

    private func inputWithSelectedMentions(_ text: String) -> String {
        guard !selectedMentionPaths.isEmpty else { return text }
        let mentions = selectedMentionPaths.map { "@\"\($0)\"" }.joined(separator: " ")
        return text.isEmpty ? mentions : "\(mentions) \(text)"
    }

    // MARK: Drop and import

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var took = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                took = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in dropFile(url) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                took = true
                provider.loadObject(ofClass: NSImage.self) { object, _ in
                    guard let image = object as? NSImage else { return }
                    Task { @MainActor in ScreenshotManager.shared.attachDroppedImage(image) }
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
        urls.forEach(addDocument)
    }

    /// Reads the file off the main thread; the chip says "Reading…" until
    /// then, and the reason if it fails.
    private func addDocument(_ url: URL) {
        let name = url.lastPathComponent
        // The same file twice is one chip; a failed read may be tried again.
        guard !documents.contains(where: { $0.name == name && !isFailed($0) }) else { return }
        documents.removeAll { $0.name == name }
        let item = ComposerDocument(name: name, phase: .reading)
        documents.append(item)
        Task {
            let phase: ComposerDocument.Phase
            do {
                let attachment = try await Task.detached(priority: .userInitiated) {
                    try ExternalDocumentLoader.load(url: url)
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
            guard !documents.contains(where: \.isReading) else { return }
            if text.hasPrefix("/") {
                if performSlashSubmit(String(text.dropFirst())) {
                    input = ""
                    selectedMentionPaths = []
                    documents = []
                }
                focusField()
                return
            }
            if !text.isEmpty { inputState.lastQuestion = text }
            llm.sendAskAnything(inputWithSelectedMentions(text), attachments: readyAttachments)
            input = ""
            selectedMentionPaths = []
            documents = []
            focusedChipID = nil
        }
    }

    @discardableResult
    private func performSlashSubmit(_ raw: String) -> Bool {
        let split = splitSlash(raw)
        if split.command == "note", !split.argument.isEmpty {
            if applyNoteModeArgument(split.argument) {
                return true
            }
            return submitLiveNote(split.argument)
        }
        return performSlashCommand(split.command, argument: split.argument)
    }

    @discardableResult
    private func performSlashCommand(_ raw: String, argument: String = "") -> Bool {
        guard let command = ComposerSlashCommand.command(named: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        switch command.id {
        case "assist":
            llm.sendAssist()
        case "answer":
            llm.sendAnswerLatest()
        case "say":
            llm.sendSaySomething()
        case "followups":
            llm.sendFollowupQuestions()
        case "recap":
            llm.sendRecap()
        case "summary":
            llm.sendSummary()
        case "note":
            if argument.isEmpty {
                inputState.mode = inputState.isNoteMode ? .chat : .liveNote
            } else if !applyNoteModeArgument(argument) {
                inputState.mode = .liveNote
            }
        case "chat":
            inputState.mode = .chat
        case "screen":
            ScreenshotManager.shared.captureAndAttach()
        case "recent":
            llm.sendAskAnything("What were the most recent meetings or sessions for this project? Use the recent meetings tool if project context is available.")
        case "search":
            llm.sendVaultSearchCommand(argument)
        case "sources":
            llm.sendVaultSourcesCommand(argument.isEmpty ? nil : argument)
        case "project":
            llm.runProjectCommand(argument)
        case "help":
            llm.showSlashHelp()
        case "new":
            AppDelegate.clearChatNow()
        default:
            return false
        }
        return true
    }

    private func splitSlash(_ raw: String) -> (command: String, argument: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let space = trimmed.firstIndex(where: { $0.isWhitespace }) else {
            return (trimmed.lowercased(), "")
        }
        let command = String(trimmed[..<space]).lowercased()
        let argument = String(trimmed[space...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (command, argument)
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
