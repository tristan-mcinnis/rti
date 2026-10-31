import AppKit
import HouseDesign
import RTICore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Notes

struct NotesTabView: View {
    private let controller = NotesGenerationController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            OverlayTabStrip {
                overlayTabStripTitle("Notes")
                if controller.isGenerating {
                    ProgressView().controlSize(.mini)
                }
            } trailing: {
                OverlayToolbarButton(icon: "arrow.clockwise", help: "Write notes now",
                                     disabled: controller.isGenerating || SessionCoordinator.shared.currentSessionId == nil)
                {
                    if let sid = SessionCoordinator.shared.currentSessionId {
                        Task { _ = await controller.generate(sessionId: sid) }
                    }
                }
                OverlayToolbarButton(icon: "doc.on.doc", help: "Copy all notes", disabled: controller.notes.isEmpty) {
                    NSPasteboard.copyMarkdownRich(combinedMarkdown())
                }
                OverlayToolbarButton(icon: "square.and.arrow.down", help: "Save as Markdown", disabled: controller.notes.isEmpty, action: export)
            }
            if let error = controller.lastError {
                Text(error).font(House.TypeToken.meta).foregroundStyle(House.ColorToken.danger)
            }
            if controller.notes.isEmpty {
                overlayEmptyHints([
                    "Notes appear every few minutes as the meeting goes on",
                    overlayRecordHint(),
                    "\(OverlayTab.setup.shortcutLabel) opens Prepare to turn notes on or off",
                ])
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(controller.notes) { note in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(alignment: .top, spacing: 6) {
                                        noteHeader(note)
                                        Spacer()
                                        OverlayToolbarButton(icon: "doc.on.doc", help: "Copy this note block") {
                                            NSPasteboard.copyMarkdownRich(noteMarkdown(note))
                                        }
                                    }
                                    RTIMarkdown(note.content, style: .overlay)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(note.id)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .onChange(of: controller.notes.count) { _, _ in
                        if let last = controller.notes.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                    // Returning to this tab re-instantiates the view at the
                    // top, so jump straight back to the newest note.
                    .onAppear {
                        if let last = controller.notes.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    /// `00:00 – 02:00 · Title` over `Local time: 10:00 AM – 10:02 AM`.
    private func noteHeader(_ note: GeneratedNote) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text("\(mmss(note.rangeStartMs)) – \(mmss(note.rangeEndMs))")
                    .font(.system(size: House.TypeToken.Size.caption, weight: .semibold, design: .monospaced))
                if !note.title.isEmpty {
                    Text("·").foregroundStyle(Color.overlayInkTertiary)
                    Text(note.title).font(.system(size: House.TypeToken.Size.caption, weight: .semibold))
                }
            }
            .foregroundStyle(Color.overlayInk)
            if let local = localRange(note) {
                Text("Local time: \(local)")
                    .font(RTIDesign.Font.micro).foregroundStyle(Color.overlayInkSecondary)
            }
        }
    }

    private func mmss(_ ms: Int) -> String {
        let s = max(0, ms) / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func localRange(_ note: GeneratedNote) -> String? {
        guard let start = controller.sessionStartedAt else { return nil }
        let from = start.addingTimeInterval(Double(note.rangeStartMs) / 1000)
        let to = start.addingTimeInterval(Double(note.rangeEndMs) / 1000)
        let style = Date.FormatStyle.dateTime.hour().minute()
        return "\(from.formatted(style)) – \(to.formatted(style))"
    }

    /// One note block as markdown, the same shape as its slice of combinedMarkdown.
    private func noteMarkdown(_ note: GeneratedNote) -> String {
        var head = "## \(mmss(note.rangeStartMs)) – \(mmss(note.rangeEndMs))"
        if !note.title.isEmpty {
            head += " · \(note.title)"
        }
        if let local = localRange(note) {
            head += "\n_Local time: \(local)_"
        }
        return "\(head)\n\n\(note.content)"
    }

    private func combinedMarkdown() -> String {
        controller.notes.map(noteMarkdown).joined(separator: "\n\n")
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "rti-notes-\(Date().formatted(.iso8601.year().month().day())).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        let content = combinedMarkdown()
        // begin (sheet-less async) instead of runModal so a slow volume
        // enumeration can't freeze the overlay.
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
