import SwiftUI

/// Renders the live card stream for one `periodic_cards` panel. Reads
/// from `PeriodicCardsController` and lets the user copy or export the
/// accumulated cards as markdown.
struct PeriodicCardsView: View {
    let panel: UserPanel

    private let controller = PeriodicCardsController.shared
    @AppStorage(notesOpacityKey) private var backgroundOpacity: Double = notesDefaultOpacity

    private var cfg: PeriodicCardsConfig? { panel.config.periodicCards }
    private var cards: [PeriodicCardsController.Card] { controller.cardsByPanel[panel.id] ?? [] }
    private var isGenerating: Bool { controller.generatingPanelIds.contains(panel.id) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(white: 0.14).opacity(backgroundOpacity))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                if cards.isEmpty {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "sparkles.rectangle.stack")
                            .font(.system(size: 26))
                            .foregroundStyle(.secondary)
                        Text("Waiting for first card…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        if let cfg {
                            Text("Generates every \(Int(cfg.intervalSeconds))s")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(cards) { card in
                                    cardView(card)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.bottom, 12)
                        }
                        .onChange(of: cards.count) { _, _ in
                            if let last = cards.last {
                                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                        }
                    }
                }
            }

            ResizeHandle()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding([.bottom, .trailing], 6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var header: some View {
        HStack {
            Text(cfg?.label ?? "Panel")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)

            if isGenerating {
                ProgressView().scaleEffect(0.6)
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
            }

            Spacer()

            if !cards.isEmpty {
                Menu {
                    Button("Copy all", action: copyAll)
                    Button("Export as .md…", action: exportToFile)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20, height: 20)
                .help("Copy or export cards")
                .accessibilityLabel("Copy or export cards")
            }

            Button {
                UserPanelStore.shared.remove(id: panel.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .help("Remove panel")
            .accessibilityLabel("Remove panel")
        }
    }

    private func cardView(_ card: PeriodicCardsController.Card) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(card.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Button {
                    NSPasteboard.copyString(card.content)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Copy this card")
                .accessibilityLabel("Copy this card")
            }

            Text(card.content)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.9))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08))
        )
    }

    private func combinedMarkdown() -> String {
        let header = "# \(cfg?.label ?? "Panel")\n\n"
        let parts: [String] = cards.map { c in
            let when = c.createdAt.formatted(date: .abbreviated, time: .shortened)
            return "## \(when)\n\n\(c.content)"
        }
        return header + parts.joined(separator: "\n\n---\n\n")
    }

    private func copyAll() { NSPasteboard.copyString(combinedMarkdown()) }

    private func exportToFile() {
        let panel = NSSavePanel()
        let slug = (cfg?.label ?? "panel").replacingOccurrences(of: " ", with: "-").lowercased()
        panel.nameFieldStringValue = "rti-\(slug)-\(Date().formatted(.iso8601.year().month().day())).md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? combinedMarkdown().write(to: url, atomically: true, encoding: .utf8)
    }
}
