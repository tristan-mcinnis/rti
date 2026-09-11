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
        SettingsPage {
            VStack(alignment: .leading, spacing: House.Spacing.sm) {
                SettingsCard("How Voice Profiles Work", detail: "These clips are the voice prints behind the speaker names RTI suggests after each session. A suggestion never renames anything by itself: you confirm names in Sessions, and each confirm adds to this store.", rows: true) {
                    CardNote(isFirst: true) {
                        CardText("Play a clip to hear what was enrolled. Delete a clip that is not that person, or move it to the right person. A wrong sample makes later suggestions worse, so this is the best fix.")
                    }
                    CardNote {
                        statusLabel
                        Spacer(minLength: House.Spacing.sm)
                        Button {
                            store.reload()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(store.isLoading)
                    }
                }

                if store.toolAvailable {
                    ForEach(store.people, id: \.name) { person in
                        SettingsCard(person.name, detail: "\(person.samples.count) sample\(person.samples.count == 1 ? "" : "s")", rows: true) {
                            ForEach(Array(person.samples.enumerated()), id: \.element.id) { index, sample in
                                VStack(spacing: 0) {
                                    if index > 0 { HouseDivider() }
                                    sampleRow(sample)
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
            Text("Use the person's full name. Later transcripts get this label.")
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
            SettingsStatusLabel(text: "The vault voice tool is not reachable (no vault or no Python stack), so there is nothing to review.", systemImage: "exclamationmark.triangle.fill", color: House.ColorToken.warning)
        } else if let error = store.lastError {
            SettingsStatusLabel(text: error, systemImage: "exclamationmark.triangle.fill", color: House.ColorToken.warning)
        } else if store.isLoading {
            SettingsStatusLabel(text: "Loading samples…", systemImage: "hourglass", color: House.ColorToken.textTertiary)
        } else {
            let total = store.people.reduce(0) { $0 + $1.samples.count }
            SettingsStatusLabel(
                text: total == 0
                    ? "No voice samples yet. Confirm speaker names in Sessions to start the store."
                    : "\(total) sample\(total == 1 ? "" : "s") across \(store.people.count) \(store.people.count == 1 ? "person" : "people").",
                systemImage: total == 0 ? "info.circle" : "checkmark.circle.fill",
                color: total == 0 ? House.ColorToken.textTertiary : House.ColorToken.success
            )
        }
    }

    private func sampleRow(_ sample: VoiceSampleCatalog.Sample) -> some View {
        HStack(spacing: House.Spacing.sm) {
            Button {
                if player.playingSampleID == sample.id {
                    player.stop()
                } else {
                    player.play(sample)
                }
            } label: {
                Image(systemName: player.playingSampleID == sample.id ? "stop.circle.fill" : "play.circle")
                    .font(HouseChatType.glyphMedium)
                    .foregroundStyle(House.ColorToken.textPrimary)
                    .frame(width: House.Control.compact, height: House.Control.compact)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!sample.canAudition)
            .help(sample.canAudition ? "Play this clip" : "Audio file not found")
            .accessibilityLabel(player.playingSampleID == sample.id ? "Stop clip" : "Play clip")

            VStack(alignment: .leading, spacing: House.Spacing.xxs / 2) {
                Text(clipTitle(sample))
                    .font(House.TypeToken.label)
                    .foregroundStyle(House.ColorToken.textPrimary)
                Text(clipSubtitle(sample))
                    .font(House.TypeToken.caption)
                    .foregroundStyle(House.ColorToken.textTertiary)
            }

            Spacer(minLength: House.Spacing.sm)

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
                    .foregroundStyle(House.ColorToken.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: House.Control.compact)
            .accessibilityLabel("Sample actions")
        }
        .frame(minHeight: House.Control.row)
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
        return parts.isEmpty ? "No details" : parts.joined(separator: " · ")
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
