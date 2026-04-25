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

    enum Tab: String, CaseIterable {
        case summary = "Summary"
        case transcript = "Transcript"
        case usage = "Usage"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Tab", selection: $selectedTab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)

                Spacer()

                if let label = copedLabel {
                    Text(label)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            Group {
                switch selectedTab {
                case .summary:
                    summaryTab
                case .transcript:
                    transcriptTab
                case .usage:
                    usageTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { loadData() }
        .onChange(of: sessionId) { _ in loadData() }
    }

    // MARK: - Summary Tab

    @ViewBuilder
    private var summaryTab: some View {
        if let summary = summary {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryHeader(summary: summary)

                    summarySection(title: "Action Items", content: summary.actionItems, icon: "checklist")
                    summarySection(title: "Key Topics", content: summary.keyTopics, icon: "lightbulb")
                    summarySection(title: "Decisions", content: summary.decisions, icon: "hammer")
                    summarySection(title: "Follow-ups", content: summary.followUps, icon: "arrow.triangle.turn.up.right.diamond")
                }
                .padding(20)
            }
        } else {
            emptySummary
        }
    }

    private func summaryHeader(summary: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Meeting Summary")
                    .font(.title2.weight(.semibold))

                Spacer()

                HStack(spacing: 8) {
                    Button(action: copySummary) {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(action: regenerateSummary) {
                        Label("Regenerate", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(SummaryController.shared.isGenerating)
                }
            }

            if let regeneratedAt = summary.regeneratedAt {
                Text("Regenerated \(regeneratedAt, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 8)
    }

    private func summarySection(title: String, content: String?, icon: String) -> some View {
        guard let content = content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              content.trimmingCharacters(in: .whitespacesAndNewlines) != "None." else {
            return AnyView(EmptyView())
        }
        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: icon)
                    .font(.headline)

                let attributed = (try? AttributedString(markdown: content,
                                                         options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                    ?? AttributedString(content)
                Text(attributed)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .textBackgroundColor).opacity(0.3))
                    )
            }
        )
    }

    private var emptySummary: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)

            if SummaryController.shared.isGenerating {
                ProgressView("Generating summary…")
                    .font(.body)
            } else {
                Text("No summary yet")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Generate a summary from this session's transcript.")
                    .font(.body)
                    .foregroundStyle(.tertiary)

                Button("Generate Summary") {
                    Task { await generateSummary() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if let error = SummaryController.shared.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    // MARK: - Transcript Tab

    private var transcriptTab: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(transcripts.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button(action: copyTranscript) {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            List(transcripts) { entry in
                transcriptRow(entry)
            }
            .listStyle(.plain)
        }
    }

    private func transcriptRow(_ entry: TranscriptEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(entry.speakerId)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(speakerColor(entry.speakerId))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(speakerColor(entry.speakerId).opacity(0.15), in: RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)

                HStack(spacing: 6) {
                    Text(timeLabel(ms: entry.startMs))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)

                    if entry.confidence < 0.85 {
                        Text(String(format: "%.0f%% confidence", entry.confidence * 100))
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Usage Tab

    private var usageTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let session = session {
                    usageSection(title: "Session Info", icon: "info.circle") {
                        infoRow(label: "Started", value: session.startedAt.formatted(date: .abbreviated, time: .shortened))
                        if let endedAt = session.endedAt {
                            infoRow(label: "Ended", value: endedAt.formatted(date: .abbreviated, time: .shortened))
                            let duration = endedAt.timeIntervalSince(session.startedAt)
                            infoRow(label: "Duration", value: formatDuration(duration))
                        } else {
                            infoRow(label: "Status", value: "Active")
                        }
                        infoRow(label: "Transcript entries", value: "\(transcripts.count)")
                        infoRow(label: "Chat messages", value: "\(chatMessages.count)")
                    }
                }

                let screenCount = chatMessages.filter { $0.hadScreenContext }.count
                let transcriptMsgCount = chatMessages.filter { $0.hadTranscriptContext }.count

                if screenCount > 0 || transcriptMsgCount > 0 {
                    usageSection(title: "Context Usage", icon: "contextualmenu.and.cursorarrow") {
                        if screenCount > 0 {
                            infoRow(label: "Screenshots attached", value: "\(screenCount)")
                        }
                        if transcriptMsgCount > 0 {
                            infoRow(label: "Transcript context used", value: "\(transcriptMsgCount) times")
                        }
                    }
                }

                let userMsgs = chatMessages.filter { $0.role == "user" }
                if !userMsgs.isEmpty {
                    usageSection(title: "LLM Actions", icon: "brain") {
                        ForEach(userMsgs, id: \.id) { msg in
                            HStack {
                                Text(msg.action ?? "message")
                                    .font(.system(size: 12))
                                Spacer()
                                Text(msg.createdAt, style: .time)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 1)
                        }
                    }
                }

                if session?.wavPath != nil {
                    usageSection(title: "Audio", icon: "waveform") {
                        infoRow(label: "Recording", value: session?.wavPath ?? "N/A")
                    }
                }
            }
            .padding(20)
        }
    }

    private func usageSection<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                content()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.3))
            )
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12))
                .textSelection(.enabled)
        }
    }

    // MARK: - Actions

    private func copySummary() {
        guard let text = summary?.summaryText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flashCopied("Summary copied")
    }

    private func copyTranscript() {
        let text = transcripts.map { "\($0.speakerId): \($0.text)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flashCopied("Transcript copied")
    }

    private func regenerateSummary() {
        Task { await generateSummary() }
    }

    private func generateSummary() async {
        await SummaryController.shared.generateSummary(for: sessionId)
        summary = SummaryController.shared.loadSummary(for: sessionId)
    }

    private func loadData() {
        do {
            session = try RTIDatabase.shared.pool.read { db in
                try Session.fetchOne(db, key: sessionId)
            }
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

    // MARK: - Helpers

    private func speakerColor(_ id: String) -> Color {
        if id == "self" { return .blue }
        let palette: [Color] = [.orange, .green, .purple, .pink]
        if id.hasPrefix("them_"), let n = Int(id.dropFirst("them_".count)), n > 0 {
            return palette[(n - 1) % palette.count]
        }
        return .gray
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
        if mins > 0 {
            return "\(mins)m \(secs)s"
        }
        return "\(secs)s"
    }
}
