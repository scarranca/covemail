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
        Text("Checks up to \(store.agentsUseModel ? 50 : CustomAgentBackfill.limit) inbox emails from the last \(CustomAgentBackfill.days) days, one at a time. Nothing changes until you apply.")
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
        Text(store.agentsUseModel ? "Uses your writing model for each email checked (\(store.agentModelName))."
                                  : "Uses TypeSafe for each email checked. Charges apply. Connect a writing model in Connections for smarter checks.")
          .font(.coveMetadata).foregroundStyle(Palette.muted)
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
    if preview.failed > 0, let error = preview.firstError {
      Text("\(preview.failed) couldn’t be checked: \(error)").font(.coveSecondary).foregroundStyle(Palette.danger)
        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
    let count = preview.matches.count
    if count > 0 || !preview.unclear.isEmpty {
      HStack(spacing: 12) {
        Button(count > 0 ? "Apply to \(count) \(count == 1 ? "email" : "emails")" : "Send \(preview.unclear.count) to Activity") {
          store.applyAgentBackfill()
        }.buttonStyle(PrimaryButton(compact: true))
        Button("Discard") { store.cancelAgentBackfill() }.buttonStyle(.plain).font(.coveControl).foregroundStyle(Palette.body)
      }
      if preview.replyCount > 0 || !preview.unclear.isEmpty {
        Text("Unclear emails go to Activity for a Yes or No. Replies are prepared for review, never sent.")
          .font(.coveMetadata).foregroundStyle(Palette.muted)
      }
    } else {
      Button("Discard") { store.cancelAgentBackfill() }.buttonStyle(.plain).font(.coveControl).foregroundStyle(Palette.body)
    }
    // Every checked email, with what the agent would do and why.
    group("Would act on", preview.matches) { detail(for: $0, preview: preview) }
    group("Unclear", preview.unclear) { _ in "Needs your call" }
    group("Not a match", preview.noMatches, limit: showAllNoMatch ? .max : 5) { _ in "No change" }
    if preview.noMatches.count > 5 && !showAllNoMatch {
      Button("Show all \(preview.noMatches.count)") { showAllNoMatch = true }.buttonStyle(.plain).font(.coveControl).foregroundStyle(Palette.body)
    }
  }
  @State private var showAllNoMatch = false
  @ViewBuilder private func group(_ title: String, _ items: [CustomAgentBackfillItem], limit: Int = .max,
                                  outcome: @escaping (CustomAgentBackfillItem) -> String) -> some View {
    if !items.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        Text("\(title) · \(items.count)").font(.coveControl).foregroundStyle(Palette.body).padding(.bottom, 6)
        VStack(spacing: 0) {
          ForEach(items.prefix(limit)) { item in
            row(item, outcome: outcome(item))
            Divider()
          }
        }
        .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line))
      }
    }
  }
  private func detail(for item: CustomAgentBackfillItem, preview: CustomAgentBackfillPreview) -> String {
    let rule = item.decision.rule(for: preview.agent)
    var parts: [String] = []
    if let label = item.decision.label(for: preview.agent) { parts.append("Label " + label) }
    if rule?.action.drafts == true { parts.append("draft a reply") }
    for extra in rule?.extras ?? [] { parts.append(extra.title.lowercased()) }
    return parts.isEmpty ? "Match" : parts.joined(separator: ", ")
  }
  private func row(_ item: CustomAgentBackfillItem, outcome: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .firstTextBaseline) {
        Text(item.sender).font(.coveLabel).foregroundStyle(Palette.ink).lineLimit(1)
        Spacer(minLength: 8)
        Text(outcome).font(.coveCaption).foregroundStyle(Palette.body).lineLimit(1)
      }
      Text(item.subject.isEmpty ? "(No subject)" : item.subject).font(.coveSecondary).foregroundStyle(Palette.ink).lineLimit(1)
      if let why = item.decision.reason ?? item.decision.excerpt {
        Text(why).font(.coveMetadata).foregroundStyle(Palette.body).lineLimit(2)
      }
    }
    .padding(.horizontal, 12).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
  }
  private func more(_ count: Int) -> some View {
    Text("and \(count) more").font(.coveMetadata).foregroundStyle(Palette.body).padding(.vertical, 6)
  }
}
