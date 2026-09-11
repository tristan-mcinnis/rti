import SwiftUI

/// Settings → Logs: the live in-memory log, past days' log files, and the
/// crash log. A toolbar strip on top (Live or Past, the count, the
/// actions), monospaced rows under it, the crash log folded at the foot.
struct LogsView: View {
    /// Invented lines for render proofs, so a proof never reads or writes the
    /// real log files or crash log. Nil in the app.
    struct Fixture {
        var entries: [AppLog.Entry]
        var crashLog: String = ""
    }

    var fixture: Fixture? = nil

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

    private var entries: [AppLog.Entry] { fixture?.entries ?? log.entries }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HouseDivider()

            if mode == .past {
                ScrollView {
                    Text(pastText.isEmpty ? "No log file for this day." : pastText)
                        .font(House.TypeToken.code)
                        .foregroundStyle(House.ColorToken.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, House.Spacing.lg)
                        .padding(.vertical, House.Spacing.sm)
                }
            } else {
                liveLog
            }

            HouseDivider()
            crashLog
        }
        .background(House.ColorToken.surface)
        .onAppear { reloadCrashLog() }
        .onChange(of: mode) { _, new in
            guard new == .past, fixture == nil else { return }
            pastFiles = AppLog.pastLogFiles()
            if selectedPast == nil { selectedPast = pastFiles.first }
        }
        .onChange(of: selectedPast) { _, _ in loadPast() }
    }

    private var toolbar: some View {
        HStack(spacing: House.Spacing.xs) {
            InkSegmentedControl(
                selection: $mode,
                options: Mode.allCases.map { InkSegment(value: $0, title: $0.rawValue) }
            )
            .fixedSize()
            if mode == .live {
                Text("\(entries.count) \(entries.count == 1 ? "line" : "lines")")
                    .font(House.TypeToken.meta)
                    .monospacedDigit()
                    .foregroundStyle(House.ColorToken.textSecondary)
            } else {
                Picker("Day", selection: $selectedPast) {
                    ForEach(pastFiles, id: \.self) { url in
                        Text(url.deletingPathExtension().lastPathComponent
                            .replacingOccurrences(of: "rti-", with: "")).tag(Optional(url))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            Spacer(minLength: House.Spacing.xs)
            if mode == .live {
                Button("Copy") { copyLive() }
                Button("Clear") { log.clear() }
            } else {
                Button("Copy") { copyPast() }
                Button("Show in Finder") { revealPastLogs() }
            }
        }
        .padding(.horizontal, House.Spacing.lg)
        .padding(.bottom, House.Spacing.sm)
    }

    /// The in-memory log. The scroll follows the newest line.
    private var liveLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: House.Spacing.xxs) {
                    ForEach(entries) { entry in
                        row(entry)
                            .id(entry.id)
                    }
                    if entries.isEmpty {
                        Text("No log lines yet. Transcription connects and errors, audio devices, model requests, and transcript upgrades show here as they happen.")
                            .font(House.TypeToken.bodySmall)
                            .foregroundStyle(House.ColorToken.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, House.Spacing.md)
                    }
                }
                .padding(.horizontal, House.Spacing.lg)
                .padding(.vertical, House.Spacing.sm)
            }
            .onChange(of: entries.count) { _, _ in
                if let last = entries.last?.id {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    private var crashLog: some View {
        DisclosureGroup {
            ScrollView {
                Text(crashLogText.isEmpty ? "No crashes recorded." : crashLogText)
                    .font(House.TypeToken.code)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(House.Spacing.xs)
            }
            .frame(height: House.Control.hero * 3)
        } label: {
            HStack(spacing: House.Spacing.xs) {
                Text("Crash log")
                    .font(House.TypeToken.label)
                    .foregroundStyle(House.ColorToken.textPrimary)
                Text(crashLogPath)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: House.Spacing.xs)
                Button("Show in Finder") { revealCrashLog() }
                    .disabled(fixture != nil)
            }
        }
        .padding(.horizontal, House.Spacing.lg)
        .padding(.vertical, House.Spacing.xs)
    }

    private func row(_ entry: AppLog.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: House.Spacing.sm) {
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(House.TypeToken.code)
                .foregroundStyle(House.ColorToken.textTertiary)
                .fixedSize()
            Text(entry.category)
                .font(House.TypeToken.code)
                .foregroundStyle(House.ColorToken.textSecondary)
                .lineLimit(1)
                .frame(width: House.Control.xlarge * 2, alignment: .leading)
            Text(entry.message)
                .font(House.TypeToken.code)
                .foregroundStyle(House.ColorToken.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var crashLogPath: String {
        guard fixture == nil else { return "~/Library/Application Support/RTI/crash.log" }
        return (CrashLog.logURL?.path ?? "(unavailable)")
            .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    private func reloadCrashLog() {
        if let fixture {
            crashLogText = fixture.crashLog
            return
        }
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
