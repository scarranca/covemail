import AppKit
import CoveCore
import UserNotifications

enum AgentNotificationPermission: Equatable {
  case allowed, denied, notDetermined, unavailable
}

/// The seam between agents and macOS notifications. Tests inject a recorder; the app uses
/// `SystemAgentNotifier`. Content stays minimal: agent name, sender and subject, never the body.
@MainActor protocol AgentNotifying: AnyObject {
  func permission() async -> AgentNotificationPermission
  /// Asks macOS once; only called when the person turns the option on.
  func requestPermission() async -> AgentNotificationPermission
  func post(agentName: String, sender: String, subject: String, mailID: String, account: String)
}

extension AgentNotifying {
  static func body(sender: String, subject: String) -> String {
    [sender, subject.isEmpty ? "(No subject)" : subject].filter { !$0.isEmpty }.joined(separator: " · ")
  }
}

@MainActor final class SystemAgentNotifier: NSObject, AgentNotifying, UNUserNotificationCenterDelegate {
  static let shared = SystemAgentNotifier()
  /// Opens the email for a clicked notification. Set by the app's store.
  var open: ((_ mailID: String, _ account: String) -> Void)?
  private var installed = false

  /// UNUserNotificationCenter requires a real app bundle; command-line tests and `swift run` have none.
  private var center: UNUserNotificationCenter? {
    guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return nil }
    let center = UNUserNotificationCenter.current()
    if !installed { center.delegate = self; installed = true }
    return center
  }
  func install() { _ = center }

  func permission() async -> AgentNotificationPermission {
    guard let center else { return .unavailable }
    let settings = await center.notificationSettings()
    return Self.permission(settings.authorizationStatus)
  }
  func requestPermission() async -> AgentNotificationPermission {
    guard let center else { return .unavailable }
    if await permission() == .notDetermined {
      _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }
    return await permission()
  }
  func post(agentName: String, sender: String, subject: String, mailID: String, account: String) {
    guard let center else { return }
    let content = UNMutableNotificationContent()
    content.title = agentName
    content.body = Self.body(sender: sender, subject: subject)
    content.sound = .default
    content.userInfo = ["coveMailID": mailID, "coveAccount": account]
    content.threadIdentifier = "cove-agent"
    center.add(UNNotificationRequest(identifier: "cove-agent-" + mailID, content: content, trigger: nil))
  }
  private static func permission(_ status: UNAuthorizationStatus) -> AgentNotificationPermission {
    switch status {
    case .authorized, .provisional: .allowed
    case .denied: .denied
    case .notDetermined: .notDetermined
    @unknown default: .denied
    }
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
  }
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    let info = response.notification.request.content.userInfo
    guard let mailID = info["coveMailID"] as? String, let account = info["coveAccount"] as? String else { return }
    await MainActor.run {
      // The person clicked the notification, so bringing Cove forward is expected here.
      CoveAppDelegate.showMainWindow(in: CoveAppDelegate.mainWindows.allObjects)
      open?(mailID, account)
    }
  }
}
