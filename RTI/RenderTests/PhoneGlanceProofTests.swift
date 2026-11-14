import HouseDesign
import SwiftUI
import XCTest

/// DESIGN PROOF, not shipped: RTI Lite on a phone (2026-11-14).
///
/// The phone is not a small Mac. On the Mac you read and type at a desk; on
/// the phone you glance for two seconds, often under the table or at the back
/// of a viewing room, with one thumb. So this layout:
/// - leads with the one thing to do next (the question to ask), large, in
///   Mandarin with pinyin and English;
/// - keeps the guide position and at most two "go back to" questions as
///   quiet lines;
/// - shows only the last line said, as context;
/// - puts every action in the thumb zone at the bottom, 56 pt tall;
/// - has no navigation, no tabs, no settings: one screen.
/// Drawn at iPhone 16 size (393 x 852 pt) with iOS type sizes. The view lives
/// in the test target until an iPhone build and a way to reach it from the
/// Mac are agreed.
struct PhoneGlance: View {
    struct Content {
        var elapsed = "1:16:42"
        var context = "Research · G4"
        var askZH = "大家平时怎么清洗杯盖的密封圈？"
        var askPinyin = "dàjiā píngshí zěnme qīngxǐ bēigài de mìfēngquān?"
        var askEN = "Ask how they clean the lid seal."
        var askWhy = "Cleaning came up three times and was never probed."
        var nowID = "S3Q11"
        var nowEN = "How would you clean the cup?"
        var goBack = [("S2Q1", "How would you carry the cup?"), ("S2Q3", "Cup A or cup B?")]
        var lastSpeaker = "Them"
        var lastLine = "洗起来很麻烦，所以有时候就不带了。"
    }

    var content = Content()
    var answer: [String]? = nil

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 28) {
                statusPill
                hero
                nowAsking
                goBack
                lastLine
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 62)
            .padding(.bottom, 140)
            thumbBar
            if let answer { answerSheet(answer) }
        }
        .frame(width: 393, height: 852)
        .background(House.ColorToken.surface)
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle().fill(House.ColorToken.danger).frame(width: 8, height: 8)
            Text(content.elapsed).font(.system(size: 15, weight: .semibold).monospacedDigit())
            Text("·").foregroundStyle(House.ColorToken.textTertiary)
            Text(content.context).font(.system(size: 15))
                .foregroundStyle(House.ColorToken.textSecondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(House.ColorToken.chipFill, in: Capsule())
    }

    /// The question to ask: the reason to look at the phone at all.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ASK NEXT")
                .font(.system(size: 13, weight: .semibold)).tracking(0.8)
                .foregroundStyle(House.ColorToken.textTertiary)
            Text(content.askZH)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(House.ColorToken.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(content.askPinyin)
                .font(.system(size: 15))
                .foregroundStyle(House.ColorToken.textTertiary)
            Text(content.askEN)
                .font(.system(size: 19))
                .foregroundStyle(House.ColorToken.textSecondary)
            Text(content.askWhy)
                .font(.system(size: 13))
                .foregroundStyle(House.ColorToken.textTertiary)
                .padding(.top, 2)
        }
    }

    private var nowAsking: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("NOW ASKING", detail: content.nowID)
            Text(content.nowEN).font(.system(size: 17)).foregroundStyle(House.ColorToken.textPrimary)
        }
    }

    private var goBack: some View {
        VStack(alignment: .leading, spacing: 10) {
            label("GO BACK TO", detail: nil)
            ForEach(content.goBack, id: \.0) { id, text in
                HStack(spacing: 10) {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(House.ColorToken.textTertiary)
                    Text(text).font(.system(size: 17)).foregroundStyle(House.ColorToken.textPrimary)
                    Spacer(minLength: 0)
                    Text(id).font(.system(size: 13).monospacedDigit()).foregroundStyle(House.ColorToken.textTertiary)
                }
            }
        }
    }

    private var lastLine: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("JUST SAID", detail: content.lastSpeaker)
            Text(content.lastLine).font(.system(size: 17)).foregroundStyle(House.ColorToken.textSecondary)
                .lineLimit(2)
        }
    }

    private func label(_ text: String, detail: String?) -> some View {
        HStack(spacing: 8) {
            Text(text).font(.system(size: 13, weight: .semibold)).tracking(0.8)
                .foregroundStyle(House.ColorToken.textTertiary)
            if let detail {
                Text(detail).font(.system(size: 13).monospacedDigit()).foregroundStyle(House.ColorToken.textTertiary)
            }
        }
    }

    /// Everything you do is here, under the thumb.
    private var thumbBar: some View {
        HStack(spacing: 12) {
            roundButton("doc.on.doc", label: "Copy question")
            Text("Catch me up")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(House.ColorToken.textInverse)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(House.ColorToken.textPrimary, in: Capsule())
            roundButton("arrow.clockwise", label: "Another question")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 44)
    }

    private func roundButton(_ symbol: String, label: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(House.ColorToken.textPrimary)
            .frame(width: 56, height: 56)
            .background(House.ColorToken.chipFill, in: Circle())
            .accessibilityLabel(label)
    }

    /// "Catch me up" answers in a sheet that covers the lower part only, so
    /// the next question stays visible above it.
    private func answerSheet(_ bullets: [String]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Capsule().fill(House.ColorToken.strokeStrong).frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
            Text("Last 5 minutes").font(.system(size: 13, weight: .semibold)).tracking(0.8)
                .foregroundStyle(House.ColorToken.textTertiary)
            ForEach(bullets, id: \.self) { bullet in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("•").font(.system(size: 17)).foregroundStyle(House.ColorToken.textTertiary)
                    Text(bullet).font(.system(size: 17)).foregroundStyle(House.ColorToken.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 52)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(House.ColorToken.surfaceRaised,
                    in: UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28))
        .shadow(color: .black.opacity(0.18), radius: 30, y: -4)
    }
}

final class PhoneGlanceProofTests: RenderProofTestCase {
    func testPhoneGlanceDuringAResearchCall() throws {
        try renderBothAppearances(name: "lite-phone-glance", size: CGSize(width: 393, height: 852), view: PhoneGlance())
    }

    func testPhoneCatchMeUpSheet() throws {
        try renderBothAppearances(
            name: "lite-phone-catch-up", size: CGSize(width: 393, height: 852),
            view: PhoneGlance(answer: [
                "Cleaning, not carrying, is now the barrier: the lid seal smells.",
                "Two people hand-wash because they think the dishwasher scratches.",
                "Nobody has said what would make them buy a second cup.",
            ])
        )
    }
}
