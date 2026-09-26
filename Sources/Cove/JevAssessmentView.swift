import CoveCore
import SwiftUI

struct JevAssessmentView: View {
  let decision: Decision
  let isSample: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(isSample ? "Sample assessment" : "Jev’s assessment")
        .font(.coveCaption).foregroundStyle(Palette.muted)
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 28) {
          action
          urgency
        }
        VStack(alignment: .leading, spacing: 14) {
          action
          urgency
        }
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
      .padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
  }

  private var action: some View {
    assessment(
      decision.needsReply >= 0.65
        ? "Reply or action likely"
        : decision.needsReply >= 0.35 ? "Review for next steps" : "Likely informational",
      icon: "arrowshape.turn.up.left",
      detail: "\(Int(decision.needsReply * 100))% likelihood of needing action")
  }

  private var urgency: some View {
    assessment(
      decision.urgent >= 0.65
        ? "Time-sensitive"
        : decision.urgent >= 0.35 ? "Timing unclear" : "Low urgency",
      icon: "clock",
      detail: "\(Int(decision.urgent * 100))% likelihood of action within 24h")
  }

  private func assessment(_ title: String, icon: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: icon).font(.coveControl)
        .foregroundStyle(Palette.ink)
      Text(detail).font(.coveMetadata).foregroundStyle(Palette.muted)
    }.fixedSize(horizontal: true, vertical: false)
  }
}
