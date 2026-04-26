import AppKit
import SwiftUI

struct DebugConsoleView: View {
    @EnvironmentObject var coordinator: SessionCoordinator
    @State private var elapsed: TimeInterval = 0
    @State private var timer: Timer?
    @State private var copedFlash: String?
    @State private var hoveredId: UUID?

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
            Button(action: copyAll) {
                HStack(spacing: 4) {
                    Image(systemName: copedFlash == "all" ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                    Text(copedFlash == "all" ? "Copied" : "Copy")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(paragraphs.isEmpty)
            .help("Copy the full live transcript")
        }
    }

    private struct LiveParagraph: Identifiable {
        let id: UUID
        let speakerId: String
        let startMs: Int
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
                    startMs: last.startMs,
                    text: last.text + " " + entry.text
                )
                out.removeLast()
                out.append(merged)
            } else {
                out.append(LiveParagraph(
                    id: entry.id,
                    speakerId: entry.speakerId,
                    startMs: entry.startMs,
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
        let isNote = p.speakerId == "note"
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if isNote {
                    Image(systemName: "note.text")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.yellow)
                }
                Text(speakerDisplayName(p.speakerId))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isNote ? Color.yellow : .secondary)
                Text(timeLabel(ms: p.startMs))
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                if hoveredId == p.id {
                    Button(action: { copyParagraph(p) }) {
                        Image(systemName: copedFlash == p.id.uuidString ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy this paragraph")
                }
            }
            Text(p.text.trimmingCharacters(in: .whitespaces))
                .font(.system(size: 14, weight: isNote ? .regular : .regular))
                .italic(isNote)
                .lineSpacing(3)
                .foregroundStyle(isNote ? Color.primary.opacity(0.85) : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(isNote ? 8 : 0)
                .background(
                    isNote
                    ? RoundedRectangle(cornerRadius: 6).fill(Color.yellow.opacity(0.08))
                    : nil
                )
                .overlay(alignment: .leading) {
                    if isNote {
                        Rectangle()
                            .fill(Color.yellow.opacity(0.5))
                            .frame(width: 2)
                    }
                }
        }
        .contentShape(Rectangle())
        .onHover { inside in hoveredId = inside ? p.id : (hoveredId == p.id ? nil : hoveredId) }
    }

    private func timeLabel(ms: Int) -> String {
        let total = max(0, ms / 1000)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private func copyAll() {
        let text = paragraphs.map {
            "[\(timeLabel(ms: $0.startMs))] \(speakerDisplayName($0.speakerId)): \($0.text.trimmingCharacters(in: .whitespaces))"
        }.joined(separator: "\n\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flashCopied("all")
    }

    private func copyParagraph(_ p: LiveParagraph) {
        let text = "[\(timeLabel(ms: p.startMs))] \(speakerDisplayName(p.speakerId)): \(p.text.trimmingCharacters(in: .whitespaces))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flashCopied(p.id.uuidString)
    }

    private func flashCopied(_ key: String) {
        copedFlash = key
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { if copedFlash == key { copedFlash = nil } }
        }
    }

    private func speakerDisplayName(_ id: String) -> String {
        switch id {
        case "self": return "You"
        case "note": return "Note"
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
