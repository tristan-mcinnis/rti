import SwiftUI

/// Shared chrome for floating panels (now just Translation — the analysis
/// panels were folded into the tabbed overlay). Handles: rounded dark
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
            // Opacity as a submenu — SwiftUI's `Menu` cannot host a real
            // `Slider`, so we expose discrete presets instead.
            Menu("Opacity — \(Int(backgroundOpacity * 100))%") {
                ForEach(FloatingPanelOpacityPresets.values, id: \.self) { value in
                    Button {
                        backgroundOpacity = value
                    } label: {
                        if abs(value - backgroundOpacity) < 0.01 {
                            Label("\(Int(value * 100))%", systemImage: "checkmark")
                        } else {
                            Text("\(Int(value * 100))%")
                        }
                    }
                }
            }
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

/// Discrete opacity presets used by every floating panel's submenu.
/// SwiftUI's `Menu` does not render a real `Slider`, so we expose fixed
/// steps spanning the same effective range a slider would (~20% → 100%).
enum FloatingPanelOpacityPresets {
    static let values: [Double] = [0.20, 0.40, 0.60, 0.75, 0.85, 0.95, 1.00]
}
