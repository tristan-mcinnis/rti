import SwiftUI

/// Shared chrome for floating analysis panels (Notes, Dossiers, Themes,
/// Discussion Guide, Translation, user counters). Handles: rounded dark
/// translucent background with user-adjustable opacity, header layout,
/// resize handle, close button, and corner clipping.
///
/// Each panel supplies its own title, optional status accessory (badges,
/// spinners), trailing header actions (export menus, custom controls),
/// and body content.
struct FloatingPanelChrome<TitleAccessory: View, HeaderActions: View, Content: View>: View {
    let title: String
    let closeNotification: Notification.Name
    @AppStorage private var backgroundOpacity: Double
    let titleAccessory: () -> TitleAccessory
    let headerActions: () -> HeaderActions
    let content: () -> Content

    init(
        title: String,
        opacityKey: String,
        defaultOpacity: Double,
        closeNotification: Notification.Name,
        @ViewBuilder titleAccessory: @escaping () -> TitleAccessory = { EmptyView() },
        @ViewBuilder headerActions: @escaping () -> HeaderActions = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.closeNotification = closeNotification
        self._backgroundOpacity = AppStorage(wrappedValue: defaultOpacity, opacityKey)
        self.titleAccessory = titleAccessory
        self.headerActions = headerActions
        self.content = content
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(white: 0.14).opacity(backgroundOpacity))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                content()
            }

            ResizeHandle()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding([.bottom, .trailing], 6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            titleAccessory()
            Spacer()
            headerActions()
            FloatingPanelOpacitySlider(opacity: $backgroundOpacity)
                .frame(width: 70)
            closeButton
        }
    }

    private var closeButton: some View {
        Button(action: {
            NotificationCenter.default.post(name: closeNotification, object: nil)
        }) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help("Close panel")
    }
}

/// Standard `⋯` quick-actions menu used in every floating panel header.
/// Each panel passes its own actions; "Hide panel" is appended at the
/// bottom so the close affordance is reachable from one consistent place
/// across panels (in addition to the explicit `×` button).
struct PanelHeaderEllipsisMenu<Content: View>: View {
    let hideNotification: Notification.Name
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content()
            Divider()
            Button("Hide panel") {
                NotificationCenter.default.post(name: hideNotification, object: nil)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.12)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22, height: 22)
        .help("Quick actions")
    }
}

/// Slim white opacity slider used in every floating panel header. Range
/// matches `OverlayAppearanceDefaults.opacityRange` (10% → 100%).
struct FloatingPanelOpacitySlider: View {
    @Binding var opacity: Double
    var body: some View {
        Slider(value: $opacity, in: 0.10...1.00, step: 0.05) {}
            .tint(.white.opacity(0.4))
            .frame(height: 12)
    }
}
