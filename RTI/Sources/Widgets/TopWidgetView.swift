import SwiftUI

/// A minimal recording indicator pill shown in the top-right corner of the
/// screen. When idle it displays a subtle grey dot; when recording it shows
/// a red pulsing dot and an elapsed timer. Tap anywhere on the pill to start
/// or stop a session.
struct TopWidgetView: View {
    @ObservedObject private var coordinator = SessionCoordinator.shared
    @ObservedObject private var llm = LLMController.shared

    @State private var now = Date()
    @State private var pulse = false

    private let tick = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            Button(action: { coordinator.toggleSession() }) {
                HStack(spacing: 6) {
                    indicatorDot

                    if coordinator.isRunning, let label = timerLabel {
                        Text(label)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white)
                            .monospacedDigit()
                    }
                }
                .padding(.leading, coordinator.isRunning ? 11 : 10)
                .padding(.trailing, coordinator.isRunning ? 11 : 10)
                .frame(height: 36)
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
                .frame(width: 8, height: 8)
        }
    }

    private var timerLabel: String? {
        guard let started = coordinator.startedAt else { return nil }
        return TopWidgetView.format(now.timeIntervalSince(started))
    }

    static func format(_ interval: TimeInterval) -> String {
        TimeFormat.elapsed(interval)
    }
}
