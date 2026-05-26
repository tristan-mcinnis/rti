import SwiftUI

@MainActor
struct CommandPaletteView: View {
    var registry: CommandRegistry
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var inputFocused: Bool
    let onDismiss: () -> Void

    private var commandMatches: [RTICommand] { registry.search(query) }

    private var results: [PaletteResult] {
        PaletteSearch.compose(commands: commandMatches)
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
                TextField("Search actions and settings…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .regular))
                    .focused($inputFocused)
                    .onChange(of: query) { _, _ in
                        selectedIndex = 0
                    }
                    .onSubmit { runSelected() }
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

    /// Emit a section header before the first result of each kind. With a
    /// query: "Actions". Without a query: "Recent" for any commands the user
    /// has run before, then "All actions" for the rest.
    @ViewBuilder
    private func sectionHeaderIfNeeded(at idx: Int) -> some View {
        let result = results[idx]
        if hasQuery {
            if idx == 0 {
                sectionLabel("Actions")
            }
        } else {
            let recentIds = Set(CommandRegistry.shared.recents().map(\.id))
            if case .command(let cmd) = result {
                let isRecent = recentIds.contains(cmd.id)
                let prevIsRecent: Bool? = {
                    guard idx > 0, case .command(let prev) = results[idx - 1] else { return nil }
                    return recentIds.contains(prev.id)
                }()
                if prevIsRecent != isRecent {
                    sectionLabel(isRecent ? "Recent" : "All actions")
                }
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private var emptyStateText: String {
        if hasQuery {
            return "No matching actions"
        }
        return "Type to search actions and settings"
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
        DispatchQueue.main.async {
            switch result {
            case .command(let cmd):
                CommandRegistry.shared.recordExecution(cmd.id)
                cmd.perform()
            }
        }
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
