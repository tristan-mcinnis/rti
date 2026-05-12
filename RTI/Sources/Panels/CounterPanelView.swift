import SwiftUI

/// Live keyword/regex counter against the current session's transcript.
/// Per-session by design: the count resets when a new session starts.
/// The sparkline buckets matches into 1-minute slots over the last 30
/// minutes so a long meeting doesn't unboundedly grow the chart.
struct CounterPanelView: View {
    let panel: UserPanel

    @ObservedObject private var session = SessionCoordinator.shared
    @AppStorage(notesOpacityKey) private var backgroundOpacity: Double = notesDefaultOpacity

    private var spec: CounterConfig? { panel.config.counter }

    /// Total matches across every finalised transcript entry for the
    /// current session. Computed live off `session.liveEntries` — Swift
    /// recomputes on Published change, but the volume (hundreds of turns
    /// in a long meeting) is trivial.
    private var totalCount: Int {
        guard let spec else { return 0 }
        return session.liveEntries.reduce(0) { acc, entry in
            acc + (spec.match.matches(entry.text) ? 1 : 0)
        }
    }

    /// 30 buckets × 60-second windows ending at "now-relative-to-session".
    /// Each value is the count of transcript turns matching the spec
    /// whose `startMs` falls in that bucket.
    private var sparkline: [Int] {
        guard let spec, !session.liveEntries.isEmpty else { return [] }
        let bucketMs = 60_000
        let bucketCount = 30
        let maxMs = session.liveEntries.last?.startMs ?? 0
        let windowStart = max(0, maxMs - bucketMs * bucketCount)
        var buckets = Array(repeating: 0, count: bucketCount)
        for entry in session.liveEntries where entry.startMs >= windowStart {
            guard spec.match.matches(entry.text) else { continue }
            let offset = (entry.startMs - windowStart) / bucketMs
            let idx = min(max(offset, 0), bucketCount - 1)
            buckets[idx] += 1
        }
        return buckets
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(white: 0.14).opacity(backgroundOpacity))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(spec?.label ?? "Counter")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        UserPanelStore.shared.remove(id: panel.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.white.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                    .help("Remove panel")
                }

                DotMatrixText(text: "\(totalCount)",
                              dot: 3.2,
                              spacing: 1.0,
                              gap: 3.0,
                              color: .white,
                              dim: Color.white.opacity(0.06))
                    .animation(.easeOut(duration: 0.2), value: totalCount)

                Sparkline(values: sparkline)
                    .frame(height: 26)
                    .opacity(sparkline.contains(where: { $0 > 0 }) ? 1.0 : 0.4)

                Text(matchDescription)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            .padding(12)
        }
    }

    private var matchDescription: String {
        guard let spec else { return "—" }
        switch spec.match {
        case .keyword(let v, let ci):
            return "matches \"\(v)\"\(ci ? " (case-insensitive)" : "")"
        case .regex(let p):
            return "regex \(p)"
        }
    }
}

/// Minimal sparkline — bars proportional to the max value in the window.
/// Falls back to a single baseline when every value is zero so the row
/// doesn't visually disappear before the first match.
private struct Sparkline: View {
    let values: [Int]

    var body: some View {
        GeometryReader { geo in
            let maxValue = max(values.max() ?? 0, 1)
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(values.indices, id: \.self) { i in
                    let v = values[i]
                    Rectangle()
                        .fill(barColor(v))
                        .frame(width: max(1, (geo.size.width / CGFloat(values.count)) - 1),
                               height: max(2, geo.size.height * CGFloat(v) / CGFloat(maxValue)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

    private func barColor(_ v: Int) -> Color {
        if v == 0 { return Color.white.opacity(0.10) }
        return Color(red: 0.4, green: 0.85, blue: 1.0).opacity(0.85)
    }
}
