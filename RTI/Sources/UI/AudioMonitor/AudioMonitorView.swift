import SwiftUI

/// Live input/output meters for both capture legs. The whole point: see, at a
/// glance mid-call, whether your mic ("You") and the other party ("Them") are
/// actually being captured — a flat bar while that side is talking means the
/// wrong device is selected (the classic AirPods / one-side-recorded trap).
/// Reused by the floating panel and the Settings audio section.
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
        .frame(height: 8)
        .animation(.linear(duration: 0.08), value: level)
    }

    @ViewBuilder
    private func status(running: Bool, active: Bool, flowing: Bool) -> some View {
        if !running {
            badge("Idle", .secondary, "circle")
        } else if !active {
            badge("Off", .secondary, "circle")
        } else if !flowing {
            badge("No audio", .red, "exclamationmark.triangle.fill")
        } else {
            badge("Live", .green, "circle.fill")
        }
    }

    private func badge(_ text: String, _ color: Color, _ icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8))
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

/// Floating-panel wrapper around the meters.
struct AudioMonitorView: View {
    var body: some View {
        FloatingPanelChrome(
            title: "Audio I/O",
            opacityKey: audioMonitorOpacityKey,
            defaultOpacity: floatingPanelDefaultOpacity,
            panelID: .audioIO,
            menuItems: {
                Button("Audio settings…") { WindowCoordinator.shared.openSettings() }
            }
        ) {
            AudioMonitorContent()
                .padding(16)
        }
    }
}
