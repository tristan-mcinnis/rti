import SwiftUI

struct SessionPlaybackBar: View {
    @Bindable var playback: SessionPlaybackModel

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            HStack(spacing: House.Spacing.sm) {
                Button(playback.isPlaying ? "Pause recording" : "Play recording", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") {
                    playback.toggle()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(SessionCircleButtonStyle())
                .disabled(playback.isLoading || playback.duration <= 0 || playback.error != nil)
                VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                    HStack {
                        Text(playback.isLoading ? "Loading recording…" : playback.sources)
                            .font(House.TypeToken.meta)
                            .foregroundStyle(House.ColorToken.textSecondary)
                        Spacer(minLength: House.Spacing.xs)
                        Text("\(time(playback.position)) / \(time(playback.duration))")
                            .font(House.TypeToken.caption)
                            .monospacedDigit()
                            .foregroundStyle(House.ColorToken.textTertiary)
                    }
                    Slider(value: Binding(get: { playback.position }, set: { playback.seek(to: $0) }), in: 0...max(1, playback.duration))
                        .disabled(playback.duration <= 0 || playback.error != nil)
                        .accessibilityLabel("Recording position")
                        .accessibilityValue("\(time(playback.position)) of \(time(playback.duration))")
                }
            }
            if let error = playback.error {
                Text(error).font(House.TypeToken.meta).foregroundStyle(House.ColorToken.textSecondary)
            }
        }
        .padding(House.Spacing.sm)
        .background(House.ColorToken.surfaceTint, in: RoundedRectangle(cornerRadius: House.Radius.lg, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session recording")
    }
    private func time(_ seconds: TimeInterval) -> String {
        let value = Int(max(0, seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

struct SessionCircleButtonStyle: ButtonStyle {
    var isSelected = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(House.TypeToken.label)
            .foregroundStyle(isEnabled ? House.ColorToken.textPrimary : House.ColorToken.textTertiary)
            .frame(width: House.Control.pill, height: House.Control.pill)
            .background(isSelected ? House.ColorToken.selectionFill : (configuration.isPressed ? House.ColorToken.hoverFill : House.ColorToken.surfaceTint), in: Circle())
            .overlay(Circle().strokeBorder(House.ColorToken.stroke, lineWidth: House.hairline))
            .contentShape(Circle())
    }
}
