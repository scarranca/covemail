import CoveCore
import SwiftUI

struct AgentBackfillState: Equatable {
  enum Phase: Equatable { case checking, ready, applying, done, failed }
  var runID: UUID
  var agentID: String
  var phase: Phase
  var done = 0
  var total = 0
  var preview: CustomAgentBackfillPreview
  var result: CustomAgentBackfillResult?
  var message: String?
}

/// "Recent mail" in the editor's Try it panel: check, review the summary, then one Apply action.
struct CustomAgentBackfillPanel: View {
  @Bindable var store: AppStore
  let agent: CustomAgent
  private var state: AgentBackfillState? { store.agentBackfill.flatMap { $0.agentID == agent.id ? $0 : nil } }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      switch state?.phase {
      case nil:
        Text("Checks up to \(CustomAgentBackfill.limit) inbox emails from the last \(CustomAgentBackfill.days) days. Nothing changes until you apply.")
          .font(.coveSecondary).foregroundStyle(Palette.body).lineSpacing(3)
        Button("Check recent mail") { store.previewAgentBackfill(agent) }.buttonStyle(SecondaryButton())
      case .checking?:
        progress("Checking \(state!.done) of \(state!.total)…")
      case .applying?:
        progress("Applying \(state!.done) of \(state!.total)…")
      case .failed?:
        Text(state?.message ?? "Couldn’t check recent mail.").font(.coveSecondary).foregroundStyle(Palette.danger).textSelection(.enabled)
        Button("Try again") { store.previewAgentBackfill(agent) }.buttonStyle(SecondaryButton())
      case .ready?:
        summary(state!.preview)
      case .done?:
        if let result = state?.result {
          Label(result.summary, systemImage: result.failed == 0 && result.stopped == nil ? "checkmark.circle" : "exclamationmark.circle")
            .font(.coveControl)
          if let stopped = result.stopped { Text("Stopped: " + stopped).font(.coveSecondary).foregroundStyle(Palette.danger) }
          Button("View activity") { store.agentEditor = nil; store.agentActivityID = agent.id }
            .buttonStyle(.plain).font(.coveControl).foregroundStyle(Palette.body)
        }
      }
      if state == nil || state?.phase == .ready || state?.phase == .failed {
        Text("Uses TypeSafe for each email checked. Charges apply.").font(.coveMetadata).foregroundStyle(Palette.muted)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private func progress(_ title: String) -> some View {
    HStack(spacing: 10) {
      ProgressView().controlSize(.small)
      Text(title).font(.coveSecondary)
      Spacer()
      Button("Cancel") { store.cancelAgentBackfill() }.buttonStyle(.plain).font(.coveControl)
    }
  }
  @ViewBuilder private func summary(_ preview: CustomAgentBackfillPreview) -> some View {
    Text(preview.summary).font(.coveSubheading).accessibilityIdentifier("backfill-summary")
    if !preview.matches.isEmpty || !preview.unclear.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(preview.matches.prefix(8)) { row($0, detail: detail(for: $0, preview: preview)) }
        if preview.matches.count > 8 { more(preview.matches.count - 8) }
        ForEach(preview.unclear.prefix(4)) { row($0, detail: "Unclear → Activity") }
        if preview.unclear.count > 4 { more(preview.unclear.count - 4) }
      }.padding(.horizontal, 12).padding(.vertical, 4)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
    }
    let count = preview.matches.count
    if count > 0 || !preview.unclear.isEmpty {
      Button(count > 0 ? "Apply to \(count) \(count == 1 ? "email" : "emails")" : "Send \(preview.unclear.count) to Activity") {
        store.applyAgentBackfill()
      }.buttonStyle(PrimaryButton())
      if preview.replyCount > 0 {
        Text("Replies are prepared for review in Activity, never sent.").font(.coveMetadata).foregroundStyle(Palette.muted)
      }
    }
    Button("Discard") { store.cancelAgentBackfill() }.buttonStyle(.plain).font(.coveControl).foregroundStyle(Palette.body)
  }
  private func detail(for item: CustomAgentBackfillItem, preview: CustomAgentBackfillPreview) -> String {
    item.decision.label(for: preview.agent) ?? "Reply for review"
  }
  private func row(_ item: CustomAgentBackfillItem, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(item.sender + " · " + (item.subject.isEmpty ? "(No subject)" : item.subject))
        .font(.coveSecondary).foregroundStyle(Palette.ink).lineLimit(1)
      Text(detail).font(.coveMetadata).foregroundStyle(Palette.body).lineLimit(1)
    }.padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
  }
  private func more(_ count: Int) -> some View {
    Text("and \(count) more").font(.coveMetadata).foregroundStyle(Palette.body).padding(.vertical, 6)
  }
}
