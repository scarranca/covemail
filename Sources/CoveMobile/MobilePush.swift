#if os(iOS)
import CoveCore
import Foundation
import Observation
import BackgroundTasks
import UIKit
import UserNotifications

/// New-mail notifications (docs/IOS.md → Notifications).
///
/// 1. This device asks Gmail to report Inbox changes to Cove's Pub/Sub topic (`GmailPush.watch`, with
///    its own token; renewed before the week-long watch expires).
/// 2. It registers its APNs token with Cove's server, which verifies the Google ID token.
/// 3. Gmail → Pub/Sub → Cove's server → a content-free push → the notification extension reads the
///    new email here and shows "Sender · Subject".
/// Cove's server never receives a Gmail credential or mail content.
@MainActor @Observable public final class MobilePush: NSObject {
  public static let shared = MobilePush()
  static let server = URL(string: "https://cove-sync-api-1079898814598.us-east1.run.app")!
  private let settings = PushSettings.shared

  private(set) var authorization: UNAuthorizationStatus = .notDetermined
  private(set) var working = false
  private(set) var status: String?
  var error: String?
  /// An email chosen from a notification, for the app to open.
  var openMailID: String?
  /// Set when the saved sign-in predates `openid email`; a new sign-in grants it.
  private(set) var needsSignIn = false

  @ObservationIgnored weak var auth: MobileAuth?
  @ObservationIgnored private var deviceToken: String?
  @ObservationIgnored private var tokenWaiters: [CheckedContinuation<String, Error>] = []

  var enabled: Bool { settings.enabled }
  var scope: NewMailAlert.Scope {
    get { settings.scope }
    set { settings.scope = newValue; status = nil }
  }
  var showPreview: Bool {
    get { settings.showPreview }
    set { settings.showPreview = newValue; status = nil }
  }

  private static var deviceID: String {
    let defaults = UserDefaults(suiteName: PushSettings.appGroup) ?? .standard
    if let id = defaults.string(forKey: "push.deviceID") { return id }
    let id = UUID().uuidString.lowercased()
    defaults.set(id, forKey: "push.deviceID")
    return id
  }

  private static var environment: String {
    #if DEBUG
    "sandbox"
    #else
    "production"
    #endif
  }

  // MARK: Setup

  func configure(auth: MobileAuth) {
    self.auth = auth
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    let open = UNNotificationAction(identifier: "open", title: "Open", options: [.foreground])
    let archive = UNNotificationAction(identifier: "archive", title: "Archive", options: [])
    let read = UNNotificationAction(identifier: "read", title: "Mark as read", options: [])
    let flag = UNNotificationAction(identifier: "flag", title: "Flag", options: [])
    center.setNotificationCategories([UNNotificationCategory(identifier: "cove.new-mail", actions: [archive, read, flag, open],
                                                             intentIdentifiers: [], options: [])])
    Task { await refreshAuthorization() }
    #if DEBUG
    // Simulator check of the notification extension: quiet (provisional) permission needs no prompt.
    if ProcessInfo.processInfo.arguments.contains("-CovePushSample") {
      settings.enabled = true
      settings.sample = true
      settings.accountEmail = auth.email
      Task {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .provisional])
        // The sandbox token, for sending this simulator a real APNs push during checks.
        if let token = try? await registeredDeviceToken() { NSLog("CovePushToken %@", token) }
      }
    }
    #endif
  }

  func refreshAuthorization() async {
    authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
  }

  /// Turns notifications on: permission, device registration, then Gmail's watch.
  func turnOn() async {
    guard let auth, let email = auth.email, !working else { return }
    working = true
    error = nil
    defer { working = false }
    do {
      let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
      await refreshAuthorization()
      guard granted else {
        error = "Notifications are off for Cove in iOS Settings. Turn them on there, then try again."
        return
      }
      if auth.isSample {
        settings.enabled = true
        settings.accountEmail = email
        settings.sample = true
        status = "Sample mailbox: notifications show a sample email."
        return
      }
      guard let identity = try await auth.identityToken() else {
        needsSignIn = true
        error = "Sign in once more so Cove's server can recognize this device. Nothing else changes."
        return
      }
      needsSignIn = false
      status = "Registering this device…"
      let device = try await registeredDeviceToken()
      try await register(device: device, identity: identity)
      status = "Asking Gmail to report new mail…"
      settings.accountEmail = email
      settings.sample = false
      try await renewWatch(force: true)
      settings.enabled = true
      status = "On. New mail arrives here within seconds."
    } catch {
      self.error = "Couldn’t turn on notifications. " + error.localizedDescription
      status = nil
    }
  }

  /// Turns notifications off: this device is forgotten by the server and Gmail stops reporting.
  func turnOff() async {
    guard let auth else { return }
    working = true
    defer { working = false }
    settings.enabled = false
    status = nil
    error = nil
    if !auth.isSample {
      if let identity = try? await auth.identityToken() {
        var request = URLRequest(url: Self.server.appending(path: "v1/push/devices/\(Self.deviceID)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(identity)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: request)
      }
      if let token = try? await auth.token() { try? await GmailPush.stop(token: token) }
    }
    settings.reset()
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: MobileWatchRefresh.identifier)
    UNUserNotificationCenter.current().removeAllDeliveredNotifications()
  }

  /// When Cove becomes active: keep the device token current and renew Gmail's watch in time.
  func appBecameActive() async {
    await refreshAuthorization()
    guard settings.enabled, let auth, !auth.isSample, auth.email == settings.accountEmail else { return }
    do {
      if let identity = try await auth.identityToken() {
        try await register(device: try await registeredDeviceToken(), identity: identity)
      }
      try await renewWatch(force: false)
    } catch {
      status = "Notifications will reconnect when Cove is online."
    }
  }

  /// The signed-in account changed or signed out: stop notifying for the old one.
  func accountChanged(to email: String?) async {
    guard settings.enabled, settings.accountEmail != email else { return }
    await turnOff()
  }

  private func renewWatch(force: Bool) async throws {
    guard let auth else { return }
    if force {
      let watch = try await GmailPush.watch(token: try await auth.token())
      settings.watchExpires = watch.expires
      settings.cursor = watch.historyId
    } else {
      try await GmailPush.renewIfNeeded(token: try await auth.token(), settings: settings)
    }
    MobileWatchRefresh.schedule()
  }

  /// When Gmail's watch is due, in words for Settings.
  var watchSummary: String? {
    guard settings.enabled, let expires = settings.watchExpires else { return nil }
    return "Gmail’s link renews itself before \(expires.formatted(.dateTime.weekday(.wide).hour().minute()))."
  }

  private func register(device: String, identity: String) async throws {
    var request = URLRequest(url: Self.server.appending(path: "v1/push/devices/\(Self.deviceID)"))
    request.httpMethod = "PUT"
    request.timeoutInterval = 20
    request.setValue("Bearer \(identity)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["token": device, "environment": Self.environment])
    let (data, response) = try await URLSession.shared.data(for: request)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else {
      let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
      switch reason {
      case "authentication_required": throw CoveError.message("Cove's server didn't accept this sign-in. This account must be in the private beta.")
      case "push_device_limit": throw CoveError.message("Too many devices are registered. Turn notifications off on one of them.")
      default: throw CoveError.message("Cove's server answered \(code).")
      }
    }
  }

  // MARK: APNs token

  private func registeredDeviceToken() async throws -> String {
    if let deviceToken { return deviceToken }
    // iOS normally answers within a second; without a network it may never call back.
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(20))
      self?.didFailToRegister(CoveError.message("no answer from Apple — check the connection"))
    }
    return try await withCheckedThrowingContinuation { continuation in
      tokenWaiters.append(continuation)
      UIApplication.shared.registerForRemoteNotifications()
    }
  }

  func didRegister(deviceToken data: Data) {
    let token = data.map { String(format: "%02x", $0) }.joined()
    deviceToken = token
    let waiters = tokenWaiters
    tokenWaiters = []
    waiters.forEach { $0.resume(returning: token) }
  }

  func didFailToRegister(_ failure: Error) {
    let waiters = tokenWaiters
    tokenWaiters = []
    waiters.forEach { $0.resume(throwing: CoveError.message("iOS couldn't register for notifications: \(failure.localizedDescription)")) }
  }

  // MARK: Senders

  func mute(_ email: String) {
    let address = ContactDirectory.normalizedEmail(email)
    settings.muted.insert(address)
    settings.alwaysNotify.remove(address)
  }
  func alwaysNotify(_ email: String) {
    let address = ContactDirectory.normalizedEmail(email)
    settings.alwaysNotify.insert(address)
    settings.muted.remove(address)
  }
  func resetSender(_ email: String) {
    let address = ContactDirectory.normalizedEmail(email)
    settings.muted.remove(address)
    settings.alwaysNotify.remove(address)
  }
  func rule(for email: String) -> String? {
    let address = ContactDirectory.normalizedEmail(email)
    if settings.muted.contains(address) { return "muted" }
    if settings.alwaysNotify.contains(address) { return "always" }
    return nil
  }

  /// Opening an email clears its notification.
  func clearNotification(for mailID: String) {
    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [mailID])
    UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
      let ids = delivered.filter { ($0.request.content.userInfo["mailID"] as? String) == mailID }.map(\.request.identifier)
      UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }
  }
}

extension MobilePush: UNUserNotificationCenterDelegate {
  // Completion-handler forms, finished on the main thread: with the async forms iOS runs the hidden
  // completion off the main thread, and UIKit aborts (TestFlight build 13 crashed on a notification tap).

  /// While Cove is open, new mail still shows as a banner (the list may be on another folder).
  nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                                 withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
    let options: UNNotificationPresentationOptions = notification.request.content.interruptionLevel == .passive ? [] : [.banner, .list, .sound]
    DispatchQueue.main.async { completionHandler(options) }
  }

  nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                                 withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
    guard let mailID = response.notification.request.content.userInfo["mailID"] as? String else {
      DispatchQueue.main.async { completionHandler() }
      return
    }
    let action = response.actionIdentifier
    Task { @MainActor in
      switch action {
      case "archive", "read", "flag":
        // Done without opening Cove: the same label change the app makes, straight to Gmail.
        let (add, remove): ([String], [String]) = action == "archive" ? ([], ["INBOX"]) : action == "read" ? ([], ["UNREAD"]) : (["STARRED"], [])
        do {
          let token = try await MobilePushActions.accessToken()
          try await GmailClient().modify(id: mailID, token: token, add: add, remove: remove)
        } catch {}
      default:
        MobilePush.shared.openMailID = mailID
      }
      completionHandler()
    }
  }
}

/// Background App Refresh: iOS wakes Cove now and then (about twice a day when used) to renew Gmail's
/// watch, so notifications keep working through a week with no new mail and the app never opened.
public enum MobileWatchRefresh {
  static let identifier = "ai.cove.ios.watch-refresh"

  static func register() {
    BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
      guard let task = task as? BGAppRefreshTask else { return }
      schedule()
      let work = Task {
        let settings = PushSettings.shared
        do {
          if settings.enabled, !settings.sample, GmailPush.needsRenewal(expires: settings.watchExpires) {
            try await GmailPush.renewIfNeeded(token: try await MobilePushActions.accessToken(), settings: settings)
          }
          task.setTaskCompleted(success: true)
        } catch {
          task.setTaskCompleted(success: false)
        }
      }
      task.expirationHandler = { work.cancel() }
    }
  }

  /// Asks iOS for the next refresh in about twelve hours (iOS decides the actual time).
  static func schedule() {
    guard PushSettings.shared.enabled else { return }
    let request = BGAppRefreshTaskRequest(identifier: identifier)
    request.earliestBeginDate = Date().addingTimeInterval(12 * 3600)
    try? BGTaskScheduler.shared.submit(request)
  }
}

/// Notification actions can run while Cove isn't open, so they read the saved session directly.
enum MobilePushActions {
  static func accessToken() async throws -> String {
    guard let saved = try MobileKeychain.read(MobileAuth.sessionKey),
          let session = try? JSONDecoder().decode(GoogleAccountSession.self, from: Data(saved.utf8))
    else { throw CoveError.message("Sign in with Google to continue.") }
    return try await GoogleTokenClient().refresh(refreshToken: session.refreshToken, clientID: session.clientID, secret: "").access_token
  }
}

/// The app delegate the iPhone shell installs (`@UIApplicationDelegateAdaptor`) for APNs callbacks.
public final class CoveAppDelegate: NSObject, UIApplicationDelegate {
  /// The notification delegate is set at launch, so tapping a notification that opened Cove is handled.
  public func application(_ application: UIApplication,
                          didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    MainActor.assumeIsolated { UNUserNotificationCenter.current().delegate = MobilePush.shared }
    MobileWatchRefresh.register()
    return true
  }
  public func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    MainActor.assumeIsolated { MobilePush.shared.didRegister(deviceToken: deviceToken) }
  }
  public func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    MainActor.assumeIsolated { MobilePush.shared.didFailToRegister(error) }
  }
}
#endif
