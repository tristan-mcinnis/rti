import AppKit
import HouseDesign
import Observation
import RTICore
import UniformTypeIdentifiers

extension SessionsWindowModel {
    // MARK: - Actions

    func actions(for row: Row) -> [SessionAction] {
        let isOpen = row.id == openRowID
        return SessionAction.allCases.filter { action in
            switch action {
            case .ask:
                return row.vaultTranscriptPath != nil
            case .rename, .nameSpeakers:
                return row.session.isRTIArchive
            case .editTranscript:
                return row.session.isRTIArchive && row.hasTranscript
            case .upgradeTranscript:
                return row.hasRetainedAudio && upgradingRowID == nil
            case .copy, .saveMarkdown, .savePDF:
                return !isOpen || !fileText.isEmpty
            case .share:
                return dependencies.shareText != nil && (!isOpen || !fileText.isEmpty)
            case .trash:
                let coordinator = SessionCoordinator.shared
                let sameStart = coordinator.startedAt.flatMap { started in
                    row.session.date.map { abs(started.timeIntervalSince($0)) < 1 }
                } ?? false
                let active = coordinator.phase != .idle && coordinator.phase != .done && sameStart
                return row.session.isRTIArchive && dependencies.trashSession != nil && !isDeleting
                    && !active && upgradingRowID != row.id
            case .revealInFinder:
                return true
            }
        }
    }

    /// Show the actions card for a row (or the open session).
    func showActions(for rowID: String? = nil, placement: ActionsPlacement) {
        guard let id = rowID ?? openRowID else { return }
        actionsRowID = id
        actionIndex = 0
        actionQuery = ""
        actionsPlacement = placement
    }

    func closeActions() {
        actionsPlacement = nil
        actionsRowID = nil
        actionQuery = ""
    }

    var actionsRow: Row? {
        rows.first { $0.id == actionsRowID }
    }

    var visibleActions: [SessionAction] {
        let actions = actionsRow.map(actions(for:)) ?? []
        guard !actionQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return actions }
        return actions.enumerated().compactMap { index, action -> (Int, Int, SessionAction)? in
            guard let score = CommandRegistry.matchScore(query: actionQuery, title: action.title) else { return nil }
            return (score, index, action)
        }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 > $1.0 }.map(\.2)
    }

    func moveActionHighlight(_ delta: Int) {
        let count = visibleActions.count
        guard count > 0 else { return }
        actionIndex = (actionIndex + delta + count) % count
    }

    func performHighlightedAction() {
        let list = visibleActions
        guard list.indices.contains(actionIndex), let id = actionsRowID else { return }
        perform(list[actionIndex], rowID: id)
    }

    /// Run an action on a row. A row that is not open opens first, so the
    /// action works on what the reader shows.
    func perform(_ action: SessionAction, rowID: String? = nil) {
        guard let id = rowID ?? openRowID, let row = rows.first(where: { $0.id == id }) else { return }
        closeActions()
        guard actions(for: row).contains(action) else { return }
        if action != .rename {
            open(id)
        }
        switch action {
        case .ask: askInRTI(row)
        case .rename: beginRename(id)
        case .nameSpeakers:
            isSpeakerEditorPresented = true
        case .editTranscript:
            selectFile(named: "transcript")
            transcriptTurns = SessionTranscriptReview.turns(from: rawText(of: "transcript") ?? "")
            isEditingTranscript = true
        case .upgradeTranscript:
            pendingUpgradeRowID = id
            isUpgradeChoicePresented = true
        case .copy:
            NSPasteboard.copyMarkdownRich(fileText)
            notice = (id, "Copied as Markdown")
        case .share: dependencies.shareText?(fileText)
        case .trash:
            pendingDeletionRowID = id
            isDeleteConfirmationPresented = true
        case .saveMarkdown: exportMarkdown()
        case .savePDF: exportPDF()
        case .revealInFinder: NSWorkspace.shared.activateFileViewerSelecting([row.session.url])
        }
    }

    func cancelDeletion() {
        isDeleteConfirmationPresented = false
        pendingDeletionRowID = nil
    }

    func confirmDeletion() {
        guard pendingDeletionRowID != nil else { return }
        isDeleteConfirmationPresented = false
        deletionRequest = UUID()
    }

    /// Called by the view's structured task only after explicit confirmation.
    func deleteConfirmedSession() async {
        guard deletionRequest != nil, let id = pendingDeletionRowID,
              let row = rows.first(where: { $0.id == id }), actions(for: row).contains(.trash),
              let trash = dependencies.trashSession else { return }
        isDeleting = true
        playback.pause()
        defer { isDeleting = false; pendingDeletionRowID = nil; deletionRequest = nil }
        do {
            try await trash(row.session.url)
            await reload()
            if let openRowID {
                notice = (openRowID, "Session moved to Trash. Restore it in Finder if needed.")
            }
        } catch {
            notice = (id, error.localizedDescription)
        }
    }

    // MARK: - Keys

    /// Run a window key. Returns false when nothing wanted it, so the event
    /// goes on to the focused view.
    func handle(_ command: SessionsWindowCommand) -> Bool {
        // Chats mode answers only the two keys that belong to the window
        // itself; every meeting command is left alone.
        guard mode == .sessions else {
            switch command {
            case .toggleList:
                toggleRail()
                return true
            case .escape:
                return chatLibrary.popLayer()
            default:
                return false
            }
        }
        let editing = isEditingTranscript
        switch command {
        case .toggleList:
            toggleRail()
            return true
        case .find:
            showFind()
            return true
        case .findNext:
            guard isFindPresented else { return false }
            findNext()
            return true
        case .findPrevious:
            guard isFindPresented else { return false }
            findPrevious()
            return true
        case .actions:
            if actionsPlacement != nil {
                closeActions()
            } else {
                let fromRail = isRailVisible && focus == .railSearch
                let rowID = fromRail ? railRows[safe: railIndex]?.id : openRowID
                showActions(for: rowID, placement: fromRail ? .rail : .header)
            }
            return true
        case .ask:
            guard let row = openRow, actions(for: row).contains(.ask) else { return false }
            perform(.ask)
            return true
        case .rename:
            guard !editing, let id = (isRailVisible && focus == .railSearch) ? railRows[safe: railIndex]?.id : openRowID else { return false }
            beginRename(id)
            return true
        case .copy, .saveMarkdown:
            guard !editing, openRow != nil, !fileText.isEmpty else { return false }
            perform(command == .copy ? .copy : .saveMarkdown)
            return true
        case .close:
            return false
        case let .openRow(number):
            return openRow(number: number)
        case .escape:
            return popLayer()
        case .moveUp, .moveDown:
            let delta = command == .moveUp ? -1 : 1
            if actionsPlacement != nil {
                moveActionHighlight(delta)
                return true
            }
            if focus == .railSearch {
                moveRailHighlight(delta)
                return true
            }
            return false
        case .confirm, .confirmAlternate:
            if actionsPlacement != nil {
                performHighlightedAction()
                return true
            }
            if focus == .find {
                command == .confirm ? findNext() : findPrevious()
                return true
            }
            if focus == .railSearch {
                openHighlighted()
                return true
            }
            return false
        }
    }

    /// `esc` pops one layer: the actions card, the rename field, the find
    /// bar, the rail's search text, then the rail. It never closes the
    /// window.
    func popLayer() -> Bool {
        if actionsPlacement != nil {
            closeActions()
        } else if renamingRowID != nil {
            cancelRename()
        } else if isFindPresented {
            closeFind()
        } else if isRailVisible, !railQuery.isEmpty {
            railQuery = ""
        } else if isRailVisible, focus == .railSearch {
            setRailVisible(false, remember: true)
        } else {
            return false
        }
        return true
    }
}
