import CoveCore
import Foundation
import Observation

/// "Back in your inbox": keeps one pending macOS notification per snoozed email. It watches the store's
/// mail, so any snooze (menu, key, Ask Cove, a cloud snooze arriving) schedules one, and un-snoozing,
/// archiving or trashing cancels it. Sender and subject only, never the body. A click opens the email
/// through `SystemAgentNotifier.open` (`openNotifiedMail`).
@MainActor @Observable final class SnoozeNotifications {
  private(set) static var shared: SnoozeNotifications?

  /// Whether macOS lets Cove notify. nil until the first snooze asked (or until checked).
  /// The snooze menu can say "Notifications are off for Cove" when this is false.
  private(set) var snoozeNotificationsAllowed: Bool?

  private let store: AppStore
  private let notifier: SystemAgentNotifier
  /// What this session scheduled for the open account: email id -> when.
  private var scheduled: [String: Date] = [:]
  private var account = ""
  private var started = false

  static func start(store: AppStore) {
    guard shared == nil else { return }
    let model = SnoozeNotifications(store: store, notifier: SystemAgentNotifier.shared)
    shared = model
    model.begin()
  }

  init(store: AppStore, notifier: SystemAgentNotifier) {
    self.store = store
    self.notifier = notifier
  }

  private func begin() {
    guard !started else { return }
    started = true
    notifier.install()
    Task {
      snoozeNotificationsAllowed = Self.allowed(await notifier.permission())
      await reconcile(initial: true)
      observe()
    }
  }

  /// Re-arms after every change to the loaded mail or the open account.
  private func observe() {
    withObservationTracking {
      _ = store.mailsRevision
      _ = store.accountEmail
    } onChange: { [weak self] in
      // onChange runs before the new value lands; hop once so reconcile reads it.
      Task { @MainActor in
        guard let self else { return }
        await self.reconcile(initial: false)
        self.observe()
      }
    }
  }

  private func reconcile(initial: Bool) async {
    let current = store.accountEmail
    let accountChanged = current != account
    if accountChanged { account = current; scheduled = [:] }
    let wanted = Dictionary(SnoozeNotice.pending(in: store.mails).compactMap { mail in
      mail.snoozedUntil.map { (mail.id, ($0, mail)) }
    }, uniquingKeysWith: { first, _ in first })

    // Cancel what is no longer snoozed. On a fresh start or account change, also sweep requests an
    // earlier session left for this account.
    var stale = scheduled.keys.filter { wanted[$0] == nil }.map { SnoozeNotice.identifier(mailID: $0) }
    if initial || accountChanged {
      let left = await notifier.pending(prefix: SnoozeNotice.identifierPrefix)
      for (identifier, owner) in left where owner == account {
        if let id = SnoozeNotice.mailID(fromIdentifier: identifier), wanted[id] == nil { stale.append(identifier) }
      }
    }
    if !stale.isEmpty { notifier.cancelPending(identifiers: Array(Set(stale))) }
    scheduled = scheduled.filter { wanted[$0.key] != nil }

    let fresh = wanted.filter { scheduled[$0.key] != $0.value.0 }
    guard !fresh.isEmpty, !store.isSample else { return }
    // Ask on the first snooze, never on launch for snoozes that already existed.
    var permission = await notifier.permission()
    if permission == .notDetermined, !initial { permission = await notifier.requestPermission() }
    snoozeNotificationsAllowed = Self.allowed(permission)
    guard permission == .allowed else { return }
    for (id, entry) in fresh {
      let (date, mail) = entry
      notifier.schedule(identifier: SnoozeNotice.identifier(mailID: id), title: SnoozeNotice.title,
                        body: SnoozeNotice.body(sender: SnoozeNotice.senderName(of: mail), subject: mail.subject),
                        mailID: id, account: account, at: date)
      scheduled[id] = date
    }
  }

  private static func allowed(_ permission: AgentNotificationPermission) -> Bool? {
    switch permission {
    case .allowed: true
    case .denied: false
    case .notDetermined, .unavailable: nil
    }
  }
}
