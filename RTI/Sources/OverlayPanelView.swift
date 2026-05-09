import SwiftUI

struct OverlayPanelView: View {
    @ObservedObject private var llm = LLMController.shared
    @ObservedObject private var session = SessionCoordinator.shared
    var onOpenSettings: () -> Void = {}

    @AppStorage(OverlayAppearanceDefaults.opacityKey) private var backgroundOpacity: Double = OverlayAppearanceDefaults.defaultOpacity

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(backgroundOpacity))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )

            VStack(spacing: 0) {
                ResponseView(
                    entries: llm.entries,
                    streaming: llm.streaming,
                    error: llm.lastError,
                    errorIsAuth: llm.lastErrorIsAuth,
                    onOpenSettings: onOpenSettings
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 18)
                .padding(.top, 36) // clear the inline record chip

                PromptActionRow()
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 10)

                AssistantInputView(onOpenSettings: onOpenSettings)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            }

            // Inline record chip — start/stop a session straight from the
            // panel without reaching for the pill or ⌘⇧R. Top-left so it
            // doesn't collide with the pill, which the overlay anchors to
            // the top-right corner externally.
            InlineRecordChip()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding([.top, .leading], 12)

            ResizeHandle()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding([.bottom, .trailing], 6)
        }
    }
}

/// Compact record/stop control mirroring the pill's behaviour but living
/// inside the panel's content area. Idle: muted dot + "Record". Recording:
/// red dot + live mm:ss. Click toggles the session.
private struct InlineRecordChip: View {
    @ObservedObject private var coordinator = SessionCoordinator.shared
    @State private var now = Date()
    @State private var hovering = false

    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Button(action: { coordinator.toggleSession() }) {
            HStack(spacing: 6) {
                if coordinator.isRunning {
                    Circle()
                        .fill(Color(red: 1.0, green: 0.27, blue: 0.27))
                        .frame(width: 6, height: 6)
                    Text(elapsedLabel)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                } else {
                    Circle()
                        .fill(Color.white.opacity(0.45))
                        .frame(width: 6, height: 6)
                    Text("Record")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundStyle(.white.opacity(coordinator.isRunning ? 1.0 : 0.75))
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.16 : 0.10))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(coordinator.isRunning ? "Stop recording (⌘⇧R)" : "Start recording (⌘⇧R)")
        .onReceive(tick) { _ in
            if coordinator.isRunning { now = Date() }
        }
    }

    private var elapsedLabel: String {
        guard let started = coordinator.startedAt else { return "0:00" }
        return TimeFormat.elapsed(now.timeIntervalSince(started))
    }
}
