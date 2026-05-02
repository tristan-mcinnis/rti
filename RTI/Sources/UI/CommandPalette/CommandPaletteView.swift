import SwiftUI

@MainActor
struct CommandPaletteView: View {
    @ObservedObject var registry: CommandRegistry
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var inputFocused: Bool
    let onDismiss: () -> Void

    private var results: [RTICommand] { registry.search(query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Type a command…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .regular))
                .padding(14)
                .focused($inputFocused)
                .onChange(of: query) { _, _ in selectedIndex = 0 }
                .onSubmit { runSelected() }

            Divider()

            if results.isEmpty {
                HStack {
                    Text("No matching commands")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13))
                    Spacer()
                }
                .padding(14)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { idx, cmd in
                                CommandRow(
                                    command: cmd,
                                    isSelected: idx == selectedIndex
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
                    .frame(maxHeight: 360)
                    .onChange(of: selectedIndex) { _, new in
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
            }
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

    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        let next = selectedIndex + delta
        selectedIndex = max(0, min(results.count - 1, next))
    }

    private func runSelected() {
        guard !results.isEmpty,
              selectedIndex >= 0,
              selectedIndex < results.count else { return }
        let cmd = results[selectedIndex]
        registry.recordExecution(cmd.id)
        onDismiss()
        // Defer the action one runloop tick so the palette closes cleanly
        // before the action executes (some actions present new windows that
        // would otherwise race with the palette's dismissal).
        DispatchQueue.main.async { cmd.perform() }
    }
}

private struct CommandRow: View {
    let command: RTICommand
    let isSelected: Bool

    var body: some View {
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
