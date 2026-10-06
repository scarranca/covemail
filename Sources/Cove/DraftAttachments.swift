import CoveCore
import Foundation

/// Where a draft's files belong: a composer draft (by its local draft ID) or a reply (by the email).
enum AttachmentTarget {
  static func draft(_ id: String) -> String { "draft.\(id)" }
  static func reply(_ mailID: String) -> String { "reply.\(mailID)" }
}

/// Files attached to drafts on the Mac. They are read when added and kept as encrypted records in the
/// mailbox store (`attachments.<target>`), so a draft keeps its files after Cove restarts. They never
/// go to the cloud mirror; Gmail receives them only when the email is sent.
extension AppStore {
  private static func recordKey(_ target: String) -> String { "attachments.\(target)" }

  /// Safe to call while drawing: it never writes state. Views call `loadAttachments` first.
  func attachments(for target: String) -> [OutgoingAttachment] {
    draftAttachments[target] ?? []
  }

  /// Loads a draft's saved files once (opening the composer or a reply).
  func loadAttachments(_ target: String) {
    guard draftAttachments[target] == nil else { return }
    draftAttachments[target] = ((try? database?.load([OutgoingAttachment].self, key: Self.recordKey(target))) ?? nil) ?? []
  }

  /// Reads the files now and adds what fits within Gmail's 25 MB. Problems become `attachmentNotice`.
  func addAttachments(_ urls: [URL], to target: String) {
    var read: [OutgoingAttachment] = []
    var problems: [String] = []
    for url in urls {
      do { read.append(try OutgoingAttachment(contentsOf: url)) } catch { problems.append(error.localizedDescription) }
    }
    addAttachments(read, to: target, problems: problems)
  }

  func addAttachments(_ files: [OutgoingAttachment], to target: String, problems: [String] = []) {
    var problems = problems
    loadAttachments(target)
    let result = OutgoingAttachment.adding(files, to: attachments(for: target))
    if let problem = result.problem { problems.append(problem) }
    save(result.files, target: target)
    attachmentNotice = problems.isEmpty ? nil : problems.joined(separator: " ")
  }

  func removeAttachment(_ id: UUID, from target: String) {
    loadAttachments(target)
    save(attachments(for: target).filter { $0.id != id }, target: target)
    attachmentNotice = nil
  }

  /// After a send: removes the files that went, keeping any added during the Undo window.
  func clearAttachments(_ target: String, keeping sent: [OutgoingAttachment]? = nil) {
    loadAttachments(target)
    let remaining = sent.map { gone in attachments(for: target).filter { file in !gone.contains { $0.id == file.id } } } ?? []
    save(remaining, target: target)
  }

  private func save(_ files: [OutgoingAttachment], target: String) {
    draftAttachments[target] = files
    do {
      if files.isEmpty { try database?.removeRecord(key: Self.recordKey(target)) }
      else { try database?.save(files, key: Self.recordKey(target)) }
    } catch {
      attachmentNotice = "Cove couldn’t save the attachments on this Mac. They stay attached while Cove is open."
    }
  }

  /// A file dropped on the main window: it joins the reply being written, or starts a new email.
  func attachDropped(_ urls: [URL]) {
    guard entered, !urls.isEmpty else { return }
    if let mailID = replyDraftTarget {
      addAttachments(urls, to: AttachmentTarget.reply(mailID))
    } else {
      newDraft()
      if let id = composeID { addAttachments(urls, to: AttachmentTarget.draft(id)) }
    }
  }
}
