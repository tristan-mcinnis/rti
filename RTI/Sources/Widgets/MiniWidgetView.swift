import SwiftUI

struct MiniWidgetView: View {
    let onExpand: () -> Void

    var body: some View {
        Button(action: onExpand) {
            Image(systemName: "location.north")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(Color.black.opacity(0.6))
                        .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
        .padding(4)
    }
}
