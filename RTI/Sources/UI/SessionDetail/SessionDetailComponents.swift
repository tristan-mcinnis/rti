import AppKit
import SwiftUI

// MARK: - SectionHeader

/// Large 20pt semibold title for major content blocks (Summary / Key Topics /
/// Action Items …). Optional trailing slot for inline actions.
struct SectionHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let trailing: () -> Trailing

    init(_ title: String,
         subtitle: String? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(RTIDesign.Font.sectionTitle)
                    .foregroundStyle(RTIDesign.Color.textPrimary)
                if let subtitle = subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(RTIDesign.Font.meta)
                        .foregroundStyle(RTIDesign.Color.textTertiary)
                }
            }
            Spacer(minLength: RTIDesign.Spacing.sm)
            trailing()
        }
    }
}

// MARK: - AIOutputCard

/// Soft-tinted card used for any LLM-produced text block (Summary sections,
/// assistant Q&A turns). Renders an "RTI" avatar + optional timestamp top-row.
struct AIOutputCard<Content: View>: View {
    let timestamp: Date?
    @ViewBuilder let content: () -> Content

    init(timestamp: Date? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.timestamp = timestamp
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RTIDesign.Spacing.sm) {
            HStack(spacing: RTIDesign.Spacing.xs) {
                ZStack {
                    Circle()
                        .fill(RTIDesign.Color.accent)
                        .frame(width: 18, height: 18)
                    Text("R")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
                Text("RTI")
                    .font(RTIDesign.Font.caption.weight(.semibold))
                    .foregroundStyle(RTIDesign.Color.textSecondary)
                if let timestamp = timestamp {
                    Text("·")
                        .foregroundStyle(RTIDesign.Color.textTertiary)
                    Text(timestamp.formatted(date: .omitted, time: .shortened))
                        .font(RTIDesign.Font.caption)
                        .foregroundStyle(RTIDesign.Color.textTertiary)
                }
                Spacer()
            }
            content()
        }
        .padding(RTIDesign.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: RTIDesign.Radius.md)
                .fill(RTIDesign.Color.aiCardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: RTIDesign.Radius.md)
                        .stroke(RTIDesign.Color.aiCardBorder, lineWidth: 1)
                )
        )
    }
}

// MARK: - SpeakerChip

/// Pill rendering a speaker label (`You`, `Speaker 1`, …) with a colored dot.
struct SpeakerChip: View {
    let raw: String

    var body: some View {
        let color = SpeakerLabels.chipColor(for: raw)
        let label = SpeakerLabels.displayName(for: raw)
        let isNote = SpeakerLabels.isNote(raw)
        HStack(spacing: 6) {
            if isNote {
                Image(systemName: "note.text")
                    .font(.system(size: 10, weight: .semibold))
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
            }
            Text(label)
                .font(RTIDesign.Font.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(
            Capsule()
                .fill(color.opacity(0.10))
                .overlay(
                    Capsule()
                        .stroke(color.opacity(0.22), lineWidth: 1)
                )
        )
    }
}

// MARK: - MessageBubble

/// One Q&A turn. User turns render right-aligned in the accent fill; assistant
/// turns render in `AIOutputCard`. Streaming `isPartial` adds a subtle pulse.
struct MessageBubble: View {
    enum Role { case user, assistant }
    let role: Role
    let text: String
    let timestamp: Date?
    let isPartial: Bool

    init(role: Role, text: String, timestamp: Date? = nil, isPartial: Bool = false) {
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.isPartial = isPartial
    }

    var body: some View {
        switch role {
        case .user:
            HStack(alignment: .top) {
                Spacer(minLength: RTIDesign.Spacing.xl)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(text)
                        .font(RTIDesign.Font.bodySmall)
                        .foregroundStyle(.white)
                        .padding(.horizontal, RTIDesign.Spacing.md)
                        .padding(.vertical, RTIDesign.Spacing.sm)
                        .background(RTIDesign.Color.accent, in: RoundedRectangle(cornerRadius: RTIDesign.Radius.lg))
                        .textSelection(.enabled)
                    if let timestamp = timestamp {
                        Text(timestamp.formatted(date: .omitted, time: .shortened))
                            .font(RTIDesign.Font.caption)
                            .foregroundStyle(RTIDesign.Color.textTertiary)
                    }
                }
            }
        case .assistant:
            AIOutputCard(timestamp: timestamp) {
                let attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
                Text(attributed)
                    .font(RTIDesign.Font.body)
                    .foregroundStyle(RTIDesign.Color.textPrimary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(isPartial && text.isEmpty ? 0 : 1)
            }
        }
    }
}

// MARK: - QuickPromptChip

/// Tappable suggestion chip shown above the composer when Q&A is empty.
struct QuickPromptChip: View {
    let label: String
    let action: () -> Void
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(RTIDesign.Font.bodySmall)
                .foregroundStyle(RTIDesign.Color.textPrimary)
                .padding(.horizontal, RTIDesign.Spacing.md)
                .padding(.vertical, RTIDesign.Spacing.xs)
                .background(
                    Capsule()
                        .fill(isHovering ? RTIDesign.Color.trackBackground : RTIDesign.Color.cardBackground)
                        .overlay(
                            Capsule()
                                .stroke(RTIDesign.Color.border, lineWidth: 1)
                        )
                )
                .overlay(
                    Capsule()
                        .stroke(RTIDesign.Color.accent, lineWidth: 2)
                        .opacity(isFocused ? 1 : 0)
                )
        }
        .buttonStyle(.plain)
        .focusable(true)
        .focused($isFocused)
        .onHover { isHovering = $0 }
    }
}

// MARK: - ToastPresenter + Toast view

/// Triggers a transient top-right pill. Coalesces concurrent toasts (latest wins).
@MainActor
final class ToastPresenter: ObservableObject {
    @Published private(set) var message: String?
    private var clearTask: Task<Void, Never>?

    func show(_ message: String, duration: TimeInterval = 2.5) {
        self.message = message
        RTILog.log("[SessionDetail] toast: \(message)", category: "UI")
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self = self else { return }
                self.message = nil
            }
        }
    }
}

struct ToastOverlay: View {
    @ObservedObject var presenter: ToastPresenter

    var body: some View {
        VStack {
            if let message = presenter.message {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                    Text(message)
                        .font(RTIDesign.Font.bodySmall.weight(.medium))
                }
                .foregroundStyle(RTIDesign.Color.toastText)
                .padding(.horizontal, RTIDesign.Spacing.md)
                .padding(.vertical, RTIDesign.Spacing.xs)
                .background(
                    Capsule()
                        .fill(RTIDesign.Color.toastBackground)
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .padding(.top, RTIDesign.Spacing.lg)
        .padding(.trailing, RTIDesign.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.18), value: presenter.message)
    }
}

// MARK: - StickySubheader

/// Pinned-at-top subheader for each tab body. Shows tab name + count chip +
/// trailing slot for tab-specific quick actions.
struct StickySubheader<Trailing: View>: View {
    let title: String
    let count: String?
    @ViewBuilder let trailing: () -> Trailing

    init(title: String, count: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.count = count
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: RTIDesign.Spacing.sm) {
            Text(title)
                .font(RTIDesign.Font.bodySmall.weight(.semibold))
                .foregroundStyle(RTIDesign.Color.textPrimary)
            if let count = count, !count.isEmpty {
                Text(count)
                    .font(RTIDesign.Font.meta)
                    .foregroundStyle(RTIDesign.Color.textTertiary)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(
                        Capsule()
                            .fill(RTIDesign.Color.trackBackground)
                    )
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, RTIDesign.Spacing.xl)
        .frame(height: 36)
        .background(
            RTIDesign.Color.panelBackground
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(RTIDesign.Color.divider)
                        .frame(height: 0.5)
                }
        )
    }
}
