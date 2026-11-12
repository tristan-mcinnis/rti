import HouseDesign
import RTICore
import SwiftUI

/// The same one-choice role menu in the live transcript and archived editor.
struct GuideSpeakerMenu: View {
    let roster: [GuideSeat]
    let assignment: GuideSpeakerAssignment
    let select: (GuideSpeakerAssignment) -> Void

    var body: some View {
        Menu {
            option("Unassigned", value: GuideSpeakerAssignment())
            option("Moderator", value: GuideSpeakerAssignment(isModerator: true))
            if !roster.isEmpty {
                Divider()
                ForEach(roster, id: \.seat) { seat in
                    option("\(seat.code) · \(seat.label)", value: GuideSpeakerAssignment(seat: seat))
                }
            }
        } label: {
            Text("Guide role · \(title)")
        }
        .accessibilityLabel("Guide role")
        .accessibilityValue(title)
        .controlSize(.small)
    }

    private var title: String {
        if assignment.isModerator {
            return "Moderator"
        }
        if let seat = assignment.seat {
            return "\(seat.code) · \(seat.label)"
        }
        return "Unassigned"
    }

    private func option(_ title: String, value: GuideSpeakerAssignment) -> some View {
        Button { select(value) } label: {
            if assignment == value {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}
