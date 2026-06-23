import RTICore
import SwiftUI

// MARK: - Record control

/// Inline record control in the overlay header. Now phase-aware: instead of a
/// binary record/stop, it names every step of the lifecycle so the user always
/// knows what the app is doing — recording, paused, saving, generating the
/// summary, or done (Granola-style). Click is the forward action for the
/// current phase (start / finish / start-new); pause/resume and "open summary"
/// live in the small aux button beside it (`OverlaySessionAuxButton`).
struct OverlayRecordButton: View {
    private let coordinator = SessionCoordinator.shared

    @State private var hovering = false

    /// No Combine timer here: a per-instance Timer.publish subscription was the
    /// crash site of a SIGSEGV (stale SubscriptionView firing during view
    /// teardown, 2026-06-10 crash report). The elapsed label uses TimelineView
    /// instead — SwiftUI owns the clock and its lifecycle.
    var body: some View {
        Button(action: primaryAction) {
            HStack(spacing: 6) {
                glyph
                label
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(background)
            .overlay(Capsule(style: .continuous).stroke(borderColor, lineWidth: 1))
            .clipShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(coordinator.phase == .finishing)
        .hoverHighlight($hovering)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(helpText)
        .help(helpText)
    }

    private var accessibilityLabel: String {
        switch coordinator.phase {
        case .idle: "Start recording"
        case .recording: "Finish and summarize recording"
        case .paused: "Finish and summarize paused recording"
        case .finishing: "Saving session"
        case .summarizing: "Generating summary"
        case .done: "Start a new recording"
        }
    }

    private func primaryAction() {
        // toggleSession knows the phase: start from idle/done/summarizing,
        // finish from recording/paused, no-op while finishing.
        coordinator.toggleSession()
    }

    @ViewBuilder
    private var glyph: some View {
        switch coordinator.phase {
        case .recording:
            PulsingRecordDot()
        case .paused:
            Image(systemName: "pause.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.orange)
        case .finishing, .summarizing:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.62)
                .frame(width: 9, height: 9)
        case .done:
            Image(systemName: coordinator.summaryURL != nil ? "checkmark.circle.fill" : "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(coordinator.summaryURL != nil ? Color.green.opacity(0.9) : Color.overlayInk.opacity(0.55))
        case .idle:
            Circle()
                .fill(Color(red: 1.0, green: 0.27, blue: 0.27).opacity(0.85))
                .frame(width: 7, height: 7)
        }
    }

    @ViewBuilder
    private var label: some View {
        switch coordinator.phase {
        case .recording, .paused:
            // Live elapsed (captured time — paused spans excluded). Monospaced
            // digits so it doesn't jitter.
            // Just the timer — the amber pause glyph + colour (and the resume
            // button beside) already say "paused", so we don't spend header
            // width on the word and squeeze the tab bar.
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                Text(TimeFormat.elapsed(coordinator.elapsed(at: context.date)))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(coordinator.phase == .paused ? Color.orange.opacity(0.95) : Color.overlayInk.opacity(0.85))
                    .kerning(0.2)
                    .fixedSize()
            }
        case .finishing:
            labelText("Saving…", opacity: 0.6)
        case .summarizing:
            labelText("Summarizing…", opacity: 0.7)
        case .done:
            labelText(coordinator.summaryURL != nil ? "Notes ready" : "Done", opacity: 0.6)
        case .idle:
            labelText("Record", opacity: 0.75)
        }
    }

    private func labelText(_ text: String, opacity: Double) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.overlayInk.opacity(opacity))
            .kerning(0.2)
            .fixedSize()
    }

    private var background: some View {
        ZStack {
            Capsule(style: .continuous).fill(Color.overlayInk.opacity(hovering ? 0.14 : 0.08))
            switch coordinator.phase {
            case .recording:
                Capsule(style: .continuous).fill(Color(red: 1.0, green: 0.20, blue: 0.20).opacity(0.18))
            case .paused:
                Capsule(style: .continuous).fill(Color.orange.opacity(0.14))
            default:
                EmptyView()
            }
        }
    }

    private var borderColor: Color {
        switch coordinator.phase {
        case .recording: Color(red: 1.0, green: 0.30, blue: 0.30).opacity(0.45)
        case .paused: Color.orange.opacity(0.5)
        default: Color.overlayInk.opacity(hovering ? 0.22 : 0.12)
        }
    }

    private var helpText: String {
        switch coordinator.phase {
        case .idle: "Start recording (⌘⇧R)"
        case .recording: "Finish & summarize (⌘⇧R)"
        case .paused: "Finish & summarize (⌘⇧R) — currently paused"
        case .finishing: "Saving the session…"
        case .summarizing: "Generating the summary in the background — click to start a new recording"
        case .done: coordinator.summaryURL != nil
            ? "Session saved, notes ready. Click to start a new recording (⌘⇧R)"
            : "Session saved. Click to start a new recording (⌘⇧R)"
        }
    }
}

/// Small companion button beside the record control. Pause/resume while a
/// session is live; "open summary" once notes are ready. Only shown when it has
/// something to do, so the header stays uncluttered when idle.
struct OverlaySessionAuxButton: View {
    private let coordinator = SessionCoordinator.shared
    @State private var hovering = false

    private enum Kind { case pause, resume, openSummary, none }

    private var kind: Kind {
        switch coordinator.phase {
        case .recording: .pause
        case .paused: .resume
        case .summarizing, .done: coordinator.summaryURL != nil ? .openSummary : .none
        default: .none
        }
    }

    var body: some View {
        if kind != .none {
            Button(action: act) {
                HStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .bold))
                    if let labelText {
                        Text(labelText)
                            .font(.system(size: 11, weight: .medium))
                            .kerning(0.2)
                            .fixedSize()
                    }
                }
                .foregroundStyle(tint)
                .frame(height: 26)
                .padding(.horizontal, labelText == nil ? 0 : 9)
                .frame(minWidth: 26)
                .background(Capsule(style: .continuous).fill(Color.overlayInk.opacity(hovering ? 0.14 : 0.08)))
                .overlay(Capsule(style: .continuous).stroke(Color.overlayInk.opacity(0.14), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .hoverHighlight($hovering)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(help)
            .help(help)
        }
    }

    private var accessibilityLabel: String {
        switch kind {
        case .pause: "Pause recording"
        case .resume: "Resume recording"
        case .openSummary: "Open meeting summary"
        case .none: ""
        }
    }

    private var icon: String {
        switch kind {
        case .pause: "pause.fill"
        case .resume: "play.fill"
        case .openSummary: "doc.text"
        case .none: ""
        }
    }

    private var tint: Color {
        switch kind {
        case .resume: Color.green.opacity(0.9)
        case .openSummary: Color.green.opacity(0.9)
        default: Color.overlayInk.opacity(0.7)
        }
    }

    /// Resume is the one aux action worth spelling out: pausing is reversible
    /// and low-stakes, but a paused session reads as "stuck" until you spot the
    /// tiny resume glyph. Labelling it (and the ⌘⇧P hint below) makes getting
    /// going again obvious. Pause/openSummary stay compact icons.
    private var labelText: String? {
        kind == .resume ? "Resume" : nil
    }

    private var help: String {
        switch kind {
        case .pause: "Pause (⌘⇧P) — stops transcribing, keeps the connection live so resume is instant"
        case .resume: "Resume recording (⌘⇧P)"
        case .openSummary: "Open the meeting summary"
        case .none: ""
        }
    }

    private func act() {
        switch kind {
        case .pause, .resume: coordinator.togglePause()
        case .openSummary:
            if let url = coordinator.summaryURL { NSWorkspace.shared.open(url) }
        case .none: break
        }
    }
}

/// Pulsing red indicator for the live record control. Owns its animation so it
/// restarts cleanly each time recording begins (onAppear → repeatForever).
private struct PulsingRecordDot: View {
    @State private var on = false

    var body: some View {
        Circle()
            .fill(Color(red: 1.0, green: 0.27, blue: 0.27))
            .frame(width: 7, height: 7)
            .shadow(color: Color(red: 1.0, green: 0.27, blue: 0.27).opacity(on ? 0.85 : 0.20), radius: on ? 4 : 1)
            .scaleEffect(on ? 1.0 : 0.65)
            .opacity(on ? 1.0 : 0.55)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) { on = true }
            }
    }
}
