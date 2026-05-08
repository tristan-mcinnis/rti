import SwiftUI

@MainActor
struct CommandPaletteView: View {
    @ObservedObject var registry: CommandRegistry
    @State private var query: String = ""
    @State private var sessionMatches: [SessionSearchResult] = []
    @State private var isSearchingSessions: Bool = false
    @State private var sessionSearchItem: DispatchWorkItem?
    @State private var selectedIndex: Int = 0
    @FocusState private var inputFocused: Bool
    let onDismiss: () -> Void

    /// How long to wait after the last keystroke before hitting FTS. Same
    /// 200ms cadence as the Sessions tab search bar — kept in lockstep so
    /// behaviour feels identical no matter which entry point the user picks.
    private static let searchDebounce: TimeInterval = 0.20

    private var commandMatches: [RTICommand] { registry.search(query) }

    private var results: [PaletteResult] {
        PaletteSearch.compose(
            query: query,
            commands: commandMatches,
            sessions: sessionMatches
        )
    }

    private var hasQuery: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search sessions, actions, and settings…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .regular))
                    .focused($inputFocused)
                    .onChange(of: query) { _, _ in
                        selectedIndex = 0
                        scheduleSessionSearch()
                    }
                    .onSubmit { runSelected() }
                if isSearchingSessions {
                    ProgressView().scaleEffect(0.6)
                }
            }
            .padding(14)

            Divider()

            resultsBody
        }
        .frame(width: 600)
        .background(.regularMaterial)
        .onAppear { inputFocused = true }
        .background(KeyboardHandler(
            onMoveUp: { moveSelection(-1) },
            onMoveDown: { moveSelection(1) },
            onEscape: onDismiss,
            onEnter: runSelected
        ))
    }

    @ViewBuilder
    private var resultsBody: some View {
        if results.isEmpty {
            HStack {
                Text(emptyStateText)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13))
                Spacer()
            }
            .padding(14)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { idx, result in
                            sectionHeaderIfNeeded(at: idx)
                            PaletteRow(
                                result: result,
                                isSelected: idx == selectedIndex,
                                query: hasQuery ? query : nil
                            )
                            .id(idx)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedIndex = idx
                                runSelected()
                            }
                        }
                    }
                }
                .frame(maxHeight: 420)
                .onChange(of: selectedIndex) { _, new in
                    proxy.scrollTo(new, anchor: .center)
                }
            }
        }
    }

    /// Emit a "Sessions" / "Actions" header before the first result of each
    /// kind. Avoids a separate `Section` view so keyboard navigation stays
    /// on the flat result indices.
    @ViewBuilder
    private func sectionHeaderIfNeeded(at idx: Int) -> some View {
        let result = results[idx]
        let isFirstOfKind: Bool = {
            if idx == 0 { return true }
            let prev = results[idx - 1]
            return prev.isCommand != result.isCommand
        }()
        if isFirstOfKind, hasQuery {
            Text(result.isCommand ? "Actions" : "Sessions")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 4)
        }
    }

    private var emptyStateText: String {
        if hasQuery && isSearchingSessions {
            return "Searching…"
        }
        if hasQuery {
            return "No matching commands or sessions"
        }
        return "Type to search sessions, actions, and settings"
    }

    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        let next = selectedIndex + delta
        selectedIndex = max(0, min(results.count - 1, next))
    }

    private func runSelected() {
        guard !results.isEmpty,
              selectedIndex >= 0,
              selectedIndex < results.count else { return }
        let result = results[selectedIndex]
        onDismiss()
        // Defer the action one runloop tick so the palette closes cleanly
        // before the action executes (some actions present new windows that
        // would otherwise race with the palette's dismissal).
        let capturedQuery = query
        DispatchQueue.main.async {
            switch result {
            case .command(let cmd):
                CommandRegistry.shared.recordExecution(cmd.id)
                cmd.perform()
            case .session(let match):
                let payload = SessionDetailRequest(
                    id: match.session.id,
                    highlightQuery: capturedQuery
                )
                NotificationCenter.default.post(name: .openSessionDetail, object: payload)
            }
        }
    }

    /// Debounce session FTS calls so fast typing doesn't fan out N concurrent
    /// reads against the database. Mirrors `SessionHistoryView.performSearch`.
    private func scheduleSessionSearch() {
        sessionSearchItem?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            sessionMatches = []
            isSearchingSessions = false
            return
        }
        isSearchingSessions = true
        let item = DispatchWorkItem {
            Task.detached(priority: .userInitiated) {
                let matches = SessionSearch.search(query: trimmed, limit: 20)
                await MainActor.run {
                    // Drop stale results: the user may have typed more by
                    // the time the DB read returned.
                    guard query == trimmed else { return }
                    sessionMatches = matches
                    isSearchingSessions = false
                }
            }
        }
        sessionSearchItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.searchDebounce, execute: item)
    }
}

// MARK: - Row

@MainActor
private struct PaletteRow: View {
    let result: PaletteResult
    let isSelected: Bool
    let query: String?

    var body: some View {
        switch result {
        case .command(let cmd):
            commandRow(cmd)
        case .session(let match):
            sessionRow(match)
        }
    }

    private func commandRow(_ command: RTICommand) -> some View {
        HStack {
            Text(command.title)
                .font(.system(size: 14))
                .foregroundStyle(isSelected ? Color.white : .primary)
            Spacer()
            if let sub = command.subtitle {
                Text(sub)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isSelected ? Color.accentColor : Color.clear)
    }

    private func sessionRow(_ match: SessionSearchResult) -> some View {
        let title = displayTitle(for: match.session)
        let subtitle = match.session.startedAt.formatted(date: .abbreviated, time: .shortened)
        let snippet = formattedSnippet(match.snippet)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? Color.white.opacity(0.9) : .secondary)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isSelected ? Color.white : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
                }
                if !snippet.characters.isEmpty {
                    Text(snippet)
                        .font(.system(size: 12))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.9) : .secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isSelected ? Color.accentColor : Color.clear)
    }

    private func displayTitle(for session: Session) -> String {
        if let t = session.calendarTitle, !t.isEmpty { return t }
        if let t = session.title, !t.isEmpty { return t }
        return "Session \(session.startedAt.formatted(date: .numeric, time: .shortened))"
    }

    /// Convert FTS5's `«` / `»` snippet markers into a styled
    /// `AttributedString`, with `…` ellipses dimmed. Falls back to plain
    /// text when no markers are present.
    private func formattedSnippet(_ raw: String) -> AttributedString {
        guard !raw.isEmpty else { return AttributedString("") }
        var out = AttributedString()
        var current = ""
        var inMatch = false
        for ch in raw {
            if ch == "«" {
                appendChunk(&out, current, inMatch: false)
                current = ""
                inMatch = true
            } else if ch == "»" {
                appendChunk(&out, current, inMatch: true)
                current = ""
                inMatch = false
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            appendChunk(&out, current, inMatch: inMatch)
        }
        return out
    }

    private func appendChunk(_ attr: inout AttributedString, _ chunk: String, inMatch: Bool) {
        guard !chunk.isEmpty else { return }
        var piece = AttributedString(chunk)
        if inMatch {
            piece.backgroundColor = Color.yellow.opacity(isSelected ? 0.55 : 0.35)
            piece.foregroundColor = isSelected ? Color.black : Color.primary
        }
        attr.append(piece)
    }
}

// MARK: - Keyboard

/// Captures Up/Down/Esc/Enter regardless of where focus lives. The TextField
/// alone won't deliver arrow keys to the SwiftUI view tree, so we intercept
/// at the NSView layer.
private struct KeyboardHandler: NSViewRepresentable {
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onEscape: () -> Void
    let onEnter: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = KeyView()
        view.onMoveUp = onMoveUp
        view.onMoveDown = onMoveDown
        view.onEscape = onEscape
        view.onEnter = onEnter
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? KeyView else { return }
        v.onMoveUp = onMoveUp
        v.onMoveDown = onMoveDown
        v.onEscape = onEscape
        v.onEnter = onEnter
    }

    private final class KeyView: NSView {
        var onMoveUp: (() -> Void)?
        var onMoveDown: (() -> Void)?
        var onEscape: (() -> Void)?
        var onEnter: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Local monitor scoped to this window; bypasses the TextField
            // for navigation/dismissal keys without losing the field's
            // first-responder for typing.
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.window?.isKeyWindow == true else { return event }
                switch event.keyCode {
                case 53: // Esc
                    self.onEscape?()
                    return nil
                case 36, 76: // Return, Enter
                    self.onEnter?()
                    return nil
                case 126: // Up
                    self.onMoveUp?()
                    return nil
                case 125: // Down
                    self.onMoveDown?()
                    return nil
                default:
                    return event
                }
            }
        }
    }
}
