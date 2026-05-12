import SwiftUI

/// Cross-session "ask anything" surface. Conversational view over the
/// entire corpus — questions are answered using retrieved excerpts from
/// every recorded meeting, with citations back to the source session.
struct AskCorpusView: View {
    private let controller = AskCorpusController.shared
    @State private var input = ""
    @State private var showingHistory = false
    @State private var historyItems: [AskCorpusConversation] = []
    @State private var copyConfirmId: UUID?
    @State private var corpusSessionCount: Int = 0
    @FocusState private var inputFocused: Bool

    private let starterPrompts = [
        "What did I work on this week?",
        "Summarize my recent meetings.",
        "What open questions came up across all meetings?",
        "Which clients have I been discussing the most?"
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(RTIDesign.Color.border)

            if controller.messages.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                conversation
            }

            inputBar
        }
        .background(RTIDesign.Color.panelBackground)
        .onAppear { inputFocused = true }
        .task { corpusSessionCount = CorpusBackedStore.allMarkdownSessions().count }
    }

    // MARK: - Header

    private var askScopeSubtitle: String {
        let count = corpusSessionCount
        let base = "Scope: entire corpus (\(count) session\(count == 1 ? "" : "s"))"
        if controller.messages.isEmpty {
            return base + " · ask anything across every meeting you've recorded"
        }
        return base
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.conversationTitle ?? "Ask Your Corpus")
                    .font(RTIDesign.Font.pageTitle)
                    .foregroundStyle(RTIDesign.Color.textPrimary)
                    .lineLimit(1)
                Text(askScopeSubtitle)
                    .font(RTIDesign.Font.caption)
                    .foregroundStyle(RTIDesign.Color.textSecondary)
            }
            Spacer()
            headerActions
        }
        .padding(.horizontal, RTIDesign.Spacing.xl)
        .padding(.vertical, RTIDesign.Spacing.xl)
    }

    private var headerActions: some View {
        HStack(spacing: RTIDesign.Spacing.sm) {
            iconAction(systemName: "square.and.pencil", help: "New chat") {
                controller.newChat()
            }
            iconAction(systemName: "clock.arrow.circlepath", help: "History") {
                historyItems = AskCorpusHistoryStore.list()
                showingHistory = true
            }
            .popover(isPresented: $showingHistory, arrowEdge: .top) {
                historyPopover
            }
            if !controller.messages.isEmpty {
                Divider().frame(height: 14)
                iconAction(systemName: "doc.on.doc", help: "Copy conversation") {
                    copyConversation()
                }
                iconAction(systemName: "square.and.arrow.up", help: "Export as markdown") {
                    exportConversation()
                }
            }
        }
    }

    private func iconAction(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(RTIDesign.Color.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var historyPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Chat history")
                    .font(RTIDesign.Font.heading)
                    .foregroundStyle(RTIDesign.Color.textPrimary)
                Spacer()
                Text("\(historyItems.count)")
                    .font(RTIDesign.Font.caption)
                    .foregroundStyle(RTIDesign.Color.textTertiary)
            }
            .padding(.horizontal, RTIDesign.Spacing.md)
            .padding(.vertical, RTIDesign.Spacing.sm)
            Divider()
            if historyItems.isEmpty {
                Text("No past conversations yet.")
                    .font(RTIDesign.Font.caption)
                    .foregroundStyle(RTIDesign.Color.textTertiary)
                    .padding(RTIDesign.Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(historyItems) { item in
                            historyRow(item)
                            Divider().padding(.leading, RTIDesign.Spacing.md)
                        }
                    }
                }
                .frame(height: min(CGFloat(historyItems.count) * 56, 360))
            }
        }
        .frame(width: 360)
    }

    private func historyRow(_ item: AskCorpusConversation) -> some View {
        Button {
            controller.load(item)
            showingHistory = false
        } label: {
            HStack(alignment: .top, spacing: RTIDesign.Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(RTIDesign.Font.bodySmall.weight(.medium))
                        .foregroundStyle(RTIDesign.Color.textPrimary)
                        .lineLimit(1)
                    Text(item.updatedAt.formatted(date: .abbreviated, time: .shortened) +
                         " · \(item.messages.count) messages")
                        .font(RTIDesign.Font.caption)
                        .foregroundStyle(RTIDesign.Color.textTertiary)
                }
                Spacer()
                Button {
                    AskCorpusHistoryStore.delete(id: item.id)
                    historyItems = AskCorpusHistoryStore.list()
                    if controller.conversationId == item.id { controller.newChat() }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(RTIDesign.Color.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Delete this conversation")
            }
            .padding(.horizontal, RTIDesign.Spacing.md)
            .padding(.vertical, RTIDesign.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func copyConversation() {
        let md = controller.exportMarkdown()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
    }

    private func exportConversation() {
        let md = controller.exportMarkdown()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        let safe = (controller.conversationTitle ?? "Ask Corpus")
            .replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "\(safe).md"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? md.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: RTIDesign.Spacing.lg) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(RTIDesign.Color.textTertiary)
            Text("Ask anything about your meetings")
                .font(RTIDesign.Font.heading)
                .foregroundStyle(RTIDesign.Color.textSecondary)
            Text("RTI will search across every session and answer with citations.")
                .font(RTIDesign.Font.bodySmall)
                .foregroundStyle(RTIDesign.Color.textTertiary)
                .multilineTextAlignment(.center)

            VStack(spacing: RTIDesign.Spacing.xs) {
                ForEach(starterPrompts, id: \.self) { prompt in
                    Button {
                        input = prompt
                        submit()
                    } label: {
                        HStack {
                            Text(prompt)
                                .font(RTIDesign.Font.bodySmall)
                                .foregroundStyle(RTIDesign.Color.textPrimary)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(RTIDesign.Color.textTertiary)
                        }
                        .padding(.horizontal, RTIDesign.Spacing.md)
                        .padding(.vertical, RTIDesign.Spacing.sm)
                        .frame(maxWidth: 440)
                        .background(
                            RoundedRectangle(cornerRadius: RTIDesign.Radius.md)
                                .fill(RTIDesign.Color.inputBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: RTIDesign.Radius.md)
                                        .stroke(RTIDesign.Color.border, lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, RTIDesign.Spacing.sm)
        }
        .padding(.horizontal, RTIDesign.Spacing.xl)
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: RTIDesign.Spacing.lg) {
                    ForEach(controller.messages) { msg in
                        messageBubble(msg)
                            .id(msg.id)
                    }
                    if let error = controller.lastError {
                        Text(error)
                            .font(RTIDesign.Font.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, RTIDesign.Spacing.md)
                    }
                }
                .padding(.horizontal, RTIDesign.Spacing.xl)
                .padding(.vertical, RTIDesign.Spacing.lg)
                .frame(maxWidth: 880, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: controller.messages.count) { _, _ in
                if let last = controller.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func messageBubble(_ msg: AskCorpusController.Entry) -> some View {
        if msg.role == "user" {
            HStack {
                Spacer(minLength: 40)
                Text(msg.text)
                    .font(RTIDesign.Font.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, RTIDesign.Spacing.md)
                    .padding(.vertical, RTIDesign.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: RTIDesign.Radius.md)
                            .fill(Color.blue)
                    )
            }
        } else {
            VStack(alignment: .leading, spacing: RTIDesign.Spacing.sm) {
                HStack(alignment: .top, spacing: RTIDesign.Spacing.sm) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(RTIDesign.Color.accentText)
                        .padding(.top, 4)
                    assistantText(msg)
                        .font(RTIDesign.Font.body)
                        .foregroundStyle(RTIDesign.Color.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !msg.text.isEmpty {
                    HStack(spacing: RTIDesign.Spacing.sm) {
                        if !msg.citations.isEmpty {
                            citationChips(msg.citations)
                        }
                        Spacer()
                        copyMessageButton(msg)
                    }
                    .padding(.leading, 22)
                }
            }
        }
    }

    private func copyMessageButton(_ msg: AskCorpusController.Entry) -> some View {
        Button {
            let body = AskCorpusView.stripCitationTokens(msg.text)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body, forType: .string)
            copyConfirmId = msg.id
            let capturedId = msg.id
            Task { try? await Task.sleep(for: .seconds(1.4)); await MainActor.run { if copyConfirmId == capturedId { copyConfirmId = nil } } }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copyConfirmId == msg.id ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
                Text(copyConfirmId == msg.id ? "Copied" : "Copy")
                    .font(RTIDesign.Font.caption)
            }
            .foregroundStyle(RTIDesign.Color.textTertiary)
        }
        .buttonStyle(.plain)
        .help("Copy this answer")
    }

    /// Render the assistant body as Markdown. While the LLM is still
    /// streaming we show "Thinking…" or plain text to avoid re-parsing
    /// Markdown on every token. Once the message is complete we render
    /// the full parsed Markdown.
    @ViewBuilder
    private func assistantText(_ msg: AskCorpusController.Entry) -> some View {
        if msg.text.isEmpty && controller.isGenerating {
            Text("Thinking…")
                .foregroundStyle(RTIDesign.Color.textTertiary)
        } else {
            let stripped = Self.stripCitationTokens(msg.text)
            let isStreaming = controller.isGenerating && msg.id == controller.messages.last?.id
            if isStreaming {
                Text(stripped)
            } else {
                RTIMarkdown(stripped, style: .panel)
            }
        }
    }

    /// Remove inline `[Session Title]` cite tokens from the rendered body
    /// since the chips below already surface them. Keeps the prose clean
    /// without losing attribution.
    private static func stripCitationTokens(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\s*\[[^\[\]\n]{1,120}\]"#) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    private func citationChips(_ citations: [AskCorpusController.Citation]) -> some View {
        HStack(spacing: RTIDesign.Spacing.xs) {
            Text("Sources")
                .font(RTIDesign.Font.caption)
                .foregroundStyle(RTIDesign.Color.textTertiary)
            FlowLayout(spacing: 4) {
                ForEach(citations) { c in
                    Button {
                        NotificationCenter.default.post(name: .openSessionDetail, object: c.sessionId)
                    } label: {
                        Text(c.title)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(RTIDesign.Color.accentText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(RTIDesign.Color.accentText.opacity(0.10))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Open \(c.title)")
                }
            }
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(spacing: RTIDesign.Spacing.sm) {
            TextField("Ask about your meetings…", text: $input)
                .textFieldStyle(.plain)
                .font(RTIDesign.Font.body)
                .focused($inputFocused)
                .onSubmit { submit() }
                .padding(.horizontal, RTIDesign.Spacing.md)
                .frame(height: RTIDesign.Control.heightMd)
                .background(
                    RoundedRectangle(cornerRadius: RTIDesign.Radius.md)
                        .fill(RTIDesign.Color.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: RTIDesign.Radius.md)
                                .stroke(RTIDesign.Color.border, lineWidth: 1)
                        )
                )

            if controller.isGenerating {
                Button(action: { controller.stop() }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.red.opacity(0.85)))
                }
                .buttonStyle(.plain)
                .help("Stop generating")
            } else {
                Button(action: submit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle().fill(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                           ? Color.gray.opacity(0.35)
                                           : Color.blue)
                        )
                }
                .buttonStyle(.plain)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, RTIDesign.Spacing.xl)
        .padding(.vertical, RTIDesign.Spacing.md)
        .background(RTIDesign.Color.panelBackground)
    }

    private func submit() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        controller.ask(question: q)
        input = ""
    }
}

/// Lightweight wrap-flow layout for citation chips so a long list of
/// sources wraps to multiple rows instead of clipping.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = layout(rows: subviews, maxWidth: maxWidth)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = layout(rows: subviews, maxWidth: bounds.width)
        var y: CGFloat = bounds.minY
        for row in rows {
            var x: CGFloat = bounds.minX
            for (sub, size) in row.items {
                sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [(LayoutSubview, CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layout(rows subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            let proposedWidth = (rows[rows.count - 1].width == 0 ? 0 : rows[rows.count - 1].width + spacing) + size.width
            if proposedWidth > maxWidth, !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            rows[rows.count - 1].items.append((sub, size))
            rows[rows.count - 1].width += (rows[rows.count - 1].items.count == 1 ? 0 : spacing) + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
