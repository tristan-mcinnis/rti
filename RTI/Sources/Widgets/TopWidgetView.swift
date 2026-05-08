import SwiftUI

/// A minimal recording indicator pill shown in the top-right corner of the
/// screen. When idle it displays a subtle grey dot; when recording it shows
/// a red pulsing dot and a live elapsed timer. After stopping, the timer
/// freezes at the final duration. Tap anywhere on the pill to start or stop
/// a session.
struct TopWidgetView: View {
    @ObservedObject private var coordinator = SessionCoordinator.shared
    @ObservedObject private var llm = LLMController.shared

    @State private var now = Date()
    @State private var pulse = false

    private let tick = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { coordinator.toggleSession() }) {
                HStack(spacing: 6) {
                    indicatorDot

                    if let label = timerLabel {
                        Text(label)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(coordinator.isRunning ? 0.95 : 0.55))
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 36)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: RTIDesign.Radius.md, style: .continuous)
                    .fill(Color.black.opacity(0.65))
                    .overlay(
                        RoundedRectangle(cornerRadius: RTIDesign.Radius.md, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    )
            )
            .help(coordinator.isRunning ? "Stop recording" : "Start recording")

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
        let endDate: Date
        if coordinator.isRunning {
            endDate = now
        } else if let ended = coordinator.endedAt {
            endDate = ended
        } else {
            return nil
        }
        return TopWidgetView.format(endDate.timeIntervalSince(started))
    }

    static func format(_ interval: TimeInterval) -> String {
        TimeFormat.elapsed(interval)
    }
}
