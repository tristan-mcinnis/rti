import SwiftUI

/// Live input/output meters for both capture legs. The whole point: see, at a
/// glance mid-call, whether your mic ("You") and the other party ("Them") are
/// actually being captured — a flat bar while that side is talking means the
/// wrong device is selected (the classic AirPods / one-side-recorded trap).
/// Used by the Settings audio section.
struct AudioMonitorContent: View {
    @State private var inputName = "—"
    @State private var outputName = "—"
    private let nameTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 15.0)) { _ in
            let levels = SessionCoordinator.shared.audioLevels()
            VStack(alignment: .leading, spacing: 14) {
                leg(
                    title: "You", icon: "mic.fill", device: inputName,
                    level: levels.mic, flowing: levels.micFlowing,
                    running: levels.isRunning, active: true, accent: .blue
                )
                leg(
                    title: "Them", icon: "speaker.wave.2.fill", device: outputName,
                    level: levels.system, flowing: levels.systemFlowing,
                    running: levels.isRunning, active: levels.systemActive, accent: .purple
                )
                Text(levels.isRunning
                    ? "A bar that stays flat while that side is talking means the wrong device is selected — fix it in Settings → Audio."
                    : "Start a session (⌘⇧R) to see live levels.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onReceive(nameTimer) { _ in refreshNames() }
        .onAppear { refreshNames() }
    }

    private func leg(title: String, icon: String, device: String, level: Float, flowing: Bool, running: Bool, active: Bool, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(accent)
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                status(running: running, active: active, flowing: flowing)
            }
            Text(device)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            meter(level: running && active ? CGFloat(level) : 0, accent: accent)
        }
    }

    private func meter(level: CGFloat, accent: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule().fill(accent).frame(width: max(2, geo.size.width * min(1, level)))
            }
        }
        .frame(height: 12)
        .animation(.linear(duration: 0.08), value: level)
    }

    @ViewBuilder
    private func status(running: Bool, active: Bool, flowing: Bool) -> some View {
        if !running {
            statusBadge("Idle", .secondary, dotColor: .secondary.opacity(0.5), pulsing: false)
        } else if !active {
            statusBadge("Off", .secondary, dotColor: .secondary.opacity(0.5), pulsing: false)
        } else if !flowing {
            statusBadge("No audio", .red, dotColor: .red, pulsing: false, icon: "exclamationmark.triangle.fill")
        } else {
            statusBadge("Live", .green, dotColor: .green, pulsing: true)
        }
    }

    private func statusBadge(_ text: String, _ color: Color, dotColor: Color, pulsing: Bool, icon: String? = nil) -> some View {
        HStack(spacing: 4) {
            if pulsing {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                    .modifier(PulsingDot())
            } else if let icon {
                Image(systemName: icon).font(.system(size: 9))
            } else {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
            }
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(color)
    }

    private func refreshNames() {
        let names = SessionCoordinator.shared.audioDeviceNames()
        inputName = names.input
        outputName = names.output
    }
}

/// Slow opacity pulse for the "Live" status dot — gives an at-a-glance
/// "we're recording" signal without the noise of a flashing indicator.
private struct PulsingDot: ViewModifier {
    @State private var pulse = false

    func body(content: Content) -> some View {
        content
            .opacity(pulse ? 0.35 : 1.0)
            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}
