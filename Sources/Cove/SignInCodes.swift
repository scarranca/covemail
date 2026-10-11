import AppKit
import CoveCore

/// Sign-in codes on the Mac (Settings → Menu bar → Sign-in codes). When a sync brings a fresh
/// verification code (`SignInCode`), Cove shows it in the menu bar until it's copied or expires, and
/// posts a notification with Copy when notifications are allowed. Only the code leaves the email.
enum SignInCodeSettings {
  static let enabledKey = "codes.enabled"
  static let notifyKey = "codes.notify"
  /// On unless turned off.
  static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
  static var notifies: Bool { UserDefaults.standard.object(forKey: notifyKey) as? Bool ?? true }
  /// How long a code stays in the menu bar and Notification Center.
  static let shownFor: TimeInterval = SignInCode.freshness
}

extension AppStore {
  /// Offers the newest fresh code among emails this sync just brought in (never older mail: the
  /// caller passes only arrivals, and `SignInCode` ignores anything over 10 minutes old).
  func announceSignInCodes(in arrived: [Mail]) {
    guard SignInCodeSettings.enabled, !isSample, !arrived.isEmpty else { return }
    let account = accountEmail
    let me = ContactDirectory.normalizedEmail(account)
    let found = arrived
      .filter { $0.labels.contains("INBOX") && $0.isUnread && ContactDirectory.normalizedEmail($0.senderEmail) != me }
      .compactMap { SignInCode.detect(in: $0, now: syncClock()) }
      .filter { !announcedCodeIDs.contains($0.mailID) }
      .max { $0.date < $1.date }
    guard let found else { return }
    announcedCodeIDs.insert(found.mailID)
    SignInCodeMenuBar.shared.show(found, account: account)
    if SignInCodeSettings.notifies { agentNotifier.postSignInCode(found, account: account) }
  }

  /// Between full syncs (every two minutes), a cheap check for new Inbox mail (Gmail history, 2 of
  /// the 6,000 quota units a minute) so a code arrives in seconds rather than minutes. A full sync
  /// runs only when something new is there.
  func probeForNewMail(elapsed: TimeInterval) async {
    // Offline or failing: wait for the two-minute retry instead of trying every 30 seconds.
    guard probesForNewMail, SignInCodeSettings.enabled, connectionIssue == nil, !probingNewMail, let history = gmailHistoryIDForProbe,
          elapsed >= (PowerState.onBattery ? 60 : 25) else { return }
    probingNewMail = true
    defer { probingNewMail = false }
    let generation = mailboxGeneration
    let found = try? await withGmailToken { token in
      try await GmailPush.newInboxMessages(token: token, after: history, client: self.gmail)
    }
    guard generation == mailboxGeneration, let found, !found.ids.isEmpty else { return }
    await sync(interactive: false)
  }
}

/// The menu bar item for a fresh code: `key 482 913`. Clicking it copies the code and removes it; it
/// also goes away by itself after ten minutes. AppKit only (never SwiftUI's MenuBarExtra: see 0.1.62).
@MainActor final class SignInCodeMenuBar: NSObject {
  static let shared = SignInCodeMenuBar()
  private(set) var current: SignInCode?
  private var statusItem: NSStatusItem?
  private var expiry: Task<Void, Never>?
  /// Tests render without touching the real menu bar.
  var installsStatusItem = Bundle.main.bundleURL.pathExtension == "app"
  var copy: (String) -> Void = { code in
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(code, forType: .string)
  }

  func show(_ code: SignInCode, account: String) {
    current = code
    if installsStatusItem {
      if statusItem == nil {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.imagePosition = .imageLeading
        statusItem = item
      }
      let image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: "Sign-in code")
      image?.isTemplate = true
      statusItem?.button?.image = image
      statusItem?.button?.title = " " + code.display
      statusItem?.button?.toolTip = "Sign-in code from \(code.sender) · Click to copy"
    }
    expiry?.cancel()
    let remaining = SignInCodeSettings.shownFor - Date().timeIntervalSince(code.date)
    expiry = Task { [weak self] in
      try? await Task.sleep(for: .seconds(max(1, remaining)))
      guard !Task.isCancelled, self?.current?.mailID == code.mailID else { return }
      self?.clear()
    }
  }

  @objc private func clicked() {
    guard let current else { clear(); return }
    copy(current.code)
    statusItem?.button?.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
    statusItem?.button?.title = " Copied"
    let id = current.mailID
    expiry?.cancel()
    expiry = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1.5))
      guard !Task.isCancelled, self?.current?.mailID == id else { return }
      self?.clear()
    }
  }

  func clear() {
    expiry?.cancel()
    current = nil
    if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    statusItem = nil
  }
}
