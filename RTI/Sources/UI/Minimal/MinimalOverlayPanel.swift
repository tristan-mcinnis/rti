import AppKit
import SwiftUI

/// The composed minimal overlay: one panel, no tabs — a header, the live
/// transcript, and the ask composer. `onOpenSettings` is supplied by the
/// integrator since this view doesn't own window lifecycle.
struct MinimalOverlayPanel: View {
    var onOpenSettings: () -> Void = {}

    var body: some View {
        let coordinator = SessionCoordinator.shared

        VStack(alignment: .leading, spacing: 16) {
            headerBar(coordinator: coordinator)
            MinimalTranscriptView()
                .frame(minHeight: 240)
            MinimalAskComposer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Palette.surfacePanel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Palette.borderHairline)
        )
        .animation(Motion.panelReveal, value: coordinator.phase)
    }

    private func headerBar(coordinator: SessionCoordinator) -> some View {
        HStack(spacing: 8) {
            StateDot(phase: coordinator.phase, hasError: coordinator.lastError != nil)
            ElapsedLabel(coordinator: coordinator)
            Spacer()
            MinimalIconButton(
                systemImage: "gearshape",
                accessibilityLabel: "Open settings",
                action: onOpenSettings
            )
        }
        .frame(height: 32)
    }
}

/// State-colored dot, symbol swaps on phase change via
/// `.symbolEffect(.replace)`, gated on `Motion.recordState`.
private struct StateDot: View {
    let phase: SessionCoordinator.Phase
    let hasError: Bool

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .contentTransition(.symbolEffect(.replace))
            .animation(Motion.recordState, value: symbolName)
    }

    private var symbolName: String {
        if hasError { return "exclamationmark.circle.fill" }
        switch phase {
        case .idle: return "circle"
        case .recording: return "circle.fill"
        case .paused: return "pause.circle.fill"
        case .finishing, .summarizing: return "arrow.triangle.2.circlepath.circle.fill"
        case .done: return "checkmark.circle.fill"
        }
    }

    private var color: Color {
        if hasError { return Palette.stateError }
        switch phase {
        case .idle, .done: return Palette.stateIdle
        case .recording: return Palette.stateLive
        case .paused, .finishing, .summarizing: return Palette.stateWarn
        }
    }
}

/// Monospaced-digit elapsed timer, ticks once a second while a session is
/// running.
private struct ElapsedLabel: View {
    let coordinator: SessionCoordinator

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.format(coordinator.elapsed(at: context.date)))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Palette.inkSecondary)
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", minutes, secs)
    }
}

// MARK: - Menubar status item helper

/// State-colored dot + elapsed timer for the `NSStatusItem`. Mirrors the
/// existing `MenuCoordinator.statusImage(running:)` pattern (a rendered
/// `NSImage` set on `statusItem.button.image`) so the integrator can drop
/// this straight into `MenuCoordinator` without adopting SwiftUI there.
enum MinimalStatusItemView {
    static func dotImage(phase: SessionCoordinator.Phase, hasError: Bool, pointSize: CGFloat = 10) -> NSImage? {
        let symbol: String
        let color: NSColor
        if hasError {
            symbol = "exclamationmark.circle.fill"
            color = .systemRed
        } else {
            switch phase {
            case .idle, .done:
                symbol = "circle"
                color = .secondaryLabelColor
            case .recording:
                symbol = "circle.fill"
                color = .systemGreen
            case .paused, .finishing, .summarizing:
                symbol = "pause.circle.fill"
                color = .systemOrange
            }
        }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            .applying(.init(paletteColors: [color]))
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "RTI status")?
            .withSymbolConfiguration(config)
        image?.isTemplate = false
        return image
    }

    /// `mm:ss`, monospaced-digit friendly for `NSStatusBarButton.title`.
    static func elapsedTitle(_ seconds: TimeInterval) -> String {
        ElapsedLabel.format(seconds)
    }
}

/// SwiftUI equivalent, for a status item hosted via `NSHostingView` instead
/// of a drawn `NSImage`.
struct MinimalStatusItemSwiftUIView: View {
    let phase: SessionCoordinator.Phase
    let hasError: Bool
    let elapsed: TimeInterval

    var body: some View {
        HStack(spacing: 4) {
            StateDot(phase: phase, hasError: hasError)
            Text(MinimalStatusItemView.elapsedTitle(elapsed))
                .font(.system(size: 11).monospacedDigit())
        }
    }
}
