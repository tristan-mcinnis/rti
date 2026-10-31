import AppKit
import RTICore
import SwiftUI
import UniformTypeIdentifiers
import HouseDesign

extension AssistantInputView {
    // MARK: Drop and import

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var took = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                took = true
                let pending = ComposerDocument(name: provider.suggestedName ?? "File", phase: .reading)
                documents.append(pending)
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    Task { @MainActor in
                        guard let index = documents.firstIndex(where: { $0.id == pending.id }) else { return }
                        guard let url else {
                            documents[index].phase = .failed("Could not read the dropped file")
                            return
                        }
                        documents.remove(at: index)
                        dropFile(url)
                    }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                took = true
                let pending = ComposerDocument(name: provider.suggestedName ?? "Image", phase: .reading)
                documents.append(pending)
                provider.loadObject(ofClass: NSImage.self) { object, _ in
                    let image = object as? NSImage
                    Task { @MainActor in
                        guard let index = documents.firstIndex(where: { $0.id == pending.id }) else { return }
                        guard let image else {
                            documents[index].phase = .failed("Could not read the dropped image")
                            return
                        }
                        documents.remove(at: index)
                        ScreenshotManager.shared.attachDroppedImage(image)
                    }
                }
            }
        }
        return took
    }

    /// An image file is read on-device like a screen; any other file loads
    /// as a document.
    private func dropFile(_ url: URL) {
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
           let image = NSImage(contentsOf: url) {
            ScreenshotManager.shared.attachDroppedImage(image)
        } else {
            addDocument(url)
        }
    }

    func handleFileImport(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result else { return }
        // `dropFile` routes an image to the screenshot lane and everything else
        // to the document lane, so picking a saved screenshot here behaves the
        // same as dropping it on the composer.
        urls.forEach(dropFile)
    }

    /// Reads the file off the main thread; the chip says "Reading…" until
    /// then, and the reason if it fails.
    private func addDocument(_ url: URL) {
        let name = url.lastPathComponent
        // The same file twice is one chip; a failed read may be tried again.
        guard !documents.contains(where: { $0.isSameSource(as: url) && !isFailed($0) }) else { return }
        documents.removeAll { $0.isSameSource(as: url) }
        let item = ComposerDocument(name: name, phase: .reading, sourceURL: url)
        documents.append(item)
        Task {
            let phase: ComposerDocument.Phase
            do {
                let attachment = try await Task.detached(priority: .userInitiated) {
                    try await ExternalDocumentLoader.load(url: url)
                }.value
                phase = .ready(attachment)
            } catch let error as ExternalDocumentLoader.LoadError {
                phase = .failed(error.chipReason)
            } catch {
                phase = .failed("Could not be read")
            }
            guard let index = documents.firstIndex(where: { $0.id == item.id }) else { return }
            documents[index].phase = phase
        }
    }

    private func isFailed(_ document: ComposerDocument) -> Bool {
        if case .failed = document.phase { return true }
        return false
    }

    // MARK: Submit

    /// What a typed slash line turned out to be.
    private enum SlashLineOutcome {
        /// Not a command at all: send the words as an ordinary question.
        case notACommand
        /// A command ran. The field's business is done.
        case ran
        /// No such command: it stays local, in the field, until the explicit
        /// Send as Text action.
        case staysLocal
    }

    func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        switch inputState.mode {
        case .liveNote:
            guard !text.isEmpty else { return }
            if submitLiveNote(text) {
                input = ""
                inputState.mode = .chat
                focusField()
            }
        case .chat:
            guard !text.isEmpty || hasSendableChips else { return }
            // A document still reading would be left behind; wait for it.
            guard attachmentStatus == .ready else { return }
            if text.hasPrefix("/") {
                switch submitSlashLine(text) {
                case .notACommand:
                    break
                case .ran:
                    input = ""
                    focusField()
                    return
                case .staysLocal:
                    // The words stay in the field: the local reason is shown,
                    // and only Send as Text sends them.
                    focusField()
                    return
                }
            }
            if !text.isEmpty { inputState.lastQuestion = text }
            llm.sendAskAnything(inputWithSelectedMentions(text), attachments: readyAttachments)
            input = ""
            selectedMentionPaths = []
            documents = []
            focusedChipID = nil
        }
    }

    /// The one path that turns a refused slash line into a message: the user
    /// chose the explicit action, so the typed words go verbatim as an
    /// ordinary question. Chips stay for the next question, the way a
    /// `/recap` line leaves them.
    func sendAsText() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, attachmentStatus == .ready else { return }
        inputState.lastQuestion = text
        llm.sendAsText(text)
        input = ""
        focusField()
    }

    /// Run a command picked from the `/` chooser.
    func runSlashCommand(_ id: String) {
        _ = submitSlashLine("/" + id)
    }

    /// A slash line, through the one shared `ChatCommandParser` (the product
    /// RTICore and Quick Launch both link), so the command set the composer
    /// recognizes is the same one the assistant runs. Builtins precede
    /// aliases inside the parser, so `/clear` can never be shadowed.
    private func submitSlashLine(_ text: String) -> SlashLineOutcome {
        switch LLMController.composerCommandParser.parse(text) {
        case .empty, .notACommand:
            return .notACommand
        case .unknown:
            // Stays local. The controller posts the reason in the thread;
            // nothing is sent and nothing runs.
            _ = llm.handleComposerCommand(text)
            return .staysLocal
        case let .command(command):
            let argument = command.arguments.joined(separator: " ")
            switch command.name {
            case .new, .clear:
                startNewChat()
                return .ran
            case let .known(name):
                let id = name.hasPrefix("/") ? String(name.dropFirst()) : name
                switch id {
                case "note":
                    // The composer owns the mode switch, so it keeps the
                    // argument's words: `/note off` leaves note mode, and
                    // `/note pricing agreed` writes that note.
                    if argument.isEmpty {
                        inputState.mode = inputState.isNoteMode ? .chat : .liveNote
                    } else if !applyNoteModeArgument(argument) {
                        _ = submitLiveNote(argument)
                    }
                    return .ran
                case "chat":
                    inputState.mode = .chat
                    return .ran
                default:
                    if llm.runComposerCommand(id: id, argument: argument) { return .ran }
                    // A catalogue entry no handler owns: show it locally and
                    // never send it as prompt text.
                    _ = llm.handleComposerCommand(text)
                    return .staysLocal
                }
            }
        }
    }

    /// `/new` and `/clear`: the controller clears the chat and its pending
    /// context without ending the recording and without discarding the saved
    /// thread; the composer clears what it owns — the draft, the chips, the
    /// queued follow-up — and starts fresh.
    private func startNewChat() {
        llm.newChat()
    }

    /// Page navigation keeps the draft; a different conversation owns none of
    /// its pending sources, queued follow-up, or previous-question recall.
    func resetPendingConversation() {
        input = ""
        selectedMentionPaths = []
        documents = []
        focusedChipID = nil
        isQueued = false
        isDropTargeted = false
        fileImporterPresented = false
        isPaletteOpen = false
        isAddContextOpen = false
        paletteQuery = ""
        addContextQuery = ""
        dismissedChooserDraft = nil
        chooserIndex = 0
        inputState.mode = .chat
        inputState.lastQuestion = nil
    }

    @discardableResult
    private func applyNoteModeArgument(_ argument: String) -> Bool {
        switch argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "meeting", "meet", "live", "transcript", "on", "prep":
            inputState.mode = .liveNote
        case "off", "exit", "cancel", "chat":
            inputState.mode = .chat
        default:
            return false
        }
        return true
    }

    private func submitLiveNote(_ text: String) -> Bool {
        if session.isRunning {
            return session.insertNote(text)
        }
        return MeetingContextStore.shared.appendPrepNote(text)
    }
}
