import CoveCore
import Foundation

/// Smarter custom agents (Agents): decisions by the user's own writing model with real context
/// (`AgentBrain`), extra actions on a confident match, and learning from the user's Yes / No / Undo.
extension AppStore {
  /// Agents think with Jev (TypeSafe's classifier, built for this) whenever a TypeSafe key is saved, now with
  /// the conversation, the sender, About you and the user's verdicts. The writing model decides only
  /// without a key (and always writes the replies). Tests use `agentBrainWriter` for the model path.
  var agentsUseModel: Bool {
    if agentBrainWriter != nil { return true }
    if hasJevKey { return false }
    return jevKeyProvider == nil && AIProviderSettings.shared.hasWorkingDefault
  }
  private var hasJevKey: Bool {
    if let jevKeyProvider { return ((try? jevKeyProvider()) ?? nil)?.isEmpty == false }
    return UserDefaults.standard.bool(forKey: "setup.jevKeySaved")
  }

  /// The writing model agents use, for labels in the UI.
  var agentModelName: String {
    let settings = AIProviderSettings.shared
    guard let provider = settings.writingProvider() else { return "writing model" }
    return settings.modelLabel(settings.model(provider), provider: provider)
  }

  /// The decision for one email: the writing model with context, or Jev's classifier.
  func decideAgent(_ mail: Mail, agent: CustomAgent, attachments: [AgentAttachmentText], warnings: [String],
                   key: String?) async throws -> CustomAgentDecision {
    // The email's conversation (newest first) and who the sender is to the user, for either brain.
    let thread = Array(mails.filter { $0.threadID == mail.threadID && $0.id != mail.id && !mail.threadID.isEmpty }
      .sorted { $0.date > $1.date }.prefix(4))
    let sender = AgentBrain.senderSummary(for: mail, in: mails, account: accountEmail, now: syncClock())
    guard agentsUseModel else {
      guard let key else { throw CoveError.message("Connect TypeSafe (or a writing model) in Connections to run agents.") }
      return try await jev.classify(mail, agent: agent, key: key, attachments: attachments, warnings: warnings,
        context: AgentBrain.jevContext(agent: agent, mail: mail, thread: thread, sender: sender, about: preferences.memoryPrompt))
    }
    let agent = try agent.validated()
    let instruction = AgentBrain.instruction(agent: agent, sender: sender, about: preferences.memoryPrompt, now: syncClock())
    var budget = 16_000
    let evidence = attachments.prefix(5).map { attachment in
      var text = String(attachment.text.prefix(min(6_000, budget)))
      while text.utf8.count > min(6_000, budget) { text.removeLast() }
      budget -= text.utf8.count
      return "Attachment: " + String(attachment.name.prefix(250)) + "\n" + text
    }.joined(separator: "\n\n")
    let prompt = try AIPrompt(intent: .answer, instruction: instruction, mails: [mail] + thread, evidence: evidence)
    let reply: String
    let model: String
    if let agentBrainWriter {
      reply = try await agentBrainWriter(prompt)
      model = "fixture"
    } else {
      let settings = AIProviderSettings.shared
      await settings.restoreWritingConnection()
      guard let provider = settings.writingProvider() else { throw CoveError.message("Connect a writing model in Connections.") }
      // Subscriptions (ChatGPT, Claude) answer one request at a time: agent checks take turns, and wait
      // for a draft the user is writing instead of failing.
      await AgentModelGate.shared.acquire()
      defer { AgentModelGate.shared.release() }
      var attempt = 0
      while true {
        try Task.checkCancellation()
        do {
          reply = try await settings.complete(prompt)
          break
        } catch let error as CoveError where error.localizedDescription.contains("already running") && attempt < 60 {
          attempt += 1
          try await Task.sleep(for: .seconds(2))
        }
      }
      model = settings.modelLabel(settings.model(provider), provider: provider)
    }
    return try AgentBrain.decision(from: reply, agent: agent, model: model, warnings: warnings)
  }

  /// Archive, flag, mark read or create a task for a confident match, through the same label path as
  /// the user's own actions. Never sends, deletes or touches the calendar.
  func applyAgentExtras(_ extras: [CustomAgentExtra], to mailID: String, agent: CustomAgent) async -> [CustomAgentExtra] {
    guard let mail = mails.first(where: { $0.id == mailID }) else { return [] }
    var done: [CustomAgentExtra] = []
    for extra in extras {
      switch extra {
      case .archive where mail.labels.contains("INBOX"):
        await modify(mail, remove: ["INBOX"]); done.append(extra)
      case .flag where !mail.isStarred:
        await modify(mail, add: ["STARRED"]); done.append(extra)
      case .markRead where mail.isUnread:
        await modify(mail, remove: ["UNREAD"]); done.append(extra)
      case .task:
        let title = (mail.sender.isEmpty ? mail.senderEmail : mail.sender) + ": " + (mail.subject.isEmpty ? "(No subject)" : mail.subject)
        if (try? await createTask(title: String(title.prefix(120)), due: nil, notes: "Created by your agent “\(agent.name)”.", from: mail.id)) != nil {
          done.append(extra)
        }
      default: break
      }
    }
    return done
  }

  // MARK: Learning from the user

  /// "Yes, that's right" (or choosing the step it should have been): applies that step's label and
  /// extras now and saves the verdict as an example.
  func confirmAgentRun(_ run: CustomAgentRun, ruleID: String?) async {
    guard var agent = customAgents.agents.first(where: { $0.id == run.agentID }),
          let mail = mails.first(where: { $0.id == run.mailID }) else { return }
    let rule = ruleID.flatMap { id in agent.rules?.first { $0.id == id } } ?? (agent.rules == nil ? nil : run.decision?.rule(for: agent))
    var updated = customAgents.runs.first { $0.id == run.id } ?? run
    let label = rule.map { $0.action.labels ? $0.labelName : "" } ?? (agent.rules == nil ? agent.labelName : "")
    do {
      if !label.isEmpty, updated.appliedLabel == nil {
        let generation = mailboxGeneration
        _ = try await applyAgentLabel(named: label, to: mail.id, generation: generation, isCurrent: { true })
        updated.appliedLabel = label
      }
      if let extras = rule?.extras, !extras.isEmpty, updated.extrasApplied == nil {
        updated.extrasApplied = await applyAgentExtras(extras, to: mail.id, agent: agent)
      }
      if var decision = updated.decision, decision.outcome != .match {
        decision.outcome = .match
        decision.ruleID = rule?.id
        updated.decision = decision
      }
      updated.matchedCondition = rule?.condition ?? updated.matchedCondition
      updated.feedback = .correct
      updated.completed = true
      try persistAgentRun(updated)
      let index = rule.flatMap { r in agent.rules?.firstIndex { $0.id == r.id } }
      agent.learn(CustomAgentExample(mail: mail, verdict: index.map { "Step \($0 + 1): " + (rule?.condition ?? "") } ?? "Match"))
      try saveAgent(agent)
      agentFailure = nil
    } catch { agentFailure = error.localizedDescription }
  }

  /// "No" / Undo: removes what the agent applied (its label and extras) and saves "Not a match".
  func rejectAgentRun(_ run: CustomAgentRun) async {
    guard var agent = customAgents.agents.first(where: { $0.id == run.agentID }),
          let mail = mails.first(where: { $0.id == run.mailID }) else { return }
    var updated = customAgents.runs.first { $0.id == run.id } ?? run
    if let name = updated.appliedLabel,
       let label = gmailLabels.first(where: { $0.type == "user" && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
      await modify(mail, remove: [label.id])
    }
    for extra in updated.extrasApplied ?? [] {
      guard let current = mails.first(where: { $0.id == mail.id }) else { break }
      switch extra {
      case .archive: await modify(current, add: ["INBOX"])
      case .flag: await modify(current, remove: ["STARRED"])
      case .markRead: await modify(current, add: ["UNREAD"])
      case .task: break // The task stays in Google Tasks; Cove never deletes tasks.
      }
    }
    if var decision = updated.decision { decision.outcome = .noMatch; decision.ruleID = nil; updated.decision = decision }
    updated.appliedLabel = nil
    updated.extrasApplied = nil
    updated.feedback = .wrong
    updated.completed = true
    do {
      try persistAgentRun(updated)
      agent.learn(CustomAgentExample(mail: mail, verdict: "Not a match"))
      try saveAgent(agent)
      agentFailure = nil
    } catch { agentFailure = error.localizedDescription }
  }

  /// Saves an agent's examples without changing its revision (a verdict isn't an edit of its rules).
  private func saveAgent(_ agent: CustomAgent) throws {
    var library = customAgents
    guard let index = library.agents.firstIndex(where: { $0.id == agent.id }) else { return }
    library.agents[index].examples = agent.examples
    try saveAgentLibrary(library)
  }
}

/// One agent check at a time on the writing model (FIFO).
@MainActor final class AgentModelGate {
  static let shared = AgentModelGate()
  private var busy = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func acquire() async {
    guard busy else { busy = true; return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func release() {
    if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
  }
}
