import AppKit
import HouseDesign
import RTICore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Auto

/// Auto mode surface: the proactive cards `AutoAssistController` surfaces live —
/// things to say, ask, recall from the project, or flag. Header, manual scan,
/// and a scrolling list; each row is an in-the-moment suggestion.
struct AutoTabView: View {
    private let controller = AutoAssistController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            OverlayTabStrip {
                overlayTabStripTitle("Auto")
                if controller.isGenerating {
                    ProgressView().controlSize(.mini)
                }
            } trailing: {
                OverlayToolbarButton(icon: "arrow.clockwise", help: "Suggest now",
                                     disabled: controller.isGenerating || SessionCoordinator.shared.currentSessionId == nil)
                {
                    if let sid = SessionCoordinator.shared.currentSessionId {
                        Task { _ = await controller.generate(sessionId: sid) }
                    }
                }
            }
            if let error = controller.lastError {
                Text(error).font(House.TypeToken.meta).foregroundStyle(House.ColorToken.danger)
            }
            if controller.cards.isEmpty {
                overlayEmptyHints([
                    "Things to say, ask, or recall show here as the meeting goes on",
                    "\(OverlayTab.setup.shortcutLabel) opens Prepare to pick the project",
                    overlayRecordHint(),
                ])
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(controller.cards) { card in
                                cardRow(card).id(card.id)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .onChange(of: controller.cards.count) { _, _ in
                        controller.markSeen()
                        if let last = controller.cards.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                    .onAppear {
                        controller.markSeen()
                        if let last = controller.cards.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func cardRow(_ c: AutoAssistCard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: c.kind.icon).font(.system(size: House.TypeToken.Size.micro, weight: .bold))
                    Text(c.kind.label.uppercased()).font(.system(size: House.TypeToken.Size.micro, weight: .bold))
                }
                .foregroundStyle(kindColor(c.kind))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: RTIDesign.Radius.xs).fill(kindColor(c.kind).opacity(0.14)))
                Spacer()
                OverlayToolbarButton(icon: "doc.on.doc", help: "Copy") {
                    NSPasteboard.copyMarkdownRich(c.text)
                }
            }
            Text(c.text)
                .font(RTIDesign.Font.label)
                .foregroundStyle(Color.overlayInk)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !c.why.isEmpty {
                Text(c.why)
                    .font(RTIDesign.Font.caption)
                    .foregroundStyle(Color.overlayInkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let source = c.source, !source.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "doc.text").font(.system(size: House.TypeToken.Size.micro))
                    Text(source).font(RTIDesign.Font.micro).lineLimit(1)
                }
                .foregroundStyle(Color.overlayInkTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Monochrome-friendly tint per kind (kept subtle).
    private func kindColor(_ kind: AutoCardKind) -> Color {
        switch kind {
        case .say: RTIDesign.Color.textSecondary
        case .ask: .teal
        case .recall: .green
        case .flag: .orange
        }
    }
}
