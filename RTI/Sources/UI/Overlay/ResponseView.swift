import SwiftUI

struct ResponseView: View {
    let entries: [ChatEntry]
    let streaming: Bool
    let error: String?
    var errorIsAuth: Bool = false
    var onOpenSettings: () -> Void = {}

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if entries.isEmpty && !streaming && error == nil {
                        Text("Responses appear here. Type a question below, or press ⌘↵ for Assist.")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.45))
                    }

                    ForEach(entries) { entry in
                        entryRow(entry)
                            .id(entry.id)
                    }

                    if let error, !error.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(error)
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
            .onChange(of: entries.last?.text) { _, _ in
                if let lastId = entries.last?.id {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
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
                Text(LLMController.shared.smartMode ? "thinking…" : "responding…")
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
