import CoveCore
import SwiftUI

/// An agent's Activity, built like Mail: the checked emails as Mail rows on the left, and on the right
/// what the agent decided and why, with Yes / No / Undo, above the email itself. Every answer becomes
/// an example the agent learns from (`confirmAgentRun`, `rejectAgentRun`).
struct CustomAgentActivity: View {
  @Bindable var store: AppStore
  let agent: CustomAgent
  @State private var tab: Tab = .needsYou
  @State private var selectedRun: String?
  @State private var working: String?

  enum Tab: Hashable { case needsYou, matched, all }

  private var allRuns: [CustomAgentRun] {
    store.customAgents.runs.filter { $0.agentID == agent.id }.sorted { $0.date > $1.date }
  }
  private func needsYou(_ run: CustomAgentRun) -> Bool {
    run.feedback == nil && (run.decision?.outcome == .review || run.error != nil
      || (run.replySuggestion != nil && run.replyApplied != true))
  }
  private var runs: [CustomAgentRun] {
    switch tab {
    case .needsYou: allRuns.filter(needsYou)
    case .matched: allRuns.filter { $0.decision?.outcome == .match }
    case .all: allRuns
    }
  }
  private var selected: CustomAgentRun? { allRuns.first { $0.id == selectedRun } ?? runs.first }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header.padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 16)
      Divider()
      HStack(spacing: 0) {
        list.frame(width: 400).background(Palette.surface)
        Divider()
        detail.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .background(Palette.canvas)
    .onAppear { if allRuns.filter(needsYou).isEmpty { tab = .all } }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 14) {
      Button { store.agentActivityID = nil } label: { Label("All agents", systemImage: "chevron.left") }
        .buttonStyle(.plain).font(.coveControl).accessibilityLabel("Back to all agents")
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 6) {
          Text(agent.name).font(.coveTitle)
          Text("\(agent.status.title) · thinks with \(store.agentsUseModel ? store.agentModelName : "Jev (connect a writing model for smarter checks)") · learned from \(agent.examples?.count ?? 0) of your answers")
            .font(.coveSecondary).foregroundStyle(Palette.body)
        }
        Spacer()
        Button("Check again") { Task { await store.runCustomAgents(ignoreCooldown: true, agentID: agent.id) } }
          .buttonStyle(SecondaryButton(compact: true)).disabled(store.busy || agent.status != .active)
        Button("Edit agent") { store.agentEditor = agent; store.agentActivityID = nil }.buttonStyle(SecondaryButton(compact: true))
      }
      if let failure = store.agentFailure { Text(failure).foregroundStyle(Palette.danger).font(.coveSecondary) }
      HStack(spacing: 18) {
        tabButton(.needsYou, "Needs you", allRuns.filter(needsYou).count)
        tabButton(.matched, "Matched", allRuns.filter { $0.decision?.outcome == .match }.count)
        tabButton(.all, "All checks", allRuns.count)
      }
    }
  }

  private func tabButton(_ value: Tab, _ title: String, _ count: Int) -> some View {
    Button { tab = value; selectedRun = nil } label: {
      HStack(spacing: 5) {
        Text(title).fontWeight(tab == value ? .medium : .regular)
        if count > 0 { Text("\(count)").font(.coveMetadata).monospacedDigit() }
      }
      .foregroundStyle(tab == value ? Palette.ink : Palette.muted).padding(.bottom, 6)
      .overlay(alignment: .bottom) { Rectangle().fill(tab == value ? Palette.ink : .clear).frame(height: 2) }
    }.buttonStyle(.plain).font(.coveText).accessibilityAddTraits(tab == value ? .isSelected : [])
  }

  // MARK: List

  private var list: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        if runs.isEmpty {
          Text(tab == .needsYou ? "Nothing needs you. The agent is handling it." :
               allRuns.isEmpty ? "No checks yet. Active agents check Inbox mail that arrives after you turn them on." : "Nothing here.")
            .font(.coveBody).foregroundStyle(Palette.body).padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        ForEach(runs) { run in
          Button { selectedRun = run.id } label: { row(run) }.buttonStyle(.plain)
          Divider()
        }
      }
    }
  }

  private func row(_ run: CustomAgentRun) -> some View {
    let isSelected = selected?.id == run.id
    return VStack(alignment: .leading, spacing: 0) {
      if let mail = store.mails.first(where: { $0.id == run.mailID }) {
        MailRow(mail: mail, selected: isSelected)
      } else {
        VStack(alignment: .leading, spacing: 6) {
          Text(run.sender ?? "Email").font(.coveText).lineLimit(1)
          Text(run.subject.isEmpty ? "(No subject)" : run.subject).font(.coveText).lineLimit(1)
          Text("No longer in downloaded mail").font(.coveSecondary).foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 22).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Palette.mailSelection : Palette.mailRead)
      }
      outcomeChip(run).padding(.horizontal, 22).padding(.bottom, 12).frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Palette.mailSelection : (store.mails.first { $0.id == run.mailID }?.isUnread == true ? Palette.canvas : Palette.mailRead))
    }
    .contentShape(Rectangle())
  }

  private func outcomeChip(_ run: CustomAgentRun) -> some View {
    let (text, symbol): (String, String) = {
      if let feedback = run.feedback { return (feedback == .correct ? "You confirmed" : "You said not a match", feedback == .correct ? "checkmark.circle" : "xmark.circle") }
      if run.error != nil { return ("Couldn’t check", "exclamationmark.triangle") }
      switch run.decision?.outcome {
      case .match?: return (run.appliedLabel.map { "Labeled \($0)" } ?? (run.replySuggestion != nil ? "Reply ready" : "Matched"), "sparkles")
      case .review?: return ("Needs your call", "questionmark.circle")
      case .noMatch?: return ("Not a match", "minus.circle")
      case nil: return ("Waiting", "clock")
      }
    }()
    return Label(text, systemImage: symbol).font(.coveCaption).foregroundStyle(Palette.body)
      .padding(.horizontal, 7).padding(.vertical, 4)
      .background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 4))
  }

  // MARK: Detail

  @ViewBuilder private var detail: some View {
    if let run = selected {
      VStack(spacing: 0) {
        decisionPanel(run).padding(20)
        Divider()
        if let mail = store.mails.first(where: { $0.id == run.mailID }) {
          ReaderView(store: store, mail: mail).id(mail.id)
        } else {
          Text("This email is no longer in downloaded mail. Open Gmail to see it.").font(.coveBody)
            .foregroundStyle(Palette.body).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    } else {
      VStack(spacing: 10) {
        Image(systemName: "sparkles").font(.system(size: 22)).frame(width: 52, height: 52)
          .background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 12))
        Text("Choose an email to see what the agent decided").font(.coveSection)
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func decisionPanel(_ run: CustomAgentRun) -> some View {
    let decision = run.decision
    return VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Label(headline(run), systemImage: "sparkles").font(.coveSection)
        Spacer()
        if let decision { Text("\(Int(decision.confidence * 100))% sure · \(decision.model)").font(.coveMetadata).foregroundStyle(Palette.muted) }
      }
      if let reason = decision?.reason ?? run.matchedCondition.map({ "Matched: " + $0 }) {
        Text(reason).font(.coveBody).foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
      }
      if let quote = decision?.excerpt {
        Text("“" + quote + "”").font(.coveSecondary).foregroundStyle(Palette.body).lineLimit(3)
          .padding(.leading, 10).overlay(alignment: .leading) { Rectangle().fill(Palette.line).frame(width: 2) }
      }
      if let error = run.error { Text(error).font(.coveSecondary).foregroundStyle(Palette.danger) }
      if let extras = run.extrasApplied, !extras.isEmpty {
        HStack(spacing: 6) {
          ForEach(extras, id: \.self) { Label($0.title, systemImage: $0.symbol).font(.coveCaption).foregroundStyle(Palette.body)
            .padding(.horizontal, 7).padding(.vertical, 4).background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 4)) }
        }
      }
      if let reply = run.replySuggestion, run.replyApplied != true {
        Text(reply).font(.coveBody).lineSpacing(4).lineLimit(6).textSelection(.enabled)
          .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
      }
      actions(run)
    }
    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
    .background(Palette.assessment, in: RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.assessmentBorder))
  }

  private func headline(_ run: CustomAgentRun) -> String {
    if run.feedback == .correct { return "You confirmed this" }
    if run.feedback == .wrong { return "You said this isn’t a match" }
    switch run.decision?.outcome {
    case .match?: return run.appliedLabel.map { "Labeled \($0)" } ?? "Matched"
    case .review?: return "Is this one for \(agent.name)?"
    case .noMatch?: return "Not a match"
    case nil: return run.error == nil ? "Waiting to check" : "Couldn’t check this email"
    }
  }

  @ViewBuilder private func actions(_ run: CustomAgentRun) -> some View {
    let busy = working == run.id
    HStack(spacing: 10) {
      if run.feedback == nil {
        switch run.decision?.outcome {
        case .match?:
          Button("Right") { act(run) { await store.confirmAgentRun(run, ruleID: run.decision?.ruleID) } }
            .buttonStyle(PrimaryButton(compact: true))
          Button(run.appliedLabel != nil || run.extrasApplied?.isEmpty == false ? "Wrong — undo" : "Wrong") { act(run) { await store.rejectAgentRun(run) } }
            .buttonStyle(SecondaryButton(compact: true))
        case .review?, .noMatch?:
          yesButton(run, title: run.decision?.outcome == .review ? "Yes, it is" : "Actually, it is")
          if run.decision?.outcome == .review {
            Button("No") { act(run) { await store.rejectAgentRun(run) } }.buttonStyle(SecondaryButton(compact: true))
          }
        case nil:
          EmptyView()
        }
      } else {
        Text("The agent learns from this answer.").font(.coveSecondary).foregroundStyle(Palette.muted)
      }
      if run.replySuggestion != nil, run.replyApplied != true {
        Button("Use reply as draft") { store.applyCustomAgentReply(run) }.buttonStyle(SecondaryButton(compact: true))
      }
      if busy { ProgressView().controlSize(.small) }
    }.disabled(busy || store.busy)
  }

  /// With several steps, "Yes" asks which one (it decides the label and actions).
  @ViewBuilder private func yesButton(_ run: CustomAgentRun, title: String) -> some View {
    if let rules = agent.rules, rules.count > 1 {
      Menu(title) {
        ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
          Button("Step \(index + 1): \(rule.condition.prefix(60))") { act(run) { await store.confirmAgentRun(run, ruleID: rule.id) } }
        }
      }.menuStyle(.borderlessButton).fixedSize().font(.coveControl)
        .padding(.horizontal, 12).frame(height: 30).background(Palette.ink, in: RoundedRectangle(cornerRadius: 6)).foregroundStyle(.white)
    } else {
      Button(title) { act(run) { await store.confirmAgentRun(run, ruleID: agent.rules?.first?.id) } }.buttonStyle(PrimaryButton(compact: true))
    }
  }

  private func act(_ run: CustomAgentRun, _ work: @escaping () async -> Void) {
    working = run.id
    Task { await work(); working = nil }
  }
}
