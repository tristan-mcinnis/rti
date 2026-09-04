import AppKit
import RTICore
import SwiftUI
import UniformTypeIdentifiers

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

private struct ComposerTextView: NSViewRepresentable {
    static let fontSize = House.TypeToken.Size.body
    static let verticalTextInset: CGFloat = 3

    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat = Self.fontSize
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .automatic

        let textView = ReturnHandlingTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.placeholder = placeholder
        textView.string = text
        textView.font = .systemFont(ofSize: fontSize)
        textView.placeholderFont = .systemFont(ofSize: fontSize)
        textView.placeholderColor = OverlayInk.nsColor(tier: .tertiary)
        textView.textColor = OverlayInk.nsColor(tier: .primary)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 0, height: Self.verticalTextInset)
        textView.insertionPointColor = House.NSColorToken.textPrimary
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ReturnHandlingTextView else { return }
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        textView.onSubmit = onSubmit
        textView.placeholder = placeholder
        if textView.string != text {
            textView.string = text
        }
        textView.font = .systemFont(ofSize: fontSize)
        textView.placeholderFont = .systemFont(ofSize: fontSize)
        textView.placeholderColor = OverlayInk.nsColor(tier: .tertiary)
        textView.textColor = OverlayInk.nsColor(tier: .primary)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }

    final class ReturnHandlingTextView: NSTextView {
        var onSubmit: (() -> Void)?
        var placeholder: String = "" {
            didSet { needsDisplay = true }
        }
        var placeholderFont: NSFont = .systemFont(ofSize: 14) {
            didSet { needsDisplay = true }
        }
        var placeholderColor: NSColor = OverlayInk.nsColor(tier: .tertiary) {
            didSet { needsDisplay = true }
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)

            guard string.isEmpty, !placeholder.isEmpty else { return }
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .font: placeholderFont,
                .foregroundColor: placeholderColor,
                .paragraphStyle: paragraphStyle,
            ]
            let x = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0)
            let y = textContainerInset.height
            let rect = NSRect(
                x: x,
                y: y,
                width: max(0, bounds.width - x),
                height: placeholderFont.ascender - placeholderFont.descender + placeholderFont.leading
            )
            placeholder.draw(in: rect, withAttributes: attributes)
        }

        override func keyDown(with event: NSEvent) {
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            if isReturn && !event.modifierFlags.contains(.shift) {
                onSubmit?()
                return
            }
            super.keyDown(with: event)
        }
    }
}

struct AssistantInputView: View {
    private enum ComposerMetrics {
        static let fontSize = House.TypeToken.Size.body
        static let iconFontSize = House.TypeToken.Size.body
        static let controlSize = House.Control.chip
        static let sendSize = House.Control.chip
        static let rowSpacing = House.Spacing.xxs + 2
        static let rowHorizontalPadding = House.Spacing.xs
        static let rowVerticalPadding: CGFloat = 7
        /// The house composer: a 52 px raised card at Radius.lg.
        static let minRowHeight = House.Control.composer
        static let textLeadingPadding = House.Spacing.xxs
        static let textVerticalInset: CGFloat = 3
        static let minTextHeight: CGFloat = 24
        static let maxTextHeight: CGFloat = 128
    }

    @State private var input: String = ""
    @State private var isDropTargeted = false
    @State private var selectedSlashIndex = 0
    @State private var selectedMentionIndex = 0
    @State private var selectedMentionPaths: [String] = []
    @State private var selectedAttachments: [ExternalDocumentAttachment] = []
    @State private var attachmentError: String?
    @State private var fileImporterPresented = false
    @State private var inputFieldWidth: CGFloat = 360
    @StateObject private var mentionSuggestions = MentionSuggestionStore()
    @FocusState private var isInputFocused: Bool
    @AppStorage(OverlayAppearanceDefaults.uiFontSizeKey) private var uiFontSize: Double = OverlayAppearanceDefaults.defaultUIFontSize
    private let llm = LLMController.shared
    private let modes = ModeStore.shared
    private let session = SessionCoordinator.shared
    private let inputState = OverlayInputState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showSlashCommands {
                slashCommandBar
            }

            if showMentionSuggestions {
                mentionBar
            }

            if shouldShowContextDashboard {
                contextDashboard
            }

            if !selectedMentionPaths.isEmpty || !selectedAttachments.isEmpty {
                selectedMentionChips
            }

            // One composer pill: ask for help, compose, choose an explicit
            // attachment or live-note target, then send. It deliberately has
            // no miscellaneous overflow menu.
            HStack(alignment: .center, spacing: ComposerMetrics.rowSpacing) {
                actionsMenu

                ComposerTextView(text: $input, placeholder: textFieldPrompt, fontSize: CGFloat(uiFontSize)) {
                    submit()
                }
                .focused($isInputFocused)
                .frame(height: composerInputHeight)
                .frame(maxWidth: .infinity)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { updateInputFieldWidth(proxy.size.width) }
                            .onChange(of: proxy.size.width) { _, width in updateInputFieldWidth(width) }
                    }
                )
                .padding(.leading, ComposerMetrics.textLeadingPadding)

                attachmentButton

                noteModeToggle

                if llm.streaming {
                    stopButton
                } else {
                    sendButton
                }
            }
            .padding(.leading, RTIDesign.Spacing.xs + 2)
            .padding(.trailing, ComposerMetrics.rowHorizontalPadding)
            .padding(.vertical, ComposerMetrics.rowVerticalPadding)
            .frame(minHeight: ComposerMetrics.minRowHeight)
            .slateRaisedCard(cornerRadius: RTIDesign.Radius.md)
            .overlay(
                RoundedRectangle(cornerRadius: RTIDesign.Radius.md, style: .continuous)
                    .strokeBorder(composerFocusStroke, lineWidth: composerFocusStroke == .clear ? 0 : 1.5)
            )
        }
        // Drop an image here → it's OCR'd on-device and attached as context for
        // the next message (same path as ⌘⇧H screen capture; no image is sent
        // to the model, only the extracted text).
        .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
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
        // A draft typed during one meeting must not survive into the next —
        // an accidental ⏎ would send stale text into the wrong conversation.
        .onReceive(NotificationCenter.default.publisher(for: .rtiSessionDidStop)) { _ in
            input = ""
            selectedAttachments = []
            if inputState.mode == .liveNote {
                inputState.mode = .chat
            }
        }
        // "Ask about this session" (Sessions browser) hands us a vault-relative
        // path to seed as an @mention, same shape as picking one from the
        // mention bar.
        .onReceive(NotificationCenter.default.publisher(for: .rtiSeedChatMention)) { notif in
            guard let path = notif.object as? String, !selectedMentionPaths.contains(path) else { return }
            selectedMentionPaths.append(path)
            inputState.mode = .chat
            DispatchQueue.main.async { isInputFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .rtiOverlayDidBecomeKey)) { _ in
            // Defer so the focus change lands after the panel finishes its
            // becomeKey transition; otherwise SwiftUI sometimes drops it.
            DispatchQueue.main.async {
                isInputFocused = true
                mentionSuggestions.prewarm()
                refreshMentionSuggestions()
            }
        }
        .onChange(of: input) { _, _ in
            selectedSlashIndex = 0
            selectedMentionIndex = 0
            refreshMentionSuggestions()
        }
        .onAppear {
            mentionSuggestions.prewarm()
            refreshMentionSuggestions()
        }
        .onMoveCommand { direction in
            if showMentionSuggestions {
                switch direction {
                case .down, .right: moveMentionSelection(1)
                case .up, .left: moveMentionSelection(-1)
                default: break
                }
            } else if showSlashCommands {
                switch direction {
                case .right: moveSlashSelection(1)
                case .left: moveSlashSelection(-1)
                default: break
                }
            }
        }
        .onKeyPress(.return) {
            submit()
            return .handled
        }
        .onKeyPress(.downArrow) {
            if showMentionSuggestions {
                moveMentionSelection(1)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.upArrow) {
            if showMentionSuggestions {
                moveMentionSelection(-1)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.rightArrow) {
            if showMentionSuggestions {
                moveMentionSelection(1)
                return .handled
            }
            if showSlashCommands {
                moveSlashSelection(1)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.leftArrow) {
            if showMentionSuggestions {
                moveMentionSelection(-1)
                return .handled
            }
            if showSlashCommands {
                moveSlashSelection(-1)
                return .handled
            }
            return .ignored
        }
    }

    /// Drop / note mode are the only states that repaint the composer edge, and
    /// both use a house token — never a raw blue or yellow.
    private var composerFocusStroke: Color {
        if isDropTargeted { return RTIDesign.Color.accent }
        if inputState.isNoteMode { return RTIDesign.Color.warning.opacity(0.5) }
        return .clear
    }

    private var contextDashboard: some View {
        HStack(spacing: 6) {
            let labels = llm.contextPreviewLabels().filter { $0 != "Screen OCR" }
            if !labels.isEmpty {
                Menu {
                    Section("Included in the next answer") {
                        ForEach(labels, id: \.self) { label in
                            Label(label, systemImage: "checkmark")
                        }
                    }
                    Section("Vault search scope") {
                        if let name = MeetingContextStore.shared.workstreamName {
                            Label(name, systemImage: "folder.fill")
                            Button("Use whole vault") {
                                MeetingContextStore.shared.clearWorkstream()
                                refreshMentionSuggestions()
                            }
                        } else {
                            Label("Whole vault", systemImage: "checkmark")
                        }
                    }
                    Section("Choose a project") {
                        ForEach(VaultWorkstreamStore.projects().prefix(8), id: \.id) { item in
                            Button(item.name) {
                                MeetingContextStore.shared.selectWorkstream(item)
                                refreshMentionSuggestions()
                            }
                        }
                    }
                    Section("Choose a client") {
                        ForEach(VaultWorkstreamStore.clients().prefix(6), id: \.id) { item in
                            Button(item.name) {
                                MeetingContextStore.shared.selectWorkstream(item)
                                refreshMentionSuggestions()
                            }
                        }
                    }
                } label: {
                    miniPill(contextSummary(labels), icon: "text.bubble", active: true)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("View what the next answer can use, or change its vault search scope")
            }

            if llm.pendingScreenContext != nil {
                Button {
                    llm.clearPendingScreenContext()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "camera.viewfinder")
                        Text("Screen · once")
                        Image(systemName: "xmark")
                    }
                    .font(RTIDesign.Font.meta)
                    .foregroundStyle(Color.overlayInkSecondary)
                    .padding(.horizontal, RTIDesign.Spacing.xs)
                    .frame(height: House.Control.keyCap + 2)
                    .background(
                        RoundedRectangle(cornerRadius: RTIDesign.Radius.chip, style: .continuous)
                            .fill(RTIDesign.Color.chipFill)
                    )
                }
                .buttonStyle(.plain)
                .help("Remove screen OCR from the next message")
            } else if let status = llm.screenCaptureStatus {
                miniPill(status, icon: "camera.viewfinder", active: true)
                    .foregroundStyle(screenStatusColor(status))
            }

            if llm.smartMode {
                miniPill("Smart", icon: "sparkles", active: true)
            }

            if let attachmentError {
                miniPill(attachmentError, icon: "exclamationmark.triangle", active: true)
                    .foregroundStyle(RTIDesign.Color.warning)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lineLimit(1)
    }

    private var shouldShowContextDashboard: Bool {
        !llm.contextPreviewLabels().filter { $0 != "Screen OCR" }.isEmpty
            || llm.pendingScreenContext != nil
            || llm.screenCaptureStatus != nil
            || attachmentError != nil
    }

    private var composerInputHeight: CGFloat {
        let text = input.isEmpty ? " " : input
        let width = max(120, inputFieldWidth - 8)
        let attr = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: CGFloat(uiFontSize))]
        )
        let rect = attr.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let fittedHeight = ceil(rect.height) + (ComposerMetrics.textVerticalInset * 2)
        return min(max(ComposerMetrics.minTextHeight, fittedHeight), ComposerMetrics.maxTextHeight)
    }

    private func updateInputFieldWidth(_ width: CGFloat) {
        guard abs(inputFieldWidth - width) > 1 else { return }
        DispatchQueue.main.async {
            inputFieldWidth = width
        }
    }

    private func contextSummary(_ labels: [String]) -> String {
        labels.count == 1 ? "Context · 1 source" : "Context · \(labels.count) sources"
    }

    private func screenStatusColor(_ status: String) -> Color {
        status.lowercased().contains("permission") || status.lowercased().contains("failed")
            ? RTIDesign.Color.warning
            : Color.overlayInkSecondary
    }

    private var showSlashCommands: Bool {
        input.hasPrefix("/") && !input.contains(" ") && !input.contains("\n")
    }

    private var currentMentionQuery: String? {
        guard let at = input.lastIndex(of: "@") else { return nil }
        let after = input[input.index(after: at)...]
        guard !after.contains("@"),
              !after.contains("\n"),
              after.first != "\"" else { return nil }
        return String(after).trimmingCharacters(in: .whitespaces)
    }

    private var showMentionSuggestions: Bool {
        currentMentionQuery != nil && !mentionSuggestions.candidates.isEmpty
    }

    private var visibleMentionCandidates: [String] {
        currentMentionQuery == nil ? [] : mentionSuggestions.candidates
    }

    private var mentionBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(visibleMentionCandidates.enumerated()), id: \.element) { idx, path in
                Button {
                    applyMention(path)
                } label: {
                    HStack(spacing: RTIDesign.Spacing.xs) {
                        SlateIconTile(systemName: "doc.text", size: House.Control.keyCap, glyphSize: 10)
                        Text(path)
                            .font(RTIDesign.Font.label)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(idx == selectedMentionIndex ? Color.overlayInk : Color.overlayInkSecondary)
                    .padding(.horizontal, RTIDesign.Spacing.xs)
                    .frame(height: RTIDesign.Control.heightSm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .slateRaisedTile(idx == selectedMentionIndex, cornerRadius: RTIDesign.Radius.sm)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 2)
    }

    private var selectedMentionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(selectedMentionPaths, id: \.self) { path in
                    HStack(spacing: 5) {
                        Image(systemName: "doc.text")
                            .font(.system(size: House.TypeToken.Size.micro, weight: .semibold))
                        Text(displayName(forMentionPath: path))
                            .font(.system(size: House.TypeToken.Size.caption, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            selectedMentionPaths.removeAll { $0 == path }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: House.TypeToken.Size.micro, weight: .bold))
                                .frame(width: 14, height: 14)
                        }
                        .buttonStyle(.plain)
                        .help("Remove file")
                    }
                    .foregroundStyle(Color.overlayInkSecondary)
                    .padding(.leading, RTIDesign.Spacing.xs)
                    .padding(.trailing, RTIDesign.Spacing.xxs + 1)
                    .frame(height: House.Control.keyCap + 4)
                    .background(
                        RoundedRectangle(cornerRadius: RTIDesign.Radius.chip, style: .continuous)
                            .fill(RTIDesign.Color.chipFill)
                            .overlay(
                                RoundedRectangle(cornerRadius: RTIDesign.Radius.chip, style: .continuous)
                                    .strokeBorder(RTIDesign.Color.border, lineWidth: House.hairline)
                            )
                    )
                    .help(path)
                }
                ForEach(selectedAttachments) { attachment in
                    HStack(spacing: 5) {
                        Image(systemName: "paperclip")
                            .font(.system(size: House.TypeToken.Size.micro, weight: .semibold))
                        Text(attachment.name)
                            .font(.system(size: House.TypeToken.Size.caption, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            selectedAttachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: House.TypeToken.Size.micro, weight: .bold))
                                .frame(width: 14, height: 14)
                        }
                        .buttonStyle(.plain)
                        .help("Remove attachment")
                    }
                    .foregroundStyle(Color.overlayInkSecondary)
                    .padding(.leading, RTIDesign.Spacing.xs)
                    .padding(.trailing, RTIDesign.Spacing.xxs + 1)
                    .frame(height: House.Control.keyCap + 4)
                    .background(
                        RoundedRectangle(cornerRadius: RTIDesign.Radius.chip, style: .continuous)
                            .fill(RTIDesign.Color.selectionFill)
                            .overlay(
                                RoundedRectangle(cornerRadius: RTIDesign.Radius.chip, style: .continuous)
                                    .strokeBorder(RTIDesign.Color.borderStrong, lineWidth: House.hairline)
                            )
                    )
                    .help("Attached for this message only")
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var slashCommandBar: some View {
        HStack(spacing: 5) {
            ForEach(Array(visibleSlashCommands.enumerated()), id: \.element.id) { idx, command in
                Button {
                    performSlashCommand(command.id)
                    input = ""
                    DispatchQueue.main.async { isInputFocused = true }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: command.symbol)
                        Text(command.label)
                    }
                    .font(RTIDesign.Font.meta)
                    .foregroundStyle(idx == selectedSlashIndex ? Color.overlayInk : Color.overlayInkSecondary)
                    .padding(.horizontal, RTIDesign.Spacing.xs)
                    .frame(height: House.Control.keyCap + 4)
                    .background(
                        RoundedRectangle(cornerRadius: RTIDesign.Radius.chip, style: .continuous)
                            .fill(idx == selectedSlashIndex ? RTIDesign.Color.selectionFill : RTIDesign.Color.chipFill)
                    )
                }
                .buttonStyle(.plain)
                .help(command.help)
            }
            Spacer(minLength: 0)
        }
    }

    private var visibleSlashCommands: [SlashCommand] {
        Array(filteredSlashCommands.prefix(6))
    }

    private var filteredSlashCommands: [SlashCommand] {
        let q = input.dropFirst().lowercased()
        guard !q.isEmpty else { return slashCommands }
        return slashCommands.filter { $0.id.contains(q) || $0.label.lowercased().contains(q) }
    }

    private var slashCommands: [SlashCommand] {
        [
            SlashCommand(id: "assist", label: "Assist", symbol: "sparkles", help: "Suggest what to do next"),
            SlashCommand(id: "answer", label: "Answer latest", symbol: "quote.bubble", help: "Answer the latest live question using project context"),
            SlashCommand(id: "say", label: "Say next", symbol: "wand.and.rays", help: "Draft a quick reply"),
            SlashCommand(id: "followups", label: "Follow-ups", symbol: "bubble.left.and.text.bubble.right", help: "Generate follow-up questions"),
            SlashCommand(id: "recap", label: "Recap", symbol: "arrow.clockwise", help: "Recap the recent conversation"),
            SlashCommand(id: "summary", label: "Summary", symbol: "doc.text", help: "Summarize the full session"),
            SlashCommand(id: "note", label: "Note", symbol: "note.text", help: "Toggle live note mode, or use /note <text>"),
            SlashCommand(id: "chat", label: "Chat", symbol: "text.bubble", help: "Exit note mode and return to chat"),
            SlashCommand(id: "screen", label: "Screen", symbol: "camera.viewfinder", help: "Attach screen OCR to the next message"),
            SlashCommand(id: "recent", label: "Recent", symbol: "calendar", help: "Ask about recent project meetings"),
            SlashCommand(id: "search", label: "Search", symbol: "doc.text", help: "Search the vault or selected project/client"),
            SlashCommand(id: "sources", label: "Sources", symbol: "text.page", help: "Show source hits for a query or last question"),
            SlashCommand(id: "project", label: "Project", symbol: "folder", help: "Show, set, or clear project/client context"),
            SlashCommand(id: "help", label: "Help", symbol: "questionmark.circle", help: "Show slash commands"),
            SlashCommand(id: "new", label: "New chat", symbol: "plus.message", help: "Clear the current chat"),
        ]
    }

    private func moveSlashSelection(_ delta: Int) {
        let count = visibleSlashCommands.count
        guard count > 0 else { return }
        selectedSlashIndex = (selectedSlashIndex + delta + count) % count
    }

    private func moveMentionSelection(_ delta: Int) {
        let count = visibleMentionCandidates.count
        guard count > 0 else { return }
        selectedMentionIndex = (selectedMentionIndex + delta + count) % count
    }

    private func refreshMentionSuggestions() {
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
        DispatchQueue.main.async { isInputFocused = true }
    }

    private func inputWithSelectedMentions(_ text: String) -> String {
        guard !selectedMentionPaths.isEmpty else { return text }
        let mentions = selectedMentionPaths.map { "@\"\($0)\"" }.joined(separator: " ")
        return text.isEmpty ? mentions : "\(mentions) \(text)"
    }

    private func displayName(forMentionPath path: String) -> String {
        let file = path.split(separator: "/").last.map(String.init) ?? path
        if file.count <= 34 { return file }
        return String(file.prefix(15)) + "…" + String(file.suffix(14))
    }

    private func miniPill(_ text: String, icon: String?, active: Bool) -> some View {
        SlateChip(height: House.Control.keyCap + 2, stroked: false) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: House.TypeToken.Size.caption, weight: .regular))
            }
            Text(text)
                .truncationMode(.tail)
        }
        .foregroundStyle(active ? Color.overlayInkSecondary : Color.overlayInkTertiary)
    }

    private var noteModeToggle: some View {
        Button {
            inputState.mode = inputState.isNoteMode ? .chat : .liveNote
            DispatchQueue.main.async {
                isInputFocused = true
            }
        } label: {
            Label("Note", systemImage: noteModeSymbol)
                .font(RTIDesign.Font.meta)
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, RTIDesign.Spacing.xs)
                .frame(height: ComposerMetrics.controlSize)
                .foregroundStyle(inputState.isNoteMode ? RTIDesign.Color.warning : Color.overlayInkSecondary)
                .background(
                    RoundedRectangle(cornerRadius: RTIDesign.Radius.chip, style: .continuous)
                        .fill(inputState.isNoteMode ? RTIDesign.Color.warning.opacity(0.12) : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: RTIDesign.Radius.chip, style: .continuous)
                                .strokeBorder(inputState.isNoteMode ? RTIDesign.Color.warning.opacity(0.4) : Color.clear,
                                              lineWidth: House.hairline)
                        )
                )
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(inputState.isNoteMode ? "Switch to chat mode" : "Switch to note mode")
        .help(noteModeHelpText)
    }

    /// Leading "✦" button contains assistant behavior only. Composer target
    /// (chat versus note) remains visible beside Send instead of hiding inside
    /// a second competing menu.
    private var actionsMenu: some View {
        Menu {
            // Mode-aware: the visible actions follow the active mode + listener
            // state (a fieldwork observer gets "Key tensions / What's unsaid /
            // Themes", not "What should I say"). One source of truth lives in
            // AssistantAction.all (RTICore).
            ForEach(llm.availableQuickActions()) { action in
                Button { llm.perform(actionID: action.id) } label: {
                    Label(actionLabel(action), systemImage: action.symbol)
                }
            }

            Divider()

            Menu("⌘⏎ runs: \(AssistantAction.byID(llm.primaryActionID)?.label ?? "Assist")") {
                ForEach(AssistantAction.primaryEligibleActions) { action in
                    Button {
                        llm.primaryActionID = action.id
                    } label: {
                        if llm.primaryActionID == action.id {
                            Label(action.label, systemImage: "checkmark")
                        } else {
                            Text(action.label)
                        }
                    }
                }
            }

            // How long ⌘⌥R (and the primary action, when set to Recap) runs.
            // Sticky default; one-shot brief/detailed live in the palette.
            Menu("Recap depth: \(llm.recapDepth.label)") {
                ForEach(RecapDepth.allCases, id: \.rawValue) { depth in
                    Button {
                        llm.recapDepth = depth
                    } label: {
                        if llm.recapDepth == depth {
                            Label(depth.label, systemImage: "checkmark")
                        } else {
                            Text(depth.label)
                        }
                    }
                }
            }

            Button { llm.listenerMode.toggle() } label: {
                if llm.listenerMode {
                    Label("Listener mode (I'm not speaking)", systemImage: "checkmark")
                } else {
                    Label("Listener mode (I'm not speaking)", systemImage: "ear")
                }
            }

            Button(action: applyFieldworkPreset) {
                Label("Fieldwork preset (interview + listener)", systemImage: "person.2.wave.2")
            }
            .help("Interview mode + listener mode + ⌘⏎ → Assist in one click; pick the project in Setup")

            Divider()

            Button { llm.smartMode.toggle() } label: {
                if llm.smartMode {
                    Label("Smart mode (slower, deeper)", systemImage: "checkmark")
                } else {
                    Label("Smart mode (slower, deeper)", systemImage: "sparkles")
                }
            }

        } label: {
            Image(systemName: "sparkles")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: ComposerMetrics.iconFontSize, weight: .regular))
                .foregroundStyle(llm.smartMode ? Color.overlayInk : Color.overlayInkSecondary)
                .frame(width: ComposerMetrics.controlSize, height: ComposerMetrics.controlSize)
                .slateRaisedTile(llm.smartMode, cornerRadius: RTIDesign.Radius.chip)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(Color.overlayInkSecondary)
        .frame(width: ComposerMetrics.controlSize, height: ComposerMetrics.controlSize)
        .accessibilityLabel("Assist actions")
        .accessibilityHint(llm.smartMode ? "Assist actions. Smart mode is on." : "Assist actions")
        .help(llm.smartMode ? "Assist actions · Smart on" : "Assist actions")
    }

    private var attachmentButton: some View {
        Button { fileImporterPresented = true } label: {
            Image(systemName: "paperclip")
                .font(.system(size: ComposerMetrics.iconFontSize, weight: .regular))
                .foregroundStyle(Color.overlayInkSecondary)
                .frame(width: ComposerMetrics.controlSize, height: ComposerMetrics.controlSize)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Attach file")
        .accessibilityHint("Attach a PDF, Markdown, or text file to the next message")
        .help("Attach file")
    }

    private var sendButton: some View {
        let isEmpty = input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedMentionPaths.isEmpty && selectedAttachments.isEmpty
        return Button(action: submit) {
            Image(systemName: "arrow.up")
                .font(.system(size: House.TypeToken.Size.bodySmall, weight: .bold))
                // A square ink tile: textPrimary fill, textInverse arrow.
                .foregroundStyle(isEmpty ? Color.overlayInkTertiary : Color.overlayInkInverse)
                .frame(width: ComposerMetrics.sendSize, height: ComposerMetrics.sendSize)
                .background(
                    RoundedRectangle(cornerRadius: RTIDesign.Radius.chip, style: .continuous)
                        .fill(isEmpty ? RTIDesign.Color.chipFill : RTIDesign.Color.textPrimary)
                )
        }
        .buttonStyle(.plain)
        .disabled(isEmpty || llm.streaming)
        .accessibilityLabel("Send message")
        .accessibilityHint("Send the current message")
        .help("Send message (return)")
    }

    private var stopButton: some View {
        Button(action: { llm.cancel() }) {
            Image(systemName: "stop.fill")
                .font(.system(size: House.TypeToken.Size.meta, weight: .semibold))
                .foregroundStyle(RTIDesign.Color.textInverse)
                .frame(width: ComposerMetrics.sendSize, height: ComposerMetrics.sendSize)
                .background(
                    RoundedRectangle(cornerRadius: RTIDesign.Radius.chip, style: .continuous)
                        .fill(RTIDesign.Color.danger)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop streaming")
        .accessibilityHint("Stop the current assistant response")
        .help("Stop streaming response")
    }

    private var textFieldPrompt: String {
        switch inputState.mode {
        case .liveNote:
            return session.isRunning ? "Quick transcript note" : "Prep note for this meeting"
        case .chat:
            return "Ask the vault, @file, or attach a PDF/text file"
        }
    }

    /// Menu label for a quick action: append "⌘⏎" when it's the bound primary,
    /// otherwise its own hotkey hint (if any). Hints mirror CommandPaletteFactory.
    private func actionLabel(_ action: AssistantAction) -> String {
        if action.id == llm.primaryActionID {
            return "\(action.label)  ⌘⏎"
        }
        let hint = action.hotkey?.display ?? ""
        return hint.isEmpty ? action.label : "\(action.label)  \(hint)"
    }

    /// One-click setup for sitting in on fieldwork (FGD/IDI as an observer):
    /// Interview mode + listener mode + ⌘⏎ bound to Assist. The workstream
    /// (project) still gets picked in Prepare — that's a per-meeting fact.
    private func applyFieldworkPreset() {
        if let interview = modes.modes.first(where: { $0.name.localizedCaseInsensitiveContains("interview") }) {
            modes.activeModeId = interview.id
        }
        llm.listenerMode = true
        llm.primaryActionID = "assist"
    }

    /// Load the first dropped image and hand it to ScreenshotManager for
    /// on-device OCR → attach as pending context. Returns true if we took it.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        if handleImageDrop(providers) { return true }
        return handleFileDrop(providers)
    }

    private func handleImageDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSImage.self) }) else {
            return false
        }
        provider.loadObject(ofClass: NSImage.self) { object, _ in
            guard let image = object as? NSImage else { return }
            Task { @MainActor in ScreenshotManager.shared.attachDroppedImage(image) }
        }
        return true
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in addAttachment(url) }
        }
        return true
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result else { return }
        urls.forEach(addAttachment)
    }

    private func addAttachment(_ url: URL) {
        do {
            let attachment = try ExternalDocumentLoader.load(url: url)
            guard !selectedAttachments.contains(where: { $0.name == attachment.name && $0.text == attachment.text }) else { return }
            selectedAttachments.append(attachment)
            attachmentError = nil
        } catch {
            attachmentError = error.localizedDescription
        }
    }

    private func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || (inputState.mode == .chat && (!selectedMentionPaths.isEmpty || !selectedAttachments.isEmpty)) else { return }
        switch inputState.mode {
        case .liveNote:
            if submitLiveNote(text) {
                input = ""
                selectedMentionPaths = []
                selectedAttachments = []
                inputState.mode = .chat
                DispatchQueue.main.async { isInputFocused = true }
            }
        case .chat:
            if showMentionSuggestions, let path = visibleMentionCandidates[safe: selectedMentionIndex] {
                applyMention(path)
                return
            }
            if text.hasPrefix("/") {
                if performSlashSubmit(String(text.dropFirst())) {
                    input = ""
                    selectedMentionPaths = []
                    selectedAttachments = []
                }
                DispatchQueue.main.async { isInputFocused = true }
                return
            }
            llm.sendAskAnything(inputWithSelectedMentions(text), attachments: selectedAttachments)
            input = ""
            selectedMentionPaths = []
            selectedAttachments = []
        }
    }

    @discardableResult
    private func performSlashSubmit(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let split = splitSlash(trimmed)
        if split.command == "note", !split.argument.isEmpty {
            if applyNoteModeArgument(split.argument) {
                return true
            }
            let noteText = split.argument
            return submitLiveNote(noteText)
        }

        if showSlashCommands, let command = visibleSlashCommands[safe: selectedSlashIndex] {
            return performSlashCommand(command.id)
        }

        return performSlashCommand(split.command, argument: split.argument)
    }

    @discardableResult
    private func performSlashCommand(_ raw: String, argument: String = "") -> Bool {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "assist":
            llm.sendAssist()
        case "answer", "latest":
            llm.sendAnswerLatest()
        case "say", "saynext":
            llm.sendSaySomething()
        case "followups", "followup":
            llm.sendFollowupQuestions()
        case "recap":
            llm.sendRecap()
        case "summary", "summarize":
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
        case "search", "grep", "rag":
            llm.sendVaultSearchCommand(argument)
        case "sources", "source":
            llm.sendVaultSourcesCommand(argument.isEmpty ? nil : argument)
        case "project", "client", "context":
            llm.runProjectCommand(argument)
        case "help", "?":
            llm.showSlashHelp()
        case "new", "clear":
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

    private var noteModeSymbol: String {
        switch inputState.mode {
        case .chat: return "note.text"
        case .liveNote: return "checkmark"
        }
    }

    private var noteModeHelpText: String {
        switch inputState.mode {
        case .liveNote:
            return session.isRunning
                ? "Transcript note mode on — next Enter inserts inline, then returns to chat"
                : "Prep note mode on — next Enter adds context for this meeting, then returns to chat"
        case .chat:
            return session.isRunning
                ? "Chat mode on — toggle to drop a quick note into the transcript"
                : "Chat mode on — toggle to add a prep note before recording"
        }
    }

    private func submitLiveNote(_ text: String) -> Bool {
        if session.isRunning {
            return session.insertNote(text)
        }
        return MeetingContextStore.shared.appendPrepNote(text)
    }
}

private struct SlashCommand: Identifiable {
    let id: String
    let label: String
    let symbol: String
    let help: String
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
