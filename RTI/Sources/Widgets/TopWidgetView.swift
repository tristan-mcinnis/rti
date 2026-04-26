import SwiftUI

struct TopWidgetView: View {
    @ObservedObject private var coordinator = SessionCoordinator.shared

    var body: some View {
        recordButton
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.55))
                    .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
            )
            .padding(4)
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
            .frame(width: 32, height: 32)
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
    }
}
