import AppKit
import RTICore
import SwiftUI
import HouseDesign

// MARK: - Header

/// Rail toggle, the session title over its date line, then "Ask in RTI"
/// and the `⌘K` glyph. No divider under it.
struct SessionsHeader: View {
    @Environment(\.isWorkspaceEmbedded) private var embedded
    @Bindable var model: SessionsWindowModel

    var body: some View {
        HStack(spacing: House.Spacing.sm) {
            if !embedded {
                QuickAIGlyphButton(
                    symbol: "sidebar.left",
                    font: HouseChatType.glyphSmall,
                    color: House.ColorToken.textSecondary,
                    label: model.isRailVisible ? "Hide Session List" : "Show Session List",
                    help: "\(model.isRailVisible ? "Hide" : "Show") session list (⌃⌘S)",
                    accessibilityValue: model.isRailVisible ? "Open" : "Closed"
                ) {
                    model.toggleRail()
                }
            }
            HouseTitleBlock(
                title: model.windowTitle,
                // One segment, so a narrow window cuts the line once.
                line: model.windowSubtitle.isEmpty ? [] : [.text(model.windowSubtitle)]
            )
            .layoutPriority(1)
            Spacer(minLength: House.Spacing.sm)
            if !embedded { SessionsModeSwitch(model: model) }
            if model.mode == .sessions, let row = model.openRow, row.vaultTranscriptPath != nil {
                // The labelled chip; a narrow window keeps its glyph only.
                ViewThatFits(in: .horizontal) {
                    askChip(label: true)
                    askChip(label: false)
                }
            }
            if model.mode == .sessions, let row = model.openRow {
                Button("Copy current document", systemImage: "doc.on.doc") { model.perform(.copy) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(SessionCircleButtonStyle())
                    .disabled(model.fileText.isEmpty)
                    .help("Copy current document as Markdown (⇧⌘C)")
                Button("Share current document", systemImage: "square.and.arrow.up") { model.perform(.share) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(SessionCircleButtonStyle())
                    .disabled(!model.actions(for: row).contains(.share))
                    .help("Choose where to share the current document")
                if model.actions(for: row).contains(.trash) {
                    Button("Move session to Trash", systemImage: "trash", role: .destructive) { model.perform(.trash) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(SessionCircleButtonStyle())
                        .help("Move this RTI session to Trash…")
                }
                Button("Session actions", systemImage: "command") {
                    if model.actionsPlacement == .header { model.closeActions() }
                    else { model.showActions(placement: .header) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(SessionCircleButtonStyle(isSelected: model.actionsPlacement == .header))
                .help("Session actions, including export options (⌘K)")
                .accessibilityValue(model.actionsPlacement == .header ? "Open" : "Closed")
            }
        }
        // The traffic lights share this row while the rail is in.
        .padding(.leading, embedded || model.isRailVisible || model.isWindowFullScreen ? House.Spacing.sm : HouseChatMetrics.trafficLightInset)
        .padding(.trailing, House.Spacing.lg)
        .frame(height: House.Control.composer)
        .background {
            ZStack {
                House.ColorToken.surface
                // A press on the header's empty space moves the window.
                WindowDragArea()
            }
        }
        .zIndex(1)
    }

    private func askChip(label: Bool) -> some View {
        Button {
            model.perform(.ask)
        } label: {
            HStack(spacing: House.Spacing.xs) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(House.TypeToken.label)
                if label {
                    Text("Ask in RTI")
                        .font(House.TypeToken.label)
                        .lineLimit(1)
                    KeyCapGroup(keys: ["⌘", "J"])
                }
            }
            .foregroundStyle(House.ColorToken.textPrimary)
            .padding(.horizontal, label ? House.Spacing.sm : House.Spacing.xs)
            .frame(height: House.Control.chip)
            .background(
                Capsule().fill(House.ColorToken.chipFill)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Ask about this session in RTI's chat (⌘J)")
        .accessibilityLabel("Ask in RTI")
    }
}

// MARK: - File chips and notice

/// The open session's files: Transcript, Chat, Screen, and so on.
/// The selected chip carries the house selection; hover is half of it.
struct SessionFileChips: View {
    @Bindable var model: SessionsWindowModel
    @State private var hovered: URL?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: House.Spacing.xxs) {
            ForEach(model.files) { file in
                let isSelected = model.selectedFile == file
                Button {
                    model.select(file)
                } label: {
                    Text(file.displayName)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(isSelected ? House.ColorToken.textPrimary : House.ColorToken.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, House.Spacing.xs)
                        .frame(height: House.Control.chip)
                        .background {
                            RowHighlight(isSelected: isSelected, isHovering: hovered == file.url, radius: House.Radius.pill)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverHighlight($hovered, id: file.url)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
            }
        }
        .padding(.bottom, House.Spacing.xxs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session files")
    }
}

/// One tool-style line for a long job: the transcript upgrade. Thinking dots
/// while it runs.
struct SessionNoticeLine: View {
    let text: String
    let isRunning: Bool

    var body: some View {
        HStack(spacing: House.Spacing.xs) {
            Group {
                if isRunning {
                    ThinkingIndicator()
                } else {
                    Image(systemName: "info.circle")
                        .font(House.TypeToken.bodySmall)
                        .foregroundStyle(House.ColorToken.textTertiary)
                }
            }
            .frame(width: House.Control.keyCap)
            Text(text)
                .font(House.TypeToken.bodySmall)
                .foregroundStyle(House.ColorToken.textTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: House.Control.keyCap)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Find bar

/// `⌘F`: find in the open file. `↩` or `⌘G` next, `⇧↩` or `⇧⌘G` previous,
/// `esc` closes. Every hit on `hoverFill`, the current one on
/// `selectionFill`.
struct SessionsFindBar: View {
    @Bindable var model: SessionsWindowModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: House.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(House.TypeToken.bodySmall)
                .foregroundStyle(House.ColorToken.textTertiary)
                .accessibilityHidden(true)
            TextField(text: $model.findQuery, prompt: Text("")) {
                Text("Find in session")
            }
            .textFieldStyle(.plain)
            .labelsHidden()
            .font(House.TypeToken.bodySmall)
            .foregroundStyle(House.ColorToken.textPrimary)
            .overlay(alignment: .leading) {
                if model.findQuery.isEmpty {
                    Text("Find in session")
                        .font(House.TypeToken.bodySmall)
                        .foregroundStyle(House.ColorToken.textTertiary)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .focused($focused)
            .onSubmit { model.findNext() }
            Text(model.findStatus)
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textTertiary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
            KeyHint(label: "Next", keys: ["↩"])
            KeyHint(label: "Previous", keys: ["⇧", "↩"])
            QuickAIGlyphButton(
                symbol: "xmark",
                font: HouseChatType.glyphSmall,
                color: House.ColorToken.textSecondary,
                label: "Close Find",
                help: "Close find (esc)"
            ) {
                model.closeFind()
            }
        }
        .padding(.horizontal, House.Spacing.md)
        .frame(height: House.Control.pill)
        .background(
            RoundedRectangle(cornerRadius: House.Radius.md, style: .continuous)
                .fill(House.ColorToken.surfaceTint)
        )
        .overlay(
            RoundedRectangle(cornerRadius: House.Radius.md, style: .continuous)
                .strokeBorder(House.ColorToken.stroke, lineWidth: House.hairline)
        )
        .padding(.horizontal, House.Spacing.lg)
        .padding(.bottom, House.Spacing.xs)
        .onAppear { focused = true }
        .onChange(of: model.findFocusRequest) { _, _ in focused = true }
        .onChange(of: focused) { _, isFocused in
            if isFocused { model.focus = .find } else if model.focus == .find { model.focus = .none }
        }
        .onChange(of: model.findStatus) { _, status in
            guard !status.isEmpty else { return }
            QuickAIAnnouncement.post(status, priority: .medium)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find in session")
    }
}
