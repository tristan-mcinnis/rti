import SwiftUI

// MARK: - Welcome — radiating mic with drifting chat bubbles

struct WelcomeArtwork: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let center = CGPoint(x: size.width * 0.32, y: size.height * 0.5)

                // Three radiating arcs. Each arc has its own phase so they
                // emanate continuously rather than pulsing in lockstep.
                for i in 0..<3 {
                    let phase = (t * 0.45 + Double(i) * 0.33).truncatingRemainder(dividingBy: 1.0)
                    let radius = 18 + phase * 70
                    let opacity = (1.0 - phase) * 0.55
                    let rect = CGRect(
                        x: center.x - radius,
                        y: center.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                    let path = Path { p in
                        p.addArc(
                            center: center,
                            radius: radius,
                            startAngle: .degrees(-30),
                            endAngle: .degrees(30),
                            clockwise: false
                        )
                    }
                    _ = rect
                    ctx.stroke(
                        path,
                        with: .color(Color.accentColor.opacity(opacity)),
                        lineWidth: 2.0
                    )
                }

                // Mic glyph — a rounded capsule on a stem.
                let micWidth: CGFloat = 22
                let micHeight: CGFloat = 32
                let micRect = CGRect(
                    x: center.x - micWidth / 2,
                    y: center.y - micHeight / 2 - 4,
                    width: micWidth,
                    height: micHeight
                )
                let mic = Path(roundedRect: micRect, cornerRadius: micWidth / 2)
                ctx.fill(mic, with: .color(Color.accentColor))

                // Stem + base
                var stem = Path()
                stem.move(to: CGPoint(x: center.x, y: center.y + micHeight / 2 - 2))
                stem.addLine(to: CGPoint(x: center.x, y: center.y + micHeight / 2 + 8))
                stem.move(to: CGPoint(x: center.x - 8, y: center.y + micHeight / 2 + 8))
                stem.addLine(to: CGPoint(x: center.x + 8, y: center.y + micHeight / 2 + 8))
                ctx.stroke(stem, with: .color(Color.accentColor), lineWidth: 2)

                // Drifting chat bubbles — three of them on the right, each
                // rising and fading at a different cadence.
                for i in 0..<3 {
                    let phase = (t * 0.18 + Double(i) * 0.33).truncatingRemainder(dividingBy: 1.0)
                    let xBase = size.width * 0.62 + CGFloat(i) * 22
                    let yBase = size.height * 0.85 - CGFloat(phase) * size.height * 0.7
                    let opacity = sin(phase * .pi) * 0.85
                    let bubbleW: CGFloat = 36 - CGFloat(i) * 4
                    let bubbleH: CGFloat = 18
                    let r = CGRect(x: xBase, y: yBase, width: bubbleW, height: bubbleH)
                    let bubble = Path(roundedRect: r, cornerRadius: bubbleH / 2)
                    ctx.fill(bubble, with: .color(Color.accentColor.opacity(opacity * 0.35)))
                    ctx.stroke(bubble, with: .color(Color.accentColor.opacity(opacity * 0.7)), lineWidth: 1)
                }
            }
        }
        .frame(height: 150)
    }
}

// MARK: - Permissions — mic + display side by side

struct PermissionsArtwork: View {
    let micGranted: Bool
    let screenGranted: Bool

    var body: some View {
        HStack(spacing: 36) {
            permissionGlyph(systemImage: "mic.fill", granted: micGranted, accent: .accentColor)
            permissionGlyph(systemImage: "rectangle.dashed.badge.record", granted: screenGranted, accent: .accentColor)
        }
        .frame(height: 110)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func permissionGlyph(systemImage: String, granted: Bool, accent: Color) -> some View {
        ZStack {
            // Halo
            Circle()
                .fill(accent.opacity(granted ? 0.15 : 0.08))
                .frame(width: 84, height: 84)
                .scaleEffect(granted ? 1.0 : 0.92)
                .animation(.spring(response: 0.5, dampingFraction: 0.7), value: granted)

            // Pulse ring while not granted
            if !granted {
                PulseRing(color: accent.opacity(0.5))
                    .frame(width: 84, height: 84)
            }

            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(granted ? accent : .secondary)

            // Check overlay
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.green)
                    .background(Circle().fill(.background).padding(2))
                    .offset(x: 28, y: -28)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 100, height: 100)
    }
}

private struct PulseRing: View {
    let color: Color
    @State private var animate = false

    var body: some View {
        Circle()
            .stroke(color, lineWidth: 2)
            .scaleEffect(animate ? 1.35 : 0.9)
            .opacity(animate ? 0 : 0.9)
            .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: animate)
            .onAppear { animate = true }
    }
}

// MARK: - Keys — two vault tokens that fill in as you type

struct KeysArtwork: View {
    let sonioxFilled: Bool
    let llmFilled: Bool

    var body: some View {
        HStack(spacing: 18) {
            keyCard(label: "Soniox", subtitle: "transcription", filled: sonioxFilled)
            keyCard(label: "LLM", subtitle: "answers", filled: llmFilled)
        }
        .frame(height: 110)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func keyCard(label: String, subtitle: String, filled: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: filled
                            ? [Color.accentColor.opacity(0.85), Color.accentColor.opacity(0.55)]
                            : [Color.secondary.opacity(0.10), Color.secondary.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(filled ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.25), lineWidth: 1)
                )
                .animation(.easeInOut(duration: 0.35), value: filled)

            VStack(spacing: 2) {
                Image(systemName: filled ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(filled ? Color.white : .secondary)
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: filled)
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(filled ? .white : .primary)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(filled ? Color.white.opacity(0.85) : .secondary)
            }
        }
        .frame(width: 130, height: 90)
    }
}

// MARK: - Tour — hotkey carousel

/// Cycles through the five primary hotkeys. Each is rendered as oversized
/// key-cap pills with a one-line caption. Crossfades on a 1.8 s cadence.
struct HotkeyCarousel: View {
    private struct HotkeyEntry {
        let keys: [String]
        let label: String
    }

    private let entries: [HotkeyEntry] = [
        .init(keys: ["⌘", "\\"], label: "Show / hide the assistant overlay"),
        .init(keys: ["⌘", "⇧", "R"], label: "Start / stop a recording session"),
        .init(keys: ["⌘", "↵"], label: "Assist — answer based on what's been said"),
        .init(keys: ["⌘", "⇧", "H"], label: "Capture screen + OCR for the next prompt"),
        .init(keys: ["⌘", "⌥", "T"], label: "Show / hide the live transcript window")
    ]

    @State private var index = 0

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(entries[index].keys, id: \.self) { key in
                    KeyCap(text: key)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .id(index) // force re-mount so .transition fires
            .animation(.spring(response: 0.45, dampingFraction: 0.75), value: index)

            Text(entries[index].label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .id("label-\(index)")
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.35), value: index)

            // Position dots
            HStack(spacing: 6) {
                ForEach(0..<entries.count, id: \.self) { i in
                    Circle()
                        .fill(i == index ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.top, 4)
        }
        .frame(height: 110)
        .frame(maxWidth: .infinity)
        .task {
            // .task is auto-cancelled when this view leaves the hierarchy,
            // so the carousel doesn't tick forever after onboarding closes.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                if Task.isCancelled { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
                    index = (index + 1) % entries.count
                }
            }
        }
    }
}

private struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 22, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .frame(minWidth: 44, minHeight: 44)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
            )
    }
}
