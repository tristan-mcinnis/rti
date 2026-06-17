import RTICore
import SwiftUI

struct ResponseView: View {
    let entries: [ChatEntry]
    let streaming: Bool
    let error: String?
    var errorIsAuth: Bool = false
    var onOpenSettings: () -> Void = {}

    private let llm = LLMController.shared
    private let sessionCoord = SessionCoordinator.shared

    private var streamingPlaceholderLabel: String {
        if let toolStatus = llm.toolStatus, !toolStatus.isEmpty { return toolStatus }
        if llm.reasoning { return "reasoning…" }
        if llm.smartMode { return "thinking…" }
        return "responding…"
    }

    private var displayedError: String? {
        if let e = error, !e.isEmpty { return e }
        if let s = sessionCoord.lastError, !s.isEmpty { return s }
        return nil
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if entries.isEmpty && !streaming && error == nil {
                        emptyStateBody
                    }

                    ForEach(entries) { entry in
                        entryRow(entry)
                            .id(entry.id)
                    }

                    if let displayedError, !displayedError.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(displayedError)
                                .font(.system(size: 12))
                                .foregroundStyle(.red.opacity(0.9))
                                .textSelection(.enabled)
                            if errorIsAuth {
                                Button("Open Settings…", action: onOpenSettings)
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Drive scroll-to-bottom from a few signals so a new turn lands
            // visibly even if the row hasn't laid out yet when onChange first
            // fires. We watch entries.count (catches batched user+assistant
            // appends), then defer one runloop tick so SwiftUI has measured
            // the new row before we ask the ScrollViewReader to seek to it.
            // Returning to this tab re-instantiates the view at the top —
            // jump straight back to the latest turn.
            .onAppear {
                if let lastId = entries.last?.id { proxy.scrollTo(lastId, anchor: .bottom) }
            }
            .onChange(of: entries.count) { _, _ in scrollToBottom(proxy: proxy) }
            .onChange(of: entries.last?.id) { _, _ in scrollToBottom(proxy: proxy) }
            // Streaming: each SSE token mutates entries.last?.text, which
            // re-renders the body. An inline Timer.publish would be re-created
            // on every rebuild and never fire while tokens arrive faster than
            // its interval, so drive scroll directly off the text growing.
            .onChange(of: entries.last?.text) { _, _ in
                guard let lastId = entries.last?.id else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private var emptyStateBody: some View {
        if CredentialStore.deepseek == nil || CredentialStore.soniox == nil {
            missingKeysBody
        } else {
            readyBody
        }
    }

    private var missingKeysBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add API keys to get started")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.overlayInk.opacity(0.85))
            Text("RTI needs a Soniox key for live transcription and a \(LLMProviders.active.displayName) key for the assistant. Both stay on this Mac.")
                .font(.system(size: 12))
                .foregroundStyle(Color.overlayInk.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings…", action: onOpenSettings)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }

    private var readyBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ready when you are")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.overlayInk.opacity(0.6))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(["Summarize the last few minutes",
                         "What did they decide?",
                         "Help me reply"], id: \.self) { example in
                    Button { llm.sendAskAnything(example) } label: {
                        Text(example)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.overlayInk.opacity(0.7))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.overlayInk.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .help("Ask this")
                }
            }
        }
    }

    /// Defer the scroll by one runloop tick so SwiftUI has actually laid out
    /// the newly-appended row before we ask the proxy to seek to it. Without
    /// this, hitting Assist on a long conversation often left the new turn
    /// off-screen because onChange fired before layout completed.
    private func scrollToBottom(proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            guard let lastId = entries.last?.id else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(lastId, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: ChatEntry) -> some View {
        if entry.role == "user" {
            HStack {
                Spacer(minLength: 40)
                // Canned actions (Assist, Recap, …) show a compact chip rather
                // than dumping the full internal prompt as a bubble.
                if let action = entry.action, action != "Ask" {
                    cannedActionChip(action)
                } else {
                    userBubble(entry)
                }
            }
        } else {
            HStack {
                AssistantMessageRow(
                    entry: entry,
                    isStreaming: streaming && entry.id == entries.last?.id,
                    toolStatus: llm.toolStatus,
                    placeholderLabel: streamingPlaceholderLabel,
                    onCopy: { NSPasteboard.copyString(entry.text) },
                    onRegenerate: { llm.regenerate(assistantID: entry.id) }
                )
                Spacer(minLength: 40)
            }
        }
    }

    private func userBubble(_ entry: ChatEntry) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 8) {
                if entry.screenContextUsed {
                    Text("Viewed screen")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.overlayInk.opacity(0.4))
                }
                if entry.contextUsed {
                    Text("Viewed conversation")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.overlayInk.opacity(0.4))
                }
            }
            Text(entry.text)
                .font(.system(size: 14))
                .foregroundStyle(Color.overlayInk)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.overlayInk.opacity(0.10))
                )
        }
    }

    /// A canned-action turn (Assist / Recap / …) shown as a compact chip
    /// instead of the verbose internal prompt the user never actually typed.
    private func cannedActionChip(_ action: String) -> some View {
        let icon: String = {
            switch action {
            case "Assist": return "sparkles"
            case "Say next": return "wand.and.rays"
            case "Follow-ups": return "bubble.left.and.text.bubble.right"
            case "Recap": return "arrow.clockwise"
            default: return "sparkles"
            }
        }()
        return HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(action)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(Color.overlayInk.opacity(0.6))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.overlayInk.opacity(0.06)))
    }

}

/// One assistant reply, with a hover-revealed Copy + Regenerate bar.
/// The bar collapses to zero height when not hovering so a long chat stays
/// tight — it pops in under the message on hover (ChatGPT-style).
private struct AssistantMessageRow: View {
    let entry: ChatEntry
    let isStreaming: Bool
    let toolStatus: String?
    let placeholderLabel: String
    let onCopy: () -> Void
    let onRegenerate: () -> Void

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        Group {
            if isStreaming && entry.text.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                    Text(placeholderLabel)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.overlayInk.opacity(0.55))
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    let display = entry.text + (isStreaming ? " ▍" : "")
                    RTIMarkdown(display, style: .overlay)
                        .fixedSize(horizontal: false, vertical: true)

                    // Tool status under the text while a tool runs mid-stream.
                    if isStreaming, let toolStatus, !toolStatus.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.6)
                            Text(toolStatus)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.overlayInk.opacity(0.55))
                        }
                    }

                    // Hover actions on a settled (non-streaming) reply. The bar
                    // always occupies its space (so hovering never reflows the
                    // chat — no jump); only its opacity changes on hover.
                    if !isStreaming && !entry.text.isEmpty {
                        actionBar
                            .opacity(hovering ? 1 : 0)
                            .allowsHitTesting(hovering)
                            // Buffer beneath the icons so moving the cursor down
                            // onto them doesn't slip past the hover region and
                            // make the bar vanish before you can click.
                            .padding(.bottom, 6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Track hover over the whole row rectangle (incl. transparent gaps),
        // not just the opaque glyphs — otherwise the corner is a dead zone.
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .hoverHighlight($hovering)
    }

    private var actionBar: some View {
        HStack(spacing: 2) {
            iconButton(systemName: copied ? "checkmark" : "doc.on.doc",
                       help: "Copy") {
                onCopy()
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            }
            iconButton(systemName: "arrow.clockwise", help: "Regenerate", action: onRegenerate)
        }
    }

    private func iconButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundStyle(Color.overlayInk.opacity(0.45))
                .frame(width: 30, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
