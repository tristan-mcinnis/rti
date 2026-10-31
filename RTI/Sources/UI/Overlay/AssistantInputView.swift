import AppKit
import RTICore
import SwiftUI
import UniformTypeIdentifiers
import HouseDesign

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

// MARK: - Composer

struct AssistantInputView: View {
    enum AddContextPage { case root, scope }

    /// A project or client on the Search Scope page.
    struct ScopeItem {
        let item: VaultItem
        let isClient: Bool
    }

    @State var input: String
    @State var isDropTargeted: Bool
    @State var isQueued: Bool
    @State var chooserIndex: Int
    @State var selectedMentionPaths: [String]
    @State var documents: [ComposerDocument]
    @State var focusedChipID: String?
    @State var isPaletteOpen: Bool
    @State var paletteQuery = ""
    @State var isAddContextOpen: Bool
    @State var addContextPage: AddContextPage
    /// The Add Context pane's own search. Typing there narrows the rows and
    /// never touches the draft.
    @State var addContextQuery = ""
    /// Bumped to put the keys in the pane's search field when it opens or
    /// changes page.
    @State var addContextFocusToken = 0
    @State var scopeItems: [ScopeItem] = []
    /// The meetings and sessions the unified context chooser can reach, read
    /// once when a chooser opens.
    @State var contextMeetings: [VaultMeetings.Meeting] = []
    /// `esc` closed the `@` or `/` chooser for this exact draft; typing
    /// brings it back.
    @State var dismissedChooserDraft: String?
    @State var fileImporterPresented = false
    @State private var inputFieldWidth: CGFloat = 360
    @State private var focusToken = 0
    @StateObject var mentionSuggestions = MentionSuggestionStore()
    @AppStorage(OverlayAppearanceDefaults.uiFontSizeKey) private var uiFontSize: Double = OverlayAppearanceDefaults.defaultUIFontSize
    let llm: LLMController
    let session = SessionCoordinator.shared
    let inputState = OverlayInputState.shared
    private let streamingOverride: Bool?
    let seededCandidates: [String]?
    let seededMentionRows: [AddContextRow]?
    private let pendingImageOverride: Bool?
    private let savesToVaultOverride: Bool?
    private let broaderSearchOverride: Bool?
    private let routeOverride: ComposerRoutePreview?
    private let retainedNoticeOverride: String?
    private let retrievalNoticeOverride: String?
    private let vaultWithheldNoticeOverride: String?
    private let datedSourceNameOverride: String?
    let availableHeight: CGFloat

    init(availableHeight: CGFloat = CGFloat(OverlayAppearanceDefaults.defaultHeight), controller: LLMController = .shared) {
        self.init(seed: nil, availableHeight: availableHeight, controller: controller)
    }

    /// The composer in a state set up front. Render proofs only; the app
    /// uses `init()`.
    init(seed: ComposerRenderSeed?, availableHeight: CGFloat = CGFloat(OverlayAppearanceDefaults.defaultHeight), controller: LLMController = .shared) {
        self.llm = controller
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
        vaultWithheldNoticeOverride = seed.vaultWithheldNotice
        datedSourceNameOverride = seed.pendingDatedSourceName
    }

    // MARK: Derived state

    var isStreaming: Bool { streamingOverride ?? llm.streaming }

    /// The field's text size: `bodySmall` at the default text size, scaled
    /// with the user's text size setting (meeting legibility).
    private var fieldFontSize: CGFloat {
        House.TypeToken.Size.bodySmall * CGFloat(uiFontSize / OverlayAppearanceDefaults.defaultUIFontSize)
    }

    var readyAttachments: [ExternalDocumentAttachment] {
        documents.compactMap(\.attachment)
    }

    /// Wire ids of the sources this turn attaches itself: the tray chips and
    /// the `@` mentions. The controller adds the dated hand-over and the
    /// retained archive, and applies the same dedup the send does.
    var freshSourceIDs: [String] {
        readyAttachments.map(\.wireSourceID) + selectedMentionPaths
    }

    /// The subset of those ids that carries an image, so a source reattached
    /// in a comparison is counted once rather than once per copy.
    private var freshImageIDs: [String] {
        readyAttachments
            .filter { $0.normalizedImage?.data.isEmpty == false }
            .map(\.wireSourceID)
    }

    /// Images this turn would carry, resolved by the controller with the SAME
    /// fresh-vs-retained choice and the SAME dedup the send uses: a fresh source
    /// turn counts only its own images, a bare follow-up counts the retained
    /// archive, an explicit comparison counts both but a reattached source
    /// once. The preview route and the frozen route agree.
    private var pendingImageCount: Int {
        let screen = (pendingImageOverride ?? (llm.pendingScreenImage != nil)) ? 1 : 0
        return llm.chosenImageCount(
            question: input,
            freshSourceIDs: freshSourceIDs,
            freshImageIDs: freshImageIDs,
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
    var isBroaderSearch: Bool { broaderSearchOverride ?? llm.broaderSearchEnabled }

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
            vaultWithheldNotice: vaultWithheldNoticeOverride
                ?? llm.vaultWithheldNotice(question: input, freshSourceIDs: freshSourceIDs),
            savesToVault: savesToVault
        )
    }

    /// Chips `↩` sends: vault files and read documents.
    var hasSendableChips: Bool {
        !selectedMentionPaths.isEmpty || !readyAttachments.isEmpty
    }

    var attachmentStatus: ComposerAttachmentStatus {
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
    var currentMentionQuery: String? { ComposerMention.query(in: input) }

    /// A mention is being typed: the chooser opens on the `@` itself, before
    /// the vault list answers.
    private var isMentionQueryActive: Bool { currentMentionQuery != nil }

    var visibleMentionCandidates: [String] {
        currentMentionQuery == nil ? [] : mentionCandidates
    }

    var visibleSlashCommands: [ComposerSlashCommand] {
        ComposerSlashCommand.isChooserDraft(input) ? ComposerSlashCommand.matches(input) : []
    }

    var layer: ComposerLayer {
        if isPaletteOpen { return .palette }
        if isAddContextOpen { return .addContext }
        guard dismissedChooserDraft != input else { return .none }
        if isMentionQueryActive { return .mention }
        if !visibleSlashCommands.isEmpty { return .slash }
        return .none
    }

    // MARK: Body

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
            onFix: {
                if session.canRetryLiveTranscription && !session.lastErrorIsAuth { session.retryLiveTranscription() }
                else { SettingsWindowController.shared.show(pane: .providers) }
            },
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

    // Opaque stages bound type-checking cost while keeping the same view tree
    // and State owner throughout conversation, context, and draft changes.
    private var conversationLifecycleSurface: some View {
        composerSurface
        .onReceive(NotificationCenter.default.publisher(for: .rtiComposerWillSwitchConversation)) { note in
            guard (note.object as? LLMController) === llm else { return }
            isQueued = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .rtiComposerWillResetConversation)) { note in
            guard (note.object as? LLMController) === llm else { return }
            resetPendingConversation()
        }
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
    }

    private var contextLifecycleSurface: some View {
        conversationLifecycleSurface
        .onReceive(NotificationCenter.default.publisher(for: .rtiOverlayDidBecomeKey)) { _ in
            focusField()
            mentionSuggestions.prewarm()
            refreshMentionSuggestions()
        }
        .onChange(of: inputState.focusRequest) { _, _ in focusField() }
        // The pane filters the rows it already has and never reads the vault:
        // the vault is searched only by the `@` in the field.
        .onChange(of: addContextQuery) { _, _ in chooserIndex = 0 }
        // A chooser opens on the space it can reach: RTI's projects, clients
        // and recent meetings are read once, not on every keystroke.
        .onChange(of: layer) { _, newLayer in
            guard newLayer == .mention || newLayer == .addContext else { return }
            if scopeItems.isEmpty { scopeItems = Self.loadScopeItems() }
            if contextMeetings.isEmpty { contextMeetings = Self.loadContextMeetings() }
        }
        .onChange(of: inputState.paletteRequest) { _, _ in openPalette() }
    }

    var body: some View {
        contextLifecycleSurface
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

    /// The composer's own height: the dated chip row when one is pending, and
    /// the row itself. What the floating layers must leave room for, and what
    /// the field's own line budget is measured against.
    var composerChromeHeight: CGFloat {
        composerRowHeight + datedSourceChipHeight
    }

    var composerRowHeight: CGFloat {
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

    func focusField() {
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
            return .init(message: message, fixTitle: session.lastErrorIsAuth ? "Open Settings" : (session.canRetryLiveTranscription ? "Retry transcription" : nil))
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

}
