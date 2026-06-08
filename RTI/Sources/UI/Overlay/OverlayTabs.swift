import RTICore
import SwiftUI
import UniformTypeIdentifiers

/// The tabs of the consolidated overlay. One window, one toggle (⌘\), tabs
/// across the top — instead of a constellation of floating panels.
enum OverlayTab: String, CaseIterable, Identifiable {
    // Setup is leftmost — it's the pre-call surface (who the meeting is about +
    // the discussion guide). The rest are live.
    case setup, assist, transcript, notes, guide
    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .setup: "Setup"
        case .assist: "Assist"
        case .transcript: "Transcript"
        case .notes: "Notes"
        case .guide: "Guide"
        }
    }

    var icon: String {
        switch self {
        case .setup: "checklist"
        case .assist: "sparkles"
        case .transcript: "text.bubble"
        case .notes: "note.text"
        case .guide: "list.bullet.clipboard"
        }
    }
}

struct OverlayTabBar: View {
    @Binding var selection: OverlayTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(OverlayTab.allCases) { tab in
                Button { selection = tab } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.icon).font(.system(size: 10, weight: .medium))
                        Text(tab.title).font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .foregroundStyle(selection == tab ? Color.overlayInk : Color.overlayInk.opacity(0.5))
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selection == tab ? Color.overlayInk.opacity(0.14) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Record control

/// Inline record/stop control that lives in the overlay's header row — it
/// replaces the old free-floating top-widget pill (the "too floaty" button),
/// folding recording into the one master panel. Click toggles the session;
/// while live it shows a pulsing dot + a dot-matrix timer over a red wash;
/// after stop it freezes the final duration until the next session.
struct OverlayRecordButton: View {
    private let coordinator = SessionCoordinator.shared

    @State private var now = Date()
    @State private var hovering = false

    /// Half-second tick keeps the timer fresh; TimeFormat quantises to seconds.
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Button(action: { coordinator.toggleSession() }) {
            HStack(spacing: 6) {
                dot
                label
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(background)
            .overlay(Capsule(style: .continuous).stroke(borderColor, lineWidth: 1))
            .clipShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(coordinator.isRunning ? "Stop recording (⌘⇧R)" : "Start recording (⌘⇧R)")
        .onReceive(tick) { _ in if coordinator.isRunning { now = Date() } }
    }

    @ViewBuilder
    private var dot: some View {
        if coordinator.isRunning {
            PulsingRecordDot()
        } else {
            Circle()
                .fill(Color(red: 1.0, green: 0.27, blue: 0.27).opacity(coordinator.endedAt != nil ? 0.45 : 0.85))
                .frame(width: 7, height: 7)
        }
    }

    @ViewBuilder
    private var label: some View {
        if coordinator.isRunning {
            DotMatrixText(text: elapsedLabel, dot: 1.2, spacing: 0.5, gap: 1.2,
                          color: .white, dim: Color.overlayInk.opacity(0.08))
        } else if let frozen = postRecordingLabel {
            DotMatrixText(text: frozen, dot: 1.2, spacing: 0.5, gap: 1.2,
                          color: Color.overlayInk.opacity(0.55), dim: Color.overlayInk.opacity(0.06))
        } else {
            Text("Record")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.overlayInk.opacity(0.75))
                .kerning(0.2)
        }
    }

    private var background: some View {
        ZStack {
            Capsule(style: .continuous).fill(Color.overlayInk.opacity(hovering ? 0.14 : 0.08))
            if coordinator.isRunning {
                Capsule(style: .continuous).fill(Color(red: 1.0, green: 0.20, blue: 0.20).opacity(0.18))
            }
        }
    }

    private var borderColor: Color {
        coordinator.isRunning
            ? Color(red: 1.0, green: 0.30, blue: 0.30).opacity(0.45)
            : Color.overlayInk.opacity(hovering ? 0.22 : 0.12)
    }

    private var elapsedLabel: String {
        guard let started = coordinator.startedAt else { return "0:00" }
        return TimeFormat.elapsed(now.timeIntervalSince(started))
    }

    private var postRecordingLabel: String? {
        guard let started = coordinator.startedAt, let ended = coordinator.endedAt else { return nil }
        return TimeFormat.elapsed(ended.timeIntervalSince(started))
    }
}

/// Pulsing red indicator for the live record control. Owns its animation so it
/// restarts cleanly each time recording begins (onAppear → repeatForever).
private struct PulsingRecordDot: View {
    @State private var on = false

    var body: some View {
        Circle()
            .fill(Color(red: 1.0, green: 0.27, blue: 0.27))
            .frame(width: 7, height: 7)
            .shadow(color: Color(red: 1.0, green: 0.27, blue: 0.27).opacity(on ? 0.85 : 0.20), radius: on ? 4 : 1)
            .scaleEffect(on ? 1.0 : 0.65)
            .opacity(on ? 1.0 : 0.55)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

// MARK: - Shared tab chrome

/// A compact icon button used in tab toolbars (copy / export / etc.), styled
/// consistently across every tab.
struct OverlayToolbarButton: View {
    let icon: String
    let help: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.overlayInk.opacity(disabled ? 0.25 : 0.6))
                .frame(width: 22, height: 18)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }
}

private func overlayEmptyState(_ icon: String, _ title: String, _ subtitle: String) -> some View {
    VStack(spacing: 6) {
        Image(systemName: icon).font(.system(size: 26)).foregroundStyle(Color.overlayInk.opacity(0.35))
        Text(title).font(.system(size: 13)).foregroundStyle(Color.overlayInk.opacity(0.6))
        Text(subtitle).font(.system(size: 11)).foregroundStyle(Color.overlayInk.opacity(0.4))
            .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.horizontal, 24)
}

// MARK: - Transcript

struct TranscriptTabView: View {
    private let session = SessionCoordinator.shared
    @AppStorage("rti.translation.enabled") private var translationEnabled = false
    @AppStorage("rti.translation.mode") private var translationMode = "one_way"
    @AppStorage("rti.translation.targetLanguage") private var targetLanguage = "en"
    @AppStorage("rti.translation.languageA") private var languageA = "en"
    @AppStorage("rti.translation.languageB") private var languageB = "zh"

    private static let languageOptions: [(code: String, label: String)] = [
        ("en", "English"), ("zh", "Chinese"), ("es", "Spanish"), ("fr", "French"),
        ("de", "German"), ("ja", "Japanese"), ("ko", "Korean"), ("pt", "Portuguese")
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
                    .onChange(of: session.liveEntries.count) { _, _ in
                        if let last = paras.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
            }
        }
        // Make this control the source of truth: push the *displayed* target to
        // Soniox whenever the tab appears or the toggle/language changes. Guards
        // against a stale config (e.g. a legacy panel's Spanish default).
        .onAppear { syncTranslation() }
        .onChange(of: translationEnabled) { _, _ in syncTranslation() }
        .onChange(of: translationMode) { _, _ in syncTranslation() }
        .onChange(of: targetLanguage) { _, _ in syncTranslation() }
        .onChange(of: languageA) { _, _ in syncTranslation() }
        .onChange(of: languageB) { _, _ in syncTranslation() }
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

    private func syncTranslation() {
        let desired: TranslationConfig?
        if !translationEnabled {
            desired = nil
        } else if translationMode == "two_way" {
            // Same language both sides is a no-op — leave translation idle.
            desired = languageA == languageB ? nil : .twoWay(languageA: languageA, languageB: languageB)
        } else {
            desired = .oneWay(targetLanguage: targetLanguage)
        }
        // Only reassign when it actually changes — a redundant set would swap the
        // Soniox clients and blip transcription for no reason.
        if session.translationConfig != desired {
            session.translationConfig = desired
        }
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
    private var paragraphs: [Paragraph] {
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
        return result.filter { !shown($0).text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// What a turn shows: the translation (when translating and present), else
    /// the original — plus whether it's the translated form (for styling).
    private func shown(_ para: Paragraph) -> (text: String, translated: Bool) {
        let t = para.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        if translationEnabled, !t.isEmpty { return (para.translation, true) }
        return (para.original, false)
    }

    private func paragraphRow(_ para: Paragraph) -> some View {
        let display = shown(para)
        return VStack(alignment: .leading, spacing: 2) {
            Text(para.speakerLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(para.speakerId == "note" ? Color.yellow.opacity(0.8) : Color.overlayInk.opacity(0.5))
            Text(display.text)
                .font(.system(size: 12))
                .foregroundStyle(display.translated ? Color.blue.opacity(0.95) : Color.overlayInk.opacity(0.9))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func languageLabel(_ code: String) -> String {
        Self.languageOptions.first { $0.code == code }?.label ?? code.uppercased()
    }

    private func transcriptText() -> String {
        paragraphs.map { "\($0.speakerLabel): \(shown($0).text)" }.joined(separator: "\n")
    }

    private var healthColor: Color {
        guard session.isRunning else { return Color.overlayInk.opacity(0.3) }
        switch session.transcriptionHealth {
        case .live: return .green
        case .connecting: return .yellow
        case .reconnecting: return .orange
        case .failed, .idle: return .red
        }
    }

    private var healthLabel: String {
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
                overlayEmptyState("note.text", "Waiting for the first note…", "Notes appear in timed blocks as the conversation goes.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(controller.notes) { note in
                                VStack(alignment: .leading, spacing: 4) {
                                    noteHeader(note)
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

    private func combinedMarkdown() -> String {
        controller.notes.map { note in
            var head = "## \(mmss(note.rangeStartMs)) – \(mmss(note.rangeEndMs))"
            if !note.title.isEmpty { head += " · \(note.title)" }
            if let local = localRange(note) { head += "\n_Local time: \(local)_" }
            return "\(head)\n\n\(note.content)"
        }.joined(separator: "\n\n")
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "rti-notes-\(Date().formatted(.iso8601.year().month().day())).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? combinedMarkdown().write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Setup

/// The pre-call surface: who the meeting is about (vault workstream + note +
/// brief) and the discussion guide. Everything here is meant to be set before
/// you go live; the guide can be attached now and is auto-bound when the
/// session starts.
struct SetupTabView: View {
    private let store = MeetingContextStore.shared
    private let guideController = DiscussionGuideController.shared
    @State private var clients: [VaultItem] = []
    @State private var projects: [VaultItem] = []
    @State private var briefs: [MeetingBrief] = []
    @State private var selectedBrief: MeetingBrief?
    @State private var briefContent = ""
    @State private var pickerOpen = false
    @State private var query = ""
    @State private var pasteOpen = false
    @State private var pasteText = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Who is this meeting about?")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.overlayInk.opacity(0.85))
                Text("Pick a client or project from your vault — RTI grounds every suggestion in it until you clear it.")
                    .font(.system(size: 11)).foregroundStyle(Color.overlayInk.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)

                if store.workstreamName != nil {
                    usingBanner
                    workstreamPreview
                } else {
                    picker
                }

                Divider().overlay(Color.overlayInk.opacity(0.08)).padding(.vertical, 2)
                discussionGuideSection

                noteEditor
                briefSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .onAppear(perform: load)
    }

    // MARK: - One combined client/project picker

    private var picker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                pickerOpen.toggle()
                if pickerOpen { searchFocused = true }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10))
                    Text("Pick client or project").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Image(systemName: pickerOpen ? "chevron.up" : "chevron.down").font(.system(size: 9))
                }
                .foregroundStyle(Color.overlayInk.opacity(0.85))
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.overlayInk.opacity(0.1)))
            }
            .buttonStyle(.plain)

            if pickerOpen { pickerList }
        }
    }

    private var pickerList: some View {
        VStack(spacing: 0) {
            TextField("Type to filter…", text: $query)
                .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.overlayInk)
                .focused($searchFocused)
                .padding(.horizontal, 10).padding(.vertical, 7)
            Divider().overlay(Color.overlayInk.opacity(0.1))
            if filteredItems.isEmpty {
                Text(allItems.isEmpty ? "Nothing found in your vault." : "No match for “\(query)”.")
                    .font(.system(size: 11)).foregroundStyle(Color.overlayInk.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredItems) { pickerRow($0) }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.overlayInk.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.overlayInk.opacity(0.1), lineWidth: 1))
    }

    private func pickerRow(_ item: VaultItem) -> some View {
        Button {
            pick(item)
            pickerOpen = false
            query = ""
        } label: {
            HStack(spacing: 7) {
                Image(systemName: item.isProject ? "folder" : "person.crop.circle")
                    .font(.system(size: 11)).foregroundStyle(Color.overlayInk.opacity(0.55)).frame(width: 16)
                Text(item.name).font(.system(size: 12)).foregroundStyle(Color.overlayInk.opacity(0.9))
                Spacer()
                Text(item.isProject ? "Project" : "Client")
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(Color.overlayInk.opacity(0.4))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var usingBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.green.opacity(0.85))
            Text("RTI is using:").font(.system(size: 11)).foregroundStyle(Color.overlayInk.opacity(0.6))
            Text(store.workstreamName ?? "").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.overlayInk)
            Spacer()
            Button { store.clearWorkstream() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Color.overlayInk.opacity(0.45))
            }
            .buttonStyle(.plain).help("Clear — stop grounding answers in this workstream")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.12)))
    }

    private var workstreamPreview: some View {
        ScrollView {
            RTIMarkdown(store.workstreamContext ?? "", style: .overlay).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 150)
        .scrollContentBackground(.hidden)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.overlayInk.opacity(0.05)))
    }

    /// Projects first, then clients — the combined list the picker filters.
    private var allItems: [VaultItem] {
        projects + clients
    }

    private var filteredItems: [VaultItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return allItems }
        return allItems.filter { $0.name.lowercased().contains(q) }
    }

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your note").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.overlayInk.opacity(0.75))
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(get: { store.note }, set: { store.note = $0 }))
                    .font(.system(size: 12)).foregroundStyle(Color.overlayInk).scrollContentBackground(.hidden)
                    .frame(height: 56).padding(6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.overlayInk.opacity(0.08)))
                if store.note.isEmpty {
                    Text("Anything extra for the assistant…")
                        .font(.system(size: 12)).foregroundStyle(Color.overlayInk.opacity(0.35))
                        .padding(.horizontal, 11).padding(.vertical, 13).allowsHitTesting(false)
                }
            }
        }
    }

    private var briefSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Pre-meeting brief").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.overlayInk.opacity(0.75))
                Spacer()
                if briefs.count > 1 {
                    Picker("", selection: $selectedBrief) {
                        ForEach(briefs) { Text($0.title).tag(Optional($0)) }
                    }
                    .labelsHidden().frame(maxWidth: 150)
                    .onChange(of: selectedBrief) { _, new in briefContent = new.map(MeetingBriefStore.content) ?? "" }
                }
            }
            if briefs.isEmpty {
                Text("No brief found — Hermes writes these to your vault before a call.")
                    .font(.system(size: 11)).foregroundStyle(Color.overlayInk.opacity(0.4))
            } else {
                RTIMarkdown(briefContent, style: .overlay).frame(maxWidth: .infinity, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Discussion guide")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.overlayInk.opacity(0.85))
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
        Text("Attach the guide for this call — RTI tracks which questions get answered live.")
            .font(.system(size: 11)).foregroundStyle(Color.overlayInk.opacity(0.45))
            .fixedSize(horizontal: false, vertical: true)

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
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await guideController.loadFile(from: url) }
    }

    private func load() {
        clients = VaultWorkstreamStore.clients()
        projects = VaultWorkstreamStore.projects()
        briefs = MeetingBriefStore.recentBriefs()
        selectedBrief = briefs.first
        briefContent = selectedBrief.map(MeetingBriefStore.content) ?? ""
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
