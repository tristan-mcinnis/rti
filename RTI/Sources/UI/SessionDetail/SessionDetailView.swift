import GRDB
import SwiftUI

struct SessionDetailView: View {
    let sessionId: String

    @State private var summary: SessionSummary?
    @State private var transcripts: [TranscriptEntry] = []
    @State private var chatMessages: [ChatMessage] = []
    @State private var session: Session?
    @State private var selectedTab: Tab = .summary
    @State private var copedLabel: String?
    @State private var qaInput = ""

    @ObservedObject private var qaController = SessionQAController.shared
    @ObservedObject private var summaryController = SummaryController.shared

    enum Tab: String, CaseIterable, CustomStringConvertible {
        case summary = "Summary"
        case transcript = "Transcript"
        case qa = "Q&A"
        case usage = "Usage"
        var description: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header
            headerBlock
                .padding(.horizontal, RTIDesign.Spacing.xl)
                .padding(.top, RTIDesign.Spacing.xl)

            // MARK: - Tabs
            RTISegmentedPicker(selection: $selectedTab, items: Tab.allCases)
                .padding(.horizontal, RTIDesign.Spacing.xl)
                .padding(.top, RTIDesign.Spacing.lg)

            Divider()
                .padding(.top, RTIDesign.Spacing.md)

            // MARK: - Body
            Group {
                switch selectedTab {
                case .summary:
                    summaryBody
                case .transcript:
                    transcriptBody
                case .qa:
                    qaBody
                case .usage:
                    usageBody
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // MARK: - Sticky Footer
            if session?.endedAt != nil || selectedTab == .qa {
                stickyFooter
            }
        }
        .background(RTIDesign.Color.panelBackground)
        .task { loadData() }
        .onChange(of: sessionId) { _, _ in loadData() }
        .onChange(of: selectedTab) { _, _ in copedLabel = nil }
    }

    // MARK: - Header Block

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: RTIDesign.Spacing.sm) {
            // Meta line
            metaLine

            // Title
            Text(sessionTitle)
                .font(RTIDesign.Font.pageTitle)
                .foregroundStyle(RTIDesign.Color.textPrimary)

            // Summary header actions (if summary exists)
            if summary != nil {
                headerActionsRow
                    .padding(.top, RTIDesign.Spacing.xs)
            }
        }
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            if let session = session {
                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                if let endedAt = session.endedAt {
                    Text("·")
                    Text(formatDuration(endedAt.timeIntervalSince(session.startedAt)))
                } else {
                    // Live ticker via TimelineView so the elapsed time updates
                    // without a manual Timer + @State. Refreshes every second.
                    TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
                        HStack(spacing: 6) {
                            Text("·")
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 7, height: 7)
                                Text("Active")
                                    .foregroundStyle(RTIDesign.Color.accentText)
                                Text("·")
                                Text(formatDuration(ctx.date.timeIntervalSince(session.startedAt)))
                                    .monospacedDigit()
                                    .foregroundStyle(RTIDesign.Color.accentText)
                            }
                        }
                    }
                }
                if let modeId = session.modeId,
                   let mode = ModeStore.shared.modes.first(where: { $0.id == modeId }) {
                    Text("·")
                    Text(mode.name)
                }
            }
        }
        .font(RTIDesign.Font.meta)
        .foregroundStyle(RTIDesign.Color.textSecondary)
    }

    private var sessionTitle: String {
        if let title = session?.calendarTitle, !title.isEmpty { return title }
        if let title = session?.title, !title.isEmpty { return title }
        return "Meeting Session"
    }

    private var headerActionsRow: some View {
        HStack(spacing: RTIDesign.Spacing.sm) {
            Spacer()

            // Copy
            Button(action: copySummary) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .font(RTIDesign.Font.button)
            .padding(.horizontal, 18)
            .frame(height: RTIDesign.Control.heightMd)

            // Regenerate
            Button(action: regenerateSummary) {
                Label("Regenerate", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless)
            .font(RTIDesign.Font.button)
            .padding(.horizontal, 18)
            .frame(height: RTIDesign.Control.heightMd)
            .disabled(summaryController.isGenerating)

            if copedLabel != nil {
                Text(copedLabel ?? "")
                    .font(RTIDesign.Font.caption)
                    .foregroundStyle(RTIDesign.Color.textSecondary)
            }
        }
    }

    // MARK: - Summary Body

    @ViewBuilder
    private var summaryBody: some View {
        if let summary = summary {
            ScrollView {
                VStack(alignment: .leading, spacing: RTIDesign.Spacing.xxl) {
                    let summaryParagraph = extractSummarySection(summary.rawResponse ?? summary.summaryText)
                    if !summaryParagraph.isEmpty {
                        summaryBlock(title: "Summary", content: summaryParagraph)
                    }
                    summarySection(title: "Key Topics", content: summary.keyTopics)
                    summarySection(title: "Decisions Made", content: summary.decisions)
                    summarySection(title: "Action Items", content: summary.actionItems)
                    // followUps is markdown containing "## Open Questions" + "## Next Steps".
                    // Split into the same heading-styled blocks rather than dumping raw markdown.
                    if let followUps = summary.followUps {
                        ForEach(splitFollowUps(followUps), id: \.title) { section in
                            summarySection(title: section.title, content: section.body)
                        }
                    }
                }
                .padding(.horizontal, RTIDesign.Spacing.xl)
                .padding(.vertical, RTIDesign.Spacing.lg)
            }
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: RTIDesign.Spacing.md) {
            if summaryController.isGenerating {
                ProgressView("Generating summary…")
                    .font(RTIDesign.Font.body)
                Button("Cancel") { summaryController.cancel() }
                    .controlSize(.small)
            } else {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 32))
                    .foregroundStyle(RTIDesign.Color.textTertiary)
                    .allowsHitTesting(false)
                Text("No summary yet")
                    .font(RTIDesign.Font.heading)
                    .foregroundStyle(RTIDesign.Color.textSecondary)
                Text("Generate a summary from this session's transcript.")
                    .font(RTIDesign.Font.bodySmall)
                    .foregroundStyle(RTIDesign.Color.textTertiary)
                Button("Generate Summary") {
                    Task { await generateSummary() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            if let error = summaryController.lastError {
                Text(error)
                    .font(RTIDesign.Font.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Transcript Body

    private struct TranscriptGroup: Identifiable {
        let id: String
        let speakerId: String
        let startMs: Int
        let text: String
    }

    /// Soniox finalizes transcripts in small chunks (1–3s windows). Rendering
    /// every chunk as its own card produces a visually fragmented "every line
    /// is a new card" view. Group consecutive entries from the same speaker
    /// when they're within ~5 seconds of each other into a single paragraph.
    private var groupedTranscripts: [TranscriptGroup] {
        var groups: [TranscriptGroup] = []
        for entry in transcripts {
            if let last = groups.last,
               last.speakerId == entry.speakerId,
               entry.startMs - (last.startMs + (last.text.count * 50)) < 5000 {
                let merged = TranscriptGroup(
                    id: last.id,
                    speakerId: last.speakerId,
                    startMs: last.startMs,
                    text: last.text + " " + entry.text
                )
                groups.removeLast()
                groups.append(merged)
            } else {
                groups.append(TranscriptGroup(
                    id: entry.id,
                    speakerId: entry.speakerId,
                    startMs: entry.startMs,
                    text: entry.text
                ))
            }
        }
        return groups
    }

    private var transcriptBody: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(transcripts.count) entries · \(groupedTranscripts.count) paragraphs")
                    .font(RTIDesign.Font.meta)
                    .foregroundStyle(RTIDesign.Color.textTertiary)
                Spacer()
                Button(action: copyTranscript) {
                    Text("Copy")
                        .font(RTIDesign.Font.meta)
                }
            }
            .padding(.horizontal, RTIDesign.Spacing.xl)
            .padding(.vertical, RTIDesign.Spacing.sm)

            List(groupedTranscripts) { group in
                transcriptRow(group)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .padding(.vertical, RTIDesign.Spacing.sm)
            }
            .listStyle(.plain)
            .padding(.horizontal, RTIDesign.Spacing.xl)
        }
    }

    private func transcriptRow(_ group: TranscriptGroup) -> some View {
        VStack(alignment: .leading, spacing: RTIDesign.Spacing.xs) {
            HStack(spacing: RTIDesign.Spacing.md) {
                Text(group.speakerId)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RTIDesign.Color.accentText)
                Text(timeLabel(ms: group.startMs))
                    .font(RTIDesign.Font.meta)
                    .foregroundStyle(RTIDesign.Color.textTertiary)
            }
            Text(group.text.trimmingCharacters(in: .whitespaces))
                .font(RTIDesign.Font.body)
                .foregroundStyle(RTIDesign.Color.textPrimary)
                .lineSpacing(4)
                .textSelection(.enabled)
        }
    }

    // MARK: - Q&A Body

    private var qaBody: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: RTIDesign.Spacing.md) {
                    ForEach(qaController.messages) { msg in
                        if msg.role == "user" {
                            HStack {
                                Spacer()
                                Text(msg.text)
                                    .font(RTIDesign.Font.bodySmall)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, RTIDesign.Spacing.md)
                                    .padding(.vertical, RTIDesign.Spacing.sm)
                                    .background(RTIDesign.Color.accent, in: RoundedRectangle(cornerRadius: RTIDesign.Radius.lg))
                            }
                        } else {
                            Text(msg.text)
                                .font(RTIDesign.Font.body)
                                .foregroundStyle(RTIDesign.Color.textPrimary)
                                .textSelection(.enabled)
                        }
                    }
                    if qaController.isGenerating, qaController.messages.last?.role == "user" {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.7)
                            Text("Thinking…")
                                .font(RTIDesign.Font.caption)
                                .foregroundStyle(RTIDesign.Color.textTertiary)
                        }
                    }
                    if let error = qaController.lastError {
                        Text(error)
                            .font(RTIDesign.Font.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, RTIDesign.Spacing.xl)
                .padding(.vertical, RTIDesign.Spacing.lg)
            }
        }
    }

    // MARK: - Usage Body

    private var usageBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RTIDesign.Spacing.xl) {
                if let session = session {
                    usageCard(title: "Session Info", icon: "info.circle") {
                        infoRow("Started", session.startedAt.formatted(date: .abbreviated, time: .shortened))
                        if let endedAt = session.endedAt {
                            infoRow("Ended", endedAt.formatted(date: .abbreviated, time: .shortened))
                            infoRow("Duration", formatDuration(endedAt.timeIntervalSince(session.startedAt)))
                        } else {
                            infoRow("Status", "Active")
                        }
                        infoRow("Transcript entries", "\(transcripts.count)")
                        infoRow("Chat messages", "\(chatMessages.count)")
                        if let modeId = session.modeId,
                           let mode = ModeStore.shared.modes.first(where: { $0.id == modeId }) {
                            infoRow("Mode", mode.name)
                        }
                        if let calendarTitle = session.calendarTitle, !calendarTitle.isEmpty {
                            infoRow("Calendar event", calendarTitle)
                        }
                    }
                }
                let screenCount = chatMessages.filter { $0.hadScreenContext }.count
                if screenCount > 0 {
                    usageCard(title: "Context", icon: "rectangle.on.rectangle") {
                        infoRow("Screenshots attached", "\(screenCount)")
                    }
                }
                if let wavPath = session?.wavPath {
                    usageCard(title: "Audio", icon: "waveform") {
                        infoRow("Recording", wavPath)
                        if FileManager.default.fileExists(atPath: wavPath) {
                            HStack {
                                Spacer()
                                Button("Reveal in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: wavPath)])
                                }
                                .controlSize(.small)
                            }
                        } else {
                            Text("File no longer exists at this path.")
                                .font(RTIDesign.Font.caption)
                                .foregroundStyle(RTIDesign.Color.textTertiary)
                        }
                    }
                }
            }
            .padding(.horizontal, RTIDesign.Spacing.xl)
            .padding(.vertical, RTIDesign.Spacing.lg)
        }
    }

    private func usageCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: RTIDesign.Spacing.sm) {
            Label(title, systemImage: icon)
                .font(RTIDesign.Font.heading)
            VStack(alignment: .leading, spacing: RTIDesign.Spacing.xxs) {
                content()
            }
        }
        .rtiCardStyle()
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(RTIDesign.Font.bodySmall)
                .foregroundStyle(RTIDesign.Color.textSecondary)
            Spacer()
            Text(value)
                .font(RTIDesign.Font.bodySmall)
                .foregroundStyle(RTIDesign.Color.textPrimary)
                .textSelection(.enabled)
        }
    }

    // MARK: - Sticky Footer

    private var stickyFooter: some View {
        HStack(spacing: RTIDesign.Spacing.sm) {
            if session?.endedAt != nil {
                Button(action: resumeSession) {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 16))
                        Text("Resume Session")
                            .font(RTIDesign.Font.button)
                    }
                    .frame(height: RTIDesign.Control.composerHeight - 8)
                    .padding(.horizontal, 24)
                }
                .buttonStyle(.borderless)
            }

            HStack(spacing: 0) {
                TextField("Ask about this meeting…", text: $qaInput)
                    .textFieldStyle(.plain)
                    .font(RTIDesign.Font.body)
                    .foregroundStyle(RTIDesign.Color.textPrimary)
                    .padding(.leading, RTIDesign.Spacing.lg)
                    .frame(height: RTIDesign.Control.composerHeight - 8)
                    .onSubmit { submitQA() }

                Button(action: submitQA) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: RTIDesign.Control.composerSendSize - 8, height: RTIDesign.Control.composerSendSize - 8)
                        .background(RTIDesign.Color.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .disabled(qaInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || qaController.isGenerating)

                Button(action: { qaController.clear() }) {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundStyle(RTIDesign.Color.textTertiary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, RTIDesign.Spacing.sm)
                .disabled(qaController.messages.isEmpty)
            }
            .background(
                RoundedRectangle(cornerRadius: RTIDesign.Radius.xl)
                    .fill(RTIDesign.Color.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: RTIDesign.Radius.xl)
                            .stroke(RTIDesign.Color.border, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
            )
        }
        .padding(.horizontal, RTIDesign.Spacing.xl)
        .padding(.vertical, RTIDesign.Spacing.sm)
    }

    // MARK: - Helpers

    private func summaryBlock(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: RTIDesign.Spacing.sm) {
            Text(title)
                .font(RTIDesign.Font.heading)
                .foregroundStyle(RTIDesign.Color.textPrimary)
            let attributed = (try? AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(content)
            Text(attributed)
                .font(RTIDesign.Font.body)
                .foregroundStyle(RTIDesign.Color.textPrimary)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func summarySection(title: String, content: String?) -> some View {
        guard let raw = content else { return AnyView(EmptyView()) }
        // Normalize so the LLM saying "None.", "none", "(none)" or "*None*"
        // all collapse to the same empty signal.
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty,
              normalized != "none",
              normalized != "none." else {
            return AnyView(EmptyView())
        }
        let content = raw
        return AnyView(
            VStack(alignment: .leading, spacing: RTIDesign.Spacing.sm) {
                Text(title)
                    .font(RTIDesign.Font.heading)
                    .foregroundStyle(RTIDesign.Color.textPrimary)
                let attributed = (try? AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(content)
                Text(attributed)
                    .font(RTIDesign.Font.body)
                    .foregroundStyle(RTIDesign.Color.textPrimary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        )
    }

    private struct FollowUpSection {
        let title: String
        let body: String
    }

    /// followUps comes back as concatenated markdown like:
    ///   ## Open Questions
    ///   - foo
    ///   ## Next Steps
    ///   - bar
    /// Split it on `## ` headings so each lands in its own styled block.
    private func splitFollowUps(_ raw: String) -> [FollowUpSection] {
        let lines = raw.components(separatedBy: "\n")
        var sections: [FollowUpSection] = []
        var currentTitle: String?
        var currentBody: [String] = []
        func flush() {
            if let title = currentTitle {
                let body = currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                sections.append(FollowUpSection(title: title, body: body))
            }
            currentTitle = nil
            currentBody = []
        }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                flush()
                currentTitle = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if currentTitle != nil {
                currentBody.append(line)
            }
        }
        flush()
        return sections
    }

    private func extractSummarySection(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## Summary" }) else {
            return text
        }
        let contentStart = start + 1
        guard let end = lines[contentStart...].firstIndex(where: { $0.hasPrefix("## ") }) else {
            return lines[contentStart...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return lines[contentStart..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Actions

    private func copySummary() {
        guard let text = summary?.summaryText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flashCopied("Copied")
    }

    private func copyTranscript() {
        let text = transcripts.map { "\($0.speakerId): \($0.text)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flashCopied("Copied")
    }

    private func regenerateSummary() {
        Task { await generateSummary() }
    }

    private func generateSummary() async {
        await SummaryController.shared.generateSummary(for: sessionId)
        summary = SummaryController.shared.loadSummary(for: sessionId)
    }

    private func submitQA() {
        let question = qaInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        // Hard cap so a pasted essay doesn't bounce off DeepSeek as a 400.
        let capped = question.count > 4000 ? String(question.prefix(4000)) : question
        qaInput = ""
        // If the user typed a question while looking at Summary/Transcript/Usage,
        // jump them to the Q&A tab so they actually see the answer stream in.
        if selectedTab != .qa {
            withAnimation(.easeInOut(duration: 0.18)) { selectedTab = .qa }
        }
        Task {
            await qaController.ask(question: capped, sessionId: sessionId)
        }
    }

    private func resumeSession() {
        SessionCoordinator.shared.resumeSession(id: sessionId)
    }

    private func loadData() {
        do {
            session = try RTIDatabase.shared.pool.read { db in try Session.fetchOne(db, key: sessionId) }
            transcripts = try RTIDatabase.shared.pool.read { db in
                try TranscriptEntry
                    .filter(Column("session_id") == sessionId)
                    .filter(Column("is_final") == 1)
                    .order(Column("start_ms"))
                    .fetchAll(db)
            }
            chatMessages = try RTIDatabase.shared.pool.read { db in
                try ChatMessage
                    .filter(Column("session_id") == sessionId)
                    .order(Column("created_at"))
                    .fetchAll(db)
            }
            summary = SummaryController.shared.loadSummary(for: sessionId)
        } catch {
            NSLog("[RTI] SessionDetail loadData failed: \(error)")
        }
    }

    private func flashCopied(_ text: String) {
        copedLabel = text
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { copedLabel = nil }
        }
    }

    private func timeLabel(ms: Int) -> String {
        let seconds = ms / 1000
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let mins = Int(interval) / 60
        let secs = Int(interval) % 60
        if mins > 0 { return "\(mins)m \(secs)s" }
        return "\(secs)s"
    }
}
