import SwiftUI

struct DossiersPanelView: View {
    @ObservedObject private var controller = DossierController.shared
    @AppStorage(dossiersOpacityKey) private var backgroundOpacity: Double = dossiersDefaultOpacity

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(backgroundOpacity))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

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
                }
            }

            ResizeHandle()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding([.bottom, .trailing], 6)
        }
    }

    private var header: some View {
        HStack {
            Text("Dossiers")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)

            if controller.isGenerating {
                ProgressView()
                    .scaleEffect(0.7)
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
            }

            Spacer()

            HStack(spacing: 8) {
                OpacitySlider(opacity: $backgroundOpacity)
                    .frame(width: 80)

                Button(action: {
                    NotificationCenter.default.post(name: .rtiToggleDossiersPanel, object: nil)
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        }
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
            HStack(spacing: 6) {
                Text(dossier.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()

                if dossier.mentions > 1 {
                    Text("\(dossier.mentions)×")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                }
            }

            Text(dossier.description)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(3)
        }
        .padding(10)
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

private struct OpacitySlider: View {
    @Binding var opacity: Double

    var body: some View {
        Slider(value: $opacity, in: 0.30...0.95, step: 0.05) {}
        .tint(.white.opacity(0.4))
        .frame(height: 12)
    }
}
