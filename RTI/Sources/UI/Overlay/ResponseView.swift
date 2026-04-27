import SwiftUI

struct ResponseView: View {
    let entries: [ChatEntry]
    let streaming: Bool
    let error: String?
    var errorIsAuth: Bool = false
    var onOpenSettings: () -> Void = {}

    @ObservedObject private var llm = LLMController.shared
    @ObservedObject private var sessionCoord = SessionCoordinator.shared

    private var streamingPlaceholderLabel: String {
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
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Responses appear here. Type a question below, or press ⌘↵ for Assist.")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.45))

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Try asking:")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.35))
                                ForEach(["Summarize the last few minutes",
                                         "What did they decide?",
                                         "Help me reply"], id: \.self) { example in
                                    Text("• " + example)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white.opacity(0.4))
                                }
                            }
                        }
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
                userBubble(entry)
            }
        } else {
            HStack {
                assistantBody(entry)
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
                        .foregroundStyle(.white.opacity(0.4))
                }
                if entry.contextUsed {
                    Text("Viewed conversation")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }
                if let action = entry.action {
                    Text(action)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.blue))
                }
            }
            Text(entry.text)
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                )
        }
    }

    @ViewBuilder
    private func assistantBody(_ entry: ChatEntry) -> some View {
        let isStreamingThis = streaming && entry.id == entries.last?.id
        if isStreamingThis && entry.text.isEmpty {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                Text(streamingPlaceholderLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
            }
        } else {
            let display = entry.text + (isStreamingThis ? " ▍" : "")
            let attributed = (try? AttributedString(markdown: display,
                                                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(display)
            Text(attributed)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.92))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
