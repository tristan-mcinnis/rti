import SwiftUI

/// Projects tab: list of user-defined session groupings on the left,
/// the selected project's detail on the right (chat box, member
/// sessions, instructions). A third tier between per-session Q&A and
/// the full corpus chat.
struct ProjectsView: View {
    @ObservedObject private var store = ProjectStore.shared
    @State private var selectedProjectId: String?
    @State private var newProjectName: String = ""

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, idealWidth: 240)

            if let id = selectedProjectId, let project = store.projects.first(where: { $0.id == id }) {
                ProjectDetailView(project: project)
                    .id(project.id) // force-recreate controller when switching
            } else {
                emptyDetail
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
                                    store.archive(id: project.id)
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
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
    @StateObject private var controller: ProjectQAController
    @ObservedObject private var store = ProjectStore.shared

    @State private var input: String = ""
    @State private var draftName: String
    @State private var draftInstructions: String
    @State private var instructionsExpanded: Bool = false
    @State private var addSessionSheet: Bool = false

    init(project: Project) {
        self.project = project
        _controller = StateObject(wrappedValue: ProjectQAController(projectId: project.id))
        _draftName = State(initialValue: project.name)
        _draftInstructions = State(initialValue: project.instructions)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)
            Divider()
            HSplitView {
                chatColumn
                sidePanel
                    .frame(minWidth: 240, idealWidth: 280)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            TextField("Project name", text: $draftName)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .semibold))
                .onSubmit(persistName)
                .onChange(of: project.id) { _, _ in draftName = project.name }
            Spacer()
            Button(action: { instructionsExpanded.toggle() }) {
                Label(instructionsExpanded ? "Hide instructions" : "Instructions",
                      systemImage: "text.alignleft")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var chatColumn: some View {
        VStack(spacing: 0) {
            if instructionsExpanded {
                instructionsEditor
                    .padding(12)
                    .background(Color.secondary.opacity(0.06))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if controller.messages.isEmpty {
                            emptyChatHint
                                .padding(.top, 40)
                        }
                        ForEach(controller.messages) { msg in
                            ChatBubble(message: msg)
                                .id(msg.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: controller.messages.count) { _, _ in
                    if let last = controller.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            if let err = controller.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
            inputBar
        }
    }

    private var emptyChatHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Chat with this project")
                .font(.headline)
            Text("Answers are drawn only from the sessions you've added to this project. Project instructions get prepended to every turn.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if store.sessionIds(forProject: project.id).isEmpty {
                Text("Add a session on the right to begin.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 4)
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 6) {
            TextField("Ask about this project…", text: $input)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
            }
            .buttonStyle(.plain)
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || controller.isGenerating)
        }
        .padding(10)
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
        VStack(alignment: .leading, spacing: 8) {
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
            }
            ProjectMembersList(projectId: project.id)
            Divider().padding(.vertical, 4)
            Text("Recent project chats")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            RecentProjectChatsList(projectId: project.id) { conv in
                controller.load(conv)
            }
            Spacer()
            Button(action: { controller.newChat() }) {
                Label("New chat", systemImage: "square.and.pencil")
            }
            .controlSize(.small)
        }
        .padding(12)
        .sheet(isPresented: $addSessionSheet) {
            AddSessionSheet(projectId: project.id, onDone: { addSessionSheet = false })
        }
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
    @ObservedObject private var store = ProjectStore.shared
    @State private var members: [Session] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
        .onReceive(store.objectWillChange) { _ in
            // Membership changes trigger a global publish; reload our slice.
            DispatchQueue.main.async(execute: reload)
        }
    }

    private func reload() {
        let ids = store.sessionIds(forProject: projectId)
        let all = CorpusBackedStore.allMarkdownSessions()
        let map = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        members = ids.compactMap { map[$0] }
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
    let onPick: (ProjectChatConversation) -> Void
    @State private var items: [ProjectChatConversation] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if items.isEmpty {
                Text("No chats yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(items) { conv in
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
        items = ProjectChatHistoryStore.list(projectId: projectId)
    }
}

private struct AddSessionSheet: View {
    let projectId: String
    let onDone: () -> Void
    @ObservedObject private var store = ProjectStore.shared
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
        .onAppear { allSessions = CorpusBackedStore.allMarkdownSessions().sorted { $0.startedAt > $1.startedAt } }
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

private struct ChatBubble: View {
    let message: ProjectQAController.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.role == "user" ? "You" : "RTI")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(.init(message.text))
                .font(.system(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !message.citations.isEmpty {
                HStack(spacing: 4) {
                    ForEach(message.citations) { c in
                        Button(action: {
                            NotificationCenter.default.post(name: .openSessionDetail, object: c.sessionId)
                        }) {
                            Text(c.title)
                                .font(.system(size: 10))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(message.role == "user" ? 0.08 : 0.04))
        )
    }
}
