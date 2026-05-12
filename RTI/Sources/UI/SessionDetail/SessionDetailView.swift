import GRDB
import SwiftUI

struct SessionDetailView: View {
    let sessionId: String
    /// Search query the user came from (typically command palette → session
    /// row). When non-nil, the view auto-selects the Transcript tab,
    /// highlights matched tokens in transcript text, and scrolls the first
    /// matching paragraph into view.
    let highlightQuery: String?

    @State var summary: SessionSummary?
    @State var transcripts: [TranscriptEntry] = []
    @State var chatMessages: [ChatMessage] = []
    @State var session: Session?
    @State var notes: [GeneratedNote] = []
    @State var dossiers: [EntityDossier] = []
    @State var cachedGroupedTranscripts: [TranscriptGroup] = []
    @State var cachedGroupedDossiers: [DetailDossierGroup] = []
    @State var selectedTab: Tab = .summary
    @State var qaInput = ""
    @State var jumpToBottomToken = UUID()
    @State var pendingHighlightScroll: Bool = false
    @AppStorage(RTIDesign.Density.storageKey) var densityRaw: String = RTIDesign.Density.comfortable.rawValue

    init(sessionId: String, highlightQuery: String? = nil) {
        self.sessionId = sessionId
        let trimmed = highlightQuery?.trimmingCharacters(in: .whitespaces)
        self.highlightQuery = (trimmed?.isEmpty ?? true) ? nil : trimmed
        // Default Transcript tab when arriving from a search — that's the
        // surface the user wanted to read.
        let initialTab: Tab = (trimmed?.isEmpty == false) ? .transcript : .summary
        _selectedTab = State(initialValue: initialTab)
        _pendingHighlightScroll = State(initialValue: trimmed?.isEmpty == false)
    }

    let qaController = SessionQAController.shared
    let summaryController = SummaryController.shared
    let regenerator = TranscriptRegenerator.shared
    @State var toast = ToastPresenter()

    enum Tab: String, CaseIterable, CustomStringConvertible {
        case summary = "Summary"
        case notes = "Notes"
        case transcript = "Transcript"
        case qa = "Q&A"
        case usage = "Details"
        var description: String { rawValue }
    }

    var density: RTIDesign.Density {
        RTIDesign.Density(rawValue: densityRaw) ?? .comfortable
    }

    private static let quickPrompts: [String] = [
        "Summarize the decisions",
        "What are the open questions?",
        "Draft a follow-up email"
    ]

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                // MARK: - Header
                headerBlock
                    .padding(.horizontal, RTIDesign.Spacing.xl)
                    .padding(.top, RTIDesign.Spacing.xl)

                // MARK: - Tabs
                RTISegmentedPicker(selection: $selectedTab, items: Tab.allCases)
                    .padding(.horizontal, RTIDesign.Spacing.xl)
                    .padding(.top, RTIDesign.Spacing.lg)
                    .padding(.bottom, RTIDesign.Spacing.sm)

                // MARK: - Body
                Group {
                    switch selectedTab {
                    case .summary:
                        summaryBody
                    case .notes:
                        notesAndEntitiesBody
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

            // Toast overlay (top-right of panel; non-interactive).
            ToastOverlay(presenter: toast)
        }
        .background(RTIDesign.Color.panelBackground)
        .task { loadData() }
        .onChange(of: sessionId) { _, _ in loadData() }
        .onChange(of: regenerator.generatingSessionId) { old, new in
            if old == sessionId && new == nil {
                loadData()
                toast.show("Transcript regenerated (Hi-Fi quality)")
            }
        }
        .onChange(of: selectedTab) { _, new in
            RTILog.log("[SessionDetail] tab=\(new.rawValue) density=\(density.rawValue)", category: "UI")
        }
        .onChange(of: transcripts) { _, _ in cachedGroupedTranscripts = computeGroupedTranscripts() }
        .onChange(of: dossiers) { _, _ in cachedGroupedDossiers = computeGroupedDossiers() }
        .onAppear {
            cachedGroupedTranscripts = computeGroupedTranscripts()
            cachedGroupedDossiers = computeGroupedDossiers()
        }
    }

    // MARK: - Header Block

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: RTIDesign.Spacing.sm) {
            metaLine
            Text(sessionTitle)
                .font(RTIDesign.Font.pageTitle)
                .foregroundStyle(RTIDesign.Color.textPrimary)
            if summary != nil {
                headerActionsRow
                    .padding(.top, RTIDesign.Spacing.xs)
            }
        }
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            backButton
            if let session = session {
                Text("·")
                    .foregroundStyle(RTIDesign.Color.textTertiary)
                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                if let endedAt = session.endedAt {
                    Text("·")
                    Text(formatDuration(endedAt.timeIntervalSince(session.startedAt)))
                } else if SessionCoordinator.shared.isRunning
                            && SessionCoordinator.shared.currentSessionId == session.id {
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
                if let quality = session.transcriptQuality {
                    Text("·")
                    transcriptQualityBadge(quality)
                }
            }
        }
        .font(RTIDesign.Font.meta)
        .foregroundStyle(RTIDesign.Color.textSecondary)
    }

    private func transcriptQualityBadge(_ quality: String) -> some View {
        let isHifi = quality == "hifi"
        return HStack(spacing: 4) {
            Image(systemName: isHifi ? "waveform.path.ecg" : "waveform")
                .font(.system(size: 9, weight: .semibold))
            Text(isHifi ? "Hi-Fi" : "Realtime")
        }
        .foregroundStyle(isHifi ? Color.green : Color.orange)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill((isHifi ? Color.green : Color.orange).opacity(0.12))
        )
        .accessibilityLabel("Transcript quality: \(isHifi ? "Hi-Fi" : "Realtime")")
    }

    private var sessionTitle: String {
        if let title = session?.calendarTitle, !title.isEmpty { return title }
        if let title = session?.title, !title.isEmpty { return title }
        return "Meeting Session"
    }

    private var backButton: some View {
        Button {
            NotificationCenter.default.post(name: .rtiShowSessionHistory, object: nil)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                Text("All Sessions")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(RTIDesign.Color.textSecondary)
    }

    /// Header action row, grouped: utility (Copy, Export) | AI ops (Regen Transcript, Regen Summary).
    private var headerActionsRow: some View {
        HStack(spacing: 0) {
            Spacer()

            // Group 1 — utility
            HStack(spacing: RTIDesign.Spacing.xxs) {
                actionButton(label: "Copy", systemImage: "doc.on.doc", role: .utility, action: copySummary)
                actionButton(label: "Export", systemImage: "square.and.arrow.up", role: .utility, action: exportSession)
            }

            // Divider between utility + AI groups
            Rectangle()
                .fill(RTIDesign.Color.divider)
                .frame(width: 1, height: 16)
                .padding(.horizontal, RTIDesign.Spacing.sm)

            // Group 2 — AI operations
            HStack(spacing: RTIDesign.Spacing.xxs) {
                if let session = session,
                   let wavPath = session.wavPath,
                   FileManager.default.fileExists(atPath: wavPath) {
                    let isRegen = regenerator.generatingSessionId == sessionId
                    let label: String = {
                        if isRegen { return "Regenerating…" }
                        if session.transcriptQuality == "hifi" { return "Re-Regenerate (Hi-Fi)" }
                        return "Hi-Fi Re-Transcript"
                    }()
                    actionButton(
                        label: label,
                        systemImage: isRegen ? "waveform.path.ecg" : "waveform",
                        role: .ai,
                        disabled: regenerator.isGenerating,
                        help: "Send the full recording to Soniox as a file for higher accuracy than the live realtime stream (uses tokens)",
                        action: regenerateTranscript
                    )
                }
                actionButton(
                    label: "Regenerate Summary",
                    systemImage: "arrow.triangle.2.circlepath",
                    role: .ai,
                    disabled: summaryController.isGenerating,
                    help: "Re-summarize this session (uses tokens)",
                    action: regenerateSummary
                )
            }
        }
    }

    private enum ActionRole { case utility, ai }

    @ViewBuilder
    private func actionButton(label: String, systemImage: String, role: ActionRole, disabled: Bool = false, help: String? = nil, action: @escaping () -> Void) -> some View {
        let tint: Color = (role == .utility) ? RTIDesign.Color.textPrimary : RTIDesign.Color.textSecondary
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                Text(label)
                    .font(RTIDesign.Font.button)
            }
            .foregroundStyle(disabled ? RTIDesign.Color.textTertiary : tint)
            .padding(.horizontal, 14)
            .frame(height: RTIDesign.Control.heightMd)
            .background(
                RoundedRectangle(cornerRadius: RTIDesign.Radius.sm)
                    .fill(Color.clear)
                    .contentShape(Rectangle())
            )
        }
        .buttonStyle(.plain)
        .focusable(true)
        .focusEffectDisabled()
        .disabled(disabled)
        .help(help ?? "")
    }

    // MARK: - Summary Body

    @ViewBuilder
    private var summaryBody: some View {
        if let summary = summary {
            ZStack(alignment: .top) {
                ScrollView {
                    VStack(alignment: .leading, spacing: density.scaled(RTIDesign.Spacing.xxxl)) {
                        let summaryParagraph = extractSummarySection(summary.rawResponse ?? summary.summaryText)
                        if !summaryParagraph.isEmpty {
                            sectionBody(summaryParagraph)
                        }
                        sectionBlockOptional(title: "Key Topics", content: summary.keyTopics)
                        sectionBlockOptional(title: "Decisions Made", content: summary.decisions)
                        sectionBlockOptional(title: "Action Items", content: summary.actionItems)
                        if let followUps = summary.followUps {
                            ForEach(splitFollowUps(followUps)) { section in
                                sectionBlock(title: section.title, content: section.body, isFirst: false)
                            }
                        }
                    }
                    .padding(.horizontal, RTIDesign.Spacing.xl)
                    .padding(.top, RTIDesign.Spacing.xxl + 36) // clear sticky subheader
                    .padding(.bottom, RTIDesign.Spacing.lg)
                    .readingWidth(720)
                }

                summaryStickySubheader
            }
        } else {
            ZStack(alignment: .top) {
                emptyState
                summaryStickySubheader
            }
        }
    }

    private var summaryStickySubheader: some View {
        StickySubheader(title: "Summary", count: nil) {
            HStack(spacing: RTIDesign.Spacing.xs) {
                densityToggleButton
                Button("Copy") { copySummary() }
                    .buttonStyle(.plain)
                    .font(RTIDesign.Font.meta.weight(.medium))
                    .foregroundStyle(RTIDesign.Color.accentText)
            }
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

    struct TranscriptGroup: Identifiable {
        let id: String
        let speakerId: String
        let startMs: Int
        let text: String
    }

    private func computeGroupedTranscripts() -> [TranscriptGroup] {
        var groups: [TranscriptGroup] = []
        var lastMergedEndMs: Int?
        for entry in transcripts {
            let gap = lastMergedEndMs.map { entry.startMs - $0 } ?? Int.max
            if let last = groups.last,
               last.speakerId == entry.speakerId,
               gap < 5000 {
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
            lastMergedEndMs = entry.endMs
        }
        return groups
    }

    private var transcriptBody: some View {
        ZStack(alignment: .top) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: density.scaled(RTIDesign.Spacing.lg)) {
                        if session?.transcriptQuality != "hifi",
                           let wavPath = session?.wavPath,
                           FileManager.default.fileExists(atPath: wavPath) {
                            realtimeQualityCallout
                        }
                        if let q = highlightQuery {
                            highlightBanner(query: q)
                        }
                        ForEach(cachedGroupedTranscripts) { group in
                            transcriptRow(group)
                                .id(group.id)
                        }
                    }
                    .padding(.horizontal, RTIDesign.Spacing.xl)
                    .padding(.top, RTIDesign.Spacing.xxl + 36)
                    .padding(.bottom, RTIDesign.Spacing.lg)
                    .readingWidth(880)
                }
                .onChange(of: jumpToBottomToken) { _, _ in
                    if let last = cachedGroupedTranscripts.last {
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: transcripts.count) { _, _ in
                    scrollToFirstHighlightMatch(using: proxy)
                }
                .onAppear { scrollToFirstHighlightMatch(using: proxy) }
            }

            StickySubheader(
                title: "Transcript",
                count: "\(transcripts.count) entries · \(cachedGroupedTranscripts.count) paragraphs"
            ) {
                HStack(spacing: RTIDesign.Spacing.xs) {
                    densityToggleButton
                    Button("Jump to bottom") { jumpToBottomToken = UUID() }
                        .buttonStyle(.plain)
                        .font(RTIDesign.Font.meta.weight(.medium))
                        .foregroundStyle(RTIDesign.Color.accentText)
                        .disabled(cachedGroupedTranscripts.isEmpty)
                    Button("Copy") { copyTranscript() }
                        .buttonStyle(.plain)
                        .font(RTIDesign.Font.meta.weight(.medium))
                        .foregroundStyle(RTIDesign.Color.accentText)
                }
            }
        }
    }

    private var realtimeQualityCallout: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
                .foregroundStyle(Color.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Realtime transcript")
                    .font(RTIDesign.Font.bodySmall.weight(.semibold))
                    .foregroundStyle(RTIDesign.Color.textPrimary)
                Text("This transcript was captured in realtime. Click \"Hi-Fi Re-Transcript\" in the header to reprocess the full recording for higher accuracy.")
                    .font(RTIDesign.Font.caption)
                    .foregroundStyle(RTIDesign.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: RTIDesign.Radius.sm)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: RTIDesign.Radius.sm)
                .stroke(Color.orange.opacity(0.2), lineWidth: 1)
        }
    }

    private func transcriptRow(_ group: TranscriptGroup) -> some View {
        let isNote = SpeakerLabels.isNote(group.speakerId)
        let groupPad = density.scaled(10)
        let trimmed = group.text.trimmingCharacters(in: .whitespaces)
        let paragraphed = isNote ? trimmed : Self.paragraphSplit(trimmed)
        let attr = TranscriptHighlight.attributed(paragraphed, query: highlightQuery)
        return VStack(alignment: .leading, spacing: RTIDesign.Spacing.xs) {
            HStack(spacing: RTIDesign.Spacing.sm) {
                SpeakerChip(raw: group.speakerId)
                timestampLink(ms: group.startMs)
                Spacer()
            }
            Text(attr)
                .font(RTIDesign.Font.body)
                .italic(isNote)
                .foregroundStyle(RTIDesign.Color.textPrimary)
                .lineSpacing(density.scaled(4))
                .textSelection(.enabled)
                .padding(.leading, isNote ? 0 : 20)
                .padding(isNote ? groupPad : 0)
                .background(
                    isNote
                    ? RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08))
                    : nil
                )
                .overlay(alignment: .leading) {
                    if isNote {
                        Rectangle()
                            .fill(Color.orange.opacity(0.5))
                            .frame(width: 2)
                    }
                }
        }
    }

    @ViewBuilder
    private func highlightBanner(query: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(RTIDesign.Color.accentText)
            Text("Showing matches for ").foregroundStyle(RTIDesign.Color.textSecondary)
                + Text("\u{201C}\(query)\u{201D}").foregroundStyle(RTIDesign.Color.textPrimary).fontWeight(.medium)
            Spacer()
        }
        .font(RTIDesign.Font.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: RTIDesign.Radius.sm)
                .fill(Color.yellow.opacity(0.10))
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: RTIDesign.Radius.sm)
                .stroke(Color.yellow.opacity(0.25), lineWidth: 1)
        }
    }

    private func scrollToFirstHighlightMatch(using proxy: ScrollViewProxy) {
        guard pendingHighlightScroll,
              let q = highlightQuery,
              !cachedGroupedTranscripts.isEmpty else { return }
        let texts = cachedGroupedTranscripts.map(\.text)
        guard let idx = TranscriptHighlight.firstMatchIndex(in: texts, query: q) else {
            // No transcript match — likely the hit was in summary/chat. Stop
            // trying so we don't keep scrolling on unrelated content updates.
            pendingHighlightScroll = false
            return
        }
        let target = cachedGroupedTranscripts[idx].id
        // Defer one runloop tick so the LazyVStack has rendered the row.
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.20)) {
                proxy.scrollTo(target, anchor: .center)
            }
            pendingHighlightScroll = false
        }
    }

    private func timestampLink(ms: Int) -> some View {
        // Renders as plain text — audio scrub-on-click isn't wired yet, so
        // do not show underline / pointer hand UI that would imply a
        // working link to the user.
        Text(timeLabel(ms: ms))
            .font(RTIDesign.Font.meta)
            .monospacedDigit()
            .foregroundStyle(RTIDesign.Color.textTertiary)
    }

    // MARK: - Q&A Body

    private var qaBody: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: density.scaled(RTIDesign.Spacing.lg)) {
                    if qaController.messages.isEmpty {
                        qaEmptyState
                    } else {
                        ForEach(qaController.messages) { msg in
                            MessageBubble(
                                role: msg.role == "user" ? .user : .assistant,
                                text: msg.text,
                                timestamp: msg.createdAt,
                                isPartial: qaController.isGenerating && msg.id == qaController.messages.last?.id && msg.role == "assistant"
                            )
                        }
                        if qaController.isGenerating, qaController.messages.last?.role == "user" {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.7)
                                Text("Thinking…")
                                    .font(RTIDesign.Font.caption)
                                    .foregroundStyle(RTIDesign.Color.textTertiary)
                            }
                            .accessibilityLabel("Generating answer")
                            .accessibilityAddTraits(.updatesFrequently)
                        }
                        if let error = qaController.lastError {
                            Text(error)
                                .font(RTIDesign.Font.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .padding(.horizontal, RTIDesign.Spacing.xl)
                .padding(.top, RTIDesign.Spacing.xxl + 36)
                .padding(.bottom, RTIDesign.Spacing.lg)
                .readingWidth(720)
            }

            StickySubheader(
                title: "Q&A",
                count: qaController.messages.isEmpty ? nil : "\(qaController.messages.count) messages"
            ) {
                HStack(spacing: RTIDesign.Spacing.xs) {
                    densityToggleButton
                    Button("Clear") { qaController.clear() }
                        .buttonStyle(.plain)
                        .font(RTIDesign.Font.meta.weight(.medium))
                        .foregroundStyle(RTIDesign.Color.accentText)
                        .disabled(qaController.messages.isEmpty)
                }
            }
        }
    }

    private var qaEmptyState: some View {
        VStack(alignment: .leading, spacing: RTIDesign.Spacing.md) {
            HStack {
                Spacer()
                VStack(spacing: RTIDesign.Spacing.sm) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 28))
                        .foregroundStyle(RTIDesign.Color.textTertiary)
                    Text("Ask anything about this meeting.")
                        .font(RTIDesign.Font.bodySmall)
                        .foregroundStyle(RTIDesign.Color.textSecondary)
                    Text("Scope: this session only")
                        .font(RTIDesign.Font.caption)
                        .foregroundStyle(RTIDesign.Color.textTertiary)
                }
                Spacer()
            }
            .padding(.vertical, RTIDesign.Spacing.lg)

            HStack(spacing: RTIDesign.Spacing.xs) {
                ForEach(Self.quickPrompts, id: \.self) { prompt in
                    QuickPromptChip(label: prompt) {
                        qaInput = prompt
                        submitQA()
                    }
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Usage Body

    private var notesAndEntitiesBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: density.scaled(RTIDesign.Spacing.xl)) {
                if notes.isEmpty && dossiers.isEmpty {
                    emptyState(
                        icon: "note.text",
                        title: "No notes yet",
                        subtitle: "Notes and entity dossiers generate every few minutes while a session is recording. Toggle them in Settings → Analysis."
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                }

                if !notes.isEmpty {
                    sectionHeader("Notes", count: notes.count, copyAll: copyAllNotes)
                    VStack(spacing: density.scaled(RTIDesign.Spacing.md)) {
                        ForEach(notes) { note in
                            sessionDetailNoteCard(note)
                        }
                    }
                }

                if !dossiers.isEmpty {
                    sectionHeader("Entities", count: dossiers.count, copyAll: copyAllDossiers)
                    VStack(alignment: .leading, spacing: density.scaled(RTIDesign.Spacing.md)) {
                        ForEach(cachedGroupedDossiers) { group in
                            sessionDetailDossierGroup(group)
                        }
                    }
                }
            }
            .padding(.horizontal, RTIDesign.Spacing.xl)
            .padding(.vertical, RTIDesign.Spacing.lg)
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String, count: Int, copyAll: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(RTIDesign.Font.sectionTitle)
                .foregroundStyle(RTIDesign.Color.textPrimary)
            Text("\(count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(RTIDesign.Color.textSecondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(RTIDesign.Color.cardBackground))
            Spacer()
            Button("Copy all", action: copyAll).controlSize(.small)
        }
    }

    @ViewBuilder
    private func sessionDetailNoteCard(_ note: GeneratedNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(note.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(RTIDesign.Color.textSecondary)
                Spacer()
                Button {
                    NSPasteboard.copyMarkdownRich(note.content)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copy this note (formatted for Word/Outlook)")
            }
            MarkdownView(note.content)
                .font(.system(size: 13))
                .foregroundStyle(RTIDesign.Color.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(RTIDesign.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(RTIDesign.Color.cardBackground))
    }

    struct DetailDossierGroup: Identifiable {
        let id = UUID()
        let type: EntityType
        let dossiers: [EntityDossier]
    }

    private func computeGroupedDossiers() -> [DetailDossierGroup] {
        Dictionary(grouping: dossiers) { $0.type }
            .map { DetailDossierGroup(type: $0.key, dossiers: $0.value) }
            .sorted { $0.type.displayName < $1.type.displayName }
    }

    @ViewBuilder
    private func sessionDetailDossierGroup(_ group: DetailDossierGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: group.type.icon)
                    .font(.system(size: 11))
                Text(group.type.displayName)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(RTIDesign.Color.textSecondary)

            ForEach(group.dossiers) { d in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(d.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(RTIDesign.Color.textPrimary)
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            NSPasteboard.copyString("\(d.name) — \(d.description)")
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .help("Copy this dossier")
                    }
                    Text(d.description)
                        .font(.system(size: 12))
                        .foregroundStyle(RTIDesign.Color.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(RTIDesign.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(RTIDesign.Color.cardBackground))
            }
        }
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(RTIDesign.Color.textSecondary)
            Text(title)
                .font(RTIDesign.Font.sectionTitle)
                .foregroundStyle(RTIDesign.Color.textPrimary)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(RTIDesign.Color.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
    }

    private func copyAllNotes() {
        let parts: [String] = notes.map { n in
            let when = n.timestamp.formatted(date: .omitted, time: .shortened)
            return "## \(when)\n\n\(n.content)"
        }
        NSPasteboard.copyMarkdownRich(parts.joined(separator: "\n\n---\n\n"))
    }

    private func copyAllDossiers() {
        let parts: [String] = cachedGroupedDossiers.map { group in
            let entries: [String] = group.dossiers.map { "**\($0.name)** — \($0.description)" }
            return "## \(group.type.displayName)\n\n\(entries.joined(separator: "\n\n"))"
        }
        NSPasteboard.copyMarkdownRich(parts.joined(separator: "\n\n"))
    }

    private var usageBody: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: density.scaled(RTIDesign.Spacing.xl)) {
                    if let session = session {
                        usageCard(title: "Session Info", icon: "info.circle") {
                            infoRow("Started", session.startedAt.formatted(date: .abbreviated, time: .shortened))
                            if let endedAt = session.endedAt {
                                infoRow("Ended", endedAt.formatted(date: .abbreviated, time: .shortened))
                                infoRow("Duration", formatDuration(endedAt.timeIntervalSince(session.startedAt)))
                            } else if SessionCoordinator.shared.isRunning
                                        && SessionCoordinator.shared.currentSessionId == session.id {
                                infoRow("Status", "Active")
                            } else {
                                infoRow("Status", "Ended")
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
                .padding(.top, RTIDesign.Spacing.xxl + 36)
                .padding(.bottom, RTIDesign.Spacing.lg)
            }

            StickySubheader(title: "Details", count: nil) {
                densityToggleButton
            }
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
        HStack(alignment: .firstTextBaseline, spacing: RTIDesign.Spacing.sm) {
            Text(label)
                .font(RTIDesign.Font.bodySmall)
                .foregroundStyle(RTIDesign.Color.textSecondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(RTIDesign.Font.bodySmall)
                .foregroundStyle(RTIDesign.Color.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Density toggle

    private var densityToggleButton: some View {
        Button(action: toggleDensity) {
            Image(systemName: density == .comfortable ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(RTIDesign.Color.textSecondary)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(density == .comfortable ? "Switch to compact density" : "Switch to comfortable density")
    }

    private func toggleDensity() {
        densityRaw = density == .comfortable ? RTIDesign.Density.compact.rawValue : RTIDesign.Density.comfortable.rawValue
    }

    // MARK: - Sticky Footer

    private var stickyFooter: some View {
        HStack(spacing: RTIDesign.Spacing.md) {
            if session?.endedAt != nil {
                Button(action: resumeSession) {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Resume Session")
                            .font(RTIDesign.Font.button)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: RTIDesign.Control.composerHeight - 8)
                    .background(
                        RoundedRectangle(cornerRadius: RTIDesign.Radius.lg)
                            .fill(RTIDesign.Color.accent)
                            .shadow(color: RTIDesign.Color.accent.opacity(0.25), radius: 6, y: 2)
                    )
                }
                .buttonStyle(.plain)
                .focusable(true)
                .focusEffectDisabled()
            }

            HStack(spacing: 0) {
                Button(action: { qaController.clear() }) {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(RTIDesign.Color.textTertiary)
                        .frame(width: 32, height: RTIDesign.Control.composerHeight - 8)
                }
                .buttonStyle(.plain)
                .disabled(qaController.messages.isEmpty)
                .help("Clear conversation")

                TextField("Ask about this meeting…", text: $qaInput)
                    .textFieldStyle(.plain)
                    .font(RTIDesign.Font.body)
                    .foregroundStyle(RTIDesign.Color.textPrimary)
                    .frame(height: RTIDesign.Control.composerHeight - 8)
                    .onSubmit { submitQA() }

                Button(action: submitQA) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: RTIDesign.Control.composerSendSize - 8, height: RTIDesign.Control.composerSendSize - 8)
                        .background(
                            Circle()
                                .fill(RTIDesign.Color.accent)
                                .shadow(color: RTIDesign.Color.accent.opacity(0.30), radius: 4, y: 1)
                        )
                }
                .buttonStyle(.plain)
                .focusable(true)
                .focusEffectDisabled()
                .accessibilityLabel("Send question")
                .padding(.trailing, 6)
                .disabled(qaInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || qaController.isGenerating)
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

}
