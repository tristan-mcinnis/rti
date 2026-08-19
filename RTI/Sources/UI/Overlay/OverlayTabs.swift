import AppKit
import RTICore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Transcript

struct TranscriptTabView: View {
    private let session = SessionCoordinator.shared
    @State private var paragraphs: [LiveTranscriptPresentation.Row] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(healthColor).frame(width: 8, height: 8)
                Text(healthLabel).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.overlayInk.opacity(0.75))
                if session.isRunning, let startedAt = session.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(TimeFormat.elapsed(context.date.timeIntervalSince(startedAt)))
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(Color.overlayInk.opacity(0.38))
                    }
                }
                Spacer()
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
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(paras) { para in
                                paragraphRow(para).id(para.id)
                            }
                            if let interim = session.interimLine {
                                interimRow(interim)
                                    .id("interim")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollContentBackground(.hidden)
                    .onChange(of: paragraphs.last?.id) { _, _ in
                        if let last = paras.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                    .onChange(of: session.interimLine) { _, interim in
                        if interim != nil { proxy.scrollTo("interim", anchor: .bottom) }
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
    }

    // MARK: - Speaker turns (one stream, coalesced by speaker)

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
    private func makeParagraphs() -> [LiveTranscriptPresentation.Row] {
        LiveTranscriptPresentation.rows(
            from: session.liveEntries,
            showTranslations: false,
            speakerLabelStyle: .neutral
        )
    }

    /// Show the original always; when translating, show the translation as a
    /// second line beneath it. So toggling translation mid-session is purely
    /// additive — it never wipes the preceding transcript.
    private func paragraphRow(_ para: LiveTranscriptPresentation.Row) -> some View {
        let isNote = para.speakerId == "note"
        let speakerColor = SpeakerLabels.chipColor(for: para.speakerId)
        let original = para.original.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if isNote {
                    Image(systemName: "note.text")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(speakerColor)
                } else {
                    Circle()
                        .fill(speakerColor)
                        .frame(width: 6, height: 6)
                }
                Text(para.speakerLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isNote ? speakerColor : Color.overlayInk.opacity(0.65))
                Text(TimeFormat.elapsedMs(para.startMs))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.overlayInk.opacity(0.38))
            }
            if !original.isEmpty {
                Text(original)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .foregroundStyle(Color.overlayInk.opacity(0.92))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 1)
    }

    private func interimRow(_ raw: String) -> some View {
        let displayText = LiveTranscriptPresentation.displayInterim(raw)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(Color.overlayAccent)
                .frame(width: 5, height: 5)
            Text(displayText)
                .font(.system(size: 12))
                .italic()
                .lineSpacing(2)
                .foregroundStyle(Color.overlayInk.opacity(0.52))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live transcription: \(displayText)")
    }

    private func transcriptText() -> String {
        LiveTranscriptPresentation.copyText(rows: paragraphs, showTranslations: false)
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

    private let store = MeetingContextStore.shared
    private let session = SessionCoordinator.shared
    private let visibleResultLimit = 8
    @State private var clients: [VaultItem] = []
    @State private var projects: [VaultItem] = []
    @State private var scopeFilter: ScopeFilter = .all
    @State private var pickerOpen = false
    @State private var query = ""
    @State private var suppressNextQueryDisclosure = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                prepareHeader
                meetingFocusSection
                liveCallSection
                noteEditor
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .onAppear {
            load()
        }
    }

    private var prepareHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Meeting options")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.overlayInk)
            Text("RTI captures the meeting, improves the transcript after Finish, then writes the notes. Client and project context are optional.")
                .font(.system(size: 11))
                .foregroundStyle(Color.overlayInk.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
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
                .onChange(of: scopeFilter) { _, _ in
                    pickerOpen = true
                }
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

    private func pickerSection(_ title: String, items: [VaultItem], total: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.overlayInk.opacity(0.48))
                Spacer()
                Text("\(total)")
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
            sectionHeader("Live", detail: "Capture")
            settingsGroup {
                liveTranscriptionRow
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
                Text(captureReadiness)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.overlayInk.opacity(0.42))
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Button("Configure") {
                WindowCoordinator.shared.showSessionsControl(tab: .general)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.overlayAccent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var captureReadiness: String {
        let devices = session.audioDeviceNames()
        return "Mic: \(devices.input) · call audio follows: \(devices.output)"
    }

    private var settingsRowDivider: some View {
        Divider()
            .overlay(Color.overlayInk.opacity(0.07))
            .padding(.leading, 42)
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
        if !query.isEmpty {
            suppressNextQueryDisclosure = true
            query = ""
        }
    }

    private func load() {
        clients = VaultWorkstreamStore.clients()
        projects = VaultWorkstreamStore.projects()
    }
}

