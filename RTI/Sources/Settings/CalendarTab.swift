import SwiftUI

// MARK: - Calendar

struct CalendarTab: View {
    private let calendar = CalendarManager.shared
    @State private var requestInProgress = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Calendar")
                .font(.system(size: 16, weight: .semibold))

            if calendar.isAuthorized {
                Label("Calendar access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
                Text("When you start a session, RTI looks at events happening right now in your default calendar. If it finds one, the event title becomes the session title and the attendees are attached for context. Nothing else is read or written — RTI never modifies your calendar.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Calendar access not granted", systemImage: "xmark.circle.fill")
                    .foregroundStyle(Color.orange)
                Text("Without access, sessions are titled by date/time only. Granting access lets RTI auto-name sessions from the calendar event in progress when you start recording. Read-only — RTI never modifies your calendar.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: requestAccess) {
                    if requestInProgress {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Text("Grant Calendar Access")
                    }
                }
                .disabled(requestInProgress)
            }

            Spacer()
        }
    }

    private func requestAccess() {
        requestInProgress = true
        Task {
            _ = await calendar.requestAccess()
            await MainActor.run {
                requestInProgress = false
            }
        }
    }
}

