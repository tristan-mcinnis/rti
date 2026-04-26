import SwiftUI

struct DebugConsoleView: View {
    @EnvironmentObject var coordinator: SessionCoordinator
    @State private var elapsed: TimeInterval = 0
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.9))
            Divider()
            transcriptList
        }
        .onAppear(perform: startClock)
        .onDisappear(perform: stopClock)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(coordinator.isRunning ? Color.red : Color.secondary)
                .frame(width: 10, height: 10)
            Text(coordinator.isRunning ? "Recording…" : "Idle")
                .font(.system(size: 13, weight: .medium))
            Spacer()
            if coordinator.isRunning {
                Text(formatElapsed(elapsed))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let err = coordinator.lastError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
    }

    private struct LiveParagraph: Identifiable {
        let id: UUID
        let speakerId: String
        let text: String
    }

    /// Soniox finalizes in 1–3s windows so the raw stream is dozens of tiny
    /// fragments. Coalesce consecutive same-speaker entries into paragraphs
    /// for a readable live view. Computed each render — small list, cheap.
    private var paragraphs: [LiveParagraph] {
        var out: [LiveParagraph] = []
        for entry in coordinator.liveEntries {
            if let last = out.last, last.speakerId == entry.speakerId {
                let merged = LiveParagraph(
                    id: last.id,
                    speakerId: last.speakerId,
                    text: last.text + " " + entry.text
                )
                out.removeLast()
                out.append(merged)
            } else {
                out.append(LiveParagraph(
                    id: entry.id,
                    speakerId: entry.speakerId,
                    text: entry.text
                ))
            }
        }
        return out
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(paragraphs) { p in
                        paragraphRow(p)
                            .id(p.id)
                    }
                    if let interim = coordinator.interimLine, !interim.isEmpty {
                        Text(interim)
                            .font(.system(size: 14))
                            .italic()
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("interim")
                    }
                }
                .padding(20)
            }
            .onChange(of: paragraphs.last?.id) { _, _ in
                if let last = paragraphs.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: coordinator.interimLine) { _, _ in
                proxy.scrollTo("interim", anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func paragraphRow(_ p: LiveParagraph) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(speakerDisplayName(p.speakerId))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(p.text.trimmingCharacters(in: .whitespaces))
                .font(.system(size: 14))
                .lineSpacing(3)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func speakerDisplayName(_ id: String) -> String {
        switch id {
        case "self": return "You"
        case let other where other.hasPrefix("them_"):
            let n = String(other.dropFirst("them_".count))
            return "Speaker \(n)"
        default: return id.capitalized
        }
    }

    private func startClock() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                if let start = coordinator.startedAt {
                    elapsed = Date().timeIntervalSince(start)
                } else {
                    elapsed = 0
                }
            }
        }
    }

    private func stopClock() {
        timer?.invalidate()
        timer = nil
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
