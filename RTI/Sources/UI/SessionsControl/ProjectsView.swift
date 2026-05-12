import SwiftUI

/// Projects tab: list of user-defined session groupings on the left,
/// the selected project's detail on the right (chat box, member
/// sessions, instructions). A third tier between per-session Q&A and
/// the full corpus chat.
struct ProjectsView: View {
    private let store = ProjectStore.shared
    @State private var selectedProjectId: String?
    @State private var newProjectName: String = ""
    @State private var pendingArchiveId: String?

    private var archiveDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingArchiveId != nil },
            set: { if !$0 { pendingArchiveId = nil } }
        )
    }

    private var archiveDialogTitle: String {
        guard let id = pendingArchiveId,
              let name = store.projects.first(where: { $0.id == id })?.name
        else { return "Archive project?" }
        return "Archive \"\(name)\"?"
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, idealWidth: 240, maxWidth: 320)

            if let id = selectedProjectId, let project = store.projects.first(where: { $0.id == id }) {
                ProjectDetailView(project: project)
                    .id(project.id) // force-recreate controller when switching
                    .frame(minWidth: 560)
            } else {
                emptyDetail
                    .frame(minWidth: 560)
            }
        }
        .onAppear {
            if selectedProjectId == nil {
                selectedProjectId = store.projects.first?.id
            }
        }
        .onChange(of: store.projects.map(\.id)) { _, newIds in
            if let id = selectedProjectId, !newIds.contains(id) {
                selectedProjectId = newIds.first
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                TextField("New project name", text: $newProjectName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(createProject)
                Button(action: createProject) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .disabled(newProjectName.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Create project")
                .accessibilityLabel("Create project")
            }
            .padding(10)

            Divider()

            if store.projects.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text("No projects yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Group related sessions into a project to chat with their combined corpus.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedProjectId) {
                    ForEach(store.projects) { project in
                        ProjectListRow(project: project, memberCount: store.sessionIds(forProject: project.id).count)
                            .tag(Optional(project.id))
                            .contextMenu {
                                Button("Archive", role: .destructive) {
                                    pendingArchiveId = project.id
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
                .confirmationDialog(
                    archiveDialogTitle,
                    isPresented: archiveDialogBinding,
                    titleVisibility: .visible
                ) {
                    Button("Archive", role: .destructive) {
                        if let id = pendingArchiveId { store.archive(id: id) }
                        pendingArchiveId = nil
                    }
                    Button("Cancel", role: .cancel) { pendingArchiveId = nil }
                } message: {
                    Text("The project's session memberships and chat history are preserved on disk. Archiving only hides it from the list.")
                }
            }
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Pick a project")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Or create one in the sidebar to start chatting across a curated set of sessions with your own project instructions.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func createProject() {
        let trimmed = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let project = store.create(name: trimmed) {
            selectedProjectId = project.id
        }
        newProjectName = ""
    }
}

private struct ProjectListRow: View {
    let project: Project
    let memberCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(project.name)
                .font(.system(size: 13, weight: .medium))
            Text("\(memberCount) session\(memberCount == 1 ? "" : "s")")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct ProjectDetailView: View {
    let project: Project
    @State private var controller: ProjectQAController
    private let store = ProjectStore.shared

    @State private var input: String = ""
    @State private var draftName: String
    @State private var draftInstructions: String
    @State private var instructionsExpanded: Bool = false
    @State private var addSessionSheet: Bool = false
    @State private var copyConfirmId: UUID?
    @State private var copyAllConfirm: Bool = false
    @State private var insights: ProjectInsightsController
    @State private var detailTab: DetailTab = .chat
    @State private var savedSynthesis: ProjectSynthesisArtifact?
    @FocusState private var nameFieldFocused: Bool
    @FocusState private var inputFocused: Bool

    enum DetailTab: String, CaseIterable, Identifiable {
        case chat = "Chat"
        case synthesis = "Synthesis"
        var id: String { rawValue }
    }

    init(project: Project) {
        self.project = project
        _controller = State(initialValue: ProjectQAController(projectId: project.id))
        _insights = State(initialValue: ProjectInsightsController(projectId: project.id))
        _draftName = State(initialValue: project.name)
        _draftInstructions = State(initialValue: project.instructions)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)
            HStack(spacing: 8) {
                Picker("", selection: $detailTab) {
                    ForEach(DetailTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                if insights.isRunning, insights.mode == .synthesize, detailTab != .synthesis {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Synthesizing…")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            Divider()
            HSplitView {
                Group {
                    switch detailTab {
                    case .chat: chatColumn
                    case .synthesis: synthesisColumn
                    }
                }
                sidePanel
                    .frame(minWidth: 240, idealWidth: 280)
            }
        }
        .onAppear(perform: reloadSynthesis)
        .onChange(of: project.id) { _, _ in reloadSynthesis() }
        .onChange(of: insights.isRunning) { _, running in
            if !running, insights.mode == .synthesize { reloadSynthesis() }
        }
    }

    private func reloadSynthesis() {
        savedSynthesis = ProjectInsightsController.loadSavedSynthesis(projectId: project.id)
    }

    @ViewBuilder
    private var projectScopeSubtitle: some View {
        let count = store.sessionIds(forProject: project.id).count
        let hasInstr = !project.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(spacing: 8) {
            Text("Scope: \(count) session\(count == 1 ? "" : "s")")
            if hasInstr {
                Text("·").foregroundStyle(.tertiary)
                Label("Instructions on", systemImage: "text.alignleft")
                    .labelStyle(.titleAndIcon)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: RTIDesign.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Project name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(RTIDesign.Font.sectionTitle)
                    .foregroundStyle(RTIDesign.Color.textPrimary)
                    .focused($nameFieldFocused)
                    .onSubmit(persistName)
                    .onChange(of: project.id) { _, _ in draftName = project.name }
                    .onChange(of: nameFieldFocused) { _, isFocused in
                        if !isFocused { persistName() }
                    }
                projectScopeSubtitle
                    .font(RTIDesign.Font.caption)
                    .foregroundStyle(RTIDesign.Color.textSecondary)
            }
            Spacer()
            headerActions
        }
    }

    private var headerActions: some View {
        HStack(spacing: RTIDesign.Spacing.sm) {
            iconAction(systemName: "square.and.pencil", help: "New chat") {
                controller.newChat()
            }
            if !controller.messages.isEmpty {
                iconAction(systemName: copyAllConfirm ? "checkmark" : "doc.on.doc",
                           help: "Copy conversation") {
                    copyConversation()
                }
                iconAction(systemName: "square.and.arrow.up",
                           help: "Export as markdown") {
                    exportConversation()
                }
            }
            Divider().frame(height: 14)
            Button(action: { instructionsExpanded.toggle() }) {
                Label(instructionsExpanded ? "Hide instructions" : "Instructions",
                      systemImage: "text.alignleft")
                    .font(RTIDesign.Font.button)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
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

    private func copyConversation() {
        let md = controller.exportMarkdown()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
        copyAllConfirm = true
        Task { try? await Task.sleep(for: .seconds(1.4)); await MainActor.run { copyAllConfirm = false } }
    }

    private func exportConversation() {
        let md = controller.exportMarkdown()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        let safe = (controller.conversationTitle ?? project.name)
            .replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "\(safe).md"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? md.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private var synthesisColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RTIDesign.Spacing.md) {
                synthesisHeader
                if let err = insights.lastError, !insights.isRunning {
                    Text(err)
                        .font(RTIDesign.Font.caption)
                        .foregroundStyle(.red)
                }
                if insights.isRunning && insights.mode == .synthesize {
                    if insights.output.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading sessions…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        RTIMarkdown(insights.output, style: .panel)
                    }
                } else if let s = savedSynthesis, !s.body.isEmpty {
                    RTIMarkdown(s.body, style: .panel)
                } else {
                    synthesisEmpty
                }
            }
            .padding(RTIDesign.Spacing.xl)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(RTIDesign.Color.panelBackground)
    }

    @ViewBuilder
    private var synthesisHeader: some View {
        HStack(spacing: RTIDesign.Spacing.sm) {
            Image(systemName: "sparkles")
                .foregroundStyle(RTIDesign.Color.accentText)
            VStack(alignment: .leading, spacing: 0) {
                Text("Synthesis")
                    .font(RTIDesign.Font.sectionTitle)
                if let s = savedSynthesis {
                    Text("Generated \(s.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(RTIDesign.Font.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Cross-session findings → tensions → insights → implications → recommendations")
                        .font(RTIDesign.Font.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if insights.isRunning, insights.mode == .synthesize {
                Button("Stop") { insights.stop() }
                    .controlSize(.small)
            } else {
                Button {
                    insights.reset()
                    insights.synthesize()
                } label: {
                    Label(savedSynthesis == nil ? "Generate" : "Regenerate", systemImage: "sparkles")
                }
                .controlSize(.small)
            }
            if let s = savedSynthesis, !s.body.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(s.body, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
            }
        }
    }

    private var synthesisEmpty: some View {
        VStack(spacing: RTIDesign.Spacing.lg) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(RTIDesign.Color.textTertiary)
            Text("No synthesis yet")
                .font(RTIDesign.Font.heading)
                .foregroundStyle(RTIDesign.Color.textSecondary)
            Text("Generate a cross-session synthesis once at least two sessions in this project have summaries. The result will live as `synthesis.md` next to the project's sessions.")
                .font(RTIDesign.Font.bodySmall)
                .foregroundStyle(RTIDesign.Color.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        }
        .frame(maxWidth: .infinity, minHeight: 280, alignment: .center)
    }

    private var chatColumn: some View {
        VStack(spacing: 0) {
            if instructionsExpanded {
                instructionsEditor
                    .padding(RTIDesign.Spacing.md)
                    .background(RTIDesign.Color.trackBackground)
            }
            if controller.messages.isEmpty {
                emptyChatHint
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                conversation
            }
            if let err = controller.lastError {
                Text(err)
                    .font(RTIDesign.Font.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, RTIDesign.Spacing.xl)
                    .padding(.bottom, 4)
            }
            inputBar
        }
        .background(RTIDesign.Color.panelBackground)
    }

    private var emptyChatHint: some View {
        VStack(spacing: RTIDesign.Spacing.lg) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(RTIDesign.Color.textTertiary)
            Text("Chat with this project")
                .font(RTIDesign.Font.heading)
                .foregroundStyle(RTIDesign.Color.textSecondary)
            Text("Answers come only from the sessions added to this project. Instructions get prepended to every turn.")
                .font(RTIDesign.Font.bodySmall)
                .foregroundStyle(RTIDesign.Color.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if store.sessionIds(forProject: project.id).isEmpty {
                Text("Add a session on the right to begin.")
                    .font(RTIDesign.Font.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(RTIDesign.Spacing.xl)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: RTIDesign.Spacing.lg) {
                    ForEach(controller.messages) { msg in
                        messageBubble(msg)
                            .id(msg.id)
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
    private func messageBubble(_ msg: CorpusChatEntry) -> some View {
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
                    Group {
                        if msg.text.isEmpty && controller.isGenerating {
                            Text("Thinking…")
                                .foregroundStyle(RTIDesign.Color.textTertiary)
                        } else {
                            let isStreaming = controller.isGenerating && msg.id == controller.messages.last?.id
                            if isStreaming {
                                Text(msg.text)
                            } else {
                                RTIMarkdown(msg.text, style: .panel)
                            }
                        }
                    }
                    .font(RTIDesign.Font.body)
                    .foregroundStyle(RTIDesign.Color.textPrimary)
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

    private func copyMessageButton(_ msg: CorpusChatEntry) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(msg.text, forType: .string)
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

    private func citationChips(_ citations: [CorpusChatCitation]) -> some View {
        HStack(spacing: RTIDesign.Spacing.xs) {
            Text("Sources")
                .font(RTIDesign.Font.caption)
                .foregroundStyle(RTIDesign.Color.textTertiary)
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

    private var inputBar: some View {
        HStack(spacing: RTIDesign.Spacing.sm) {
            TextField("Ask about this project…", text: $input)
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

    private var instructionsEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Project instructions")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $draftInstructions)
                .font(.system(.body, design: .default))
                .frame(minHeight: 100, maxHeight: 180)
                .overlay(
                    RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3))
                )
            HStack {
                Spacer()
                Button("Save instructions") {
                    store.update(id: project.id, instructions: draftInstructions)
                }
                .controlSize(.small)
                .disabled(draftInstructions == project.instructions)
            }
        }
    }

    private var sidePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ProjectStatusCard(
                    projectId: project.id,
                    onSynthesize: runSynthesis
                )
                Divider().padding(.vertical, 4)
                HStack {
                    Text("Sessions in this project")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: { addSessionSheet = true }) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .help("Add a session")
                    .accessibilityLabel("Add a session")
                }
                ProjectMembersList(projectId: project.id)
                Divider().padding(.vertical, 4)
                Text("Recent project chats")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                RecentProjectChatsList(projectId: project.id) { conv in
                    controller.load(conv)
                }
                Button(action: { controller.newChat() }) {
                    Label("New chat", systemImage: "square.and.pencil")
                }
                .controlSize(.small)
            }
            .padding(12)
        }
        .sheet(isPresented: $addSessionSheet) {
            AddSessionSheet(projectId: project.id, onDone: { addSessionSheet = false })
        }
    }

    private func runSynthesis() {
        insights.reset()
        detailTab = .synthesis
        insights.synthesize()
    }

    private func persistName() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != project.name else { return }
        store.update(id: project.id, name: trimmed)
    }

    private func submit() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        controller.ask(question: trimmed)
        input = ""
    }
}

private struct ProjectMembersList: View {
    let projectId: String
    private let store = ProjectStore.shared
    @State private var members: [Session] = []
    @State private var lastMemberIds: [String] = []
    @State private var orphanIds: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !orphanIds.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("\(orphanIds.count) member\(orphanIds.count == 1 ? "" : "s") not found in current corpus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove") {
                        for id in orphanIds { store.removeSession(id, fromProject: projectId) }
                        reload()
                    }
                    .controlSize(.small)
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.orange.opacity(0.10))
                )
            }
            if members.isEmpty {
                Text("No sessions yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(members) { session in
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(displayTitle(session))
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Text(session.startedAt.formatted(date: .abbreviated, time: .omitted))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(action: { remove(session.id) }) {
                            Image(systemName: "minus.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove from project")
                        .accessibilityLabel("Remove from project")
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        NotificationCenter.default.post(name: .openSessionDetail, object: session.id)
                    }
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: store.projects) {
            // Membership changes trigger reload; onChange fires on main actor.
            reload()
        }
    }

    private func reload() {
        let ids = store.sessionIds(forProject: projectId)
        // Skip the disk scan when this project's membership hasn't changed —
        // ProjectStore.objectWillChange fires for every project mutation
        // (including renames of other projects), and the corpus scan is the
        // expensive part of this reload.
        if ids == lastMemberIds, !members.isEmpty || ids.isEmpty {
            return
        }
        lastMemberIds = ids
        let all = CorpusBackedStore.allMarkdownSessions()
        let map = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        members = ids.compactMap { map[$0] }
        orphanIds = ids.filter { map[$0] == nil }
    }

    private func remove(_ sessionId: String) {
        store.removeSession(sessionId, fromProject: projectId)
    }

    private func displayTitle(_ s: Session) -> String {
        if let t = s.calendarTitle, !t.isEmpty { return t }
        if let t = s.title, !t.isEmpty { return t }
        return "Session \(s.startedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct RecentProjectChatsList: View {
    let projectId: String
    let onPick: (ProjectChatEntry) -> Void
    @State private var items: [ProjectChatEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if items.isEmpty {
                Text("No chats yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(items, id: \.id) { conv in
                    Button(action: { onPick(conv) }) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(conv.title)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Text(conv.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: projectId) { _, _ in reload() }
    }

    private func reload() {
        guard let slug = ProjectStore.shared.slug(forProject: projectId) else {
            items = []
            return
        }
        items = ProjectChatFileStore.list(projectSlug: slug)
    }
}

private struct AddSessionSheet: View {
    let projectId: String
    let onDone: () -> Void
    private let store = ProjectStore.shared
    private let importer = SessionImporter.shared
    @State private var allSessions: [Session] = []
    @State private var query: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add session to project")
                    .font(.headline)
                Spacer()
                Button("Done", action: onDone)
            }
            .padding(12)
            Divider()
            TextField("Search sessions…", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            List(filtered, id: \.id) { session in
                let inProject = store.sessionIds(forProject: projectId).contains(session.id)
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(displayTitle(session))
                            .font(.system(size: 13, weight: .medium))
                        Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if inProject {
                        Button("Remove") { store.removeSession(session.id, fromProject: projectId) }
                            .controlSize(.small)
                    } else {
                        Button("Add") { store.addSession(session.id, toProject: projectId) }
                            .controlSize(.small)
                    }
                }
            }
        }
        .frame(width: 480, height: 460)
        .onAppear(perform: reloadSessions)
        // Refresh the picker when a drag-to-import finishes mid-sheet, so a
        // freshly-transcribed session is immediately addable without closing
        // and reopening the sheet.
        .onChange(of: importer.activeFilename) {
            reloadSessions()
        }
    }

    private func reloadSessions() {
        allSessions = CorpusBackedStore.allMarkdownSessions().sorted { $0.startedAt > $1.startedAt }
    }

    private var filtered: [Session] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return allSessions }
        return allSessions.filter { displayTitle($0).lowercased().contains(q) }
    }

    private func displayTitle(_ s: Session) -> String {
        if let t = s.calendarTitle, !t.isEmpty { return t }
        if let t = s.title, !t.isEmpty { return t }
        return "Session \(s.startedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}


/// Compact project status card. Surfaces the one thing that matters
/// (the suggested next action) plus last-activity, with a single
/// Synthesize button. The numeric stats and Recall action that lived
/// here previously were noise — dropped.
private struct ProjectStatusCard: View {
    let projectId: String
    let onSynthesize: () -> Void
    private let store = ProjectStore.shared
    @State private var pulse: ProjectPulse?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Status")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if let p = pulse {
                Text(p.suggestion.headline)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                if let last = p.lastSessionAt {
                    Text("Last meeting: \(Self.relative(last))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Button(action: onSynthesize) {
                    Label("Synthesize", systemImage: "sparkles")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                .disabled(p.summarizedCount < 2)
                .padding(.top, 4)
                .help(p.summarizedCount < 2
                      ? "Needs at least two summarized sessions"
                      : "Cross-session findings, tensions, insights, recommendations")
            } else {
                Text("Loading…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.06))
        )
        .onAppear(perform: reload)
        .onChange(of: store.projects) {
            reload()
        }
    }

    private func reload() {
        pulse = ProjectPulse.compute(projectId: projectId)
    }

    private static func relative(_ date: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: date, relativeTo: Date())
    }
}
