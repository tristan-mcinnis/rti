import AppKit
import RTICore
import SwiftUI

/// The Assist tab's answer area: the house thread (`AssistThread`), the
/// find bar over it, and the errors that belong to no turn just above the
/// composer. An adapter only: it reads `LLMController` and hands the thread
/// plain values, so the thread never observes the session or the recorder.
struct ResponseView: View {
    let entries: [ChatEntry]
    let streaming: Bool
    let error: String?
    var errorIsAuth: Bool = false
    var onOpenSettings: () -> Void = {}

    private let llm = LLMController.shared
    @Bindable private var find = ThreadFindState.shared
    @AppStorage(OverlayAppearanceDefaults.uiFontSizeKey) private var uiFontSize: Double = OverlayAppearanceDefaults.defaultUIFontSize

    var body: some View {
        let model = threadModel
        let index = find.isPresented ? ThreadFindIndex(query: find.query, entries: entries, questionText: model.pillText(for:)) : nil
        let current = index.flatMap { index in find.currentIndex(of: index.hits.count).map { index.hits[$0] } }
        VStack(spacing: 0) {
            if find.isPresented {
                HouseFindBar(
                    find: find,
                    status: find.status(count: index?.hits.count ?? 0),
                    onNext: { find.step(1, count: index?.hits.count ?? 0) },
                    onPrevious: { find.step(-1, count: index?.hits.count ?? 0) }
                )
            }
            AssistThread(
                model: model,
                find: index.map { ThreadFindHighlights(hits: $0.hits, current: current) },
                actions: AssistThreadActions(
                    retry: { llm.retryLastTurn() },
                    openSource: Self.openSource
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The thread never scrolls up under what sits above it.
            .clipped()
            composerNotices
        }
        .background { keyShortcuts(hitCount: index?.hits.count ?? 0) }
    }

    // MARK: - Model

    private var threadModel: AssistThreadModel {
        var model = AssistThreadModel()
        model.entries = entries
        // Only the newest entry can be the one streaming, and only an answer.
        model.streamingID = streaming && entries.last?.role == "assistant" ? entries.last?.id : nil
        model.streamingStatus = streamingStatus
        model.progress = llm.progressStatus
        if let error, !error.isEmpty, !errorIsAuth, let id = llm.lastErrorTurnID {
            model.turnError = .init(questionID: id, message: error)
        }
        model.recapDepth = llm.recapDepth
        model.emptyHints = keysMissing ? missingKeyHints : readyHints
        model.proseSize = CGFloat(uiFontSize)
        return model
    }

    /// What the answer is doing before its text lands.
    private var streamingStatus: String {
        if let status = llm.toolStatus.map(ToolTraceParser.statusText), !status.isEmpty { return status }
        return llm.reasoning ? "Reasoning…" : "Thinking…"
    }

    /// Three ways in, each with its real key.
    private var readyHints: [String] {
        let primary = AssistantAction.byID(llm.primaryActionID)?.label ?? "Assist"
        return ["⌘↩ runs \(primary)", "@ adds a vault file", "⌘K for actions"]
    }

    private var keysMissing: Bool { !LLMProviders.activeHasKey || !STTProviders.activeHasKey }

    private var missingKeyHints: [String] {
        ["RTI needs a Soniox key to transcribe and a \(LLMProviders.active.displayName) key to answer.", "Keys stay on this Mac."]
    }

    // MARK: - Above the composer

    /// Errors with no turn to sit under: missing keys, an auth failure, a
    /// file that would not attach, a capture fault. Each with its fix.
    @ViewBuilder
    private var composerNotices: some View {
        if keysMissing {
            AssistComposerNotice(message: missingKeysMessage, fixTitle: "Open Settings", onFix: onOpenSettings)
        } else if let error, !error.isEmpty, errorIsAuth || llm.lastErrorTurnID == nil {
            AssistComposerNotice(message: error, fixTitle: errorIsAuth ? "Open Settings" : nil, onFix: onOpenSettings)
        }
        AssistCaptureErrorNotice()
    }

    private var missingKeysMessage: String {
        switch (STTProviders.activeHasKey, LLMProviders.activeHasKey) {
        case (false, false): "No API keys yet."
        case (false, true): "No Soniox key yet."
        default: "No \(LLMProviders.active.displayName) key yet."
        }
    }

    // MARK: - Keys

    /// The thread's own keys while the Assist tab shows: `⌘F` find, `⌘G`
    /// and `⇧⌘G` step through hits, `⌘R` asks the last turn again. The menu
    /// bar may name the same actions; these keep them working until it does.
    private func keyShortcuts(hitCount: Int) -> some View {
        Group {
            Button("Find in Chat") { find.open() }
                .keyboardShortcut("f", modifiers: .command)
            if find.isPresented {
                Button("Find Next") { find.step(1, count: hitCount) }
                    .keyboardShortcut("g", modifiers: .command)
                Button("Find Previous") { find.step(-1, count: hitCount) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }
            if !streaming, llm.lastErrorTurnID != nil || llm.latestAnswer != nil {
                Button("Retry") { llm.retryLastTurn() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: - Sources

    /// A source row: an RTI session opens in Sessions; any other vault file
    /// shows in Finder.
    private static func openSource(_ source: ChatSource) {
        let parts = source.path.split(separator: "/").map(String.init)
        if let i = parts.firstIndex(of: "sessions"), i > 0, parts[i - 1] == "rti", i + 1 < parts.count {
            WindowCoordinator.shared.showSession(folder: parts[i + 1])
            return
        }
        let url = source.path.hasPrefix("/")
            ? URL(fileURLWithPath: source.path)
            : VaultPaths.databasesDirectory()?.appendingPathComponent(source.path)
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// A capture fault (`SessionCoordinator.lastError`) above the composer. Its
/// own small view, so only it observes the session.
private struct AssistCaptureErrorNotice: View {
    private let session = SessionCoordinator.shared

    var body: some View {
        if let message = session.lastError, !message.isEmpty {
            AssistComposerNotice(message: message)
        }
    }
}
