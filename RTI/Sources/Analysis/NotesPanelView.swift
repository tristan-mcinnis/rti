import SwiftUI

struct NotesPanelView: View {
    private let controller = NotesGenerationController.shared

    var body: some View {
        FloatingPanelChrome(
            title: "Notes",
            opacityKey: notesOpacityKey,
            defaultOpacity: notesDefaultOpacity,
            panelID: .notes,
            titleAccessory: {
                if controller.isGenerating {
                    ProgressView()
                        .scaleEffect(0.7)
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                }
            },
            headerActions: {
                PanelHeaderEllipsisMenu(panelID: .notes) {
                    Button("Copy all", action: copyAll)
                        .disabled(controller.notes.isEmpty)
                    Button("Export as .md…", action: exportToFile)
                        .disabled(controller.notes.isEmpty)
                    Divider()
                    Button("Regenerate now", action: regenerate)
                        .disabled(controller.isGenerating || SessionCoordinator.shared.currentSessionId == nil)
                    Button("Clear", role: .destructive) { controller.clear() }
                        .disabled(controller.notes.isEmpty)
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

                if controller.notes.isEmpty {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "note.text")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("Waiting for first note…")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text("Notes generate every few minutes while recording.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(controller.notes) { note in
                                    NoteCard(note: note)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                        }
                        .scrollContentBackground(.hidden)
                        .onChange(of: controller.notes.count) { _, _ in
                            if let last = controller.notes.last {
                                withAnimation {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func combinedMarkdown() -> String {
        let parts: [String] = controller.notes.map { n in
            let when = n.timestamp.formatted(date: .abbreviated, time: .shortened)
            return "## Notes — \(when)\n\n\(n.content)"
        }
        return parts.joined(separator: "\n\n---\n\n")
    }

    private func copyAll() {
        NSPasteboard.copyMarkdownRich(combinedMarkdown())
    }

    private func regenerate() {
        guard let sid = SessionCoordinator.shared.currentSessionId else { return }
        Task { _ = await controller.generate(sessionId: sid) }
    }

    private func exportToFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "rti-notes-\(Date().formatted(.iso8601.year().month().day())).md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? combinedMarkdown().write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct NoteCard: View {
    let note: GeneratedNote

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(formattedTime(note.timestamp))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.12)))

                Spacer()

                Button {
                    NSPasteboard.copyMarkdownRich(note.content)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Copy this note's markdown")
            }

            MarkdownText(note.content)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.9))
                .textSelection(.enabled)
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

    private func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}

/// Renders multi-line LLM-produced markdown including block syntax
/// (headings, bullet lists, task checkboxes). SwiftUI's `Text(AttributedString)`
/// only handles inline syntax, so we hand-render line-by-line: headings get
/// weighted/sized, list items get a bullet/checkbox prefix, and inline
/// emphasis/code/links inside each line stay attributed.
private struct MarkdownText: View {
    let markdown: String

    init(_ markdown: String) { self.markdown = markdown }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                renderLine(line)
            }
        }
    }

    private var lines: [String] {
        markdown.components(separatedBy: "\n")
    }

    @ViewBuilder
    private func renderLine(_ raw: String) -> some View {
        let line = raw
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            Spacer().frame(height: 4)
        } else if let stripped = line.stripPrefix("### ") {
            inline(stripped).font(.system(size: 12, weight: .semibold))
        } else if let stripped = line.stripPrefix("## ") {
            inline(stripped).font(.system(size: 13, weight: .bold))
                .padding(.top, 4)
        } else if let stripped = line.stripPrefix("# ") {
            inline(stripped).font(.system(size: 14, weight: .bold))
                .padding(.top, 4)
        } else if let stripped = line.stripPrefix("- [ ] ") ?? line.stripPrefix("* [ ] ") {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "square").font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                inline(stripped)
            }
        } else if let stripped = line.stripPrefix("- [x] ") ?? line.stripPrefix("* [x] ")
                    ?? line.stripPrefix("- [X] ") ?? line.stripPrefix("* [X] ") {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "checkmark.square.fill").font(.system(size: 11))
                    .foregroundStyle(.green.opacity(0.8))
                inline(stripped)
            }
        } else if let stripped = line.stripPrefix("- ") ?? line.stripPrefix("* ") {
            HStack(alignment: .top, spacing: 6) {
                Text("•").foregroundStyle(.white.opacity(0.5))
                inline(stripped)
            }
        } else {
            inline(line)
        }
    }

    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text,
                                                  options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }
}

private extension String {
    /// Returns the substring after `prefix` if present, else nil. Used by
    /// the per-line markdown renderer to detect heading / list / task syntax.
    func stripPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
