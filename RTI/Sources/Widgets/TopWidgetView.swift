import SwiftUI

struct TopWidgetView: View {
    @ObservedObject private var coordinator = SessionCoordinator.shared
    @State private var now = Date()

    /// Tick at 1Hz while recording so the timer label updates. The publisher
    /// keeps emitting when not recording but the closure short-circuits.
    private let tick = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                recordButton
                if coordinator.isRunning, let label = timerLabel {
                    Text(label)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                        .monospacedDigit()
                        .kerning(0.2)
                        .padding(.trailing, 6)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .leading)),
                            removal: .opacity
                        ))
                        .help("Recording — elapsed time")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
            )
            Spacer(minLength: 0)
        }
        .padding(4)
        .animation(.easeInOut(duration: 0.22), value: coordinator.isRunning)
        .onReceive(tick) { _ in
            if coordinator.isRunning { now = Date() }
        }
    }

    private var timerLabel: String? {
        guard let started = coordinator.startedAt else { return nil }
        return Self.format(now.timeIntervalSince(started))
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private var recordButton: some View {
        Button(action: { SessionCoordinator.shared.toggleSession() }) {
            ZStack {
                if coordinator.isRunning {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 11, height: 11)
                }
            }
            .frame(width: 28, height: 28)
            .background(
                Circle()
                    .fill(Color.white.opacity(coordinator.isRunning ? 0.10 : 0.06))
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(coordinator.isRunning ? 0.15 : 0.10), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .help(coordinator.isRunning ? "Stop session (⌘⇧R)" : "Start session (⌘⇧R)")
    }
}
