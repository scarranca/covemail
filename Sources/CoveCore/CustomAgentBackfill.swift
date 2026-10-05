import Foundation

/// "Try on recent mail": a bounded, preview-first run of one agent over already downloaded inbox mail.
/// The preview never changes Gmail or saves runs; only an explicit apply labels the confident matches.
public enum CustomAgentBackfill {
  public static let days = 14
  public static let limit = 200
  public static let concurrency = 4

  /// Recent inbox mail the agent has not handled yet, newest first, at most `limit` emails.
  /// Mail the active agent already watches (after `activeSince`) belongs to the normal new-mail loop.
  public static func candidates(in mail: [Mail], agent: CustomAgent, runs: [CustomAgentRun], account: String,
                                now: Date, days: Int = days, limit: Int = limit) -> [Mail] {
    let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
    let handled = Set(runs.filter { $0.agentID == agent.id && $0.completed
      && ($0.revision == agent.revision || $0.appliedLabel != nil || $0.decision?.outcome == .review) }.map(\.mailID))
    return mail.filter {
      $0.date >= cutoff && $0.date <= now.addingTimeInterval(300)
        && $0.labels.contains("INBOX") && $0.labels.isDisjoint(with: ["SENT", "DRAFT", "TRASH", "SPAM"])
        && !$0.id.hasPrefix("local-") && $0.senderEmail.caseInsensitiveCompare(account) != .orderedSame
        && !handled.contains($0.id) && !agent.accepts($0, account: account)
    }
    .sorted { $0.date == $1.date ? $0.id > $1.id : $0.date > $1.date }
    .prefix(limit).map { $0 }
  }
}

public struct CustomAgentBackfillItem: Identifiable, Equatable, Sendable {
  public var id: String { mailID }
  public var mailID: String
  public var sender: String
  public var subject: String
  public var date: Date
  public var decision: CustomAgentDecision
  public init(mail: Mail, decision: CustomAgentDecision) {
    mailID = mail.id; sender = mail.sender.isEmpty ? mail.senderEmail : mail.sender
    subject = mail.subject; date = mail.date; self.decision = decision
  }
}

public struct CustomAgentBackfillPreview: Equatable, Sendable {
  public var agent: CustomAgent
  public var items: [CustomAgentBackfillItem] = []
  /// Emails Jev couldn't check (network or evaluation errors). They are never labeled.
  public var failed = 0
  /// Why the first email couldn't be checked, so a failure is never just a count.
  public var firstError: String?
  public init(agent: CustomAgent) { self.agent = agent }
  /// Confident non-matches, for the full list.
  public var noMatches: [CustomAgentBackfillItem] { items.filter { $0.decision.outcome == .noMatch } }
  /// Confident matches that would label and/or prepare a reply.
  public var matches: [CustomAgentBackfillItem] {
    items.filter { $0.decision.outcome == .match && ($0.decision.label(for: agent) != nil || $0.decision.rule(for: agent)?.action.drafts == true) }
  }
  public var unclear: [CustomAgentBackfillItem] { items.filter { $0.decision.outcome == .review } }
  public var noMatchCount: Int { items.count - matches.count - unclear.count }
  public var labelCount: Int { matches.filter { $0.decision.label(for: agent) != nil }.count }
  public var replyCount: Int { matches.filter { $0.decision.rule(for: agent)?.action.drafts == true }.count }
  /// "Would label 18 · 3 unclear · 179 no match"
  public var summary: String {
    var parts = ["Would label \(labelCount)"]
    if replyCount > 0 { parts.append("\(replyCount) \(replyCount == 1 ? "reply" : "replies")") }
    parts.append("\(unclear.count) unclear")
    parts.append("\(noMatchCount) no match")
    if failed > 0 { parts.append("\(failed) not checked") }
    return parts.joined(separator: " · ")
  }
}

public struct CustomAgentBackfillResult: Equatable, Sendable {
  public var applied = 0
  public var alreadyLabeled = 0
  public var failed = 0
  public var unclear = 0
  public var stopped: String?
  public init() {}
  public var summary: String {
    var parts = ["Applied to \(applied)"]
    if alreadyLabeled > 0 { parts.append("\(alreadyLabeled) already labeled") }
    parts.append("\(failed) failed")
    if unclear > 0 { parts.append("\(unclear) unclear in Activity") }
    return parts.joined(separator: " · ")
  }
}
