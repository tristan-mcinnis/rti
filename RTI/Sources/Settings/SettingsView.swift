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
        case keys, modes, prompts, glossary, general

        var id: String { rawValue }

        var label: String {
            switch self {
            case .keys: "Keys"
            case .modes: "Modes"
            case .prompts: "Prompts"
            case .glossary: "Glossary"
            case .general: "General"
            }
        }

        var systemImage: String {
            switch self {
            case .keys: "key.fill"
            case .modes: "square.stack.3d.up"
            case .prompts: "text.bubble"
            case .glossary: "character.book.closed"
            case .general: "gearshape"
            }
        }

        var description: String {
            switch self {
            case .keys: "Connect RTI to your transcription and assistant providers."
            case .modes: "Tune the assistant persona and reference context."
            case .prompts: "Edit the action prompts RTI sends to the model."
            case .glossary: "Keep names, acronyms, and domain terms consistent."
            case .general: "Configure capture, automation, overlay, and diagnostics."
            }
        }
    }

    var onClose: (() -> Void)?

    @State private var section: SettingsTab = .keys

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Settings")
                    .font(.system(size: 20, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.top, 18)

                List(selection: $section) {
                    ForEach(SettingsTab.allCases) { tab in
                        Label(tab.label, systemImage: tab.systemImage)
                            .tag(tab)
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 178, idealWidth: 188, maxWidth: 220)
            .background(.thinMaterial)

            VStack(alignment: .leading, spacing: 0) {
                SettingsHeader(tab: section, onClose: onClose)

                Divider()

                Group {
                    switch section {
                    case .keys: KeysTab()
                    case .modes: ModesTab()
                    case .prompts: PromptsTab()
                    case .glossary: GlossaryTab()
                    case .general: GeneralTab()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SettingsSurfaceBackground())
            }
        }
        .frame(minWidth: 720, idealWidth: 860, maxWidth: .infinity,
               minHeight: 520, idealHeight: 680, maxHeight: .infinity)
    }
}

private struct SettingsHeader: View {
    let tab: SettingsView.SettingsTab
    let onClose: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tab.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.10))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(tab.label)
                    .font(.system(size: 20, weight: .semibold))
                Text(tab.description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let onClose {
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(.bar)
    }
}

struct SettingsSurfaceBackground: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .overlay(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.35),
                        Color.secondary.opacity(0.025)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }
}

struct SettingsPage<Content: View>: View {
    let maxWidth: CGFloat
    private let content: Content

    init(maxWidth: CGFloat = 760, @ViewBuilder content: () -> Content) {
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
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
        .background(SettingsSurfaceBackground())
    }
}

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
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || detail != nil {
                VStack(alignment: .leading, spacing: 3) {
                    if let title {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.13), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.035), radius: 8, y: 2)
        )
    }
}

struct SettingsStatusLabel: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(color.opacity(0.12))
            )
    }
}

extension View {
    func settingsEditorBorder(cornerRadius: CGFloat = 8) -> some View {
        self
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.secondary.opacity(0.24), lineWidth: 1)
            )
    }
}
