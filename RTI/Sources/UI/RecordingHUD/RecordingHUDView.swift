import SwiftUI

/// A small, glanceable recording surface that stays near the bottom of the
/// active display. It proves both audio legs are moving and keeps Finish one
/// deliberate click away without bringing RTI to the foreground.
struct RecordingHUDView: View {
    private let session = SessionCoordinator.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 15.0)) { context in
            HStack(spacing: 10) {
                switch session.phase {
                case .recording, .paused:
                    let levels = session.audioLevels()
                    HUDWaveform(level: levels.mic, active: levels.micFlowing, color: .cyan)
                        .help("Your microphone")
                    Text(TimeFormat.elapsed(session.elapsed(at: context.date)))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(minWidth: 42)
                    if session.isPaused {
                        Text("Paused")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                    HUDWaveform(level: levels.system, active: levels.systemFlowing, color: .purple)
                        .help("Meeting audio")
                    Button {
                        session.stopSession()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(.white.opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                    .help("Finish recording and improve transcript")

                case .finishing:
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Saving audio…").font(.system(size: 11, weight: .medium))

                case .summarizing:
                    ProgressView().controlSize(.small).tint(.white)
                    Text(session.postProcessingStatus ?? "Improving transcript…")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)

                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(session.postProcessingStatus ?? "Notes ready")
                        .font(.system(size: 11, weight: .semibold))

                case .idle:
                    EmptyView()
                }
            }
            .foregroundStyle(.white.opacity(0.88))
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.84))
                    .overlay(Capsule(style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            )
            .padding(6)
        }
    }
}

private struct HUDWaveform: View {
    let level: Float
    let active: Bool
    let color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(0..<7, id: \.self) { index in
                Capsule()
                    .fill(active ? color : Color.red.opacity(0.8))
                    .frame(width: 2, height: height(for: index))
            }
        }
        .frame(width: 24, height: 18)
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityLabel(active ? "Audio moving" : "No audio detected")
    }

    private func height(for index: Int) -> CGFloat {
        guard active else { return 3 }
        let pattern: [CGFloat] = [0.42, 0.72, 1.0, 0.62, 0.88, 0.52, 0.34]
        let scaled = CGFloat(max(0.12, min(1, level * 3.4)))
        return max(3, 18 * pattern[index] * scaled)
    }
}
