import Foundation
import Observation
import RTICore

/// Settings › Voices backing store: reads the enrolled voice-sample catalog
/// from the vault-side speaker-profiles CLI and applies review decisions
/// (delete / reassign) back through it. The CLI stays the single writer of
/// the profile store — RTI never opens the SQLite file itself.
@Observable @MainActor
final class VoiceProfilesStore {
    private(set) var people: [(name: String, samples: [VoiceSampleCatalog.Sample])] = []
    private(set) var isLoading = false
    private(set) var lastError: String?
    /// Nil when the vault tool or its python stack isn't reachable.
    private(set) var toolAvailable = true

    var knownNames: [String] { people.map(\.name) }

    func reload() {
        guard !isLoading else { return }
        isLoading = true
        lastError = nil
        Task { [weak self] in
            let result = await Self.run(arguments: ["samples", "--json"])
            guard let self else { return }
            self.isLoading = false
            switch result {
            case .unavailable:
                self.toolAvailable = false
                self.people = []
            case .failure(let message):
                self.toolAvailable = true
                self.lastError = message
            case .success(let output):
                self.toolAvailable = true
                guard let data = output.data(using: .utf8),
                      let catalog = try? JSONDecoder().decode(VoiceSampleCatalog.self, from: data) else {
                    self.lastError = "Could not read the sample catalog."
                    return
                }
                self.people = catalog.byPerson
            }
        }
    }

    func deleteSample(id: Int) {
        mutate(arguments: ["delete-sample", "--id", String(id)])
    }

    func reassignSample(id: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate(arguments: ["reassign", "--id", String(id), "--name", trimmed])
    }

    private func mutate(arguments: [String]) {
        lastError = nil
        Task { [weak self] in
            let result = await Self.run(arguments: arguments)
            guard let self else { return }
            if case .failure(let message) = result {
                self.lastError = message
            }
            self.reload()
        }
    }

    private enum RunResult {
        case success(String)
        case failure(String)
        case unavailable
    }

    private nonisolated static func run(arguments: [String]) async -> RunResult {
        guard let script = SpeakerEnrollment.speakerProfilesScriptURL(),
              let python = SpeakerEnrollment.pythonExecutableURL() else {
            return .unavailable
        }
        return await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = python
            proc.arguments = [script.path] + arguments
            let out = Pipe(), err = Pipe()
            proc.standardOutput = out
            proc.standardError = err
            do {
                try proc.run()
            } catch {
                return .unavailable
            }
            let stdout = out.fileHandleForReading.readDataToEndOfFile()
            let stderr = err.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                let message = String(data: stderr, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(message?.isEmpty == false ? message! : "speaker-profiles exited \(proc.terminationStatus)")
            }
            return .success(String(data: stdout, encoding: .utf8) ?? "")
        }.value
    }
}
