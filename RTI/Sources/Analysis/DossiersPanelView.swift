import SwiftUI

struct DossiersPanelView: View {
    private let controller = DossierController.shared

    var body: some View {
        FloatingPanelChrome(
            title: "Dossiers",
            opacityKey: dossiersOpacityKey,
            defaultOpacity: dossiersDefaultOpacity,
            panelID: .dossiers,
            titleAccessory: {
                if controller.isGenerating {
                    ProgressView()
                        .scaleEffect(0.7)
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                }
            },
            headerActions: {
                PanelHeaderEllipsisMenu(panelID: .dossiers) {
                    Button("Copy all", action: copyAll)
                        .disabled(controller.dossiers.isEmpty)
                    Button("Export as .md…", action: exportToFile)
                        .disabled(controller.dossiers.isEmpty)
                    Divider()
                    Button("Regenerate now", action: regenerate)
                        .disabled(controller.isGenerating || SessionCoordinator.shared.currentSessionId == nil)
                    Button("Clear", role: .destructive) { controller.clear() }
                        .disabled(controller.dossiers.isEmpty)
                }
            }
        ) {
            VStack(spacing: 0) {
                if let error = controller.lastError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)
                }

                if controller.dossiers.isEmpty {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "person.text.rectangle")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("Waiting for entities…")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text("Dossiers update every few minutes while recording.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(groupedDossiers) { group in
                                TypeSection(group: group)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
        }
    }

    private func combinedMarkdown() -> String {
        let parts: [String] = groupedDossiers.map { group in
            let entries: [String] = group.dossiers.map { "- **\($0.name)** — \($0.description)" }
            return "## \(group.type.displayName)\n\n\(entries.joined(separator: "\n"))"
        }
        return parts.joined(separator: "\n\n")
    }

    private func copyAll() {
        NSPasteboard.copyString(combinedMarkdown())
    }

    private func regenerate() {
        guard let sid = SessionCoordinator.shared.currentSessionId else { return }
        Task { _ = await controller.generate(sessionId: sid) }
    }

    private func exportToFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "rti-dossiers-\(Date().formatted(.iso8601.year().month().day())).md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? combinedMarkdown().write(to: url, atomically: true, encoding: .utf8)
    }

    private var groupedDossiers: [DossierGroup] {
        let grouped = Dictionary(grouping: controller.dossiers) { $0.type }
        return grouped.map { DossierGroup(type: $0.key, dossiers: $0.value) }
            .sorted { $0.type.displayName < $1.type.displayName }
    }
}

private struct DossierGroup: Identifiable {
    let id = UUID()
    let type: EntityType
    let dossiers: [EntityDossier]
}

private struct TypeSection: View {
    let group: DossierGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: group.type.icon)
                    .font(.system(size: 10))
                Text(group.type.displayName)
                    .font(.system(size: 11, weight: .semibold))
                Text("\(group.dossiers.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }
            .foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 4)

            ForEach(group.dossiers) { dossier in
                DossierCard(dossier: dossier)
            }
        }
    }
}

private struct DossierCard: View {
    let dossier: EntityDossier

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(dossier.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    NSPasteboard.copyString("\(dossier.name) — \(dossier.description)")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Copy this dossier")
            }

            Text(dossier.description)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.78))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
    }
}
