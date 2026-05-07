import GRDB
import SwiftUI

struct SessionDetailView: View {
    let sessionId: String

    @State private var summary: SessionSummary?
    @State private var transcripts: [TranscriptEntry] = []
    @State private var chatMessages: [ChatMessage] = []
    @State private var session: Session?
    @State private var selectedTab: Tab = .summary
    @State private var qaInput = ""
    @State private var jumpToBottomToken = UUID()
    @AppStorage(RTIDesign.Density.storageKey) private var densityRaw: String = RTIDesign.Density.comfortable.rawValue

    @ObservedObject private var qaController = SessionQAController.shared
    @ObservedObject private var summaryController = SummaryController.shared
    @ObservedObject private var regenerator = TranscriptRegenerator.shared
    @StateObject private var toast = ToastPresenter()

    enum Tab: String, CaseIterable, CustomStringConvertible {
        case summary = "Summary"
        case transcript = "Transcript"
        case qa = "Q&A"
        case usage = "Usage"
        var description: String { rawValue }
    }

    private var density: RTIDesign.Density {
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
                } else {
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
        HStack(spacing: RTIDesign.Spacing.xxs) {
            Spacer()

            // Group 1 — utility
            HStack(spacing: RTIDesign.Spacing.xxs) {
                actionButton(label: "Copy", systemImage: "doc.on.doc", role: .utility, action: copySummary)
                actionButton(label: "Export", systemImage: "square.and.arrow.up", role: .utility, action: exportSession)
            }

            // Divider between utility + AI groups
            Rectangle()
                .fill(RTIDesign.Color.divider)
                .frame(width: 1, height: 20)
                .padding(.horizontal, RTIDesign.Spacing.xxs)

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
                            sectionBlock(title: "Summary", content: summaryParagraph, isFirst: true)
                        }
                        sectionBlockOptional(title: "Key Topics", content: summary.keyTopics)
                        sectionBlockOptional(title: "Decisions Made", content: summary.decisions)
                        sectionBlockOptional(title: "Action Items", content: summary.actionItems)
                        if let followUps = summary.followUps {
                            ForEach(splitFollowUps(followUps), id: \.title) { section in
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
                    generateSummary()
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

    private var groupedTranscripts: [TranscriptGroup] {
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
                        ForEach(groupedTranscripts) { group in
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
                    if let last = groupedTranscripts.last {
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            StickySubheader(
                title: "Transcript",
                count: "\(transcripts.count) entries · \(groupedTranscripts.count) paragraphs"
            ) {
                HStack(spacing: RTIDesign.Spacing.xs) {
                    densityToggleButton
                    Button("Jump to bottom") { jumpToBottomToken = UUID() }
                        .buttonStyle(.plain)
                        .font(RTIDesign.Font.meta.weight(.medium))
                        .foregroundStyle(RTIDesign.Color.accentText)
                        .disabled(groupedTranscripts.isEmpty)
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
        return VStack(alignment: .leading, spacing: RTIDesign.Spacing.xs) {
            HStack(spacing: RTIDesign.Spacing.sm) {
                SpeakerChip(raw: group.speakerId)
                timestampLink(ms: group.startMs)
                Spacer()
            }
            Text(group.text.trimmingCharacters(in: .whitespaces))
                .font(RTIDesign.Font.body)
                .italic(isNote)
                .foregroundStyle(RTIDesign.Color.textPrimary)
                .lineSpacing(density.scaled(4))
                .textSelection(.enabled)
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

    private func timestampLink(ms: Int) -> some View {
        // Wired as a button so future audio-scrub can land here without
        // restyling. For now, click logs and is otherwise a no-op.
        Button(action: {
            RTILog.log("[SessionDetail] timestamp tapped: \(ms)ms", category: "UI")
        }) {
            Text(timeLabel(ms: ms))
                .font(RTIDesign.Font.meta)
                .monospacedDigit()
                .foregroundStyle(RTIDesign.Color.textTertiary)
                .underline()
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
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
                .padding(.top, RTIDesign.Spacing.xxl + 36)
                .padding(.bottom, RTIDesign.Spacing.lg)
            }

            StickySubheader(title: "Usage", count: nil) {
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

    // MARK: - Section rendering

    /// Single rendering path for "title + markdown body" used by all summary
    /// sections. Pre-parses bullet lines so they show as proper bullets with
    /// hanging indent rather than literal `-` characters.
    private func sectionBlock(title: String, content: String, isFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: RTIDesign.Spacing.md) {
            SectionHeader(title)
            sectionBody(content)
        }
    }

    private func sectionBlockOptional(title: String, content: String?) -> some View {
        Group {
            if let raw = content, !isContentEmpty(raw) {
                sectionBlock(title: title, content: raw, isFirst: false)
            }
        }
    }

    private func isContentEmpty(_ raw: String) -> Bool {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty || normalized == "none" || normalized == "none."
    }

    /// Render markdown body as either a bulleted list (when most lines start
    /// with `-` or `*`) or a flowing paragraph (with inline markdown).
    @ViewBuilder
    private func sectionBody(_ raw: String) -> some View {
        let lines = raw.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let bulletLines = lines.filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }
        let isList = !lines.isEmpty && bulletLines.count >= max(1, lines.count - 1)

        if isList {
            VStack(alignment: .leading, spacing: density.scaled(RTIDesign.Spacing.xs)) {
                ForEach(Array(bulletLines.enumerated()), id: \.offset) { _, line in
                    let stripped = String(line.dropFirst(2))
                    HStack(alignment: .top, spacing: RTIDesign.Spacing.sm) {
                        Text("•")
                            .font(RTIDesign.Font.body)
                            .foregroundStyle(RTIDesign.Color.accentText)
                            .frame(width: 12, alignment: .leading)
                        Text(attributed(stripped))
                            .font(RTIDesign.Font.body)
                            .foregroundStyle(RTIDesign.Color.textPrimary)
                            .lineSpacing(density.scaled(4))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        } else {
            Text(attributed(raw))
                .font(RTIDesign.Font.body)
                .foregroundStyle(RTIDesign.Color.textPrimary)
                .lineSpacing(density.scaled(4))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func attributed(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    private struct FollowUpSection {
        let title: String
        let body: String
    }

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
        toast.show("Summary copied")
    }

    private func copyTranscript() {
        let text = transcripts.map { "\(SpeakerLabels.displayName(for: $0.speakerId)): \($0.text)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        toast.show("Transcript copied")
    }

    private func regenerateSummary() {
        Task {
            generateSummary()
            await MainActor.run { toast.show("Summary regenerated") }
        }
    }

    private func regenerateTranscript() {
        regenerator.regenerate(sessionId: sessionId)
        // Completion toast fires from the regenerator state observer above.
    }

    private func exportSession() {
        SessionExport.exportToFile(sessionId: sessionId)
    }

    private func generateSummary() {
        SummaryController.shared.generateSummary(for: sessionId)
        summary = SummaryController.shared.loadSummary(for: sessionId)
    }

    private func submitQA() {
        let question = qaInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        let capped = question.count > 4000 ? String(question.prefix(4000)) : question
        qaInput = ""
        if selectedTab != .qa {
            withAnimation(.easeInOut(duration: 0.18)) { selectedTab = .qa }
        }
        Task {
            qaController.ask(question: capped, sessionId: sessionId)
        }
    }

    private func resumeSession() {
        SessionCoordinator.shared.resumeSession(id: sessionId)
    }

    private func loadData() {
        // Corpus-backed reads: session metadata + transcript come from
        // markdown (or live JSONL for an in-flight session); chat history
        // remains in SQLite as the interaction log.
        session = CorpusBackedStore.session(id: sessionId)
        transcripts = CorpusBackedStore.transcripts(forSessionId: sessionId)
        summary = CorpusBackedStore.summary(forSessionId: sessionId)
            ?? SummaryController.shared.loadSummary(for: sessionId)
        do {
            chatMessages = try RTIDatabase.shared.pool.read { db in
                try ChatMessage
                    .filter(Column("session_id") == sessionId)
                    .order(Column("created_at"))
                    .fetchAll(db)
            }
        } catch {
            NSLog("[RTI] SessionDetail chat load failed: \(error)")
        }
    }

    private func timeLabel(ms: Int) -> String {
        TimeFormat.stampMs(ms)
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        TimeFormat.duration(interval)
    }
}
