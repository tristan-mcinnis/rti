import AppKit
import HouseDesign
import RTICore
import SwiftUI

/// One Auto suggestion: its kind, the line itself, why it matters now and
/// the document it draws on. The live rail and its sheet draw it. A card
/// with a Mandarin line shows it first, then its pinyin (when the user's
/// setting is on), then the English line as a small gloss.
///
/// Monochrome: the kind is a glyph and a word, never a colour. On the rail
/// an older card is dimmed and the newest one is lit for a moment.
struct AutoCardRow: View {
    struct Actions {
        var pin: (() -> Void)?
        var dismiss: (() -> Void)?
        var copy: () -> Void
    }

    let kind: AutoCardKind
    let text: String
    let why: String
    let source: String?
    var textZH: String?
    var pinyin: String?
    var pinned = false
    /// Older cards step back so the newest reads first.
    var dimmed = false
    /// One line, no reason or source: an older card in a crowded rail. The
    /// full line is in the tooltip and on Copy.
    var compact = false
    var actions: Actions
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            HStack(spacing: House.Spacing.xxs) {
                Label(kind.label, systemImage: kind.icon)
                    .labelStyle(AutoCardKindLabelStyle())
                if pinned {
                    Image(systemName: "pin.fill")
                        .font(House.TypeToken.micro)
                        .foregroundStyle(House.ColorToken.textTertiary)
                        .accessibilityLabel("Pinned")
                }
                Spacer(minLength: House.Spacing.xs)
            }
            if compact {
                Text(textZH ?? text)
                    .font(House.TypeToken.bodySmall)
                    .foregroundStyle(dimmed ? House.ColorToken.textSecondary : House.ColorToken.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help([textZH ?? text, gloss].compactMap(\.self).joined(separator: "\n"))
            } else {
                // The line, its pinyin and its English gloss sit tight as one
                // block, so the gloss reads as the line's own.
                VStack(alignment: .leading, spacing: 0) {
                    Text(textZH ?? text)
                        .font(House.TypeToken.bodySmall)
                        .foregroundStyle(dimmed ? House.ColorToken.textSecondary : House.ColorToken.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if textZH != nil {
                        if let pinyin {
                            Text(pinyin)
                                .font(House.TypeToken.caption)
                                .foregroundStyle(House.ColorToken.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        if let gloss {
                            Text(gloss)
                                .font(House.TypeToken.meta)
                                .foregroundStyle(dimmed ? House.ColorToken.textTertiary : House.ColorToken.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            if !compact, !why.isEmpty {
                // The reason, set apart from the line block in a quieter tone.
                Text(why)
                    .font(House.TypeToken.caption)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, House.Spacing.xxs)
            }
            if !compact, let source, !source.isEmpty {
                Label(source, systemImage: "doc.text")
                    .font(House.TypeToken.caption)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // Actions under the card, as under an answer (2026-11-14). A
            // dimmed card keeps them out of sight until the pointer is on it;
            // they stay reachable by keyboard.
            HStack(spacing: House.Spacing.xxs) {
                LiveRailGlyphButton(icon: "doc.on.doc", help: "Copy line", action: actions.copy)
                if let pin = actions.pin, !pinned {
                    LiveRailGlyphButton(icon: "pin", help: "Pin", action: pin)
                }
                if let dismiss = actions.dismiss {
                    LiveRailGlyphButton(icon: "xmark", help: "Dismiss", action: dismiss)
                }
            }
            .opacity(dimmed && !hovering ? 0 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .hoverHighlight($hovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(kind.label): \([textZH ?? text, gloss].compactMap(\.self).joined(separator: ", "))")
    }

    /// The English line under a Mandarin one, or nil when the card has only
    /// the one line.
    private var gloss: String? {
        guard let textZH, textZH != text else { return nil }
        return text
    }
}

/// The kind word in the section style, after its glyph.
private struct AutoCardKindLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: House.Spacing.xxs) {
            configuration.icon
                .font(House.TypeToken.micro)
            configuration.title
                .font(House.TypeToken.section)
                .tracking(House.TypeToken.Tracking.section)
                .textCase(.uppercase)
        }
        .foregroundStyle(House.ColorToken.textTertiary)
    }
}

/// A small glyph action on a rail row: a `Control.keyCap` square with hover.
struct LiveRailGlyphButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(House.TypeToken.caption)
                .foregroundStyle(hovering ? House.ColorToken.textPrimary : House.ColorToken.textTertiary)
                .frame(width: House.Control.keyCap, height: House.Control.keyCap)
                .background { RowHighlight(isSelected: false, isHovering: hovering, radius: House.Radius.xs) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight($hovering)
        .accessibilityLabel(help)
        .help(help)
    }
}
