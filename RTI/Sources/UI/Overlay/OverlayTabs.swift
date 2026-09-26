import AppKit
import RTICore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Transcript

struct TranscriptTabView: View {
    private let session = SessionCoordinator.shared
    @AppStorage(TranslationDefaults.enabledKey) private var translationEnabled = false
    @AppStorage(TranslationDefaults.modeKey) private var translationMode = "one_way"
    @AppStorage(TranslationDefaults.targetLanguageKey) private var targetLanguage = "en"
    @AppStorage(TranslationDefaults.languageAKey) private var languageA = "en"
    @AppStorage(TranslationDefaults.languageBKey) private var languageB = "zh"
    @State private var paragraphs: [LiveTranscriptPresentation.Row] = []
    /// Live speaker names (click a name to set one). Rows are rebuilt when a
    /// name changes, so the label and the copied text both use it.
    private let speakerNames = SpeakerNameStore.shared

    private static let languageOptions: [(code: String, label: String)] = [
        ("en", "English"), ("zh", "Chinese"), ("es", "Spanish"), ("fr", "French"),
        ("de", "German"), ("ja", "Japanese"), ("ko", "Korean"), ("pt", "Portuguese"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            // The strip lines up with the tabs row. The captured-time clock
            // is the header's record chip; it is not repeated here.
            OverlayTabStrip {
                HStack(spacing: House.Spacing.xs) {
                    SlateStatusDot(color: healthColor)
                    Text(healthLabel)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Transcription: \(healthLabel)")
            } trailing: {
                translateControl
                OverlayToolbarButton(icon: "doc.on.doc", help: "Copy transcript", disabled: session.liveEntries.isEmpty) {
                    NSPasteboard.copyString(transcriptText())
                }
            }
            if let notice = session.systemAudioNotice {
                Text(notice).font(House.TypeToken.caption).foregroundStyle(House.ColorToken.warning)
            }
            if session.liveEntries.isEmpty {
                overlayEmptyHints([
                    overlayRecordHint(),
                    "What you say shows on the right, everyone else on the left",
                    "Click a speaker to give them a name",
                ])
            } else {
                LiveTranscriptList(rows: paragraphs, showTranslations: translationEnabled)
            }
        }
        // SessionCoordinator observes UserDefaults and is the sole writer of
        // `translationConfig`. The view only reads the same defaults keys for
        // its controls; it no longer pushes config directly.
        .onAppear { paragraphs = makeParagraphs() }
        .onChange(of: session.liveEntries.count) { _, _ in paragraphs = makeParagraphs() }
        .onChange(of: session.liveEntries.last?.id) { _, _ in paragraphs = makeParagraphs() }
        .onChange(of: translationEnabled) { _, _ in paragraphs = makeParagraphs() }
        .onChange(of: speakerNames.names) { _, _ in paragraphs = makeParagraphs() }
    }

    // MARK: - Translation control

    private var translateControl: some View {
        HStack(spacing: 4) {
            Button {
                translationEnabled.toggle()
            } label: {
                HStack(spacing: HouseChatMetrics.chipGap) {
                    Image(systemName: "globe").font(House.TypeToken.caption)
                    Text(translationEnabled ? pillLabel : "Translate")
                        .font(House.TypeToken.meta)
                }
                .foregroundStyle(translationEnabled ? House.ColorToken.textPrimary : House.ColorToken.textSecondary)
                .padding(.horizontal, House.Spacing.xs)
                .frame(height: House.Control.chip)
                .background(
                    RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                        .fill(translationEnabled ? House.ColorToken.selectionFill : House.ColorToken.chipFill)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(translationEnabled ? "Turn translation off" : "Turn translation on")
            .help(translationEnabled ? "Translation is on. It shows under each line." : "Translate the transcript inline")

            if translationEnabled {
                Menu {
                    Picker("Mode", selection: $translationMode) {
                        Text("One-way (all into one language)").tag("one_way")
                        Text("Two-way (between two languages)").tag("two_way")
                    }
                    Divider()
                    if translationMode == "two_way" {
                        Picker("From", selection: $languageA) { languageItems }
                        Picker("To", selection: $languageB) { languageItems }
                    } else {
                        Picker("Target", selection: $targetLanguage) { languageItems }
                    }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: House.TypeToken.Size.micro, weight: .semibold))
                        .foregroundStyle(Color.overlayInkTertiary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 14)
                .accessibilityLabel("Translation mode and languages")
                .help("Translation mode and languages")
            }
        }
    }

    private var languageItems: some View {
        ForEach(Self.languageOptions, id: \.code) { opt in
            Text(opt.label).tag(opt.code)
        }
    }

    private var pillLabel: String {
        translationMode == "two_way"
            ? "\(languageA.uppercased())↔\(languageB.uppercased())"
            : languageLabel(targetLanguage)
    }

    // MARK: - Speaker turns (one stream, coalesced by speaker)

    /// Build the transcript as speaker turns, merging each speaker's consecutive
    /// fragments into one run. Each turn keeps BOTH its original and its
    /// translation text; the run shows the translation under the original when
    /// translating, so turning translation on mid-session never erases the
    /// (untranslated) history before it.
    ///
    /// Labels are stable per speaker id (`LiveTranscriptPresentation.label`):
    /// "You" for the mic wearer, "Speaker N" for the call's voices, and any
    /// name the user gave.
    ///
    /// Cached in `@State` and rebuilt only when `liveEntries` changes, so long
    /// transcripts don't re-coalesce on every SwiftUI render.
    private func makeParagraphs() -> [LiveTranscriptPresentation.Row] {
        LiveTranscriptPresentation.rows(
            from: session.liveEntries,
            showTranslations: translationEnabled,
            names: speakerNames.names
        )
    }

    private func languageLabel(_ code: String) -> String {
        Self.languageOptions.first { $0.code == code }?.label ?? code.uppercased()
    }

    private func transcriptText() -> String {
        LiveTranscriptPresentation.copyText(rows: paragraphs, showTranslations: translationEnabled)
    }

    private var healthColor: Color {
        if session.isPaused { return RTIDesign.Color.warning }
        guard session.isRunning else { return Color.overlayInkTertiary }
        switch session.transcriptionHealth {
        case .live: return RTIDesign.Color.success
        case .connecting, .reconnecting: return RTIDesign.Color.warning
        case .failed, .idle: return RTIDesign.Color.danger
        }
    }

    private var healthLabel: String {
        if session.isPaused { return "Paused" }
        guard session.isRunning else { return "Idle" }
        switch session.transcriptionHealth {
        case .live: return "Live"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .failed: return "Connection lost"
        case .idle: return "Recording…"
        }
    }
}

// MARK: - Notes

struct NotesTabView: View {
    private let controller = NotesGenerationController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            OverlayTabStrip {
                overlayTabStripTitle("Notes")
                if controller.isGenerating {
                    ProgressView().controlSize(.mini)
                }
            } trailing: {
                OverlayToolbarButton(icon: "arrow.clockwise", help: "Write notes now",
                                     disabled: controller.isGenerating || SessionCoordinator.shared.currentSessionId == nil)
                {
                    if let sid = SessionCoordinator.shared.currentSessionId { Task { _ = await controller.generate(sessionId: sid) } }
                }
                OverlayToolbarButton(icon: "doc.on.doc", help: "Copy all notes", disabled: controller.notes.isEmpty) {
                    NSPasteboard.copyMarkdownRich(combinedMarkdown())
                }
                OverlayToolbarButton(icon: "square.and.arrow.down", help: "Save as Markdown", disabled: controller.notes.isEmpty, action: export)
            }
            if let error = controller.lastError {
                Text(error).font(House.TypeToken.meta).foregroundStyle(House.ColorToken.danger)
            }
            if controller.notes.isEmpty {
                overlayEmptyHints([
                    "Notes appear every few minutes as the meeting goes on",
                    overlayRecordHint(),
                    "\(OverlayTab.setup.shortcutLabel) opens Prepare to turn notes on or off",
                ])
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(controller.notes) { note in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(alignment: .top, spacing: 6) {
                                        noteHeader(note)
                                        Spacer()
                                        OverlayToolbarButton(icon: "doc.on.doc", help: "Copy this note block") {
                                            NSPasteboard.copyMarkdownRich(noteMarkdown(note))
                                        }
                                    }
                                    RTIMarkdown(note.content, style: .overlay)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(note.id)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .onChange(of: controller.notes.count) { _, _ in
                        if let last = controller.notes.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                    // Returning to this tab re-instantiates the view at the
                    // top — jump straight back to the newest note.
                    .onAppear {
                        if let last = controller.notes.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }

    /// `00:00 – 02:00 · Title` over `Local time: 10:00 AM – 10:02 AM`.
    private func noteHeader(_ note: GeneratedNote) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text("\(mmss(note.rangeStartMs)) – \(mmss(note.rangeEndMs))")
                    .font(.system(size: House.TypeToken.Size.caption, weight: .semibold, design: .monospaced))
                if !note.title.isEmpty {
                    Text("·").foregroundStyle(Color.overlayInkTertiary)
                    Text(note.title).font(.system(size: House.TypeToken.Size.caption, weight: .semibold))
                }
            }
            .foregroundStyle(Color.overlayInk)
            if let local = localRange(note) {
                Text("Local time: \(local)")
                    .font(RTIDesign.Font.micro).foregroundStyle(Color.overlayInkSecondary)
            }
        }
    }

    private func mmss(_ ms: Int) -> String {
        let s = max(0, ms) / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func localRange(_ note: GeneratedNote) -> String? {
        guard let start = controller.sessionStartedAt else { return nil }
        let from = start.addingTimeInterval(Double(note.rangeStartMs) / 1000)
        let to = start.addingTimeInterval(Double(note.rangeEndMs) / 1000)
        let style = Date.FormatStyle.dateTime.hour().minute()
        return "\(from.formatted(style)) – \(to.formatted(style))"
    }

    /// One note block as markdown — same shape as its slice of combinedMarkdown.
    private func noteMarkdown(_ note: GeneratedNote) -> String {
        var head = "## \(mmss(note.rangeStartMs)) – \(mmss(note.rangeEndMs))"
        if !note.title.isEmpty { head += " · \(note.title)" }
        if let local = localRange(note) { head += "\n_Local time: \(local)_" }
        return "\(head)\n\n\(note.content)"
    }

    private func combinedMarkdown() -> String {
        controller.notes.map(noteMarkdown).joined(separator: "\n\n")
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "rti-notes-\(Date().formatted(.iso8601.year().month().day())).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        let content = combinedMarkdown()
        // begin (sheet-less async) instead of runModal so a slow volume
        // enumeration can't freeze the overlay.
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Intelligence ledger

/// Accumulating ledger of live decisions/actions/questions/risks across the
/// session. Mirrors NotesTabView's shape: chronological list, newest last,
/// auto-scrolled, copy/export in the toolbar.
struct FindingsTabView: View {
    private let controller = FindingsController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            OverlayTabStrip {
                overlayTabStripTitle("Intel")
                if controller.isGenerating {
                    ProgressView().controlSize(.mini)
                }
            } trailing: {
                OverlayToolbarButton(icon: "arrow.clockwise", help: "Scan for intel now",
                                     disabled: controller.isGenerating || SessionCoordinator.shared.currentSessionId == nil)
                {
                    if let sid = SessionCoordinator.shared.currentSessionId { Task { _ = await controller.generate(sessionId: sid) } }
                }
                OverlayToolbarButton(icon: "doc.on.doc", help: "Copy all intel", disabled: controller.findings.isEmpty) {
                    NSPasteboard.copyMarkdownRich(combinedMarkdown())
                }
                OverlayToolbarButton(icon: "square.and.arrow.down", help: "Save as Markdown", disabled: controller.findings.isEmpty, action: export)
            }
            if let error = controller.lastError {
                Text(error).font(House.TypeToken.meta).foregroundStyle(House.ColorToken.danger)
            }
            if controller.findings.isEmpty {
                overlayEmptyHints([
                    "Decisions, actions, open questions, and risks show here",
                    "⌘⌥N adds a note you can mark",
                    overlayRecordHint(),
                ])
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(controller.findings) { finding in
                                findingRow(finding).id(finding.id)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .onChange(of: controller.findings.count) { _, _ in
                        if let last = controller.findings.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                    .onAppear {
                        if let last = controller.findings.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }

    private func findingRow(_ f: FindingEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: f.tag.icon).font(.system(size: House.TypeToken.Size.micro, weight: .bold))
                    Text(f.tag.label.uppercased()).font(.system(size: House.TypeToken.Size.micro, weight: .bold))
                }
                .foregroundStyle(tagColor(f.tag))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: RTIDesign.Radius.xs).fill(tagColor(f.tag).opacity(0.14)))
                Text(mmss(f.rangeMs))
                    .font(.system(size: House.TypeToken.Size.micro, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.overlayInkTertiary)
                Spacer()
                OverlayToolbarButton(icon: "doc.on.doc", help: "Copy this finding") {
                    NSPasteboard.copyMarkdownRich(findingMarkdown(f))
                }
            }
            Text(f.headline)
                .font(RTIDesign.Font.label)
                .foregroundStyle(Color.overlayInk)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !f.matters.isEmpty {
                Text("Why: \(f.matters)")
                    .font(RTIDesign.Font.caption)
                    .foregroundStyle(Color.overlayInkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let quote = f.quote, !quote.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Rectangle().fill(tagColor(f.tag).opacity(0.4)).frame(width: 2)
                    VStack(alignment: .leading, spacing: 1) {
                        if let speaker = f.speaker, !speaker.isEmpty {
                            Text(speaker).font(.system(size: House.TypeToken.Size.micro, weight: .semibold)).foregroundStyle(Color.overlayInkSecondary)
                        }
                        Text(quote).font(RTIDesign.Font.caption).italic().foregroundStyle(Color.overlayInk)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tagColor(_ tag: FindingTag) -> Color {
        switch tag {
        case .decision: .green
        case .action: RTIDesign.Color.textSecondary
        case .openQuestion: .teal
        case .risk: .orange
        case .followUp: .purple
        case .finding: .green
        case .tension: .orange
        case .contradiction: .red
        case .newThread: RTIDesign.Color.textSecondary
        case .missed: .yellow
        }
    }

    private func mmss(_ ms: Int) -> String {
        let s = max(0, ms) / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func findingMarkdown(_ f: FindingEntry) -> String {
        var out = "- **[\(f.tag.label)]** `\(mmss(f.rangeMs))` \(f.headline)"
        if !f.matters.isEmpty { out += "\n  - _Why:_ \(f.matters)" }
        if let quote = f.quote, !quote.isEmpty {
            let who = f.speaker.map { "\($0): " } ?? ""
            out += "\n  - > \(who)\(quote)"
        }
        return out
    }

    private func combinedMarkdown() -> String {
        controller.findings.map(findingMarkdown).joined(separator: "\n")
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "rti-intelligence-\(Date().formatted(.iso8601.year().month().day())).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        let content = combinedMarkdown()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Auto

/// Auto mode surface: the proactive cards `AutoAssistController` surfaces live —
/// things to say, ask, recall from the project, or flag. Mirrors the Findings
/// panel's shape (header + manual scan + scrolling list) but each row is an
/// in-the-moment suggestion rather than a logged observation.
struct AutoTabView: View {
    private let controller = AutoAssistController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            OverlayTabStrip {
                overlayTabStripTitle("Auto")
                if controller.isGenerating {
                    ProgressView().controlSize(.mini)
                }
            } trailing: {
                OverlayToolbarButton(icon: "arrow.clockwise", help: "Suggest now",
                                     disabled: controller.isGenerating || SessionCoordinator.shared.currentSessionId == nil)
                {
                    if let sid = SessionCoordinator.shared.currentSessionId { Task { _ = await controller.generate(sessionId: sid) } }
                }
            }
            if let error = controller.lastError {
                Text(error).font(House.TypeToken.meta).foregroundStyle(House.ColorToken.danger)
            }
            if controller.cards.isEmpty {
                overlayEmptyHints([
                    "Things to say, ask, or recall show here as the meeting goes on",
                    "\(OverlayTab.setup.shortcutLabel) opens Prepare to pick the project",
                    overlayRecordHint(),
                ])
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(controller.cards) { card in
                                cardRow(card).id(card.id)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .onChange(of: controller.cards.count) { _, _ in
                        controller.markSeen()
                        if let last = controller.cards.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                    .onAppear {
                        controller.markSeen()
                        if let last = controller.cards.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }

    private func cardRow(_ c: AutoAssistCard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: c.kind.icon).font(.system(size: House.TypeToken.Size.micro, weight: .bold))
                    Text(c.kind.label.uppercased()).font(.system(size: House.TypeToken.Size.micro, weight: .bold))
                }
                .foregroundStyle(kindColor(c.kind))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: RTIDesign.Radius.xs).fill(kindColor(c.kind).opacity(0.14)))
                Spacer()
                OverlayToolbarButton(icon: "doc.on.doc", help: "Copy") {
                    NSPasteboard.copyMarkdownRich(c.text)
                }
            }
            Text(c.text)
                .font(RTIDesign.Font.label)
                .foregroundStyle(Color.overlayInk)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !c.why.isEmpty {
                Text(c.why)
                    .font(RTIDesign.Font.caption)
                    .foregroundStyle(Color.overlayInkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let source = c.source, !source.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "doc.text").font(.system(size: House.TypeToken.Size.micro))
                    Text(source).font(RTIDesign.Font.micro).lineLimit(1)
                }
                .foregroundStyle(Color.overlayInkTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Monochrome-friendly tint per kind (kept subtle, like the Findings tags).
    private func kindColor(_ kind: AutoCardKind) -> Color {
        switch kind {
        case .say: RTIDesign.Color.textSecondary
        case .ask: .teal
        case .recall: .green
        case .flag: .orange
        }
    }
}

// MARK: - Setup

/// The meeting home: establish context and choose the live aids before going
/// live. The guide can be attached now and is auto-bound when the session
/// starts.
struct SetupTabView: View {
    private enum ScopeFilter: String, CaseIterable, Identifiable {
        case all
        case projects
        case clients

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All"
            case .projects: "Projects"
            case .clients: "Clients"
            }
        }
    }

    private enum LiveOption: Equatable, Identifiable {
        case visualContext
        case notes
        case guide
        case findings
        case autoAssist

        var id: String {
            switch self {
            case .visualContext: "visualContext"
            case .notes: "notes"
            case .guide: "guide"
            case .findings: "findings"
            case .autoAssist: "autoAssist"
            }
        }

        var title: String {
            switch self {
            case .visualContext: "Screen context"
            case .notes: "Notes"
            case .guide: "Guide"
            case .findings: "Intel"
            case .autoAssist: "Auto"
            }
        }

        var detail: String {
            switch self {
            case .visualContext: "Read the active screen every minute; images discarded"
            case .notes: "Capture running notes as the call develops"
            case .guide: "Match questions from an attached guide"
            case .findings: "Decisions, actions, questions, risks"
            case .autoAssist: "Surface suggestions during the call"
            }
        }

        var icon: String {
            switch self {
            case .visualContext: "eye"
            case .notes: "note.text"
            case .guide: "checklist"
            case .findings: "checklist.checked"
            case .autoAssist: "sparkles"
            }
        }
    }

    /// Render proofs turn this off, so a proof never reads the Mac's real
    /// calendar (real meeting titles). The app always reads it.
    @MainActor static var readsCalendar = true

    private let store = MeetingContextStore.shared
    private let calendarStore = CalendarMeetingStore.shared
    private let guideController = DiscussionGuideController.shared
    private let session = SessionCoordinator.shared
    private let visibleResultLimit = 8
    // These also gate the live tabs (Notes / Guide) — see OverlayPanelView.
    @AppStorage(AnalysisSettingsDefaults.notesEnabledKey) private var notesEnabled = AnalysisSettingsDefaults.defaultNotesEnabled
    @AppStorage(AnalysisSettingsDefaults.guideEnabledKey) private var guideEnabled = AnalysisSettingsDefaults.defaultGuideEnabled
    @AppStorage(AnalysisSettingsDefaults.findingsEnabledKey) private var findingsEnabled = AnalysisSettingsDefaults.defaultFindingsEnabled
    @AppStorage(AnalysisSettingsDefaults.autoAssistEnabledKey) private var autoAssistEnabled = AnalysisSettingsDefaults.defaultAutoAssistEnabled
    @AppStorage(VisualContextSettingsDefaults.enabledKey) private var visualContextEnabled = VisualContextSettingsDefaults.defaultEnabled
    @State private var clients: [VaultItem] = []
    @State private var projects: [VaultItem] = []
    @State private var scopeFilter: ScopeFilter = .all
    @State private var pickerOpen = false
    @State private var query = ""
    @State private var suppressNextQueryDisclosure = false
    @State private var pasteOpen = false
    @State private var pasteText = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: House.Spacing.lg) {
                prepareHeader
                meetingFocusSection
                calendarMeetingSection
                liveCallSection
                discussionGuideSection
                noteEditor
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .onAppear {
            load()
            if Self.readsCalendar { calendarStore.refresh() }
        }
        .onChange(of: visualContextEnabled) { _, enabled in
            let session = SessionCoordinator.shared
            VisualContextTrail.shared.setEnabled(
                enabled,
                sessionStartedAt: session.isRunning ? session.startedAt : nil
            )
            if session.isPaused { VisualContextTrail.shared.setPaused(true) }
        }
    }

    private var prepareHeader: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            Text("Prepare the meeting")
                .font(House.TypeToken.heading)
                .foregroundStyle(House.ColorToken.textPrimary)
            Text("RTI records the meeting, improves the transcript after Finish, then writes the notes. A client or project is optional.")
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, House.Spacing.xs)
    }

    // MARK: - Meeting focus

    private var meetingFocusSection: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            sectionHeader("Focus", detail: "Client or project")
            if store.workstreamName != nil {
                usingBanner
            }
            picker
        }
    }

    // MARK: - Confirmed calendar meeting

    private var calendarMeetingSection: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            sectionHeader("Meeting", detail: "Calendar (optional)")
            settingsGroup {
                switch calendarStore.accessState {
                case .notDetermined:
                    HStack(spacing: 9) {
                        Image(systemName: "calendar")
                            .foregroundStyle(Color.overlayInkSecondary)
                        Text("Use a calendar event for the title and invitees")
                            .font(RTIDesign.Font.caption)
                            .foregroundStyle(Color.overlayInkSecondary)
                        Spacer(minLength: 6)
                        Button("Allow access") { calendarStore.requestAccess() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    .padding(10)
                case .denied:
                    HStack(spacing: 8) {
                        Image(systemName: "calendar.badge.exclamationmark")
                            .foregroundStyle(RTIDesign.Color.warning)
                        Text("Calendar access is off. Enable it in System Settings to choose a meeting.")
                            .font(RTIDesign.Font.caption)
                            .foregroundStyle(Color.overlayInkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                case .available:
                    calendarPicker
                }
            }
        }
    }

    private var calendarPicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let selected = store.calendarMeeting {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(RTIDesign.Color.success)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(selected.title)
                            .font(.system(size: House.TypeToken.Size.meta, weight: .semibold))
                            .foregroundStyle(Color.overlayInk)
                            .lineLimit(1)
                        Text(calendarDetail(selected))
                            .font(RTIDesign.Font.micro)
                            .foregroundStyle(Color.overlayInkSecondary)
                    }
                    Spacer(minLength: 4)
                    Button { store.clearCalendarMeeting() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.overlayInkTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove calendar meeting context")
                }
                .padding(.horizontal, 10)
                .padding(.top, 9)
            } else if let suggestion = calendarStore.suggestion {
                HStack(spacing: 8) {
                    Image(systemName: "calendar.badge.clock")
                        .foregroundStyle(RTIDesign.Color.textSecondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Suggested: \(suggestion.title)")
                            .font(.system(size: House.TypeToken.Size.meta, weight: .semibold))
                            .foregroundStyle(Color.overlayInk)
                            .lineLimit(1)
                        Text(calendarDetail(suggestion))
                            .font(RTIDesign.Font.micro)
                            .foregroundStyle(Color.overlayInkSecondary)
                    }
                    Spacer(minLength: 4)
                    Button("Use") { store.selectCalendarMeeting(suggestion) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.top, 9)
            } else {
                Text("No event overlaps the current time.")
                    .font(RTIDesign.Font.caption)
                    .foregroundStyle(Color.overlayInkSecondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 9)
            }

            if !calendarStore.events.isEmpty {
                Menu {
                    ForEach(calendarStore.events) { event in
                        Button("\(calendarTime(event))  \(event.title)  ·  \(calendarSourceLabel(event))") {
                            store.selectCalendarMeeting(event)
                        }
                    }
                } label: {
                    Label("Choose calendar event", systemImage: "chevron.up.chevron.down")
                        .font(.system(size: House.TypeToken.Size.caption, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 10)
                .padding(.bottom, 9)
            }
        }
    }

    private func calendarDetail(_ event: CalendarMeeting) -> String {
        let count = event.attendees.count
        return "\(calendarTime(event)) · \(calendarSourceLabel(event)) · \(count == 0 ? "no invitees" : "\(count) invitee\(count == 1 ? "" : "s")")"
    }

    private func calendarTime(_ event: CalendarMeeting) -> String {
        Self.calendarTimeFormatter.string(from: event.startDate)
    }

    private func calendarSourceLabel(_ event: CalendarMeeting) -> String {
        let labels = [event.calendarSource, event.calendarName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return labels.isEmpty ? "Calendar" : labels.joined(separator: " / ")
    }

    private static let calendarTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    /// A group's lead-in, as the settings shell draws it: the uppercase
    /// `section` label, then a `meta` detail.
    private func sectionHeader(_ title: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: House.Spacing.xs) {
            SlateSectionLabel(text: title)
            if let detail {
                Text(detail)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
    }

    /// A settings-shell group: a quiet card at `Radius.lg` holding 40 pt rows.
    private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .slateGroupCard(cornerRadius: House.Radius.lg)
    }

    // MARK: - Combined client/project picker

    private var picker: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(RTIDesign.Font.caption)
                    .foregroundStyle(Color.overlayInkSecondary)
                TextField(store.workstreamName == nil ? "Search client or project" : "Change client or project", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: House.TypeToken.Size.meta, weight: .medium))
                    .foregroundStyle(Color.overlayInk)
                    .focused($searchFocused)
                    .onTapGesture { openPicker() }
                    .onChange(of: query) { _, _ in
                        if suppressNextQueryDisclosure {
                            suppressNextQueryDisclosure = false
                        } else {
                            pickerOpen = true
                        }
                    }
                    .onSubmit {
                        if let first = filteredItems.first {
                            pick(first)
                            closePicker()
                        }
                    }
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(RTIDesign.Font.caption)
                            .foregroundStyle(Color.overlayInkTertiary)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    togglePicker()
                } label: {
                    Image(systemName: pickerOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: House.TypeToken.Size.micro, weight: .semibold))
                        .foregroundStyle(Color.overlayInkSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: RTIDesign.Radius.tile).fill(RTIDesign.Color.chipFill))

            HStack(spacing: 8) {
                Picker("", selection: $scopeFilter) {
                    ForEach(ScopeFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 194)
                .onChange(of: scopeFilter) { _, _ in
                    pickerOpen = true
                }
                if let hint = scopeHint {
                    Text(hint)
                        .font(RTIDesign.Font.micro)
                        .foregroundStyle(Color.overlayInkTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }

            if pickerOpen {
                pickerList
            }
        }
    }

    private func openPicker() {
        pickerOpen = true
        searchFocused = true
    }

    private func closePicker() {
        pickerOpen = false
        searchFocused = false
    }

    private func togglePicker() {
        pickerOpen ? closePicker() : openPicker()
    }

    private var pickerList: some View {
        VStack(spacing: 0) {
            if filteredItems.isEmpty {
                Text(emptyPickerMessage)
                    .font(RTIDesign.Font.caption)
                    .foregroundStyle(Color.overlayInkTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !visibleProjects.isEmpty {
                            pickerSection("Projects", items: visibleProjects, total: filteredProjects.count)
                        }
                        if !visibleClients.isEmpty {
                            pickerSection("Clients", items: visibleClients, total: filteredClients.count)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 178)
                if scopeFilter == .all, !query.isEmpty, !filteredProjects.isEmpty, filteredClients.isEmpty {
                    Text("Showing individual projects for “\(query)”.")
                        .font(RTIDesign.Font.micro)
                        .foregroundStyle(Color.overlayInkTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: RTIDesign.Radius.tile).fill(RTIDesign.Color.chipFill))
        .overlay(RoundedRectangle(cornerRadius: RTIDesign.Radius.tile).stroke(RTIDesign.Color.border, lineWidth: House.hairline))
    }

    private func pickerSection(_ title: String, items: [VaultItem], total: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: House.TypeToken.Size.micro, weight: .semibold))
                    .foregroundStyle(Color.overlayInkSecondary)
                Spacer()
                Text("\(total)")
                    .font(.system(size: House.TypeToken.Size.micro, weight: .semibold))
                    .foregroundStyle(Color.overlayInkTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)
            ForEach(items) { pickerRow($0) }
        }
    }

    private func pickerRow(_ item: VaultItem) -> some View {
        Button {
            pick(item)
            closePicker()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.isProject ? "folder" : "person.crop.circle")
                    .font(RTIDesign.Font.caption)
                    .foregroundStyle(Color.overlayInkSecondary)
                    .frame(width: 16)
                Text(item.name)
                    .font(RTIDesign.Font.meta)
                    .foregroundStyle(Color.overlayInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(item.isProject ? "Project" : "Client")
                    .font(.system(size: House.TypeToken.Size.micro, weight: .medium))
                    .foregroundStyle(Color.overlayInkTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: RTIDesign.Radius.xs)
                    .fill(store.workstreamItem == item ? RTIDesign.Color.selectionFill : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var usingBanner: some View {
        HStack(spacing: 7) {
            Image(systemName: store.workstreamItem?.isProject == false ? "person.crop.circle.fill" : "folder.fill")
                .font(RTIDesign.Font.caption)
                .foregroundStyle(RTIDesign.Color.success)
                .frame(width: 16)
            Text(store.workstreamName ?? "")
                .font(.system(size: House.TypeToken.Size.caption, weight: .semibold))
                .foregroundStyle(Color.overlayInk)
                .lineLimit(1)
                .truncationMode(.middle)
            if let item = store.workstreamItem {
                Text(item.isProject ? "Project scope" : "Client note")
                    .font(.system(size: House.TypeToken.Size.micro, weight: .medium))
                    .foregroundStyle(Color.overlayInkTertiary)
            }
            Spacer(minLength: 8)
            Button { store.clearWorkstream() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(RTIDesign.Font.meta)
                    .foregroundStyle(Color.overlayInkTertiary)
            }
            .buttonStyle(.plain)
            .help("Clear meeting focus")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: RTIDesign.Radius.tile).fill(RTIDesign.Color.success.opacity(0.10)))
    }

    private var allItems: [VaultItem] {
        switch scopeFilter {
        case .all:
            projects + clients
        case .projects:
            projects
        case .clients:
            clients
        }
    }

    private var filteredItems: [VaultItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return allItems }
        return allItems.filter { $0.name.lowercased().contains(q) }
    }

    private var filteredProjects: [VaultItem] {
        filteredItems.filter(\.isProject)
    }

    private var filteredClients: [VaultItem] {
        filteredItems.filter { !$0.isProject }
    }

    private var visibleProjects: [VaultItem] {
        Array(filteredProjects.prefix(scopeFilter == .all ? visibleResultLimit : visibleResultLimit + 2))
    }

    private var visibleClients: [VaultItem] {
        Array(filteredClients.prefix(scopeFilter == .all ? max(2, visibleResultLimit - visibleProjects.count) : visibleResultLimit + 2))
    }

    private var scopeHint: String? {
        switch scopeFilter {
        case .all:
            nil
        case .projects:
            "searches project files"
        case .clients:
            "uses one client note"
        }
    }

    private var emptyPickerMessage: String {
        if allItems.isEmpty {
            return "Nothing found in your vault."
        }
        if scopeFilter == .clients {
            return "No client note matches “\(query)”."
        }
        return "No match for “\(query)”."
    }

    // MARK: - Live call

    private var liveCallSection: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            sectionHeader("Live", detail: "Capture & analysis")
            settingsGroup {
                liveTranscriptionRow
                settingsRowDivider
                livePanelToggle(.visualContext, $visualContextEnabled)
                settingsRowDivider
                livePanelToggle(.notes, $notesEnabled)
                settingsRowDivider
                livePanelToggle(.guide, $guideEnabled)
                settingsRowDivider
                livePanelToggle(.findings, $findingsEnabled)
                settingsRowDivider
                livePanelToggle(.autoAssist, $autoAssistEnabled)
            }
        }
    }

    private var liveTranscriptionRow: some View {
        HStack(spacing: House.Spacing.sm) {
            Image(systemName: "waveform")
                .font(House.TypeToken.label)
                .foregroundStyle(House.ColorToken.textSecondary)
                .frame(width: House.Control.tile)
            VStack(alignment: .leading, spacing: 0) {
                Text("Transcription")
                    .font(House.TypeToken.label)
                    .foregroundStyle(House.ColorToken.textPrimary)
                Text(captureReadiness)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: House.Spacing.sm)
            Button("Configure") {
                WindowCoordinator.shared.showSessionsControl(tab: .general)
            }
            .buttonStyle(.borderless)
            .font(.system(size: House.TypeToken.Size.caption, weight: .medium))
            .foregroundStyle(Color.overlayAccent)
        }
        .padding(.horizontal, House.Spacing.sm)
        .padding(.vertical, House.Spacing.xxs)
        .frame(maxWidth: .infinity, minHeight: House.Control.row, alignment: .leading)
    }

    private var captureReadiness: String {
        let devices = session.audioDeviceNames()
        return "Mic: \(devices.input) · call audio follows: \(devices.output)"
    }

    /// The line between rows, inset to the rows' text column.
    private var settingsRowDivider: some View {
        HouseDivider()
            .padding(.leading, House.Spacing.sm + House.Control.tile + House.Spacing.sm)
    }

    private func livePanelToggle(_ option: LiveOption, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: House.Spacing.sm) {
                Image(systemName: option.icon)
                    .font(House.TypeToken.label)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .frame(width: House.Control.tile)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: HouseChatMetrics.chipGap) {
                        Text(option.title)
                            .font(House.TypeToken.label)
                            .foregroundStyle(House.ColorToken.textPrimary)
                        if option == .notes {
                            Text("Default")
                                .font(House.TypeToken.meta)
                                .foregroundStyle(House.ColorToken.textTertiary)
                        }
                    }
                    Text(option.detail)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: House.Spacing.sm)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(House.ColorToken.textPrimary)
        .padding(.horizontal, House.Spacing.sm)
        .padding(.vertical, House.Spacing.xxs)
        .frame(maxWidth: .infinity, minHeight: House.Control.row, alignment: .leading)
    }

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            sectionHeader("Prep note", detail: "Optional")
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(get: { store.note }, set: { store.note = $0 }))
                    .font(RTIDesign.Font.meta).foregroundStyle(Color.overlayInk).scrollContentBackground(.hidden)
                    .frame(height: 64).padding(6)
                    .background(RoundedRectangle(cornerRadius: RTIDesign.Radius.row).fill(RTIDesign.Color.chipFill))
                if store.note.isEmpty {
                    Text("Anything extra for the assistant…")
                        .font(RTIDesign.Font.meta).foregroundStyle(Color.overlayInkTertiary)
                        .padding(.horizontal, 11).padding(.vertical, 13).allowsHitTesting(false)
                }
            }
        }
    }

    private func pick(_ item: VaultItem) {
        store.workstreamName = item.name
        store.workstreamContext = VaultWorkstreamStore.context(for: item)
        store.workstreamItem = item
        if !query.isEmpty {
            suppressNextQueryDisclosure = true
            query = ""
        }
    }

    // MARK: - Discussion guide

    /// `.md` guides in the picked project's `discussion-guide/` folder.
    private var projectGuides: [URL] {
        guard let item = store.workstreamItem, item.isProject else { return [] }
        return VaultWorkstreamStore.discussionGuides(for: item)
    }

    private var discussionGuideSection: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            HStack(spacing: HouseChatMetrics.chipGap) {
                sectionHeader("Guide", detail: guideController.guide == nil ? "Optional" : nil)
                if guideController.isImporting {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
            }

            if let guide = guideController.guide {
                committedGuideRow(guide)
            } else if let pending = guideController.pendingGuide {
                pendingGuidePreview(pending)
            } else {
                guideInputs
            }

            if let error = guideController.lastError {
                Text(error).font(RTIDesign.Font.micro).foregroundStyle(RTIDesign.Color.danger)
            }
        }
    }

    private func committedGuideRow(_ guide: DiscussionGuide) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.clipboard").font(RTIDesign.Font.meta).foregroundStyle(RTIDesign.Color.success)
            VStack(alignment: .leading, spacing: 1) {
                Text(guide.fileName).font(.system(size: House.TypeToken.Size.meta, weight: .medium)).foregroundStyle(Color.overlayInk)
                    .lineLimit(1).truncationMode(.middle)
                Text("\(guide.objectives.count) objectives • \(guide.coverage.total) questions")
                    .font(RTIDesign.Font.micro).foregroundStyle(Color.overlayInkSecondary)
            }
            Spacer()
            Button { guideController.remove() } label: {
                Image(systemName: "xmark.circle.fill").font(RTIDesign.Font.meta).foregroundStyle(Color.overlayInkSecondary)
            }
            .buttonStyle(.plain).help("Remove this guide")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: RTIDesign.Radius.sm).fill(RTIDesign.Color.success.opacity(0.12)))
    }

    private func pendingGuidePreview(_ guide: DiscussionGuide) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Found \(guide.objectives.count) objectives and \(guide.coverage.total) questions. Does this look right?")
                .font(RTIDesign.Font.caption).foregroundStyle(Color.overlayInkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(guide.objectives, id: \.id) { obj in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(obj.title).font(.system(size: House.TypeToken.Size.caption, weight: .semibold)).foregroundStyle(Color.overlayInk)
                            ForEach(obj.sections, id: \.id) { sec in
                                Text("\(sec.title) · \(sec.questions.count) questions")
                                    .font(RTIDesign.Font.micro).foregroundStyle(Color.overlayInkSecondary)
                                    .padding(.leading, 8)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: RTIDesign.Radius.tile).fill(RTIDesign.Color.chipFill))
            HStack(spacing: 8) {
                Button("Use this guide") { guideController.confirmPending() }
                    .buttonStyle(InkButtonStyle())
                Button { guideController.discardPending() } label: {
                    Text("Discard").font(RTIDesign.Font.caption).foregroundStyle(Color.overlayInkSecondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var guideInputs: some View {
        HStack(spacing: 8) {
            guideInputButton("Paste", "doc.on.clipboard") {
                pasteOpen.toggle()
            }
            guideInputButton("Upload…", "square.and.arrow.up", action: uploadGuide)
        }

        if pasteOpen { pasteBox }

        if !projectGuides.isEmpty {
            Text("In \(store.workstreamItem?.name ?? "this project"):")
                .font(.system(size: House.TypeToken.Size.micro, weight: .medium)).foregroundStyle(Color.overlayInkSecondary)
                .padding(.top, 2)
            VStack(spacing: 0) {
                ForEach(projectGuides, id: \.self) { url in
                    Button { Task { await guideController.loadFile(from: url) } } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "doc.text").font(RTIDesign.Font.caption).foregroundStyle(Color.overlayInkSecondary).frame(width: 16)
                            Text(url.deletingPathExtension().lastPathComponent)
                                .font(RTIDesign.Font.meta).foregroundStyle(Color.overlayInk)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(RoundedRectangle(cornerRadius: RTIDesign.Radius.sm).fill(RTIDesign.Color.chipFill))
        }
    }

    private func guideInputButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(RTIDesign.Font.micro)
                Text(title).font(.system(size: House.TypeToken.Size.caption, weight: .medium))
            }
            .foregroundStyle(Color.overlayInk)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: RTIDesign.Radius.tile).fill(RTIDesign.Color.selectionFill))
        }
        .buttonStyle(.plain)
    }

    private var pasteBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $pasteText)
                .font(RTIDesign.Font.meta).foregroundStyle(Color.overlayInk).scrollContentBackground(.hidden)
                .frame(height: 90).padding(6)
                .background(RoundedRectangle(cornerRadius: RTIDesign.Radius.tile).fill(RTIDesign.Color.chipFill))
            HStack(spacing: 8) {
                Button("Read guide") { parsePasted() }
                    .buttonStyle(InkButtonStyle())
                .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || guideController.isImporting)
                Button { pasteOpen = false; pasteText = "" } label: {
                    Text("Cancel").font(RTIDesign.Font.caption).foregroundStyle(Color.overlayInkSecondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func parsePasted() {
        let text = pasteText
        Task {
            await guideController.parse(text: text, fileName: "Pasted guide")
            if guideController.pendingGuide != nil {
                pasteOpen = false
                pasteText = ""
            }
        }
    }

    private func uploadGuide() {
        let panel = NSOpenPanel()
        // Markdown/text plus the common exported formats — extraction is handled
        // by GuideTextExtractor, so the picker just has to let them through.
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md") ?? .plainText,
            .plainText, .text,
            UTType(filenameExtension: "docx") ?? .data,
            UTType(filenameExtension: "doc") ?? .data,
            .pdf, .rtf, .html,
        ]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await guideController.loadFile(from: url) }
    }

    private func load() {
        clients = VaultWorkstreamStore.clients()
        projects = VaultWorkstreamStore.projects()
    }
}

// MARK: - Guide

struct GuideTabView: View {
    private let controller = DiscussionGuideController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            OverlayTabStrip {
                overlayTabStripTitle("Discussion guide")
                if controller.isMatching {
                    ProgressView().controlSize(.mini)
                }
            } trailing: {
                if let guide = controller.guide {
                    Text("\(guide.coverage.answered) of \(guide.coverage.total) · \(guide.coverage.percent)%")
                        .font(House.TypeToken.meta)
                        .monospacedDigit()
                        .foregroundStyle(House.ColorToken.textSecondary)
                }
            }
            if let error = controller.lastError {
                Text(error).font(House.TypeToken.meta).foregroundStyle(House.ColorToken.danger)
            }
            if let guide = controller.guide {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(guide.objectives) { ObjectiveSection(objective: $0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollContentBackground(.hidden)
            } else {
                overlayEmptyHints([
                    "No guide yet",
                    "\(OverlayTab.setup.shortcutLabel) opens Prepare to add one",
                    "RTI ticks off its questions as they come up",
                ])
            }
        }
    }
}
