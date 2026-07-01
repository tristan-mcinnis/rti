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
    @State private var paragraphs: [Paragraph] = []

    private static let languageOptions: [(code: String, label: String)] = [
        ("en", "English"), ("zh", "Chinese"), ("es", "Spanish"), ("fr", "French"),
        ("de", "German"), ("ja", "Japanese"), ("ko", "Korean"), ("pt", "Portuguese"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(healthColor).frame(width: 8, height: 8)
                Text(healthLabel).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.overlayInk.opacity(0.75))
                Spacer()
                translateControl
                OverlayToolbarButton(icon: "doc.on.doc", help: "Copy transcript", disabled: session.liveEntries.isEmpty) {
                    NSPasteboard.copyString(transcriptText())
                }
            }
            if let notice = session.systemAudioNotice {
                Text(notice).font(.system(size: 10)).foregroundStyle(.orange)
            }
            if session.liveEntries.isEmpty {
                overlayEmptyState("text.bubble", "No transcript yet", "Start a session with ⌘⇧R.")
            } else {
                let paras = paragraphs
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(paras) { para in
                                paragraphRow(para).id(para.id)
                            }
                            if let interim = session.interimLine {
                                Text(interim).font(.system(size: 12)).foregroundStyle(Color.overlayInk.opacity(0.45)).italic()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollContentBackground(.hidden)
                    .onChange(of: paragraphs.last?.id) { _, _ in
                        if let last = paras.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                    // Returning to this tab re-instantiates the view at the
                    // top — jump straight back to the latest line.
                    .onAppear {
                        if let last = paras.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        // SessionCoordinator observes UserDefaults and is the sole writer of
        // `translationConfig`. The view only reads the same defaults keys for
        // its controls; it no longer pushes config directly.
        .onAppear { paragraphs = makeParagraphs() }
        .onChange(of: session.liveEntries.count) { _, _ in paragraphs = makeParagraphs() }
        .onChange(of: session.liveEntries.last?.id) { _, _ in paragraphs = makeParagraphs() }
        .onChange(of: translationEnabled) { _, _ in paragraphs = makeParagraphs() }
    }

    // MARK: - Translation control

    private var translateControl: some View {
        HStack(spacing: 4) {
            Button {
                translationEnabled.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "globe").font(.system(size: 10, weight: .medium))
                    Text(translationEnabled ? pillLabel : "Translate")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(translationEnabled ? Color.blue : Color.overlayInk.opacity(0.55))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(translationEnabled ? Color.blue.opacity(0.18) : Color.overlayInk.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(translationEnabled ? "Turn translation off" : "Turn translation on")
            .help(translationEnabled ? "Translation on — shown under each line" : "Translate the transcript inline")

            if translationEnabled {
                Menu {
                    Picker("Mode", selection: $translationMode) {
                        Text("One-way (everything → one language)").tag("one_way")
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
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.overlayInk.opacity(0.5))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 14)
                .accessibilityLabel("Translation mode and languages")
                .help("Translation mode & languages")
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

    private struct Paragraph: Identifiable {
        let id: UUID
        let speakerId: String
        let speakerLabel: String
        var original: String
        var translation: String
    }

    /// Build the transcript as speaker turns, merging each speaker's consecutive
    /// fragments into one flowing line. Each turn keeps BOTH its original and its
    /// translation text; the row then shows the translation when translating and
    /// one exists, otherwise the original — so turning translation on mid-session
    /// doesn't erase the (untranslated) history before it.
    ///
    /// Speakers are labelled neutrally — "Speaker 1", "Speaker 2", … in order of
    /// first appearance. We deliberately do NOT call the mic source "You": with
    /// people in the room, their voices come through the mic too, so the capture
    /// channel doesn't identify who's talking.
    ///
    /// Cached in `@State` and rebuilt only when `liveEntries` changes, so long
    /// transcripts don't re-coalesce on every SwiftUI render.
    private func makeParagraphs() -> [Paragraph] {
        var result: [Paragraph] = []
        var speakerNumber: [String: Int] = [:]
        var nextNumber = 1
        func label(for id: String) -> String {
            if id == "note" { return "📝 Note" }
            if let n = speakerNumber[id] { return "Speaker \(n)" }
            let n = nextNumber
            speakerNumber[id] = n
            nextNumber += 1
            return "Speaker \(n)"
        }

        for entry in session.liveEntries {
            let isTranslation = entry.translationStatus == "translation"
            let isNote = entry.speakerId == "note"
            if !isNote, !result.isEmpty, result[result.count - 1].speakerId == entry.speakerId {
                let i = result.count - 1
                if isTranslation {
                    result[i].translation += (result[i].translation.isEmpty ? "" : " ") + entry.text
                } else {
                    result[i].original += (result[i].original.isEmpty ? "" : " ") + entry.text
                }
            } else {
                result.append(Paragraph(
                    id: entry.id,
                    speakerId: entry.speakerId,
                    speakerLabel: label(for: entry.speakerId),
                    original: isTranslation ? "" : entry.text,
                    translation: isTranslation ? entry.text : ""
                ))
            }
        }
        // Keep a turn if it has spoken text, or a translation to show. Crucially
        // the original is ALWAYS kept — turning translation on never hides the
        // transcript you already have.
        return result.filter { para in
            !para.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || (translationEnabled && !para.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// Show the original always; when translating, show the translation as a
    /// second line beneath it. So toggling translation mid-session is purely
    /// additive — it never wipes the preceding transcript.
    private func paragraphRow(_ para: Paragraph) -> some View {
        let original = para.original.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = para.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 2) {
            Text(para.speakerLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(para.speakerId == "note" ? Color.yellow.opacity(0.8) : Color.overlayInk.opacity(0.5))
            if !original.isEmpty {
                Text(original)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.overlayInk.opacity(0.9))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if translationEnabled, !translation.isEmpty {
                Text(translation)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.blue.opacity(0.95))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func languageLabel(_ code: String) -> String {
        Self.languageOptions.first { $0.code == code }?.label ?? code.uppercased()
    }

    private func transcriptText() -> String {
        paragraphs.map { para in
            var line = "\(para.speakerLabel): \(para.original)"
            let t = para.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            if translationEnabled, !t.isEmpty { line += "\n  ↳ \(para.translation)" }
            return line
        }.joined(separator: "\n")
    }

    private var healthColor: Color {
        if session.isPaused { return .orange }
        guard session.isRunning else { return Color.overlayInk.opacity(0.3) }
        switch session.transcriptionHealth {
        case .live: return .green
        case .connecting: return .yellow
        case .reconnecting: return .orange
        case .failed, .idle: return .red
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Notes").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.overlayInk.opacity(0.75))
                if controller.isGenerating {
                    ProgressView().scaleEffect(0.6).progressViewStyle(.circular)
                }
                Spacer()
                OverlayToolbarButton(icon: "arrow.clockwise", help: "Regenerate now",
                                     disabled: controller.isGenerating || SessionCoordinator.shared.currentSessionId == nil)
                {
                    if let sid = SessionCoordinator.shared.currentSessionId { Task { _ = await controller.generate(sessionId: sid) } }
                }
                OverlayToolbarButton(icon: "doc.on.doc", help: "Copy all notes", disabled: controller.notes.isEmpty) {
                    NSPasteboard.copyMarkdownRich(combinedMarkdown())
                }
                OverlayToolbarButton(icon: "square.and.arrow.down", help: "Export as .md", disabled: controller.notes.isEmpty, action: export)
            }
            if let error = controller.lastError {
                Text(error).font(.system(size: 10)).foregroundStyle(.red)
            }
            if controller.notes.isEmpty {
                overlayEmptyState("note.text", "No notes yet", "Notes appear as the conversation develops.")
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
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                if !note.title.isEmpty {
                    Text("·").foregroundStyle(Color.overlayInk.opacity(0.3))
                    Text(note.title).font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(Color.overlayInk.opacity(0.85))
            if let local = localRange(note) {
                Text("Local time: \(local)")
                    .font(.system(size: 10)).foregroundStyle(Color.overlayInk.opacity(0.45))
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

// MARK: - Findings ledger

/// Accumulating ledger of tagged findings across the session — the passive
/// counterpart to the one-shot ⌘↵ listener flag. Mirrors NotesTabView's shape:
/// chronological list, newest last, auto-scrolled, copy/export in the toolbar.
struct FindingsTabView: View {
    private let controller = FindingsController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Findings").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.overlayInk.opacity(0.75))
                if controller.isGenerating {
                    ProgressView().scaleEffect(0.6).progressViewStyle(.circular)
                }
                Spacer()
                OverlayToolbarButton(icon: "arrow.clockwise", help: "Scan for findings now",
                                     disabled: controller.isGenerating || SessionCoordinator.shared.currentSessionId == nil)
                {
                    if let sid = SessionCoordinator.shared.currentSessionId { Task { _ = await controller.generate(sessionId: sid) } }
                }
                OverlayToolbarButton(icon: "doc.on.doc", help: "Copy all findings", disabled: controller.findings.isEmpty) {
                    NSPasteboard.copyMarkdownRich(combinedMarkdown())
                }
                OverlayToolbarButton(icon: "square.and.arrow.down", help: "Export as .md", disabled: controller.findings.isEmpty, action: export)
            }
            if let error = controller.lastError {
                Text(error).font(.system(size: 10)).foregroundStyle(.red)
            }
            if controller.findings.isEmpty {
                overlayEmptyState("flag", "No findings yet", "Tagged findings, tensions, and missed threads appear here as the session develops.")
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
                    Image(systemName: f.tag.icon).font(.system(size: 9, weight: .bold))
                    Text(f.tag.label.uppercased()).font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(tagColor(f.tag))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(tagColor(f.tag).opacity(0.14)))
                Text(mmss(f.rangeMs))
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.overlayInk.opacity(0.4))
                Spacer()
                OverlayToolbarButton(icon: "doc.on.doc", help: "Copy this finding") {
                    NSPasteboard.copyMarkdownRich(findingMarkdown(f))
                }
            }
            Text(f.headline)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.overlayInk.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !f.matters.isEmpty {
                Text("Matters: \(f.matters)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.overlayInk.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let quote = f.quote, !quote.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Rectangle().fill(tagColor(f.tag).opacity(0.4)).frame(width: 2)
                    VStack(alignment: .leading, spacing: 1) {
                        if let speaker = f.speaker, !speaker.isEmpty {
                            Text(speaker).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.overlayInk.opacity(0.6))
                        }
                        Text(quote).font(.system(size: 11)).italic().foregroundStyle(Color.overlayInk.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tagColor(_ tag: FindingTag) -> Color {
        switch tag {
        case .finding: .green
        case .tension: .orange
        case .contradiction: .red
        case .newThread: .blue
        case .missed: .yellow
        }
    }

    private func mmss(_ ms: Int) -> String {
        let s = max(0, ms) / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func findingMarkdown(_ f: FindingEntry) -> String {
        var out = "- **[\(f.tag.label)]** `\(mmss(f.rangeMs))` \(f.headline)"
        if !f.matters.isEmpty { out += "\n  - _Matters:_ \(f.matters)" }
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
        panel.nameFieldStringValue = "rti-findings-\(Date().formatted(.iso8601.year().month().day())).md"
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Auto").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.overlayInk.opacity(0.75))
                if controller.isGenerating {
                    ProgressView().scaleEffect(0.6).progressViewStyle(.circular)
                }
                Spacer()
                OverlayToolbarButton(icon: "arrow.clockwise", help: "Surface suggestions now",
                                     disabled: controller.isGenerating || SessionCoordinator.shared.currentSessionId == nil)
                {
                    if let sid = SessionCoordinator.shared.currentSessionId { Task { _ = await controller.generate(sessionId: sid) } }
                }
            }
            if let error = controller.lastError {
                Text(error).font(.system(size: 10)).foregroundStyle(.red)
            }
            if controller.cards.isEmpty {
                overlayEmptyState("wand.and.stars", "Listening…",
                                  "As the meeting develops, Auto surfaces things to say, ask, or recall from this project. Set the project in Setup to ground it.")
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
                    Image(systemName: c.kind.icon).font(.system(size: 9, weight: .bold))
                    Text(c.kind.label.uppercased()).font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(kindColor(c.kind))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(kindColor(c.kind).opacity(0.14)))
                Spacer()
                OverlayToolbarButton(icon: "doc.on.doc", help: "Copy") {
                    NSPasteboard.copyMarkdownRich(c.text)
                }
            }
            Text(c.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.overlayInk.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !c.why.isEmpty {
                Text(c.why)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.overlayInk.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let source = c.source, !source.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "doc.text").font(.system(size: 8))
                    Text(source).font(.system(size: 10)).lineLimit(1)
                }
                .foregroundStyle(Color.overlayInk.opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Monochrome-friendly tint per kind (kept subtle, like the Findings tags).
    private func kindColor(_ kind: AutoCardKind) -> Color {
        switch kind {
        case .say: .blue
        case .ask: .teal
        case .recall: .green
        case .flag: .orange
        }
    }
}

// MARK: - Setup

/// The pre-call surface: who the meeting is about (vault workstream + note +
/// brief) and the discussion guide. Everything here is meant to be set before
/// you go live; the guide can be attached now and is auto-bound when the
/// session starts.
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
        case notes
        case guide
        case findings
        case autoAssist

        var id: String {
            switch self {
            case .notes: "notes"
            case .guide: "guide"
            case .findings: "findings"
            case .autoAssist: "autoAssist"
            }
        }

        var title: String {
            switch self {
            case .notes: "Notes"
            case .guide: "Guide"
            case .findings: "Findings"
            case .autoAssist: "Auto"
            }
        }

        var detail: String {
            switch self {
            case .notes: "Capture running notes as the call develops"
            case .guide: "Match questions from an attached guide"
            case .findings: "Keep a live ledger of observations"
            case .autoAssist: "Surface suggestions during the call"
            }
        }

        var icon: String {
            switch self {
            case .notes: "note.text"
            case .guide: "checklist"
            case .findings: "tag"
            case .autoAssist: "sparkles"
            }
        }
    }

    private let store = MeetingContextStore.shared
    private let guideController = DiscussionGuideController.shared
    private let visibleResultLimit = 8
    // These also gate the live tabs (Notes / Guide) — see OverlayPanelView.
    @AppStorage(AnalysisSettingsDefaults.notesEnabledKey) private var notesEnabled = AnalysisSettingsDefaults.defaultNotesEnabled
    @AppStorage(AnalysisSettingsDefaults.guideEnabledKey) private var guideEnabled = AnalysisSettingsDefaults.defaultGuideEnabled
    @AppStorage(AnalysisSettingsDefaults.findingsEnabledKey) private var findingsEnabled = AnalysisSettingsDefaults.defaultFindingsEnabled
    @AppStorage(AnalysisSettingsDefaults.autoAssistEnabledKey) private var autoAssistEnabled = AnalysisSettingsDefaults.defaultAutoAssistEnabled
    @State private var clients: [VaultItem] = []
    @State private var projects: [VaultItem] = []
    @State private var scopeFilter: ScopeFilter = .all
    @State private var pickerOpen = false
    @State private var query = ""
    @State private var pasteOpen = false
    @State private var pasteText = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                meetingFocusSection
                liveCallSection
                discussionGuideSection
                noteEditor
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .onAppear(perform: load)
    }

    // MARK: - Meeting focus

    private var meetingFocusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Focus", detail: "Client or project")
            if store.workstreamName != nil {
                usingBanner
            }
            picker
        }
    }

    private func sectionHeader(_ title: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.overlayInk.opacity(0.86))
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.overlayInk.opacity(0.42))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
    }

    private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.overlayInk.opacity(0.050)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.overlayInk.opacity(0.075), lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Combined client/project picker

    private var picker: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.overlayInk.opacity(0.45))
                TextField(store.workstreamName == nil ? "Search client or project" : "Change client or project", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.overlayInk)
                    .focused($searchFocused)
                    .onTapGesture { openPicker() }
                    .onSubmit {
                        if let first = filteredItems.first {
                            pick(first)
                            query = ""
                            closePicker()
                        }
                    }
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.overlayInk.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    togglePicker()
                } label: {
                    Image(systemName: pickerOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.overlayInk.opacity(0.55))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.overlayInk.opacity(0.09)))

            HStack(spacing: 8) {
                Picker("", selection: $scopeFilter) {
                    ForEach(ScopeFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 194)
                if let hint = scopeHint {
                    Text(hint)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.overlayInk.opacity(0.38))
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
                    .font(.system(size: 11))
                    .foregroundStyle(Color.overlayInk.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !visibleProjects.isEmpty {
                            pickerSection("Projects", items: visibleProjects)
                        }
                        if !visibleClients.isEmpty {
                            pickerSection("Clients", items: visibleClients)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 178)
                if scopeFilter == .all, !query.isEmpty, !filteredProjects.isEmpty, filteredClients.isEmpty {
                    Text("Showing individual projects for “\(query)”.")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.overlayInk.opacity(0.42))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.overlayInk.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.overlayInk.opacity(0.10), lineWidth: 1))
    }

    private func pickerSection(_ title: String, items: [VaultItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.overlayInk.opacity(0.48))
                Spacer()
                Text("\(items.count)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.overlayInk.opacity(0.30))
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
            query = ""
            closePicker()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.isProject ? "folder" : "person.crop.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.overlayInk.opacity(0.48))
                    .frame(width: 16)
                Text(item.name)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.overlayInk.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(item.isProject ? "Project" : "Client")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.overlayInk.opacity(0.36))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.overlayInk.opacity(store.workstreamItem == item ? 0.10 : 0.0001))
            )
        }
        .buttonStyle(.plain)
    }

    private var usingBanner: some View {
        HStack(spacing: 7) {
            Image(systemName: store.workstreamItem?.isProject == false ? "person.crop.circle.fill" : "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green.opacity(0.85))
                .frame(width: 16)
            Text(store.workstreamName ?? "")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.overlayInk)
                .lineLimit(1)
                .truncationMode(.middle)
            if let item = store.workstreamItem {
                Text(item.isProject ? "Project scope" : "Client note")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.overlayInk.opacity(0.42))
            }
            Spacer(minLength: 8)
            Button { store.clearWorkstream() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.overlayInk.opacity(0.38))
            }
            .buttonStyle(.plain)
            .help("Clear meeting focus")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.green.opacity(0.10)))
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
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Live", detail: "Soniox realtime")
            settingsGroup {
                liveTranscriptionRow
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
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.overlayInk.opacity(0.55))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Transcription")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.overlayInk.opacity(0.88))
                Text("Realtime capture and translation")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.overlayInk.opacity(0.42))
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text("Soniox")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.overlayInk.opacity(0.50))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settingsRowDivider: some View {
        Divider()
            .overlay(Color.overlayInk.opacity(0.07))
            .padding(.leading, 42)
    }

    private func livePanelToggle(_ option: LiveOption, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 10) {
                Image(systemName: option.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.overlayInk.opacity(0.50))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(option.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.overlayInk.opacity(0.88))
                        if option == .notes {
                            Text("Default")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.overlayInk.opacity(0.42))
                        }
                    }
                    Text(option.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.overlayInk.opacity(0.42))
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(.blue)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Prep note", detail: "Optional")
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(get: { store.note }, set: { store.note = $0 }))
                    .font(.system(size: 12)).foregroundStyle(Color.overlayInk).scrollContentBackground(.hidden)
                    .frame(height: 64).padding(6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.overlayInk.opacity(0.075)))
                if store.note.isEmpty {
                    Text("Anything extra for the assistant…")
                        .font(.system(size: 12)).foregroundStyle(Color.overlayInk.opacity(0.35))
                        .padding(.horizontal, 11).padding(.vertical, 13).allowsHitTesting(false)
                }
            }
        }
    }

    private func pick(_ item: VaultItem) {
        store.workstreamName = item.name
        store.workstreamContext = VaultWorkstreamStore.context(for: item)
        store.workstreamItem = item
    }

    // MARK: - Discussion guide

    /// `.md` guides in the picked project's `discussion-guide/` folder.
    private var projectGuides: [URL] {
        guard let item = store.workstreamItem, item.isProject else { return [] }
        return VaultWorkstreamStore.discussionGuides(for: item)
    }

    private var discussionGuideSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                sectionHeader("Guide", detail: guideController.guide == nil ? "Optional" : nil)
                if guideController.isImporting {
                    ProgressView().scaleEffect(0.55).progressViewStyle(.circular)
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
                Text(error).font(.system(size: 10)).foregroundStyle(.red)
            }
        }
    }

    private func committedGuideRow(_ guide: DiscussionGuide) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.clipboard").font(.system(size: 12)).foregroundStyle(.green.opacity(0.85))
            VStack(alignment: .leading, spacing: 1) {
                Text(guide.fileName).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.overlayInk.opacity(0.9))
                    .lineLimit(1).truncationMode(.middle)
                Text("\(guide.objectives.count) objectives • \(guide.coverage.total) questions")
                    .font(.system(size: 10)).foregroundStyle(Color.overlayInk.opacity(0.5))
            }
            Spacer()
            Button { guideController.remove() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Color.overlayInk.opacity(0.45))
            }
            .buttonStyle(.plain).help("Remove this guide")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.12)))
    }

    private func pendingGuidePreview(_ guide: DiscussionGuide) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Parsed \(guide.objectives.count) objectives • \(guide.coverage.total) questions — does this look right?")
                .font(.system(size: 11)).foregroundStyle(Color.overlayInk.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(guide.objectives, id: \.id) { obj in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(obj.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.overlayInk.opacity(0.85))
                            ForEach(obj.sections, id: \.id) { sec in
                                Text("\(sec.title) — \(sec.questions.count) Qs")
                                    .font(.system(size: 10)).foregroundStyle(Color.overlayInk.opacity(0.5))
                                    .padding(.leading, 8)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.overlayInk.opacity(0.05)))
            HStack(spacing: 8) {
                Button { guideController.confirmPending() } label: {
                    Text("Use this guide").font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.85)))
                        .foregroundStyle(Color.overlayInk)
                }
                .buttonStyle(.plain)
                Button { guideController.discardPending() } label: {
                    Text("Discard").font(.system(size: 11)).foregroundStyle(Color.overlayInk.opacity(0.6))
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
                .font(.system(size: 10, weight: .medium)).foregroundStyle(Color.overlayInk.opacity(0.5))
                .padding(.top, 2)
            VStack(spacing: 0) {
                ForEach(projectGuides, id: \.self) { url in
                    Button { Task { await guideController.loadFile(from: url) } } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(Color.overlayInk.opacity(0.5)).frame(width: 16)
                            Text(url.deletingPathExtension().lastPathComponent)
                                .font(.system(size: 12)).foregroundStyle(Color.overlayInk.opacity(0.9))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.overlayInk.opacity(0.05)))
        }
    }

    private func guideInputButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Color.overlayInk.opacity(0.85))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.overlayInk.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }

    private var pasteBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $pasteText)
                .font(.system(size: 12)).foregroundStyle(Color.overlayInk).scrollContentBackground(.hidden)
                .frame(height: 90).padding(6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.overlayInk.opacity(0.08)))
            HStack(spacing: 8) {
                Button { parsePasted() } label: {
                    Text("Parse").font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.85)))
                        .foregroundStyle(Color.overlayInk)
                }
                .buttonStyle(.plain)
                .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || guideController.isImporting)
                Button { pasteOpen = false; pasteText = "" } label: {
                    Text("Cancel").font(.system(size: 11)).foregroundStyle(Color.overlayInk.opacity(0.6))
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Discussion guide").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.overlayInk.opacity(0.75))
                if controller.isMatching {
                    ProgressView().scaleEffect(0.6).progressViewStyle(.circular)
                }
                Spacer()
                if let guide = controller.guide {
                    Text("\(guide.coverage.answered)/\(guide.coverage.total) • \(guide.coverage.percent)%")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.overlayInk.opacity(0.7))
                }
            }
            if let error = controller.lastError {
                Text(error).font(.system(size: 10)).foregroundStyle(.red)
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
                overlayEmptyState("list.bullet.clipboard", "No guide loaded", "Attach a guide in the Setup tab; RTI pairs its questions with the conversation.")
            }
        }
    }
}
