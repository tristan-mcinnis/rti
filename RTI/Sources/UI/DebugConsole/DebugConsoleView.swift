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

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(coordinator.liveEntries) { entry in
                        TranscriptRowView(speakerId: entry.speakerId, text: entry.text, isFinal: true)
                            .id(entry.id)
                    }
                    if let interim = coordinator.interimLine, !interim.isEmpty {
                        TranscriptRowView(speakerId: nil, text: interim, isFinal: false)
                            .id("interim")
                    }
                }
                .padding(16)
            }
            .onChange(of: coordinator.liveEntries.count) { _, _ in
                if let last = coordinator.liveEntries.last {
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
