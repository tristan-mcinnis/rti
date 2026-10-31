import AppKit
import HouseDesign
import RTICore
import SwiftUI
import UniformTypeIdentifiers

extension AssistantInputView {
    // MARK: Chips

    private static let screenChipID = "screen"
    private static let vaultChipPrefix = "vault:"

    var chips: [AttachmentChipModel] {
        var chips = selectedMentionPaths.map { path in
            AttachmentChipModel(
                ref: ChatAttachmentRef(kind: .vaultFile, name: MentionChooserPane.fileName(path), path: path),
                id: Self.vaultChipPrefix + path
            )
        }
        chips += documents.map(\.chip)
        if let screen = screenChip {
            chips.append(screen)
        }
        return chips
    }

    /// One screen or window read: the chip carries the captured screenshot as
    /// a thumbnail, so the attachment is visible before it is sent.
    private var screenChip: AttachmentChipModel? {
        if llm.pendingScreenContext != nil, llm.screenCaptureStatus?.isEmpty != false {
            var chip = AttachmentChipModel(ref: ChatAttachmentRef(kind: .screen, name: "Screenshot"), id: Self.screenChipID)
            chip.thumbnail = llm.pendingScreenPreview
            return chip
        }
        guard let status = llm.screenCaptureStatus, !status.isEmpty else { return nil }
        // The capture posts its steps ("Reading all screens…") and, on a
        // failure, the reason; a step ends with an ellipsis.
        let isStep = status.hasSuffix("…")
        return AttachmentChipModel(
            id: Self.screenChipID,
            kind: .screen,
            name: "Screenshot",
            phase: isStep ? .reading : .failed(status),
            detail: isStep ? status : ""
        )
    }

    func removeChip(_ id: String) {
        if id == Self.screenChipID {
            llm.clearPendingScreenContext()
        } else if id.hasPrefix(Self.vaultChipPrefix) {
            let path = String(id.dropFirst(Self.vaultChipPrefix.count))
            selectedMentionPaths.removeAll { $0 == path }
        } else {
            documents.removeAll { $0.id.uuidString == id }
        }
        if focusedChipID == id {
            focusedChipID = nil
        }
        focusField()
    }

    func clearChips() {
        selectedMentionPaths = []
        documents = []
        llm.clearPendingScreenContext()
        focusedChipID = nil
        focusField()
    }

    private func moveStrip(_ delta: Int) {
        let ids = chips.map(\.id)
        guard !ids.isEmpty else { return }
        let current = focusedChipID.flatMap { ids.firstIndex(of: $0) } ?? ids.count - 1
        focusedChipID = ids[min(max(current + delta, 0), ids.count - 1)]
    }

    // MARK: Keys

    func handleKey(_ key: ComposerKey, _ modifiers: ComposerKeyModifiers, _ hasMarkedText: Bool) -> ComposerTextView.KeyOutcome {
        let chipIDs = chips.map(\.id)
        let context = ComposerKeyContext(
            hasMarkedText: hasMarkedText,
            layer: layer,
            isStreaming: isStreaming,
            isQueued: isQueued,
            isNoteMode: inputState.isNoteMode,
            draft: input,
            hasAttachments: hasSendableChips,
            hasOtherChips: !chipIDs.isEmpty,
            isStripFocused: focusedChipID.map { id in chipIDs.contains(id) } ?? false,
            attachmentStatus: attachmentStatus
        )
        switch ComposerKeyRouter.route(key, modifiers: modifiers, context: context) {
        case .passThrough:
            return .passThrough
        case .consume:
            return .handled
        case .submit:
            submit()
        case .queue:
            isQueued = true
        case .runPrimary:
            llm.sendPrimary()
        case .acceptChooser:
            acceptChooser()
        case let .moveChooser(delta):
            moveChooser(delta)
        case .closeLayer:
            closeLayer()
        case .stopStream:
            stopStream()
        case .clearDraft:
            input = ""
        case .recallLastQuestion:
            guard let last = inputState.lastQuestion, !last.isEmpty else { return .passThrough }
            input = last
        case .togglePalette:
            togglePalette()
        case .toggleAttachments:
            toggleAddContext()
        case .enterStrip:
            focusedChipID = chipIDs.last
        case let .moveStrip(delta):
            moveStrip(delta)
        case .removeFocusedChip:
            if let id = focusedChipID {
                let index = chipIDs.firstIndex(of: id) ?? 0
                removeChip(id)
                let remaining = chips.map(\.id)
                focusedChipID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)]
            }
        case .removeNewestChip:
            if let id = chipIDs.last {
                removeChip(id)
            }
        case let .leaveStrip(alsoPassThrough):
            focusedChipID = nil
            return alsoPassThrough ? .passThrough : .handled
        case let .moveFocus(forward):
            return .moveFocus(forward: forward)
        }
        return .handled
    }

    func performAction(_ action: ComposerAction) {
        switch action.kind {
        case .ask, .addNote: submit()
        case .sendAsText: sendAsText()
        case .runPrimary: llm.sendPrimary()
        case .stop: stopStream()
        case .queued, .blocked: break
        case .acceptChooser: acceptChooser()
        }
        focusField()
    }

    private func stopStream() {
        llm.cancel()
        // The queued draft stays in the field, unsent.
        isQueued = false
    }

    // MARK: Layers

    private func closeLayer() {
        switch layer {
        case .palette:
            closePalette()
        case .addContext:
            if addContextPage == .scope {
                addContextPage = .root
                addContextQuery = ""
                chooserIndex = 0
                addContextFocusToken &+= 1
            } else {
                isAddContextOpen = false
                focusField()
            }
        case .mention, .slash:
            dismissedChooserDraft = input
        case .none:
            break
        }
    }

    func toggleAddContext() {
        if isAddContextOpen {
            isAddContextOpen = false
            focusField()
        } else {
            isPaletteOpen = false
            focusedChipID = nil
            addContextPage = .root
            addContextQuery = ""
            chooserIndex = 0
            isAddContextOpen = true
            // The pane's search field takes the keyboard; the composer keeps
            // its draft untouched behind it.
            addContextFocusToken &+= 1
        }
    }

    func togglePalette() {
        if isPaletteOpen {
            closePalette()
        } else {
            openPalette()
        }
    }

    func openPalette() {
        isAddContextOpen = false
        paletteQuery = ""
        isPaletteOpen = true
    }

    func closePalette() {
        isPaletteOpen = false
        focusField()
    }

    private func moveChooser(_ delta: Int) {
        let count: Int = switch layer {
        case .mention: visibleMentionRows.count
        case .slash: visibleSlashCommands.count
        case .addContext: visibleAddContextRows.count
        case .palette, .none: 0
        }
        guard count > 0 else { return }
        chooserIndex = (chooserIndex + delta + count) % count
    }

    private func acceptChooser() {
        switch layer {
        case .mention:
            if let row = visibleMentionRows[safe: chooserIndex] {
                activate(row)
            }
        case .slash:
            if let command = visibleSlashCommands[safe: chooserIndex] {
                input = ""
                runSlashCommand(command.id)
            }
        case .addContext:
            if let row = visibleAddContextRows[safe: chooserIndex] {
                activate(row)
            }
        case .palette, .none:
            break
        }
    }

    @ViewBuilder
    var floatingLayer: some View {
        switch layer {
        case .palette:
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                CommandPaletteView(
                    query: $paletteQuery,
                    onRun: runPaletteCommand,
                    onClose: closePalette,
                    leadingCommands: paletteLeadingCommands,
                    hiddenRegistryIDs: ["note.toggle", "capture.screen", "capture.window"],
                    maxVisibleRows: HouseComposerMetrics.paletteRows(availableHeight: availableHeight, composerHeight: composerChromeHeight)
                )
                .frame(maxWidth: HouseChatMetrics.paletteWidth)
                .panelGlass(radius: House.Radius.lg)
                .panelShadows()
            }
            .padding(.trailing, House.Spacing.sm)
            .padding(.bottom, composerRowHeight)
            .fixedSize(horizontal: false, vertical: true)
        case .addContext:
            HouseFloatingChooser {
                AddContextPane(
                    rows: visibleAddContextRows.map(\.row),
                    selectedIndex: chooserIndex,
                    query: $addContextQuery,
                    focusToken: addContextFocusToken,
                    title: addContextPage == .scope ? "Search Scope" : "Add Context",
                    isSubpage: addContextPage == .scope,
                    footnote: addContextPage == .root ? contextFootnote : nil,
                    searchPlaceholder: addContextPage == .scope ? "Search scopes" : "Search context",
                    maxRows: HouseComposerMetrics.addContextRows(
                        availableHeight: availableHeight,
                        composerHeight: composerChromeHeight
                    ),
                    onMove: { moveChooser($0) },
                    onSubmit: { acceptChooser() },
                    onClose: { closeLayer() },
                    // `⌘K` here means the action palette, as it does in Quick
                    // Launch's Attach pane, rather than just closing the menu.
                    onCommandK: openPalette,
                    onActivate: activate
                )
            }
            .padding(.bottom, composerRowHeight)
            .fixedSize(horizontal: false, vertical: true)
        case .mention:
            HouseFloatingChooser {
                // The `+` pane's rows plus the vault's own matches, filtered by
                // the words typed after the `@`. The chooser opens on the `@`
                // itself, so with no answer yet it says it is looking.
                ContextChooserPane(
                    rows: visibleMentionRows,
                    selectedIndex: chooserIndex,
                    isSearching: mentionSuggestions.isSearching,
                    onPick: activate
                )
            }
            .padding(.bottom, composerRowHeight)
            .fixedSize(horizontal: false, vertical: true)
        case .slash:
            HouseFloatingChooser {
                SlashChooserPane(commands: visibleSlashCommands, selectedIndex: chooserIndex) { command in
                    input = ""
                    runSlashCommand(command.id)
                    focusField()
                }
            }
            .padding(.bottom, composerRowHeight)
            .fixedSize(horizontal: false, vertical: true)
        case .none:
            EmptyView()
        }
    }
}
