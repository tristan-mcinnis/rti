import AppKit
import Foundation
import HouseChatCore
import HouseChatDocuments
import Observation
import RTICore

extension LLMController {
    // MARK: Composer commands

    /// What the composer should do with a line.
    enum ChatCommandOutcome: Equatable {
        /// A command ran, or a composer-owned one was recognized.
        case handled(String)
        /// No such command. It went nowhere: only an explicit Send as Text
        /// action may turn it into a message.
        case unknown(rawName: String, message: String)
        /// Ordinary prompt text.
        case notACommand
        case empty
    }

    /// Commands the composer owns (a mode switch, not a model call). The
    /// parser recognizes them so they are never mistaken for unknown, and the
    /// caller acts on the id.
    static let composerOwnedCommandIDs: Set<String> = ["note", "chat"]

    /// The commands the shared parser recognizes for RTI: RTI's own catalogue
    /// as known commands, plus its aliases. The parser's own builtins
    /// (`/new`, `/clear`) are recognized before any alias, so an alias can
    /// never shadow them.
    static var composerCommandParser: ChatCommandParser {
        var aliases: [String: String] = [:]
        for command in ComposerSlashCommand.all {
            let canonical = "/" + command.id
            for alias in command.aliases {
                aliases["/" + alias] = canonical
            }
        }
        return ChatCommandParser(
            knownCommands: Set(ComposerSlashCommand.all.map { "/" + $0.id }),
            aliases: aliases
        )
    }

    /// Parse and run a composer line.
    ///
    /// An unknown slash command is refused and shown locally. This method never
    /// sends it: the only path that turns it into a message is the caller's
    /// explicit `sendAsText(_:)`, which is what "stay local with an explicit
    /// Send as Text action" means.
    func handleComposerCommand(_ input: String) -> ChatCommandOutcome {
        switch Self.composerCommandParser.parse(input) {
        case .empty:
            return .empty
        case .notACommand:
            return .notACommand
        case let .unknown(rawName, message):
            postLocalTurn(userInput: input, action: "Command", output: message)
            return .unknown(rawName: rawName, message: message)
        case let .command(command):
            switch command.name {
            case .new, .clear:
                newChat()
                return .handled(command.name.rawValue)
            case let .known(name):
                let id = name.hasPrefix("/") ? String(name.dropFirst()) : name
                if Self.composerOwnedCommandIDs.contains(id) {
                    return .handled(id)
                }
                let argument = command.arguments.joined(separator: " ")
                guard runComposerCommand(id: id, argument: argument) else {
                    let detail = "Unknown command \(command.rawName)."
                    postLocalTurn(userInput: input, action: "Command", output: detail)
                    return .unknown(rawName: command.rawName, message: detail)
                }
                return .handled(id)
            }
        }
    }

    /// Run one RTI command by id. Returns false when no handler exists.
    @discardableResult
    func runComposerCommand(id: String, argument: String) -> Bool {
        switch id {
        case "assist": sendAssist()
        case "answer": sendAnswerLatest()
        case "say": sendSaySomething()
        case "followups": sendFollowupQuestions()
        case "recap": sendRecap()
        case "screen": ScreenshotManager.shared.captureAndAttach()
        case "recent":
            sendAskAnything("What were the most recent meetings or sessions for this project? Use the recent meetings tool if project context is available.")
        case "search": sendVaultSearchCommand(argument)
        case "sources": sendVaultSourcesCommand(argument.isEmpty ? nil : argument)
        case "project": runProjectCommand(argument)
        case "help": showSlashHelp()
        default: return false
        }
        return true
    }

    /// The one path that turns a refused line into a message: the caller asks
    /// for it explicitly, after the local error has been shown.
    func sendAsText(_ text: String) {
        sendAskAnything(text)
    }

    // MARK: Streaming checkpoints

    /// Start writing the partial answer periodically. The terminal write
    /// replaces the same turn, so a checkpointed answer is one row.
    func startCheckpointing(turnID: UUID) {
        checkpointTask?.cancel()
        checkpointTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.checkpointIntervalNanoseconds)
                if Task.isCancelled { return }
                await self?.writeCheckpoint(turnID: turnID)
            }
        }
    }

    @discardableResult
    func stopCheckpointing() -> Task<Void, Never>? {
        let task = checkpointTask
        task?.cancel()
        checkpointTask = nil
        return task
    }

    /// One checkpoint write. Silent when there is nothing to say yet, and loud
    /// only to the log when the write fails: the answer is still streaming and
    /// the user is owed the text, not a dialog.
    private func writeCheckpoint(turnID: UUID) async {
        guard streaming, streamingEntryID == turnID,
              let pending = pendingTurn, pending.id == turnID,
              let conversationID = pending.conversationID,
              let index = entries.firstIndex(where: { $0.id == turnID })
        else { return }
        let text = entries[index].text
        guard !text.isEmpty else { return }
        do {
            guard let store = try chatStore() else { return }
            try await store.checkpoint(
                conversationID: conversationID,
                turnID: turnID.uuidString,
                text: text,
                startedAt: pending.startedAt,
                model: Self.modelSelection(for: pending.route),
                toolRounds: Self.toolRounds(from: pending.toolCalls)
            )
        } catch {
            RTILog.log("checkpoint skipped: \(error)", category: .llm)
        }
    }

    /// Freeze this turn's route from the chat's selection. The decision itself    /// is pure (`ChatRouteResolver`); this only supplies the registry entry
    /// and the vision fallback the user accepted.
    func resolveTurnRoute(
        imageCount: Int,
        forceSmart: Bool
    ) -> Result<ChatRouteConfiguration, ChatRouteBlocker> {
        if let routeResolver {
            return routeResolver(chatSelection, imageCount, forceSmart)
        }
        let provider = LLMProviders.option(id: chatSelection.providerId).config
        var selection = chatSelection
        // The visible thinking override and the global smart default
        // both land here, on the per-chat selection, before it freezes.
        if forceSmart { selection.reasoning = .thinking }
        // No separate vision model ships today, so an image on a text-only
        // route degrades to text-only and is labelled. When the registry gains
        // a vision model, name it here and the thread labels the fallback.
        let options = ChatRouteOptions(
            visionModelIds: provider.supportsVision ? [provider.model] : [],
            visionFallbackModelId: nil
        )
        return ChatRouteResolver.resolve(
            selection: selection,
            provider: provider,
            options: options,
            imageCount: imageCount
        )
    }

    func showSlashHelp() {
        postLocalTurn(
            userInput: "/help",
            action: "Help",
            output: """
            **Slash commands**
            `/search <query>` — fast vault RAG search in the selected project/client, or whole vault if nothing is selected.
            `/sources [query]` — show source hits for a query; if blank, uses your last question.
            `/project [name]` — set project/client context by name. Blank shows current context. Use `/project clear` to go vault-wide.
            `/answer` — answer the latest live question/point.
            `/recent` — ask about recent sessions for the selected project.
            `/screen` — OCR connected screens and attach them to the next message.
            `/note <text>` — add a live transcript note.
            `/new` — clear this chat.

            `@file-or-phrase` attaches a vault document. It searches the selected project/client first, then the whole vault.
            Use **Attach file…** (or drag one in) for a one-turn PDF, Markdown, or text-file attachment; RTI keeps only its in-memory text for that request.
            """
        )
    }

    func sendVaultSearchCommand(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            postLocalTurn(userInput: "/search", action: "Search", output: "Usage: `/search <query>`")
            return
        }
        guard !streaming else { return }
        let userInput = "/search \(trimmed)"
        let assistant = ChatEntry(role: "assistant", text: "Searching vault…", action: nil, contextUsed: false, screenContextUsed: false)
        entries.append(ChatEntry(role: "user", text: userInput, action: "Search", contextUsed: false, screenContextUsed: false))
        entries.append(assistant)
        let assistantID = assistant.id
        progressStatus[assistantID] = "Searching the vault…"
        Task { @MainActor in
            let scope = Self.retrievalScope(for: trimmed)
            let retrieval = await VaultRetrieval.search(query: trimmed, scopeRelativePath: scope)
            self.retrievalDiagnostic = Self.statusDiagnostic(retrieval.status)
            let label = scope == nil ? "Vault-wide search" : "Scoped search"
            finishLocalProgress(assistantID, retrieval: retrieval, scoped: scope != nil)
            updateLocalAssistant(
                assistantID,
                text: Self.searchAnswerText(label: label, retrieval: retrieval)
            )
        }
    }

    func sendVaultSourcesCommand(_ query: String?) {
        let fallback = lastUserQuestion()
        let trimmed = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = trimmed.isEmpty ? fallback : trimmed
        guard !effective.isEmpty else {
            postLocalTurn(userInput: "/sources", action: "Sources", output: "Usage: `/sources <query>` or run it after asking a question.")
            return
        }
        guard !streaming else { return }
        let userInput = trimmed.isEmpty ? "/sources" : "/sources \(trimmed)"
        let assistant = ChatEntry(role: "assistant", text: "Finding sources…", action: nil, contextUsed: false, screenContextUsed: false)
        entries.append(ChatEntry(role: "user", text: userInput, action: "Sources", contextUsed: false, screenContextUsed: false))
        entries.append(assistant)
        let assistantID = assistant.id
        progressStatus[assistantID] = "Finding sources…"
        Task { @MainActor in
            let scope = Self.retrievalScope(for: effective)
            let retrieval = await VaultRetrieval.search(query: effective, scopeRelativePath: scope)
            self.retrievalDiagnostic = Self.statusDiagnostic(retrieval.status)
            let label = scope == nil ? "Vault-wide sources" : "Scoped sources"
            finishLocalProgress(assistantID, retrieval: retrieval, scoped: scope != nil)
            updateLocalAssistant(
                assistantID,
                text: "**\(label) for:** \(effective)\n\n" + Self.searchAnswerText(label: label, retrieval: retrieval)
            )
        }
    }

    func runProjectCommand(_ argument: String) {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let current = MeetingContextStore.shared.workstreamName.map { "Current context: **\($0)**" }
                ?? "No project/client selected. RAG defaults to the whole vault."
            let projects = VaultWorkstreamStore.projects().prefix(8).map(\.name).joined(separator: ", ")
            let clients = VaultWorkstreamStore.clients().prefix(5).map(\.name).joined(separator: ", ")
            let examples = "Use `/project acme wear`, `/project clear`, or pick one in Setup."
            postLocalTurn(
                userInput: "/project",
                action: "Project",
                output: "\(current)\n\nProjects: \(projects.isEmpty ? "none found" : projects)\n\nClients: \(clients.isEmpty ? "none found" : clients)\n\n\(examples)"
            )
            return
        }
        if ["clear", "none", "vault", "all"].contains(trimmed.lowercased()) {
            MeetingContextStore.shared.clearWorkstream()
            postLocalTurn(userInput: "/project \(trimmed)", action: "Project", output: "Project/client context cleared. Vault commands and RAG now search the whole vault by default.")
            return
        }
        if let item = MeetingContextStore.shared.selectWorkstream(matching: trimmed) {
            let kind = item.isProject ? "project" : "client"
            let scope = item.isProject ? (VaultWorkstreamStore.scopeRelativePath(for: item) ?? "unknown") : (VaultWorkstreamStore.fileAccessRelativePath(for: item) ?? "unknown")
            postLocalTurn(userInput: "/project \(trimmed)", action: "Project", output: "Using \(kind): **\(item.name)**\n\nScope: `\(scope)`")
        } else {
            postLocalTurn(userInput: "/project \(trimmed)", action: "Project", output: "No matching project or client found for `\(trimmed)`. Try a shorter name or pick it in Setup.")
        }
    }
}
