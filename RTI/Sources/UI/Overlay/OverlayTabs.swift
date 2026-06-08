import RTICore
import SwiftUI
import UniformTypeIdentifiers

/// The tabs of the consolidated overlay. One window, one toggle (⌘\), tabs
/// across the top — instead of a constellation of floating panels.
enum OverlayTab: String, CaseIterable, Identifiable {
    case assist, transcript, notes, context, guide
    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .assist: "Assist"
        case .transcript: "Transcript"
        case .notes: "Notes"
        case .context: "Context"
        case .guide: "Guide"
        }
    }

    var icon: String {
        switch self {
        case .assist: "sparkles"
        case .transcript: "text.bubble"
        case .notes: "note.text"
        case .context: "info.circle"
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
                    .foregroundStyle(selection == tab ? Color.white : Color.white.opacity(0.5))
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selection == tab ? Color.white.opacity(0.14) : Color.clear)
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
                          color: .white, dim: Color.white.opacity(0.08))
        } else if let frozen = postRecordingLabel {
            DotMatrixText(text: frozen, dot: 1.2, spacing: 0.5, gap: 1.2,
                          color: Color.white.opacity(0.55), dim: Color.white.opacity(0.06))
        } else {
            Text("Record")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .kerning(0.2)
        }
    }

    private var background: some View {
        ZStack {
            Capsule(style: .continuous).fill(Color.white.opacity(hovering ? 0.14 : 0.08))
            if coordinator.isRunning {
                Capsule(style: .continuous).fill(Color(red: 1.0, green: 0.20, blue: 0.20).opacity(0.18))
            }
        }
    }

    private var borderColor: Color {
        coordinator.isRunning
            ? Color(red: 1.0, green: 0.30, blue: 0.30).opacity(0.45)
            : Color.white.opacity(hovering ? 0.22 : 0.12)
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
                .foregroundStyle(.white.opacity(disabled ? 0.25 : 0.6))
                .frame(width: 22, height: 18)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }
}

private func overlayEmptyState(_ icon: String, _ title: String, _ subtitle: String) -> some View {
    VStack(spacing: 6) {
        Image(systemName: icon).font(.system(size: 26)).foregroundStyle(.white.opacity(0.35))
        Text(title).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
        Text(subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.horizontal, 24)
}

// MARK: - Transcript

struct TranscriptTabView: View {
    private let session = SessionCoordinator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(healthColor).frame(width: 8, height: 8)
                Text(healthLabel).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.75))
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
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(session.liveEntries) { entry in
                                row(entry).id(entry.id)
                            }
                            if let interim = session.interimLine {
                                Text(interim).font(.system(size: 12)).foregroundStyle(.white.opacity(0.45)).italic()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollContentBackground(.hidden)
                    .onChange(of: session.liveEntries.count) { _, _ in
                        if let last = session.liveEntries.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
            }
        }
    }

    private func row(_ entry: LiveEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label(for: entry.speakerId))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(entry.speakerId == "note" ? .yellow.opacity(0.8) : .white.opacity(0.5))
            Text(entry.text)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.9))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func label(for speakerId: String) -> String {
        switch speakerId {
        case "self": return "You"
        case "note": return "📝 Note"
        default:
            if speakerId.hasPrefix("them_"), let n = speakerId.split(separator: "_").last { return "Them \(n)" }
            return speakerId == "them" ? "Them" : speakerId.capitalized
        }
    }

    private func transcriptText() -> String {
        session.liveEntries.map { "\(label(for: $0.speakerId)): \($0.text)" }.joined(separator: "\n")
    }

    private var healthColor: Color {
        guard session.isRunning else { return .white.opacity(0.3) }
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
                Text("Notes").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
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
                overlayEmptyState("note.text", "Waiting for first note…", "Notes generate every few minutes while recording.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(controller.notes) { note in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(note.timestamp.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                                RTIMarkdown(note.content, style: .overlay)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func combinedMarkdown() -> String {
        controller.notes.map { "## Notes — \($0.timestamp.formatted(date: .abbreviated, time: .shortened))\n\n\($0.content)" }
            .joined(separator: "\n\n---\n\n")
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "rti-notes-\(Date().formatted(.iso8601.year().month().day())).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? combinedMarkdown().write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Context

struct ContextTabView: View {
    private let store = MeetingContextStore.shared
    @State private var clients: [VaultItem] = []
    @State private var projects: [VaultItem] = []
    @State private var briefs: [MeetingBrief] = []
    @State private var selectedBrief: MeetingBrief?
    @State private var briefContent = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                pickers
                if let name = store.workstreamName {
                    workstreamPreview(name: name)
                }
                noteEditor
                briefSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .onAppear(perform: load)
    }

    /// Pick a client or project from the vault.
    private var pickers: some View {
        HStack(spacing: 8) {
            menu(title: "Client", icon: "person.crop.circle", items: clients)
            menu(title: "Project", icon: "folder", items: projects)
            Spacer()
            if store.workstreamName != nil {
                OverlayToolbarButton(icon: "xmark.circle", help: "Clear workstream") { store.clearWorkstream() }
            }
        }
    }

    private func menu(title: String, icon: String, items: [VaultItem]) -> some View {
        Menu {
            if items.isEmpty {
                Text("None found in vault")
            } else {
                ForEach(items) { item in Button(item.name) { pick(item) } }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10))
                Text(title).font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.1)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func workstreamPreview(name: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "link").font(.system(size: 9))
                Text(name).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.green.opacity(0.85))
            ScrollView {
                RTIMarkdown(store.workstreamContext ?? "", style: .overlay).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05)))
        }
    }

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your note").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(get: { store.note }, set: { store.note = $0 }))
                    .font(.system(size: 12)).foregroundStyle(.white).scrollContentBackground(.hidden)
                    .frame(height: 56).padding(6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
                if store.note.isEmpty {
                    Text("Anything extra for the assistant…")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.35))
                        .padding(.horizontal, 11).padding(.vertical, 13).allowsHitTesting(false)
                }
            }
        }
    }

    private var briefSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Pre-meeting brief").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
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
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            } else {
                RTIMarkdown(briefContent, style: .overlay).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func pick(_ item: VaultItem) {
        store.workstreamName = item.name
        store.workstreamContext = VaultWorkstreamStore.context(for: item)
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
                Text("Discussion guide").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                if controller.isImporting || controller.isMatching {
                    ProgressView().scaleEffect(0.6).progressViewStyle(.circular)
                }
                Spacer()
                if let guide = controller.guide {
                    Text("\(guide.coverage.answered)/\(guide.coverage.total) • \(guide.coverage.percent)%")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                }
                OverlayToolbarButton(icon: "square.and.arrow.up", help: "Import guide…", action: importGuide)
                if controller.guide != nil {
                    OverlayToolbarButton(icon: "trash", help: "Remove guide", action: removeGuide)
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
                overlayEmptyState("list.bullet.clipboard", "No guide loaded", "Import a .md/.txt guide; RTI pairs its questions with the conversation.")
            }
        }
    }

    private func importGuide() {
        guard let sessionId = SessionCoordinator.shared.currentSessionId else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await controller.importGuide(from: url, sessionId: sessionId) }
    }

    private func removeGuide() {
        guard let sessionId = SessionCoordinator.shared.currentSessionId else { return }
        controller.removeGuide(for: sessionId)
    }
}
