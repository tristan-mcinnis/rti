// Copied from quick-launch@8ee19aa Sources/Views/SlateChrome.swift, DesignTokens.swift,
// QuickAITitleBlock.swift, and OverlayView.swift (ThinkingIndicator)
import AppKit
import SwiftUI

// The shared pieces of the house chat grammar (design-system
// docs/chat-surfaces.md), copied from Quick Launch with their names kept so a
// later shared package can find every copy. Reads go straight to `House.`
// tokens; Quick Launch's `AQDesign` aliases are spelled out here. RTI rule:
// no bare `.onHover`; hover goes through the nonisolated `hoverHighlight`.
//
// Adapted for RTI's macOS 14 floor: `WindowDragArea` stands in for
// `WindowDragGesture` (macOS 15), and `HouseTitleBlock` takes values and
// closures instead of Quick Launch's view model.

// MARK: - Derived type and named liberties

/// The three fonts and the prose leading that chat-surfaces.md derives from
/// token sizes. They are not tokens (spec: "Type names").
enum HouseChatType {
    /// Titles in a header or a group lead-in: 13 semibold.
    static let subheading = Font.system(size: House.TypeToken.Size.bodySmall, weight: .semibold)
    /// A quieter glyph beside text: 14 semibold (the rail toggle, remove).
    static let glyphSmall = Font.system(size: House.TypeToken.Size.body, weight: .semibold)
    /// A glyph in a compact or pill control: 16 semibold (plus, ⌘, new).
    static let glyphMedium = Font.system(size: House.TypeToken.Size.heading, weight: .semibold)
    /// Line spacing so `House.TypeToken.body` reaches its 1.55 line height:
    /// the target height minus SF's own line height (about 5 pt).
    static let proseLineSpacing: CGFloat = {
        let font = NSFont.systemFont(ofSize: House.TypeToken.Size.body)
        let native = font.ascender - font.descender + font.leading
        let target = House.TypeToken.Size.body * House.TypeToken.LineHeight.body
        return max(0, target - native)
    }()
}

/// Reference values that are not tokens yet (chat-surfaces.md "Not a token
/// yet"). Copy them by name; never retype the number.
enum HouseChatMetrics {
    /// Gap between a `KeyHint` label and its caps.
    static let keyHintGap: CGFloat = 6
    /// `KeyHint` label ink, as a fraction of `textPrimary`.
    static let keyHintLabelOpacity: Double = 0.8
    /// Side padding of a key cap wider than one glyph ("esc").
    static let keyCapSidePadding: CGFloat = 6
    /// Gap inside a `HouseChip` between its glyph and its text.
    static let chipGap: CGFloat = 6
    /// Collapse control and `HouseChip` height: `Control.chip − 6` (22).
    static let collapseControlHeight: CGFloat = House.Control.chip - 6
    /// Thinking dots: diameter, gap, and step between phases.
    static let thinkingDot: CGFloat = 5
    static let thinkingDotGap: CGFloat = 3
    static let thinkingStep: TimeInterval = 0.35
    /// Opacity of the thinking dots: lit, dim, and still (Reduce Motion).
    static let thinkingLit: Double = 0.95
    static let thinkingDim: Double = 0.3
    static let thinkingStill: Double = 0.55
    /// Widest an attachment chip's name draws before middle truncation.
    static let attachmentNameMax: CGFloat = 180
    /// The `⌘K` action palette: width and tallest height.
    static let paletteWidth: CGFloat = 520
    static let paletteMaxHeight: CGFloat = 460
    /// The open-chat marker on a rail row: 2 wide.
    static let openChatMarkerWidth: CGFloat = House.Spacing.xxs / 2
    /// Header leading inset that clears the traffic lights (88).
    static let trafficLightInset: CGFloat = House.Spacing.xxxxl + House.Spacing.xl
    /// Pressed ink button opacity.
    static let pressedOpacity: Double = 0.75
}

// MARK: - Glass and cards

/// Panel glass: blur material, `panelTint`, hairline `stroke`, and a 1 px
/// `highlightTop` along the top edge. The ground of every floating layer
/// (choosers, the `⌘K` palette). In-window SwiftUI, never a child window,
/// so it inherits the overlay's `sharingType = .none`.
struct PanelGlass: ViewModifier {
    var radius: CGFloat = House.Radius.xl
    var material: NSVisualEffectView.Material = .popover

    func body(content: Content) -> some View {
        content
            .background {
                ZStack(alignment: .top) {
                    if SlateRenderMode.flattenGlass {
                        // A headless bitmap has nothing behind it to blur:
                        // draw the raised ground the glass reads as.
                        House.ColorToken.surfaceRaised
                    } else {
                        SlateVisualEffect(material: material)
                        House.ColorToken.panelTint
                    }
                    Rectangle()
                        .fill(House.ColorToken.highlightTop)
                        .frame(height: House.hairline)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(House.ColorToken.stroke, lineWidth: House.hairline)
            }
    }
}

/// An opaque raised card: a fill, the hairline, and the top highlight.
struct RaisedCard: ViewModifier {
    var radius: CGFloat = House.Radius.lg
    var fill: Color = House.ColorToken.surfaceTint

    func body(content: Content) -> some View {
        content
            .background {
                ZStack(alignment: .top) {
                    fill
                    Rectangle()
                        .fill(House.ColorToken.highlightTop)
                        .frame(height: House.hairline)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(House.ColorToken.stroke, lineWidth: House.hairline)
            }
    }
}

/// One house shadow. Opacity follows the appearance.
private struct HouseShadow: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let spec: House.ShadowSpec

    func body(content: Content) -> some View {
        content.shadow(
            color: .black.opacity(spec.opacity(dark: colorScheme == .dark)),
            radius: spec.blur / 2,
            y: spec.y
        )
    }
}

extension View {
    func panelGlass(
        radius: CGFloat = House.Radius.xl,
        material: NSVisualEffectView.Material = .popover
    ) -> some View {
        modifier(PanelGlass(radius: radius, material: material))
    }

    func raisedCard(
        radius: CGFloat = House.Radius.lg,
        fill: Color = House.ColorToken.surfaceTint
    ) -> some View {
        modifier(RaisedCard(radius: radius, fill: fill))
    }

    func houseShadow(_ spec: House.ShadowSpec) -> some View {
        modifier(HouseShadow(spec: spec))
    }

    /// The two shadows under every floating layer.
    func panelShadows() -> some View {
        houseShadow(House.Shadow.panelNear).houseShadow(House.Shadow.panelFar)
    }
}

// MARK: - Divider and chip

/// The quiet line between rows. Never drawn with the panel stroke.
struct HouseDivider: View {
    var body: some View {
        Rectangle()
            .fill(House.ColorToken.divider)
            .frame(height: House.hairline)
    }
}

/// A chip: `chipFill` at `Radius.sm`, `meta` text, an optional glyph. The
/// thread's Latest chip is `HouseChip(text: "Latest", icon: "arrow.down")`.
struct HouseChip: View {
    let text: String
    var icon: String? = nil

    var body: some View {
        HStack(spacing: HouseChatMetrics.chipGap) {
            if let icon {
                Image(systemName: icon).font(House.TypeToken.caption)
            }
            Text(text)
                .font(House.TypeToken.meta)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(House.ColorToken.textSecondary)
        .padding(.horizontal, House.Spacing.xs)
        .frame(minHeight: HouseChatMetrics.collapseControlHeight)
        .background(
            RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                .fill(House.ColorToken.chipFill)
        )
    }
}

// MARK: - Key caps

/// A run of key caps such as ⌥ ⌘ ←.
struct KeyCapGroup: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: House.Spacing.xxs) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                KeyCap(text: key)
            }
        }
    }
}

/// One outlined key cap: 20 pt tall, `keyCapStroke` hairline, no fill.
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(House.TypeToken.keyCap)
            .foregroundStyle(House.ColorToken.textSecondary)
            .padding(.horizontal, text.count > 1 ? HouseChatMetrics.keyCapSidePadding : 0)
            .frame(minWidth: House.Control.keyCap, minHeight: House.Control.keyCap)
            .background(
                RoundedRectangle(cornerRadius: House.Radius.xs, style: .continuous)
                    .fill(House.ColorToken.keyCapFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: House.Radius.xs, style: .continuous)
                    .strokeBorder(House.ColorToken.keyCapStroke, lineWidth: House.hairline)
            )
    }
}

/// A hint and its keys, as a row or a line reads it: "Retry ⌘ R".
struct KeyHint: View {
    let label: String
    let keys: [String]

    var body: some View {
        HStack(spacing: HouseChatMetrics.keyHintGap) {
            Text(label)
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textPrimary.opacity(HouseChatMetrics.keyHintLabelOpacity))
                .lineLimit(1)
            KeyCapGroup(keys: keys)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(keys.joined(separator: " "))")
    }
}

// MARK: - Thinking

/// Three dots that step while an answer has no text yet. Still at 55 %
/// with Reduce Motion.
struct ThinkingIndicator: View {
    @State private var phase = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let timer = Timer.publish(every: HouseChatMetrics.thinkingStep, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: HouseChatMetrics.thinkingDotGap) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(House.ColorToken.textPrimary)
                    .frame(width: HouseChatMetrics.thinkingDot, height: HouseChatMetrics.thinkingDot)
                    .opacity(reduceMotion
                             ? HouseChatMetrics.thinkingStill
                             : (index == phase ? HouseChatMetrics.thinkingLit : HouseChatMetrics.thinkingDim))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: House.Motion.normal), value: phase)
        .onReceive(timer) { _ in
            guard !reduceMotion else { return }
            phase = (phase + 1) % 3
        }
        .accessibilityLabel("Working")
    }
}

// MARK: - Rows

/// The background behind one list row: selection (fill, inset ring, 1 pt
/// drop) or hover (half the fill, no ring). Hover is not selection.
struct RowHighlight: View {
    var isSelected: Bool
    var isHovering: Bool = false
    var radius: CGFloat = House.Radius.row

    var body: some View {
        Group {
            if isSelected {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(House.ColorToken.selectionFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(House.ColorToken.selectionRing, lineWidth: House.hairline)
                    )
                    .houseShadow(House.Shadow.selection)
            } else if isHovering {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(House.ColorToken.hoverFill)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Controls

/// The one primary action on a form or a fix-it line: an ink fill with
/// inverse text. There is no accent button in the house.
struct InkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(House.TypeToken.label)
            .foregroundStyle(House.ColorToken.textInverse)
            .padding(.horizontal, House.Spacing.sm)
            .frame(minHeight: House.Control.compact)
            .background(
                RoundedRectangle(cornerRadius: House.Radius.md, style: .continuous)
                    .fill(House.ColorToken.textPrimary)
            )
            .opacity(configuration.isPressed ? HouseChatMetrics.pressedOpacity : 1)
    }
}

/// A header glyph button: a `Control.compact` square around one symbol.
struct QuickAIGlyphButton: View {
    let symbol: String
    let font: Font
    let color: Color
    let label: String
    let help: String
    /// "Open" or "Closed" for a toggle (the rail toggle); nil otherwise.
    var accessibilityValue: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(font)
                .foregroundStyle(color)
                .frame(width: House.Control.compact, height: House.Control.compact)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue ?? "")
        .help(help)
    }
}

// MARK: - Title block

/// One piece of the title block's second line. Pieces sit in order, `·`
/// between them.
enum HouseTitleSegment {
    /// A live state: a 6 pt status dot and its word ("Recording · 12:41").
    /// Never colour alone: the text always says the state.
    case status(String, color: Color)
    /// Plain `meta` `textSecondary` text: a source, a date, a project.
    case text(String)
    /// A `meta` button: the model (opens the model chooser) or, with
    /// `emphasised`, an assistant or mode name in `textPrimary`.
    case button(HouseTitleButton)
}

/// A button on the title block's second line.
struct HouseTitleButton {
    let title: String
    /// Full ink and never truncated: an assistant or mode name ahead of
    /// the model. The model itself is not emphasised.
    var emphasised = false
    /// VoiceOver label, for example "Model: DeepSeek V4 Flash".
    let accessibilityLabel: String
    /// VoiceOver hint, for example "Change the model".
    let accessibilityHint: String
    /// Tooltip with the key, for example "Change model (⌘⇧M)".
    let help: String
    /// "Open" or "Closed" while its chooser can show; nil otherwise.
    var isOpen: Bool? = nil
    let action: () -> Void
}

/// The chat title over its second line, as the Quick AI header draws it and
/// the AI Chat window reuses it (chat-surfaces.md sections 1 and 8). The
/// title is `subheading`, one line, middle truncation. The second line is
/// `meta`: a model button, an assistant or mode button, a source, or, on a
/// live surface, a status dot and its word first.
struct HouseTitleBlock: View {
    let title: String
    var line: [HouseTitleSegment] = []

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            Text(title)
                .font(HouseChatType.subheading)
                .foregroundStyle(House.ColorToken.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !line.isEmpty {
                HStack(spacing: House.Spacing.xxs) {
                    ForEach(Array(line.enumerated()), id: \.offset) { index, segment in
                        if index > 0 {
                            Text("·")
                                .font(House.TypeToken.meta)
                                .foregroundStyle(House.ColorToken.textTertiary)
                                .accessibilityHidden(true)
                        }
                        segmentView(segment)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: HouseTitleSegment) -> some View {
        switch segment {
        case let .status(text, color):
            HStack(spacing: House.Spacing.xxs) {
                SlateStatusDot(color: color)
                Text(text)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .fixedSize()
            .accessibilityElement(children: .combine)
        case let .text(text):
            Text(text)
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        case let .button(button):
            Button(action: button.action) {
                Text(button.title)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(button.emphasised ? House.ColorToken.textPrimary : House.ColorToken.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: button.emphasised, vertical: false)
            .accessibilityLabel(button.accessibilityLabel)
            .accessibilityHint(button.accessibilityHint)
            .accessibilityValue(button.isOpen.map { $0 ? "Open" : "Closed" } ?? "")
            .help(button.help)
        }
    }
}

// MARK: - Window drag (macOS 14 fallback for WindowDragGesture)

/// Put behind a window header: a press on the header's empty space moves the
/// window, so the window itself can keep `isMovableByWindowBackground = false`
/// (selecting text must not move it). Controls on top take their own clicks.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

// MARK: - Announcements

/// A VoiceOver announcement from a chat surface: errors at high priority,
/// notices and confirmations at medium.
enum QuickAIAnnouncement {
    @MainActor
    static func post(_ text: String, priority: NSAccessibilityPriorityLevel) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: priority.rawValue,
            ]
        )
    }
}
