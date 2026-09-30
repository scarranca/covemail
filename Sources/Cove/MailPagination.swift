import CoveCore
import SwiftUI

struct MailPageRequest: Hashable {
  let account: String
  let folder: String
  let search: String
  let priorityOnly: Bool
  let unreadOnly: Bool
  let oldestFirst: Bool
  let cursor: String
  var inboxTab: InboxSplit? = nil

  func hasSameView(as other: Self) -> Bool {
    account == other.account && folder == other.folder && search == other.search
      && priorityOnly == other.priorityOnly && unreadOnly == other.unreadOnly && oldestFirst == other.oldestFirst
      && inboxTab == other.inboxTab
  }
}

/// One request per page, with an explicit retry after errors. Scroll geometry, rather
/// than LazyVStack's speculative onAppear, decides when a page is needed.
@MainActor @Observable final class MailPageLoader {
  private(set) var loading = false
  private(set) var failed: MailPageRequest?
  private var completed = Set<MailPageRequest>()
  private var waitingForScroll = false
  private var lastView: MailPageRequest?

  func leftEnd() {
    waitingForScroll = false
    completed.removeAll()
  }

  func load(_ request: MailPageRequest?, atEnd: Bool, allowed: Bool,
            retry: Bool = false, operation: () async -> (advanced: Bool, addedVisibleMail: Bool)?) async {
    guard let request, atEnd, allowed, !loading else { return }
    if lastView?.hasSameView(as: request) != true { leftEnd() }
    lastView = request
    guard retry || (!waitingForScroll && failed != request), !completed.contains(request) else { return }
    loading = true
    failed = nil
    defer { loading = false }
    guard let result = await operation() else { return }
    if result.advanced {
      completed.insert(request)
      // A local filter may exclude an entire page. Don't drain the whole mailbox
      // while the same empty tail stays visible; another scroll can continue.
      waitingForScroll = !result.addedVisibleMail
    } else {
      failed = request
    }
  }
}

extension AppStore {
  var nextMailPageRequest: MailPageRequest? {
    guard let cursor = mailScopeLabelID.map({ labelNextPages[$0] }) ?? nextPage else { return nil }
    return MailPageRequest(account: accountEmail, folder: folder, search: search,
      priorityOnly: priorityOnly, unreadOnly: labelUnreadOnly, oldestFirst: labelOldestFirst, cursor: cursor,
      inboxTab: effectiveInboxTab)
  }
  var canLoadNextMailPage: Bool { entered && screen == "mail" && !isSample && !busy && queuedTrashIDs.isEmpty }

  func loadNextMailPage(_ expected: MailPageRequest) async -> (advanced: Bool, addedVisibleMail: Bool)? {
    guard canLoadNextMailPage, nextMailPageRequest == expected else { return nil }
    let visibleIDs = Set(visible.map(\.id))
    if mailScopeLabelID != nil { await loadLabelMail(older: true) }
    else { await sync(older: true) }
    guard accountEmail == expected.account, folder == expected.folder, search == expected.search,
      priorityOnly == expected.priorityOnly, labelUnreadOnly == expected.unreadOnly,
      labelOldestFirst == expected.oldestFirst, effectiveInboxTab == expected.inboxTab else { return nil }
    let cursor = mailScopeLabelID.map({ labelNextPages[$0] }) ?? nextPage
    return (cursor != expected.cursor, visible.contains { !visibleIDs.contains($0.id) })
  }
}

struct MailListEndKey: PreferenceKey {
  static let defaultValue: CGFloat? = nil
  static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
    if let next = nextValue() { value = next }
  }
}
