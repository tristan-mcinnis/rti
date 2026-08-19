import SwiftUI

/// Named animations for the minimal UI. Every one is gated on
/// `OverlayAppearanceDefaults.effectiveReduceMotion()` and returns `nil`
/// (no animation) when reduce motion is on.
enum Motion {
    /// Panel appear/disappear: opacity + scale, 0.16s easeOut.
    static var panelReveal: Animation? {
        guard !OverlayAppearanceDefaults.effectiveReduceMotion() else { return nil }
        return .easeOut(duration: 0.16)
    }

    /// Record state dot / icon transition, 0.2s easeOut. Pair with
    /// `.contentTransition(.symbolEffect(.replace))` on the symbol itself.
    static var recordState: Animation? {
        guard !OverlayAppearanceDefaults.effectiveReduceMotion() else { return nil }
        return .easeOut(duration: 0.2)
    }

    /// New transcript row fading in, 0.18s easeOut.
    static var transcriptAppend: Animation? {
        guard !OverlayAppearanceDefaults.effectiveReduceMotion() else { return nil }
        return .easeOut(duration: 0.18)
    }

    /// Answer stream becoming visible, 0.2s easeOut.
    static var answerReveal: Animation? {
        guard !OverlayAppearanceDefaults.effectiveReduceMotion() else { return nil }
        return .easeOut(duration: 0.2)
    }
}

/// Scale-down-on-press feedback. Animates only the scale, not layout.
private struct PressableModifier: ViewModifier {
    @State private var pressed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed ? 0.97 : 1.0)
            .animation(Motion.recordState, value: pressed)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in pressed = true }
                    .onEnded { _ in pressed = false }
            )
    }
}

extension View {
    /// Scales to 0.97 while pressed, springs back on release.
    func pressable() -> some View {
        modifier(PressableModifier())
    }
}

/// A 28x28 hit-box icon button with a required accessibility label and a
/// focus-visible ring in `Palette.borderFocus`.
struct MinimalIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    @FocusState private var focused: Bool

    init(systemImage: String, accessibilityLabel: String, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.inkSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Palette.borderFocus, lineWidth: focused ? 2 : 0)
        )
        .pressable()
        .accessibilityLabel(accessibilityLabel)
    }
}
