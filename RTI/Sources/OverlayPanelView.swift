import SwiftUI

struct OverlayPanelView: View {
    @ObservedObject private var llm = LLMController.shared
    @ObservedObject private var session = SessionCoordinator.shared
    var onOpenSettings: () -> Void = {}

    @AppStorage(OverlayAppearanceDefaults.opacityKey) private var backgroundOpacity: Double = OverlayAppearanceDefaults.defaultOpacity

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(white: 0.14).opacity(backgroundOpacity))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
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
                .padding(.top, 14)

                PromptActionRow()
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 10)

                AssistantInputView(onOpenSettings: onOpenSettings)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            }

            ResizeHandle()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding([.bottom, .trailing], 6)

            // Floating opacity slider — same affordance as the auxiliary
            // panels. Tucked in the top-right so it stays out of the way
            // but is always reachable. 10% (almost transparent) → 100%
            // (fully opaque).
            Slider(value: $backgroundOpacity,
                   in: OverlayAppearanceDefaults.opacityRange,
                   step: 0.05) {}
                .tint(.white.opacity(0.4))
                .controlSize(.mini)
                .frame(width: 70)
                .help("Panel opacity")
                .padding(.top, 8)
                .padding(.trailing, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .topTrailing)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
