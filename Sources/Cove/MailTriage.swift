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
  /// STUB: the Mac triage agent implements this; UI agents may call it.
  func triage(_ targets: [Mail], _ action: TriageAction) async {
    for mail in targets {
      switch action {
      case .archive: await archive(mail)
      case .moveToInbox: await modify(mail, add: ["INBOX"])
      case .markRead: await modify(mail, remove: ["UNREAD"])
      case .markUnread: await modify(mail, add: ["UNREAD"])
      case .flag: await modify(mail, add: ["STARRED"])
      case .unflag: await modify(mail, remove: ["STARRED"])
      case .trash: queueTrash(mail)
      case .snooze(let date): snooze(mail, until: date)
      }
    }
    selectedIDs = []
  }

  /// Snoozes with a preset; `nil` from the preset (too near) is ignored by the menus, never here.
  func snooze(_ mail: Mail, preset: SnoozePreset, now: Date = Date()) {
    guard let date = preset.date(from: now) else { return }
    snooze(mail, until: date)
  }

  /// Z / Undo: reverses the last triage action exactly, then reopens the email it came from.
  /// STUB: the Mac triage agent implements this.
  func undoLastTriage() async {
    guard let undo = triageUndo else { return }
    triageUndo = nil
    await undo.restore()
    if let id = undo.reselect, screen == "mail", visible.contains(where: { $0.id == id }) { selectedID = id }
  }
}
