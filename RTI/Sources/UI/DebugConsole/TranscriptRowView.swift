import SwiftUI

struct TranscriptRowView: View {
    let speakerId: String?
    let text: String
    let isFinal: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let speakerId = speakerId {
                Text(speakerId)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(speakerColor(speakerId))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(speakerColor(speakerId).opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            } else {
                Text("…")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .font(.system(size: 13))
                .italic(!isFinal)
                .foregroundStyle(isFinal ? Color.primary : Color.secondary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func speakerColor(_ id: String) -> Color {
        if id == "self" { return .blue }
        let palette: [Color] = [.orange, .green, .purple, .pink]
        if id.hasPrefix("them_"), let n = Int(id.dropFirst("them_".count)), n > 0 {
            return palette[(n - 1) % palette.count]
        }
        return .gray
    }
}
