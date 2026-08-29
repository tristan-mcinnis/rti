import AVFoundation
import RTICore
import SwiftUI

// MARK: - Voices (enrolled speaker samples review)

/// Review surface for the vault's voice-profile store: every enrolled sample,
/// grouped by person, auditionable in place. Keep is the default (do nothing);
/// each row can be deleted, reassigned to another enrolled person, or moved to
/// a brand-new person. Mutations run through the vault CLI — the single writer.
struct VoicesTab: View {
    @State private var store = VoiceProfilesStore()
    @State private var player = ClipPlayer()
    @State private var reassignTarget: VoiceSampleCatalog.Sample?
    @State private var newPersonName = ""

    var body: some View {
        SettingsPage(maxWidth: 760) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsCard("How Voice Profiles Work", detail: "These clips are the voice fingerprints used to suggest speaker names after every session. Suggestions never rename anything on their own — you confirm names in Sessions, and confirms grow this store.") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Play a clip to hear exactly what was enrolled. Delete anything that isn't that person, or move it to the right one — a wrong sample makes future suggestions worse, so pruning here is the highest-leverage fix.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            statusLabel
                            Spacer()
                            Button {
                                store.reload()
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            .disabled(store.isLoading)
                        }
                    }
                }

                if store.toolAvailable {
                    ForEach(store.people, id: \.name) { person in
                        SettingsCard(person.name, detail: "\(person.samples.count) sample\(person.samples.count == 1 ? "" : "s")") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(person.samples) { sample in
                                    sampleRow(sample)
                                    if sample.id != person.samples.last?.id {
                                        Divider()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear { store.reload() }
        .onDisappear { player.stop() }
        .alert("Move sample to a new person", isPresented: newPersonAlertShown) {
            TextField("Full name", text: $newPersonName)
            Button("Move") {
                if let sample = reassignTarget {
                    store.reassignSample(id: sample.id, to: newPersonName)
                }
                reassignTarget = nil
                newPersonName = ""
            }
            Button("Cancel", role: .cancel) {
                reassignTarget = nil
                newPersonName = ""
            }
        } message: {
            Text("Use the person's real full name — it becomes the label future transcripts get.")
        }
    }

    private var newPersonAlertShown: Binding<Bool> {
        Binding(
            get: { reassignTarget != nil },
            set: { if !$0 { reassignTarget = nil } }
        )
    }

    @ViewBuilder
    private var statusLabel: some View {
        if !store.toolAvailable {
            SettingsStatusLabel(text: "Vault voice tool not reachable (vault or python stack missing) — nothing to review.", systemImage: "exclamationmark.triangle.fill", color: .orange)
        } else if let error = store.lastError {
            SettingsStatusLabel(text: error, systemImage: "exclamationmark.triangle.fill", color: .orange)
        } else if store.isLoading {
            SettingsStatusLabel(text: "Loading samples…", systemImage: "hourglass", color: .secondary)
        } else {
            let total = store.people.reduce(0) { $0 + $1.samples.count }
            SettingsStatusLabel(
                text: total == 0
                    ? "No voice samples enrolled yet. Confirm speaker names in Sessions to start the store."
                    : "\(total) sample\(total == 1 ? "" : "s") across \(store.people.count) \(store.people.count == 1 ? "person" : "people").",
                systemImage: total == 0 ? "info.circle" : "checkmark.circle.fill",
                color: total == 0 ? .secondary : .green
            )
        }
    }

    private func sampleRow(_ sample: VoiceSampleCatalog.Sample) -> some View {
        HStack(spacing: 10) {
            Button {
                if player.playingSampleID == sample.id {
                    player.stop()
                } else {
                    player.play(sample)
                }
            } label: {
                Image(systemName: player.playingSampleID == sample.id ? "stop.circle.fill" : "play.circle")
                    .font(.system(size: 17))
            }
            .buttonStyle(.plain)
            .disabled(!sample.canAudition)
            .help(sample.canAudition ? "Play this clip" : "Audio file not found")

            VStack(alignment: .leading, spacing: 2) {
                Text(clipTitle(sample))
                    .font(.system(size: 12, weight: .medium))
                Text(clipSubtitle(sample))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Menu {
                Menu("Move to") {
                    ForEach(store.knownNames.filter { $0 != sample.name }, id: \.self) { name in
                        Button(name) { store.reassignSample(id: sample.id, to: name) }
                    }
                    Divider()
                    Button("New person…") { reassignTarget = sample }
                }
                Divider()
                Button("Delete sample", role: .destructive) {
                    if player.playingSampleID == sample.id { player.stop() }
                    store.deleteSample(id: sample.id)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
        .padding(.vertical, 3)
    }

    private func clipTitle(_ sample: VoiceSampleCatalog.Sample) -> String {
        var parts: [String] = ["Clip #\(sample.id)"]
        if let offset = sample.offset {
            let duration = sample.duration ?? 8
            parts.append("\(Int(offset))s–\(Int(offset + duration))s")
        } else {
            parts.append("clip window unknown")
        }
        if let label = sample.label {
            parts.append(label)
        }
        return parts.joined(separator: " · ")
    }

    private func clipSubtitle(_ sample: VoiceSampleCatalog.Sample) -> String {
        var parts: [String] = []
        if let session = sample.session { parts.append("Session \(session)") }
        if let created = sample.created, created.count >= 10 {
            parts.append("enrolled \(created.prefix(10))")
        }
        if !(sample.playable ?? false) { parts.append("audio missing") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

// MARK: - Clip playback

/// Plays one enrolled window out of a session WAV: seek to the stored offset,
/// stop after the stored duration. One clip at a time.
@Observable @MainActor
final class ClipPlayer {
    private(set) var playingSampleID: Int?
    private var player: AVAudioPlayer?
    private var stopTask: Task<Void, Never>?

    func play(_ sample: VoiceSampleCatalog.Sample) {
        stop()
        guard let path = sample.audio else { return }
        guard let audioPlayer = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) else { return }
        let duration = sample.duration ?? 8
        audioPlayer.currentTime = sample.offset ?? 0
        guard audioPlayer.play() else { return }
        player = audioPlayer
        playingSampleID = sample.id
        stopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        player?.stop()
        player = nil
        playingSampleID = nil
    }
}
