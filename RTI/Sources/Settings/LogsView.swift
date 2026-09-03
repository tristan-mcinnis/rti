import SwiftUI

struct LogsView: View {
    private let log = AppLog.shared
    @State private var crashLogText: String = ""
    @State private var mode: Mode = .live
    @State private var pastFiles: [URL] = []
    @State private var selectedPast: URL?
    @State private var pastText: String = ""

    enum Mode: String, CaseIterable { case live = "Live", past = "Past" }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 130)
                if mode == .live {
                    Text("\(log.entries.count) entries")
                        .font(RTIDesign.Font.caption)
                        .foregroundStyle(RTIDesign.Color.textSecondary)
                } else {
                    Picker("", selection: $selectedPast) {
                        ForEach(pastFiles, id: \.self) { url in
                            Text(url.deletingPathExtension().lastPathComponent
                                .replacingOccurrences(of: "rti-", with: "")).tag(Optional(url))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
                Spacer()
                if mode == .live {
                    Button("Copy") { copyLive() }
                    Button("Clear") { log.clear() }
                } else {
                    Button("Copy") { copyPast() }
                    Button("Reveal in Finder") { revealPastLogs() }
                }
                Button("Crash log") { revealCrashLog() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RTIDesign.Color.well)

            Divider()

            if mode == .past {
                ScrollView {
                    Text(pastText.isEmpty ? "No log file for this day." : pastText)
                        .font(.system(size: House.TypeToken.Size.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            } else {

            // In-memory live log — scroll auto-pins to the latest line.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(log.entries) { entry in
                            row(entry)
                                .id(entry.id)
                        }
                        if log.entries.isEmpty {
                            Text("No log entries yet. Recent activity — Soniox connect/error, audio device binding, LLM requests, regen progress — will appear here as it fires.")
                                .font(RTIDesign.Font.meta)
                                .foregroundStyle(RTIDesign.Color.textSecondary)
                                .padding(.vertical, 16)
                                .padding(.horizontal, 12)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: log.entries.count) { _, _ in
                    if let last = log.entries.last?.id {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            }

            Divider()

            DisclosureGroup("Crash log (\(crashLogPath))") {
                ScrollView {
                    Text(crashLogText.isEmpty ? "No crashes recorded." : crashLogText)
                        .font(.system(size: House.TypeToken.Size.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(height: 180)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 600, minHeight: 480)
        .onAppear { reloadCrashLog() }
        .onChange(of: mode) { _, new in
            guard new == .past else { return }
            pastFiles = AppLog.pastLogFiles()
            if selectedPast == nil { selectedPast = pastFiles.first }
        }
        .onChange(of: selectedPast) { _, _ in loadPast() }
    }

    private func row(_ entry: AppLog.Entry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(.system(size: House.TypeToken.Size.caption, design: .monospaced))
                .foregroundStyle(RTIDesign.Color.textTertiary)
                .frame(width: 90, alignment: .leading)
            Text(entry.category)
                .font(.system(size: House.TypeToken.Size.caption, weight: .semibold, design: .monospaced))
                .foregroundStyle(RTIDesign.Color.textSecondary)
                .frame(width: 80, alignment: .leading)
            Text(entry.message)
                .font(.system(size: House.TypeToken.Size.caption, design: .monospaced))
                .foregroundStyle(RTIDesign.Color.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var crashLogPath: String {
        CrashLog.logURL?.path ?? "(unavailable)"
    }

    private func reloadCrashLog() {
        guard let url = CrashLog.logURL,
              FileManager.default.fileExists(atPath: url.path) else {
            crashLogText = ""
            return
        }
        crashLogText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func revealCrashLog() {
        guard let url = CrashLog.logURL, FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func loadPast() {
        guard let selectedPast else { pastText = ""; return }
        pastText = (try? String(contentsOf: selectedPast, encoding: .utf8)) ?? ""
    }

    private func copyPast() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pastText, forType: .string)
    }

    private func revealPastLogs() {
        if let selectedPast {
            NSWorkspace.shared.activateFileViewerSelecting([selectedPast])
        } else {
            NSWorkspace.shared.open(AppLog.logsDirectory)
        }
    }

    private func copyLive() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(log.renderForCopy(), forType: .string)
    }
}
