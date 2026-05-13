import SwiftUI

/// Shared chrome for floating analysis panels (Notes, Dossiers, Themes,
/// Discussion Guide, Translation, user counters). Handles: rounded dark
/// translucent background with user-adjustable opacity, header layout,
/// resize handle, close button, and corner clipping.
///
/// Each panel supplies its own title, optional status accessory (badges,
/// spinners), trailing ellipsis-menu items (export, regenerate, etc.),
/// and body content. The chrome itself builds the `⋯` menu and prepends
/// the opacity slider + appends "Hide panel" so every panel has the same
/// shape without each one re-implementing the wrapper.
struct FloatingPanelChrome<TitleAccessory: View, MenuItems: View, Content: View>: View {
    let title: String
    let panelID: FloatingPanelID
    @AppStorage private var backgroundOpacity: Double
    let titleAccessory: () -> TitleAccessory
    let menuItems: () -> MenuItems
    let content: () -> Content

    init(
        title: String,
        opacityKey: String,
        defaultOpacity: Double,
        panelID: FloatingPanelID,
        @ViewBuilder titleAccessory: @escaping () -> TitleAccessory = { EmptyView() },
        @ViewBuilder menuItems: @escaping () -> MenuItems = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.panelID = panelID
        self._backgroundOpacity = AppStorage(wrappedValue: defaultOpacity, opacityKey)
        self.titleAccessory = titleAccessory
        self.menuItems = menuItems
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
            ellipsisMenu
            closeButton
        }
    }

    private var ellipsisMenu: some View {
        Menu {
            // Opacity slider as a menu item — keeps the header uncluttered
            // and groups per-panel chrome controls in one place.
            FloatingPanelOpacityMenuRow(opacity: $backgroundOpacity)
            Divider()
            menuItems()
            Divider()
            Button("Hide panel") {
                WindowCoordinator.shared.toggle(panelID)
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
        .help("Panel options")
    }

    private var closeButton: some View {
        Button(action: {
            WindowCoordinator.shared.toggle(panelID)
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

/// Opacity slider as a Menu row. SwiftUI's Menu renders arbitrary views,
/// but to feel native we lay out a labelled slider with the same range as
/// `OverlayAppearanceDefaults.opacityRange` (10% → 100%).
struct FloatingPanelOpacityMenuRow: View {
    @Binding var opacity: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Opacity — \(Int(opacity * 100))%")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Slider(value: $opacity, in: 0.10...1.00, step: 0.05)
                .frame(width: 180)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}
