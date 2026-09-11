import RTICore
import SwiftUI

// MARK: - Shared tab chrome

/// A tab toolbar glyph (copy, export, refresh): a `Control.compact` square
/// in the shape of the house header glyph button (`QuickAIGlyphButton`),
/// with hover and a disabled state.
struct OverlayToolbarButton: View {
    let icon: String
    let help: String
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(House.TypeToken.bodySmall)
                .foregroundStyle(disabled ? House.ColorToken.textTertiary : House.ColorToken.textSecondary)
                .frame(width: House.Control.compact, height: House.Control.compact)
                .background { RowHighlight(isSelected: false, isHovering: hovering && !disabled, radius: House.Radius.sm) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .hoverHighlight($hovering)
        .accessibilityLabel(help)
        .help(help)
    }
}

/// The house empty state for a tab (chat-surfaces.md section 2, "Empty
/// hints"): a few short lines in `bodySmall` `textTertiary`, centred,
/// `Spacing.xs` apart, each naming a way in, with its real key when it has one.
func overlayEmptyHints(_ lines: [String]) -> some View {
    VStack(spacing: House.Spacing.xs) {
        ForEach(lines, id: \.self) { line in
            Text(line)
                .font(House.TypeToken.bodySmall)
                .foregroundStyle(House.ColorToken.textTertiary)
                .multilineTextAlignment(.center)
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.horizontal, House.Spacing.lg)
    .accessibilityElement(children: .combine)
}

/// The record key's hint for an empty tab: what ⌘⇧R does now.
@MainActor
func overlayRecordHint() -> String {
    SessionCoordinator.shared.isRunning ? "⌘⇧R finishes the recording" : "⌘⇧R starts a recording"
}

/// A tab's title strip: the tab's name (or its state) on the left and its
/// glyph buttons on the right, `Control.railRow` high so it lines up with
/// the tabs row above it.
struct OverlayTabStrip<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: House.Spacing.xs) {
            leading
            Spacer(minLength: House.Spacing.xs)
            trailing
        }
        .frame(height: House.Control.railRow)
    }
}

/// The name of a tab in its strip.
func overlayTabStripTitle(_ title: String) -> some View {
    Text(title)
        .font(HouseChatType.subheading)
        .foregroundStyle(House.ColorToken.textSecondary)
        .lineLimit(1)
}

// MARK: - Hover highlight (Swift 6 teardown-crash workaround)

extension View {
    /// `.onHover` whose action closure is authored in a `nonisolated` context,
    /// so the Swift 6 compiler does NOT wrap it in the dynamic main-actor
    /// executor assertion (`swift_task_isCurrentExecutor`) that a plain
    /// `.onHover { hovering = $0 }` inside a `@MainActor` `body` gets.
    ///
    /// That assertion segfaulted — EXC_BAD_ACCESS in `swift_getObjectType` ←
    /// `swift_task_isMainExecutor` — when a stale AppKit tracking-area
    /// `mouseMoved:` was delivered into an overlay node mid-teardown. That's the
    /// crash that took RTI down when you moused over the "Notes ready" pill at
    /// session end (crash reports 2026-06-15..17, all in OverlayMicControl /
    /// OverlayRecordButton hover closures). AppKit always delivers hover events
    /// on the main thread, so dropping the now-fatal runtime check is safe — the
    /// state write still happens on main.
    nonisolated func hoverHighlight(_ flag: Binding<Bool>) -> some View {
        onHover { flag.wrappedValue = $0 }
    }

    /// Optional-id variant for list rows: set `binding` to `id` on enter, clear
    /// it on exit (only if it still points at this row). Same nonisolated-closure
    /// rationale as `hoverHighlight(_:)`.
    nonisolated func hoverHighlight<ID: Equatable>(_ binding: Binding<ID?>, id: ID) -> some View {
        onHover { inside in
            binding.wrappedValue = inside ? id : (binding.wrappedValue == id ? nil : binding.wrappedValue)
        }
    }
}
