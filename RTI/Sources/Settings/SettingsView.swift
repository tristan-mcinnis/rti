import AppKit
import SwiftUI

/// Top-level Settings shell. Each tab lives in its own file
/// (`KeysTab.swift`, `ModesTab.swift`, …) so changes to one section
/// don't drag the whole 1k-line monolith into review.
///
/// Navigation uses a native sidebar instead of a tab strip so the panel reads
/// like a compact macOS preferences surface while leaving more room for
/// section-level controls.
struct SettingsView: View {
    enum SettingsTab: String, CaseIterable, Identifiable {
        case providers, modes, prompts, glossary, general

        var id: String { rawValue }

        var label: String {
            switch self {
            case .providers: "Providers"
            case .modes: "Modes"
            case .prompts: "Prompts"
            case .glossary: "Glossary"
            case .general: "General"
            }
        }

        var systemImage: String {
            switch self {
            case .providers: "server.rack"
            case .modes: "square.stack.3d.up"
            case .prompts: "text.bubble"
            case .glossary: "character.book.closed"
            case .general: "gearshape"
            }
        }

        var description: String {
            switch self {
            case .providers: "Choose providers, store keys, and swap LLM or STT backends."
            case .modes: "Tune the assistant persona and reference context."
            case .prompts: "Edit the action prompts RTI sends to the model."
            case .glossary: "Keep names, acronyms, and domain terms consistent."
            case .general: "Configure capture, automation, overlay, and diagnostics."
            }
        }
    }

    var onClose: (() -> Void)?
    /// Which pane opens first. Defaults to Providers, as it always has; the
    /// offscreen render proof uses it to capture General.
    var initialSection: SettingsTab = .providers

    @State private var section: SettingsTab?

    var body: some View {
        HSplitView {
            SettingsSidebar(selection: Binding(
                get: { section ?? initialSection },
                set: { section = $0 }
            ))
                .frame(width: RTIDesign.Layout.settingsRail)

            VStack(alignment: .leading, spacing: 0) {
                SettingsHeader(tab: section ?? initialSection, onClose: onClose)

                Group {
                    switch section ?? initialSection {
                    case .providers: ProvidersTab()
                    case .modes: ModesTab()
                    case .prompts: PromptsTab()
                    case .glossary: GlossaryTab()
                    case .general: GeneralTab()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SettingsSurfaceBackground())
                .toggleStyle(SlateToggleStyle())

                SlateFooter(statusColor: RTIDesign.Color.success, status: "Applies immediately") {
                    SlateKeyHint(label: "Close", keys: ["esc"])
                }
            }
        }
        .background(SettingsSurfaceBackground())
        // Chrome is ink, never the system accent.
        .tint(RTIDesign.Color.textPrimary)
        .frame(minWidth: House.Layout.settingsWidth, idealWidth: 860, maxWidth: .infinity,
               minHeight: House.Layout.settingsHeight, idealHeight: 680, maxHeight: .infinity)
    }
}

/// The 220 px rail: `surfaceSunken`, 36 px rows, an icon tile per row, and a
/// raised tile for the selected one. No accent anywhere.
private struct SettingsSidebar: View {
    @Binding var selection: SettingsView.SettingsTab
    @State private var hovered: SettingsView.SettingsTab?

    var body: some View {
        VStack(alignment: .leading, spacing: RTIDesign.Spacing.sm + 2) {
            HStack(spacing: RTIDesign.Spacing.xs + 2) {
                SlateIconTile(systemName: "waveform", size: RTIDesign.Control.chip, glyphSize: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text("RTI")
                        .font(RTIDesign.Font.label)
                        .foregroundStyle(RTIDesign.Color.textPrimary)
                    SlateSectionLabel(text: "Preferences")
                }
            }
            .padding(.horizontal, RTIDesign.Spacing.xxs)

            VStack(alignment: .leading, spacing: RTIDesign.Spacing.xxs - 1) {
                ForEach(SettingsView.SettingsTab.allCases) { tab in
                    Button {
                        selection = tab
                    } label: {
                        HStack(spacing: RTIDesign.Spacing.sm) {
                            SlateIconTile(systemName: tab.systemImage, glyphSize: 13)
                            Text(tab.label)
                                .font(RTIDesign.Font.label)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(selection == tab ? RTIDesign.Color.textPrimary : RTIDesign.Color.textSecondary)
                        .padding(.horizontal, RTIDesign.Spacing.xs + 2)
                        .frame(height: RTIDesign.Control.railRow)
                        .slateRaisedTile(selection == tab,
                                         cornerRadius: RTIDesign.Radius.row,
                                         hovering: hovered == tab)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight($hovered, id: tab)
                    .accessibilityAddTraits(selection == tab ? [.isButton, .isSelected] : .isButton)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(RTIDesign.Spacing.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RTIDesign.Color.trackBackground)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(RTIDesign.Color.divider)
                .frame(width: House.hairline)
        }
    }
}

/// Pane title in `title` with a `meta` subtitle. No tile, no uppercase kicker:
/// the rail already says where you are.
private struct SettingsHeader: View {
    let tab: SettingsView.SettingsTab
    let onClose: (() -> Void)?

    var body: some View {
        HStack(spacing: RTIDesign.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.label)
                    .font(RTIDesign.Font.sectionTitle)
                    .foregroundStyle(RTIDesign.Color.textPrimary)
                Text(tab.description)
                    .font(RTIDesign.Font.meta)
                    .foregroundStyle(RTIDesign.Color.textSecondary)
            }

            Spacer()

            if let onClose {
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, RTIDesign.Spacing.lg - 2)
        .padding(.vertical, RTIDesign.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsSurfaceBackground())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(RTIDesign.Color.divider)
                .frame(height: House.hairline)
        }
    }
}

/// Settings sits in an opaque window, so its ground is `surface`, not glass.
struct SettingsSurfaceBackground: View {
    var body: some View {
        RTIDesign.Color.appBackground
    }
}

struct SettingsPage<Content: View>: View {
    let maxWidth: CGFloat
    private let content: Content

    init(maxWidth: CGFloat = House.Layout.settingsWidth, @ViewBuilder content: () -> Content) {
        self.maxWidth = maxWidth
        self.content = content()
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            HStack(alignment: .top, spacing: 0) {
                content
                    .frame(maxWidth: maxWidth, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, RTIDesign.Spacing.lg - 2)
            .padding(.vertical, RTIDesign.Spacing.md)
        }
        .background(SettingsSurfaceBackground())
        // Toggles are ink, never blue (DESIGN.md).
        .toggleStyle(SlateToggleStyle())
    }
}

/// A settings group: a card at `Radius.lg` with an uppercase `section` label.
struct SettingsCard<Content: View>: View {
    let title: String?
    let detail: String?
    private let content: Content

    init(_ title: String? = nil, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RTIDesign.Spacing.sm) {
            if title != nil || detail != nil {
                VStack(alignment: .leading, spacing: RTIDesign.Spacing.xxs) {
                    if let title {
                        SlateSectionLabel(text: title)
                    }
                    if let detail {
                        Text(detail)
                            .font(RTIDesign.Font.caption)
                            .foregroundStyle(RTIDesign.Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            content
        }
        .padding(RTIDesign.Spacing.sm + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .slateGroupCard()
    }
}

/// A status pill inside a settings group: outlined, with a status dot. Never a
/// tinted capsule.
struct SettingsStatusLabel: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        SlateOutlineChip(height: House.Control.keyCap + 2) {
            SlateStatusDot(color: color)
            Text(text)
        }
        .accessibilityLabel(text)
    }
}

extension View {
    func settingsEditorBorder(cornerRadius: CGFloat = RTIDesign.Radius.sm) -> some View {
        self
            .background(RTIDesign.Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(RTIDesign.Color.border, lineWidth: House.hairline)
            )
    }
}
