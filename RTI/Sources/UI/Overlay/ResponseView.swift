import RTICore
import SwiftUI

/// Carries the y of the scroll content's bottom edge (in the ScrollView's
/// coordinate space) up to the parent, so a streaming reply can tell whether
/// the user is parked at the bottom before it follows the tokens down.
private struct ResponseBottomEdgeKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ResponseView: View {
    let entries: [ChatEntry]
    let streaming: Bool
    let error: String?
    var errorIsAuth: Bool = false
    var onOpenSettings: () -> Void = {}

    private let llm = LLMController.shared
    private let sessionCoord = SessionCoordinator.shared

    // True while the view is parked at (or near) the bottom. Drives whether a
    // streaming reply follows the tokens down. Recomputed from the content's
    // bottom edge vs the viewport so scrolling up detaches the follow and
    // scrolling back down re-attaches it — the standard ChatGPT/Granola feel.
    @State private var pinnedToBottom = true
    @AppStorage(OverlayAppearanceDefaults.reduceMotionKey) private var reduceMotionMode: String = OverlayAppearanceDefaults.defaultReduceMotion
    private let scrollSpace = "rtiResponseScroll"

    private var streamingPlaceholderLabel: String {
        if let toolStatus = llm.toolStatus, !toolStatus.isEmpty { return toolStatus }
        if llm.reasoning { return "reasoning…" }
        if llm.smartMode { return "thinking…" }
        return "responding…"
    }

    private var displayedError: String? {
        if let e = error, !e.isEmpty { return e }
        if let s = sessionCoord.lastError, !s.isEmpty { return s }
        return nil
    }

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { outer in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if entries.isEmpty, !streaming, error == nil {
                            emptyStateBody
                        }

                        ForEach(entries) { entry in
                            entryRow(entry)
                                .id(entry.id)
                        }

                        if let displayedError, !displayedError.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(displayedError)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.red.opacity(0.9))
                                    .textSelection(.enabled)
                                if errorIsAuth {
                                    Button("Open Settings…", action: onOpenSettings)
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Report the content's bottom edge, measured in the
                    // ScrollView's own coordinate space, so we can tell whether
                    // the user is parked at the bottom or has scrolled up.
                    .background(
                        GeometryReader { inner in
                            SwiftUI.Color.clear.preference(
                                key: ResponseBottomEdgeKey.self,
                                value: inner.frame(in: .named(scrollSpace)).maxY
                            )
                        }
                    )
                }
                .coordinateSpace(name: scrollSpace)
                // contentBottom ≈ viewport height when parked at the bottom; a
                // growing gap means the user scrolled up to read. 80pt of slack
                // keeps the follow attached through normal streaming growth
                // while still detaching on a deliberate scroll-up.
                .onPreferenceChange(ResponseBottomEdgeKey.self) { contentBottom in
                    pinnedToBottom = contentBottom - outer.size.height < 80
                }
                // A new turn (user+assistant append, or a fresh assistant stream
                // starting) always re-pins and scrolls down. Defer one runloop
                // tick so SwiftUI has laid out the new row before we seek to it.
                // Returning to this tab re-instantiates at the top — jump back
                // to the latest turn.
                .onAppear {
                    if let lastId = entries.last?.id { proxy.scrollTo(lastId, anchor: .bottom) }
                }
                .onChange(of: entries.count) { _, _ in
                    pinnedToBottom = true
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: entries.last?.id) { _, _ in
                    pinnedToBottom = true
                    scrollToBottom(proxy: proxy)
                }
                // Follow the stream token-by-token, but only while parked at the
                // bottom — scroll up to read earlier turns and the follow lets
                // go; scroll back down and it re-attaches.
                .onChange(of: entries.last?.text) { _, _ in
                    guard streaming, pinnedToBottom else { return }
                    scrollToBottom(proxy: proxy, animated: false)
                }
            }
        }
    }

    @ViewBuilder
    private var emptyStateBody: some View {
        if !LLMProviders.activeHasKey || !STTProviders.activeHasKey {
            missingKeysBody
        } else {
            readyBody
        }
    }

    private var missingKeysBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add API keys to get started")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.overlayInk.opacity(0.85))
            Text("RTI needs a Soniox key for live transcription and a \(LLMProviders.active.displayName) key for the assistant. Both stay on this Mac.")
                .font(.system(size: 12))
                .foregroundStyle(Color.overlayInk.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings…", action: onOpenSettings)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }

    private var readyBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ready when you are")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.overlayInk.opacity(0.6))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(["Summarize the last few minutes",
                         "What did they decide?",
                         "Help me reply"], id: \.self)
                { example in
                    Button { llm.sendAskAnything(example) } label: {
                        Text(example)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.overlayInk.opacity(0.7))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.overlayInk.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .help("Ask this")
                }
            }
        }
    }

    /// Defer the scroll by one runloop tick so SwiftUI has actually laid out
    /// the newly-appended row before we ask the proxy to seek to it. Without
    /// this, hitting Assist on a long conversation often left the new turn
    /// off-screen because onChange fired before layout completed. New turns
    /// animate; per-token streaming follow does not (an animation per token
    /// stutters and lags behind the text).
    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
        DispatchQueue.main.async {
            guard let lastId = entries.last?.id else { return }
            if animated, !OverlayAppearanceDefaults.effectiveReduceMotion() {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(lastId, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: ChatEntry) -> some View {
        if entry.role == "user" {
            HStack {
                Spacer(minLength: 40)
                // Canned actions (Assist, Recap, …) show a compact chip rather
                // than dumping the full internal prompt as a bubble.
                if let action = entry.action, action != "Ask" {
                    cannedActionChip(action)
                } else {
                    userBubble(entry)
                }
            }
        } else {
            HStack {
                AssistantMessageRow(
                    entry: entry,
                    isStreaming: streaming && entry.id == entries.last?.id,
                    toolStatus: llm.toolStatus,
                    sourceTrace: sourceTrace(for: entry),
                    placeholderLabel: streamingPlaceholderLabel,
                    // The whole-meeting Summary is the one reply you most often
                    // re-run (it's long, expensive, and the meeting moved on),
                    // so its Copy/Regenerate bar stays visible instead of
                    // hiding until hover — a discoverable 🔁, Granola-style.
                    alwaysShowActions: isSummaryReply(entry),
                    onCopy: { NSPasteboard.copyString(entry.text) },
                    onRegenerate: { llm.regenerate(assistantID: entry.id) }
                )
                Spacer(minLength: 40)
            }
        }
    }

    /// True when this assistant reply answered a "Session summary" action — i.e.
    /// the immediately preceding entry is a user turn whose action is "Summary".
    private func isSummaryReply(_ entry: ChatEntry) -> Bool {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }), idx > 0 else { return false }
        let prev = entries[idx - 1]
        return prev.role == "user" && prev.action == "Summary"
    }

    private func sourceTrace(for entry: ChatEntry) -> String? {
        var parts: [String] = []
        if let trace = llm.toolTrace(for: entry.id), !trace.isEmpty {
            parts.append(trace)
        }
        if let idx = entries.firstIndex(where: { $0.id == entry.id }), idx > 0 {
            let prev = entries[idx - 1]
            if prev.role == "user", !prev.referencedPaths.isEmpty {
                parts.append("Mentioned sources: " + prev.referencedPaths.joined(separator: ", "))
            }
        }
        let trace = parts.joined(separator: "\n")
        return trace.isEmpty ? nil : trace
    }

    private func userBubble(_ entry: ChatEntry) -> some View {
        UserMessageRow(entry: entry)
    }

    /// A canned-action turn (Assist / Recap / …) shown as a compact chip
    /// instead of the verbose internal prompt the user never actually typed.
    private func cannedActionChip(_ action: String) -> some View {
        let icon = switch action {
        case "Assist": "sparkles"
        case "Say next": "wand.and.rays"
        case "Follow-ups": "bubble.left.and.text.bubble.right"
        case "Recap": "arrow.clockwise"
        default: "sparkles"
        }
        return HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(action)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(Color.overlayInk.opacity(0.6))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.overlayInk.opacity(0.06)))
    }
}

/// One user question bubble with a hover copy affordance. Assistant replies had
/// copy already; vault chat needs the question copy too because the question is
/// often the reusable search brief.
private struct UserMessageRow: View {
    let entry: ChatEntry

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if entry.screenContextUsed || entry.contextUsed {
                HStack(spacing: 8) {
                    if entry.screenContextUsed {
                        Text("Viewed screen")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.overlayInk.opacity(0.4))
                    }
                    if entry.contextUsed {
                        Text("Viewed conversation")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.overlayInk.opacity(0.4))
                    }
                }
            }
            Text(entry.text)
                .font(.system(size: 14))
                .foregroundStyle(Color.overlayInk)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.overlayInk.opacity(0.07))
                )

            if !entry.referencedPaths.isEmpty {
                referencedFileChips
            }

            HStack(spacing: 2) {
                Button {
                    NSPasteboard.copyString(entry.text)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.overlayInk.opacity(0.45))
                        .frame(width: 24, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
                .help("Copy question")
            }
            .frame(height: 20)
        }
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .hoverHighlight($hovering)
    }

    private var referencedFileChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(entry.referencedPaths, id: \.self) { path in
                    HStack(spacing: 5) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 9, weight: .semibold))
                        Text(Self.displayName(for: path))
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(Color.overlayInk.opacity(0.58))
                    .padding(.leading, 8)
                    .padding(.trailing, 9)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(Color.overlayInk.opacity(0.045))
                            .overlay(Capsule().stroke(Color.overlayInk.opacity(0.08), lineWidth: 1))
                    )
                    .help(path)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: 620, alignment: .trailing)
    }

    private static func displayName(for path: String) -> String {
        let file = path.split(separator: "/").last.map(String.init) ?? path
        if file.count <= 34 { return file }
        return String(file.prefix(15)) + "…" + String(file.suffix(14))
    }
}

/// One assistant reply, with a hover-revealed Copy + Regenerate bar.
/// The bar collapses to zero height when not hovering so a long chat stays
/// tight — it pops in under the message on hover (ChatGPT-style).
private struct AssistantMessageRow: View {
    let entry: ChatEntry
    let isStreaming: Bool
    let toolStatus: String?
    let sourceTrace: String?
    let placeholderLabel: String
    var alwaysShowActions: Bool = false
    let onCopy: () -> Void
    let onRegenerate: () -> Void

    @State private var hovering = false
    @State private var copied = false
    @State private var copiedSources = false
    @State private var showingSources = false

    var body: some View {
        Group {
            if isStreaming, entry.text.isEmpty {
                WorkingStatusView(text: placeholderLabel)
            } else if isStreaming, isProgressText(entry.text) {
                WorkingStatusView(text: entry.text)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    let display = entry.text + (isStreaming ? " ▍" : "")
                    RTIMarkdown(display, style: .overlay)
                        .fixedSize(horizontal: false, vertical: true)

                    // Tool status under the text while a tool runs mid-stream.
                    if isStreaming, let toolStatus, !toolStatus.isEmpty {
                        WorkingStatusView(text: toolStatus)
                    }

                    if !isStreaming, let sourceTrace, !sourceTrace.isEmpty {
                        sourceChip(trace: sourceTrace)
                    }

                    // Hover actions on a settled (non-streaming) reply. The bar
                    // always occupies its space (so hovering never reflows the
                    // chat — no jump); only its opacity changes on hover.
                    if !isStreaming, !entry.text.isEmpty {
                        actionBar
                            .opacity(hovering || alwaysShowActions ? 1 : 0)
                            .allowsHitTesting(hovering || alwaysShowActions)
                            // Buffer beneath the icons so moving the cursor down
                            // onto them doesn't slip past the hover region and
                            // make the bar vanish before you can click.
                            .padding(.bottom, 6)
                    }
                }
                .frame(maxWidth: 780, alignment: .leading)
            }
        }
        // Track hover over the whole row rectangle (incl. transparent gaps),
        // not just the opaque glyphs — otherwise the corner is a dead zone.
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .hoverHighlight($hovering)
    }

    private var actionBar: some View {
        HStack(spacing: 2) {
            iconButton(systemName: copied ? "checkmark" : "doc.on.doc",
                       help: "Copy")
            {
                onCopy()
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            }
            iconButton(systemName: "arrow.clockwise", help: "Regenerate", action: onRegenerate)
        }
    }

    private func sourceChip(trace: String) -> some View {
        let count = DisplaySource.sources(in: trace).count
        return Button {
            showingSources = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: copiedSources ? "checkmark" : "text.page")
                    .font(.system(size: 10, weight: .medium))
                Text(count == 0 ? "Sources" : "\(count) source\(count == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Color.overlayInk.opacity(0.56))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.overlayInk.opacity(0.045))
                    .overlay(Capsule().stroke(Color.overlayInk.opacity(0.075), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sources")
        .help("Show sources")
        .popover(isPresented: $showingSources, arrowEdge: .bottom) {
            SourceTracePopover(trace: trace) {
                NSPasteboard.copyString(trace)
                copiedSources = true
                showingSources = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedSources = false }
            }
        }
    }

    private func sourceButton(trace: String) -> some View {
        Button {
            showingSources = true
        } label: {
            Image(systemName: copiedSources ? "checkmark" : "text.page")
                .font(.system(size: 12))
                .foregroundStyle(Color.overlayInk.opacity(0.58))
                .frame(width: 30, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sources")
        .help("Show sources")
        .popover(isPresented: $showingSources, arrowEdge: .bottom) {
            SourceTracePopover(trace: trace) {
                NSPasteboard.copyString(trace)
                copiedSources = true
                showingSources = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedSources = false }
            }
        }
    }

    private func iconButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundStyle(Color.overlayInk.opacity(0.45))
                .frame(width: 30, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(help)
        .accessibilityHint("Double-click or press VO-Space to activate")
        .help(help)
    }

    private func isProgressText(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("searching ")
            || lower.hasPrefix("found ")
            || lower.hasPrefix("context ready")
            || lower.hasPrefix("vault search finished")
            || lower.hasPrefix("reading ")
    }
}

private struct WorkingStatusView: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.65)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.overlayInk.opacity(0.62))
                .lineLimit(2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.overlayInk.opacity(0.045))
        )
    }
}

private struct SourceTracePopover: View {
    let trace: String
    let onCopy: () -> Void

    private var sources: [DisplaySource] {
        DisplaySource.sources(in: trace)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "text.page")
                    .font(.system(size: 12, weight: .medium))
                Text(sources.isEmpty ? "Sources" : "\(sources.count) Source\(sources.count == 1 ? "" : "s")")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.plain)
                .help("Copy sources")
            }
            .foregroundStyle(Color.overlayInk.opacity(0.72))

            if sources.isEmpty {
                Text(displayTrace)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.overlayInk.opacity(0.62))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(sources) { source in
                        sourceRow(source)
                    }
                }

                if let timing = DisplaySource.timingLine(in: trace) {
                    Text(timing)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.overlayInk.opacity(0.42))
                }
            }
        }
        .padding(12)
        .frame(width: 390, alignment: .leading)
        .background(Color.white)
    }

    private func sourceRow(_ source: DisplaySource) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(source.kind)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.overlayInk.opacity(0.55))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.overlayInk.opacity(0.055)))
                Text(source.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.overlayInk.opacity(0.76))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(source.path)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.overlayInk.opacity(0.48))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.overlayInk.opacity(0.035))
        )
    }

    private var displayTrace: String {
        trace
            .split(separator: "\n")
            .filter { !$0.hasPrefix("Read document") && !$0.hasPrefix("Running Read document") }
            .joined(separator: "\n")
    }
}

private struct DisplaySource: Identifiable, Hashable {
    let path: String
    let kind: String
    let title: String

    var id: String { path }

    static func sources(in trace: String) -> [DisplaySource] {
        let pattern = #"([A-Za-z0-9_\-./ ]+\.md)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = trace as NSString
        var paths: [String] = []
        for match in regex.matches(in: trace, range: NSRange(location: 0, length: ns.length)) {
            let path = ns.substring(with: match.range(at: 1))
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,.;"))
            if !paths.contains(path) { paths.append(path) }
        }
        return paths.map { path in
            DisplaySource(path: path, kind: kind(for: path), title: title(for: path))
        }
    }

    static func timingLine(in trace: String) -> String? {
        trace
            .split(separator: "\n")
            .map(String.init)
            .first { $0.contains("·") && $0.lowercased().contains("ms") }
    }

    private static func kind(for path: String) -> String {
        let lower = path.lowercased()
        if lower.contains("discussion-guide") { return "Guide" }
        if lower.contains("transcript") || lower.contains("session") { return "Transcript" }
        if lower.contains("evidence") || lower.contains("deck") { return "Evidence" }
        if lower.hasSuffix("00-status.md") { return "Status" }
        if lower.contains("/chats/") { return "Chat" }
        if lower.contains("language-bank") { return "Language" }
        if lower.contains("meeting") { return "Meeting" }
        return "Doc"
    }

    private static func title(for path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        guard let file = parts.last else { return path }
        return file
            .replacingOccurrences(of: ".md", with: "")
            .replacingOccurrences(of: "-", with: " ")
    }
}
