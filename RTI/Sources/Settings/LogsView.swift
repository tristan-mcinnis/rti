import SwiftUI

struct LogsView: View {
    private let log = AppLog.shared
    @State private var crashLogText: String = ""

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Live log")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(log.entries.count) entries")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { copyLive() }
                Button("Clear") { log.clear() }
                Button("Reveal in Finder") { revealCrashLog() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.9))

            Divider()

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
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
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

            Divider()

            DisclosureGroup("Crash log (\(crashLogPath))") {
                ScrollView {
                    Text(crashLogText.isEmpty ? "No crashes recorded." : crashLogText)
                        .font(.system(size: 11, design: .monospaced))
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
    }

    private func row(_ entry: AppLog.Entry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 90, alignment: .leading)
            Text(entry.category)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
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

    private func copyLive() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(log.renderForCopy(), forType: .string)
    }
}
