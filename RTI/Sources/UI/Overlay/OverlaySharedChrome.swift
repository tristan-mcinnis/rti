import RTICore
import SwiftUI

// MARK: - Shared tab chrome

/// A compact icon button used in tab toolbars (copy / export / etc.), styled
/// consistently across every tab.
struct OverlayToolbarButton: View {
    let icon: String
    let help: String
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.overlayInk.opacity(disabled ? 0.25 : hovering ? 0.82 : 0.6))
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.overlayInk.opacity(hovering && !disabled ? 0.06 : 0))
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .hoverHighlight($hovering)
        .accessibilityLabel(help)
        .accessibilityHint("Double-click or press VO-Space to activate")
        .help(help)
    }
}

func overlayEmptyState(_ icon: String, _ title: String, _ subtitle: String) -> some View {
    VStack(spacing: 6) {
        Image(systemName: icon).font(.system(size: 26)).foregroundStyle(Color.overlayInk.opacity(0.35))
        Text(title).font(.system(size: 13)).foregroundStyle(Color.overlayInk.opacity(0.6))
        Text(subtitle).font(.system(size: 11)).foregroundStyle(Color.overlayInk.opacity(0.4))
            .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.horizontal, 24)
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
