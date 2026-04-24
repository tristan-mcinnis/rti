import SwiftUI

struct TopWidgetView: View {
    let onHideToggle: () -> Void
    @ObservedObject private var coordinator = SessionCoordinator.shared

    var body: some View {
        HStack(spacing: 10) {
            compass
            hideButton
            stopButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.55))
                .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
        )
        .padding(4)
    }

    private var compass: some View {
        Image(systemName: "location.north")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: 32, height: 32)
            .background(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
    }

    private var hideButton: some View {
        Button(action: onHideToggle) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                Text("Hide")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }

    private var stopButton: some View {
        Button(action: { SessionCoordinator.shared.stopSession() }) {
            Image(systemName: "stop.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(coordinator.isRunning ? Color.white : Color.white.opacity(0.3))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
        .disabled(!coordinator.isRunning)
    }
}
