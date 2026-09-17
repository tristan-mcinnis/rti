// Copied from quick-launch@b9ee129 Sources/Views/AttachmentChip.swift
import AppKit
import RTICore
import SwiftUI

// Attachment chips (design-system docs/chat-surfaces.md section 4): one chip
// view for the composer strip and for the read-only chips over a sent
// question; the strip above the composer; the flow layout for pill chips; and
// the drop overlay. Names kept from Quick Launch so a later shared package
// finds every copy.
//
// Adapted for RTI: the kinds are `ChatAttachmentRef.Kind` (vault file, PDF,
// text, screen); a screen chip draws the captured screenshot as a small
// thumbnail when one is attached, so the attachment is visible at a glance;
// no Quick Look (its panel is its own window and would show in a screen
// share); hover goes through `hoverHighlight`, never a bare `.onHover`.

// MARK: - Chip model

/// What one chip shows, whatever it came from: an item in the composer's
/// strip, or a reference on a sent question.
struct AttachmentChipModel: Identifiable, Equatable {
    enum Phase: Equatable {
        case reading
        case ready
        case failed(String)
    }

    let id: String
    var kind: ChatAttachmentRef.Kind
    var name: String
    var phase: Phase
    /// Units and size ("12 pp · 84 KB · cut"), "once" for a screen read.
    var detail: String
    /// The detail read aloud ("12 pages, 84 KB").
    var spokenDetail: String
    /// The tooltip when ready: a vault file's path, a document's path.
    var tooltip: String?
    /// A screenshot attached to this chip, drawn in place of the kind glyph.
    var thumbnail: NSImage? = nil

    /// `NSImage` is not `Equatable`; comparing by identity keeps the chip's
    /// change detection meaningful without copying pixels.
    static func == (lhs: AttachmentChipModel, rhs: AttachmentChipModel) -> Bool {
        lhs.id == rhs.id
            && lhs.kind == rhs.kind
            && lhs.name == rhs.name
            && lhs.phase == rhs.phase
            && lhs.detail == rhs.detail
            && lhs.spokenDetail == rhs.spokenDetail
            && lhs.tooltip == rhs.tooltip
            && lhs.thumbnail === rhs.thumbnail
    }

    var systemImage: String {
        if case .failed = phase { return "exclamationmark.triangle" }
        return kind.symbolName
    }

    /// The detail as drawn: "Reading…" (or the step under way), the failure
    /// line, or the detail.
    var detailLine: String {
        switch phase {
        case .reading: return detail.isEmpty ? "Reading…" : detail
        case .failed(let line): return line
        case .ready: return detail
        }
    }

    var help: String {
        switch phase {
        case .failed(let line): return "\(name): \(line)"
        case .reading: return "Reading \(name)…"
        case .ready: return tooltip ?? name
        }
    }

    /// VoiceOver: "Attachment: Launch plan.pdf, PDF, 12 pages, 84 KB".
    var accessibilityLabel: String {
        var parts = ["Attachment: \(name)", Self.kindName(for: kind)]
        switch phase {
        case .reading: parts.append("reading")
        case .failed(let line): parts.append(line)
        case .ready: if !spokenDetail.isEmpty { parts.append(spokenDetail) }
        }
        return parts.joined(separator: ", ")
    }

    static func kindName(for kind: ChatAttachmentRef.Kind) -> String {
        switch kind {
        case .vaultFile: "Vault file"
        case .pdf: "PDF"
        case .text: "Text file"
        case .image: "Image"
        case .screen: "Screenshot"
        }
    }

    // MARK: Builders

    /// A ready chip for a reference: a sent question's chip, or a strip item
    /// that was read.
    init(ref: ChatAttachmentRef, id: String? = nil) {
        self.id = id ?? [ref.kind.rawValue, ref.path ?? ref.name].joined(separator: ":")
        self.kind = ref.kind
        self.name = ref.name
        self.phase = .ready
        self.detail = ComposerAttachmentDetail.detail(for: ref)
        self.spokenDetail = ComposerAttachmentDetail.spokenDetail(for: ref)
        self.tooltip = ref.path
    }

    /// A chip that is still reading or that failed.
    init(id: String, kind: ChatAttachmentRef.Kind, name: String, phase: Phase, detail: String = "") {
        self.id = id
        self.kind = kind
        self.name = name
        self.phase = phase
        self.detail = detail
        self.spokenDetail = detail
        self.tooltip = nil
    }
}

// MARK: - Chip

/// One attachment: the glyph, the name, the detail, and in the composer strip
/// a remove button. `Control.chip` high at `Radius.sm` on `chipFill`; no colour
/// in any state (DESIGN rule 2).
struct AttachmentChip: View {
    let model: AttachmentChipModel
    /// The strip's keyboard selection.
    var isSelected = false
    /// Present only in the composer strip.
    var onRemove: (() -> Void)? = nil
    /// Opens the attachment (a chip over a sent question).
    var onOpen: (() -> Void)? = nil

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .padding(.leading, House.Spacing.xs)
            .padding(.trailing, onRemove == nil ? House.Spacing.xs : House.Spacing.xxs)
            .frame(height: House.Control.chip)
            .background { background }
            .contentShape(RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous))
            .onTapGesture { if let onOpen { onOpen() } }
            .hoverHighlight($isHovering)
            .animation(reduceMotion ? nil : .easeOut(duration: House.Motion.hover), value: isHovering)
            .help(model.help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.accessibilityLabel)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .modifier(ChipAccessibilityActions(onRemove: onRemove, onOpen: onOpen))
    }

    private var content: some View {
        HStack(spacing: House.Spacing.xxs) {
            leading
            nameText
            detailText
            if model.phase == .reading {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: House.Spacing.sm, height: House.Spacing.sm)
                    .accessibilityHidden(true)
            }
            if let onRemove { removeButton(onRemove) }
        }
    }

    private var nameText: some View {
        Text(model.name)
            .font(House.TypeToken.meta)
            .foregroundStyle(House.ColorToken.textPrimary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: HouseChatMetrics.attachmentNameMax, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var detailText: some View {
        let line = model.detailLine
        if !line.isEmpty {
            Text(line)
                .font(House.TypeToken.meta)
                .monospacedDigit()
                .foregroundStyle(House.ColorToken.textTertiary)
                .lineLimit(1)
        }
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(HouseChatType.glyphSmall)
                .foregroundStyle(House.ColorToken.textSecondary)
                .frame(width: House.Control.keyCap, height: House.Control.keyCap)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Remove \(model.name)")
        .accessibilityHidden(true)
    }

    /// The screenshot when the chip carries one, else the kind glyph. The
    /// thumbnail is what makes an attached screenshot visible instead of a
    /// bare "Screenshot" label.
    @ViewBuilder
    private var leading: some View {
        if let thumbnail = model.thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
                .clipShape(RoundedRectangle(cornerRadius: House.Radius.sm - 1, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: House.Radius.sm - 1, style: .continuous)
                        .strokeBorder(House.ColorToken.stroke, lineWidth: House.hairline)
                }
                .accessibilityHidden(true)
        } else {
            glyph
        }
    }

    private static let thumbnailSize = CGSize(width: 34, height: 22)

    private var glyph: some View {
        Image(systemName: model.systemImage)
            .font(House.TypeToken.caption)
            .foregroundStyle(House.ColorToken.textSecondary)
            .frame(width: House.Spacing.md, height: House.Spacing.md)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
        if isSelected {
            shape
                .fill(House.ColorToken.selectionFill)
                .overlay(shape.strokeBorder(House.ColorToken.selectionRing, lineWidth: House.hairline))
        } else {
            shape.fill(isHovering && (onRemove != nil || onOpen != nil)
                ? House.ColorToken.hoverFill
                : House.ColorToken.chipFill)
        }
    }
}

/// Remove and Open as VoiceOver actions, since the chip reads as one element.
private struct ChipAccessibilityActions: ViewModifier {
    let onRemove: (() -> Void)?
    let onOpen: (() -> Void)?

    func body(content: Content) -> some View {
        content.accessibilityActions {
            if let onRemove { Button("Remove", action: onRemove) }
            if let onOpen { Button("Open", action: onOpen) }
        }
    }
}

// MARK: - Strip

/// The row of chips above the composer: `Control.chip` plus `Spacing.xs`
/// above and below, chips `Spacing.xs` apart, scrolling sideways when they
/// overflow, the routing line at the trailing end, then clear-all.
struct AttachmentStripView: View {
    let chips: [AttachmentChipModel]
    var focusedID: String? = nil
    var routingLine: String? = nil
    var sideInset: CGFloat = House.Spacing.xs
    let onRemove: (String) -> Void
    let onClearAll: () -> Void

    /// `Control.chip + 2 × Spacing.xs` (44).
    static let height = House.Control.chip + House.Spacing.xs * 2

    var body: some View {
        HStack(spacing: House.Spacing.xs) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: House.Spacing.xs) {
                        ForEach(chips) { chip in
                            AttachmentChip(
                                model: chip,
                                isSelected: chip.id == focusedID,
                                onRemove: { onRemove(chip.id) }
                            )
                            .id(chip.id)
                        }
                    }
                }
                .onChange(of: focusedID) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                }
                .onChange(of: chips.last?.id) { _, id in
                    guard let id, focusedID == nil else { return }
                    proxy.scrollTo(id, anchor: .trailing)
                }
            }
            if let routingLine, !routingLine.isEmpty {
                Text(routingLine)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Button(action: onClearAll) {
                Image(systemName: "xmark.circle.fill")
                    .font(House.TypeToken.label)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .frame(width: House.Control.chip, height: House.Control.chip)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove all attachments (⌫ in an empty field removes the newest)")
            .accessibilityLabel("Remove all attachments")
        }
        .padding(.horizontal, sideInset)
        .padding(.vertical, House.Spacing.xs)
        .frame(height: Self.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(chips.count == 1 ? "1 attachment" : "\(chips.count) attachments")
    }
}

// MARK: - Chips over a question pill

/// A sent question's attachments over its pill: right aligned, read only,
/// wrapping. A click opens the attachment.
struct AttachmentPillChips: View {
    let chips: [AttachmentChipModel]
    var onOpen: ((AttachmentChipModel) -> Void)? = nil

    var body: some View {
        ChipFlowLayout(spacing: House.Spacing.xs) {
            ForEach(chips) { chip in
                AttachmentChip(model: chip, onOpen: onOpen.map { open in { open(chip) } })
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(chips.count == 1 ? "1 attachment" : "\(chips.count) attachments")
    }
}

/// Lays chips in rows, right aligned, wrapping to a new row when the next
/// chip does not fit.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.maxX - row.width
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let added = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if added > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Drop

/// Over a drop target while a drag is over it: `hoverFill` at `Radius.xl`
/// with a `strokeStrong` hairline and one line, "Drop to attach". Over a
/// composer it hides what is typed (`coversContent`), since the line would
/// sit on it.
struct AttachmentDropOverlay: View {
    var coversContent = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: House.Radius.xl, style: .continuous)
        ZStack {
            if coversContent { shape.fill(House.ColorToken.surface) }
            shape.fill(House.ColorToken.hoverFill)
            shape.strokeBorder(House.ColorToken.strokeStrong, lineWidth: House.hairline)
            if coversContent {
                label
            } else {
                // Circular, not continuous: at half the height a continuous
                // capsule's stroke leaves a stray hairline past its caps.
                let pill = RoundedRectangle(cornerRadius: House.Radius.pill, style: .circular)
                label
                    .padding(.horizontal, House.Spacing.md)
                    .frame(height: House.Control.pill)
                    .background(pill.fill(House.ColorToken.surfaceRaised))
                    .overlay(pill.strokeBorder(House.ColorToken.stroke, lineWidth: House.hairline))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var label: some View {
        Text("Drop to attach")
            .font(House.TypeToken.label)
            .foregroundStyle(House.ColorToken.textPrimary)
    }
}
