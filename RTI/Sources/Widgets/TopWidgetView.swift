import SwiftUI

struct TopWidgetView: View {
    @ObservedObject private var coordinator = SessionCoordinator.shared
    @ObservedObject private var llm = LLMController.shared
    var onTap: () -> Void

    @State private var now = Date()
    @State private var pulse = false

    private let tick = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 9) {
                indicatorDot

                if coordinator.isRunning, let label = timerLabel {
                    Text(label)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                } else {
                    Text("Tap to chat…")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.55))
                }

                Spacer(minLength: 0)

                if llm.smartMode {
                    Text("Smart")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color(red: 0.0, green: 0.733, blue: 0.498))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color(red: 0.0, green: 0.733, blue: 0.498).opacity(0.12))
                        )
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, llm.smartMode ? 8 : 14)
            .padding(.vertical, 8)
            .frame(height: 38)
        }
        .buttonStyle(.plain)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.65))
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
        )
        .padding(4)
        .onReceive(tick) { _ in
            if coordinator.isRunning { now = Date() }
        }
        .onChange(of: coordinator.isRunning) { recording in
            if recording { pulse = true }
        }
        .onAppear {
            if coordinator.isRunning { pulse = true }
        }
    }

    @ViewBuilder
    private var indicatorDot: some View {
        if coordinator.isRunning {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .scaleEffect(pulse ? 1.0 : 0.7)
                .opacity(pulse ? 1.0 : 0.4)
                .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulse)
        } else {
            Circle()
                .fill(Color.white.opacity(0.35))
                .frame(width: 6, height: 6)
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
}
