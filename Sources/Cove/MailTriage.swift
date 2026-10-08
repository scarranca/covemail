import CoveCore
import Foundation

/// One triage action on one or many emails: the keys E, U, S, H, ⌘⌫ and the selection bar all go
/// through `AppStore.triage(_:_:)`, which applies it, offers Undo (Z) and advances the selection.
enum TriageAction: Equatable {
  case archive, moveToInbox, markRead, markUnread, flag, unflag, trash
  case snooze(Date?)

  var title: String {
    switch self {
    case .archive: "Archived"
    case .moveToInbox: "Moved to Inbox"
    case .markRead: "Marked read"
    case .markUnread: "Marked unread"
    case .flag: "Flagged"
    case .unflag: "Flag removed"
    case .trash: "Moved to Trash"
    case .snooze(let date): date.map { "Snoozed until \(SnoozePreset.describe($0))" } ?? "Returned to inbox"
    }
  }

  /// "Archived" for one email, "Archived · 3 emails" for a set (the Undo toast's text).
  func message(count: Int) -> String { count == 1 ? title : "\(title) · \(count) emails" }

  /// The Gmail label change, or nil for actions that aren't one (trash, snooze).
  var labelChange: (add: Set<String>, remove: Set<String>)? {
    switch self {
    case .archive: ([], ["INBOX"])
    case .moveToInbox: (["INBOX"], [])
    case .markRead: ([], ["UNREAD"])
    case .markUnread: (["UNREAD"], [])
    case .flag: (["STARRED"], [])
    case .unflag: ([], ["STARRED"])
    case .trash, .snooze: nil
    }
  }

  /// Only emails the action really changes are touched, so Undo reverses exactly those and no others.
  func changes(_ mail: Mail, now: Date) -> Bool {
    let snoozed = (mail.snoozedUntil ?? .distantPast) > now
    switch self {
    case .archive: return mail.labels.contains("INBOX") && mail.labels.isDisjoint(with: ["TRASH", "DRAFT", "SPAM"])
    // ⇧E brings archived mail back and wakes snoozed mail.
    case .moveToInbox: return (!mail.labels.contains("INBOX") || snoozed) && mail.labels.isDisjoint(with: ["TRASH", "DRAFT", "SPAM"])
    case .markRead: return mail.isUnread
    case .markUnread: return !mail.isUnread
    case .flag: return !mail.isStarred
    case .unflag: return mail.isStarred
    case .trash: return !mail.labels.contains("TRASH")
    case .snooze(let date): return mail.snoozedUntil != date && !mail.labels.contains("DRAFT")
    }
  }

  /// `mail` as it will look afterwards, to know before applying whether it leaves the list.
  func applied(to mail: Mail, now: Date) -> Mail {
    var result = mail
    if let change = labelChange {
      result.labels.formUnion(change.add); result.labels.subtract(change.remove)
    }
    if case .snooze(let date) = self { result.snoozedUntil = date }
    if self == .moveToInbox, (mail.snoozedUntil ?? .distantPast) > now { result.snoozedUntil = nil }
    return result
  }
}

/// What Z or the Undo button reverses. `restore` must go through `modify`/`applyBulk`/`snooze(_:until:)`
/// so `reapplyLabelEdits` keeps the reversal safe against a concurrent sync; never a snapshot restore.
struct TriageUndo: Identifiable {
  let id = UUID()
  var message: String
  /// The email to reopen after Undo, if it was open.
  var reselect: String?
  var restore: @MainActor () async -> Void
}

extension AppStore {
  /// Above this many emails a label change goes to Gmail as one `batchModify` (`applyBulk`) instead of
  /// one request per email.
  static let triageBatchThreshold = 25

  /// The emails a key or toolbar action applies to: the chosen set when it includes `mail` (or when
  /// nothing is open), otherwise just `mail`.
  func triageTargets(for mail: Mail?) -> [Mail] {
    if !selectedIDs.isEmpty, mail == nil || selectedIDs.contains(mail!.id) {
      return visible.filter { selectedIDs.contains($0.id) }
    }
    return mail.map { [$0] } ?? []
  }

  /// Inbox emails in one tab of the split (for "Archive all in Other").
  func inboxMails(in tab: InboxSplit) -> [Mail] {
    mails.filter {
      !queuedTrashIDs.contains($0.id) && $0.labels.contains("INBOX") && $0.labels.isDisjoint(with: ["TRASH", "SPAM", "DRAFT"])
        && ($0.snoozedUntil ?? .distantPast) <= now && inboxSplit(of: $0) == tab
    }
  }

  /// Applies `action` to `targets`, records one `triageUndo` for the whole set, clears `selectedIDs`,
  /// and moves the selection to the next listed email when the open one leaves the list.
  func triage(_ targets: [Mail], _ action: TriageAction) async {
    await beginTriage(targets, action)?.value
  }

  /// The synchronous half of `triage`: the selection advances, the chosen set clears and Undo is offered
  /// before this returns (keys rely on that); the Gmail work continues in the returned task.
  /// Nil when no target would change, so a key can pass through.
  @discardableResult
  func beginTriage(_ targets: [Mail], _ action: TriageAction) -> Task<Void, Never>? {
    guard entered else { return nil }
    let now = now
    var seen = Set<String>()
    // Fresh copies: a row or key may hold an email from before the last sync.
    let mails = targets.compactMap { target in seen.insert(target.id).inserted ? mail(id: target.id) : nil }
      .filter { action.changes($0, now: now) && (action != .trash || !queuedTrashIDs.contains($0.id)) }
    guard !mails.isEmpty else { return nil }
    let ids = Set(mails.map(\.id))
    let opened = selectedID.flatMap { ids.contains($0) ? $0 : nil }

    // Choose the next email before anything changes, so it never depends on when Gmail answers:
    // the one below the open email, or above at the end, skipping emails this action also removes.
    if let opened {
      let leaving = Set(mails.filter { action == .trash || !staysListed(action.applied(to: $0, now: now)) }.map(\.id))
      if leaving.contains(opened) {
        let list = visible
        if let index = list.firstIndex(where: { $0.id == opened }) {
          let below = list[(index + 1)...].first { !leaving.contains($0.id) }
          let above = list[..<index].last { !leaving.contains($0.id) }
          selectedID = (below ?? above)?.id
        } else {
          selectedID = nil
        }
      }
    }
    clearTriageSelection()

    let generation = mailboxGeneration
    let work: Task<[String], Never>
    var snoozes: [(id: String, previous: Date?)] = []
    switch action {
    case .trash:
      // Trash keeps its own five-second window; Z cancels it like the toast's Undo.
      mails.forEach { queueTrash($0) }
      work = Task { mails.map(\.id) }
    case .snooze(let date):
      for mail in mails {
        snoozes.append((mail.id, mail.snoozedUntil))
        snooze(mail, until: date)
      }
      work = Task { mails.map(\.id) }
    default:
      // ⇧E also wakes snoozed mail; that part is local and reversed per email like a snooze.
      if action == .moveToInbox {
        for mail in mails where (mail.snoozedUntil ?? .distantPast) > now {
          snoozes.append((mail.id, mail.snoozedUntil))
          snooze(mail, until: nil)
        }
      }
      let change = action.labelChange ?? ([], [])
      let labelled = mails.filter { !$0.labels.isSuperset(of: change.add) || !$0.labels.isDisjoint(with: change.remove) }
      work = Task { @MainActor [weak self] in
        guard let self else { return [] }
        return await self.applyTriageLabels(labelled, add: change.add, remove: change.remove, label: "Updating")
      }
    }

    triageUndo = TriageUndo(
      message: action.message(count: mails.count), reselect: opened,
      restore: { [weak self] in
        guard let self, generation == self.mailboxGeneration else { return }
        // Undo queues behind the change it reverses, so it can never be overtaken by it.
        let changed = await work.value
        guard generation == self.mailboxGeneration else { return }
        switch action {
        case .trash:
          self.undoQueuedTrash()
        default:
          for (id, previous) in snoozes {
            if let mail = self.mail(id: id) { self.snooze(mail, until: previous) }
          }
          if let change = action.labelChange {
            let reverted = changed.compactMap { self.mail(id: $0) }
            _ = await self.applyTriageLabels(reverted, add: change.remove, remove: change.add, label: "Undoing")
          }
        }
      })
    return Task { _ = await work.value }
  }

  /// One label change on many emails. Up to `triageBatchThreshold` go through `modify` side by side
  /// (each email keeps its own ordered queue); more go to Gmail in one paced `applyBulk`.
  /// Returns the ids that were sent (for `modify`, a refusal already restores that email by itself).
  private func applyTriageLabels(_ mails: [Mail], add: Set<String>, remove: Set<String>, label: String) async -> [String] {
    guard !mails.isEmpty else { return [] }
    if mails.count > Self.triageBatchThreshold {
      let result = await applyBulk(mails.map(AssistantBulkTarget.init), add: Array(add), remove: Array(remove), label: label)
      return result.succeeded
    }
    await withTaskGroup(of: Void.self) { group in
      for mail in mails {
        group.addTask { @MainActor in await self.modify(mail, add: Array(add), remove: Array(remove)) }
      }
    }
    return mails.map(\.id)
  }

  /// Snoozes with a preset as a triage action (advances, offers Z); `nil` from the preset (too near) is
  /// ignored by the menus, never here. For a chosen set use `triage(triageTargets(for:), .snooze(date))`.
  func snooze(_ mail: Mail, preset: SnoozePreset, now: Date = Date()) {
    guard let date = preset.date(from: now) else { return }
    beginTriage([mail], .snooze(date))
  }

  /// Z / Undo: reverses the last triage action exactly, then reopens the email it came from.
  func undoLastTriage() async {
    guard let undo = triageUndo else { return }
    triageUndo = nil
    await undo.restore()
    if let id = undo.reselect, screen == "mail", visible.contains(where: { $0.id == id }) { selectedID = id }
  }
}
