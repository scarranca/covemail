import CoveCore
import Foundation
import SwiftUI

struct ConnectionIssue: Identifiable {
  let id = UUID()
  let operation: String
  let offline: Bool
  /// Gmail itself failed (a server error on a write, which is never retried automatically).
  var gmailFailed = false
  var title: String { offline ? "You’re offline" : gmailFailed ? "Gmail had a problem" : "Connection issue" }
  var detail: String {
    offline ? "Cove can’t connect to the internet. Your downloaded mail is still available."
      : gmailFailed ? "Gmail couldn’t take a change, so that email is back as it was. Your downloaded mail is still available."
      : "Cove couldn’t reach the server. Your downloaded mail is still available."
  }
  var canRetryMailSync: Bool { operation == "Syncing Gmail…" }
  /// Network failures worth waiting out: the request never got an answer, so trying again is harmless.
  static let transientCodes: [URLError.Code] = [
    .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
    .networkConnectionLost, .timedOut, .dataNotAllowed, .internationalRoamingOff,
    .cannotLoadFromNetwork, .callIsActive,
  ]

  init?(_ error: Error, operation: String) {
    var current = error as NSError
    for _ in 0..<5 {
      if current.domain == NSURLErrorDomain {
        let code = URLError.Code(rawValue: current.code)
        guard Self.transientCodes.contains(code) else { return nil }
        self.operation = operation
        offline = code == .notConnectedToInternet
        return
      }
      guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { return nil }
      current = underlying
    }
    return nil
  }
  init(offline: Bool, operation: String) {
    self.operation = operation
    self.offline = offline
  }
  init(gmailError operation: String) {
    self.operation = operation
    offline = false
    gmailFailed = true
  }
}

/// Google no longer accepts Cove's sign-in for this account (revoked, expired, or the session is gone).
/// Shown once as a persistent "Sign in again" tag (`AppStore.googleSignInNeeded`), never as repeated alerts.
struct GoogleSignInRequired: LocalizedError {
  var email: String
  var errorDescription: String? {
    "Google needs you to sign in to \(email.isEmpty ? "your account" : email) again before Cove can reach Gmail."
  }
  /// Errors from getting a token. Only Google refusing the refresh (invalid_grant is a 400 from the token
  /// endpoint, a deleted client a 401) or a missing or mismatched session mean "sign in again". Network
  /// trouble, rate limits, Google's server errors, a locked Keychain and a switch in progress stay
  /// what they are: they pass by themselves.
  static func classify(_ error: Error, email: String) -> Error {
    if let http = error as? HTTPFailure, !http.isRateLimited, [400, 401, 403].contains(http.statusCode) {
      return GoogleSignInRequired(email: email)
    }
    let text = error.localizedDescription
    if error is CoveError, text.hasPrefix("Connect Gmail to continue") || text.hasPrefix("Sign in to ")
      || text.contains("does not match this mailbox") {
      return GoogleSignInRequired(email: email)
    }
    return error
  }
}

extension AppStore {
  func reportFailure(_ failure: Error, operation: String, message: String? = nil) {
    // Gmail slowing Cove down is temporary and not the user's doing: a quiet status, never an alert.
    if let http = failure as? HTTPFailure, http.isRateLimited { return }
    if failure is GoogleSignInRequired { googleSignInNeeded = true }
    if let issue = ConnectionIssue(failure, operation: operation) {
      connectionIssue = issue
    } else {
      error = message ?? failure.localizedDescription
    }
  }
  /// For work the user didn't ask for just now (the two-minute mail check, a continuation, an older
  /// page): the tag and the status line, never an alert. A failure that repeats changes nothing, so
  /// an offline Mac or a revoked sign-in doesn't flicker or nag every two minutes.
  func reportBackgroundFailure(_ failure: Error, operation: String) {
    if let http = failure as? HTTPFailure, http.isRateLimited { return }
    if failure is GoogleSignInRequired {
      if !googleSignInNeeded { googleSignInNeeded = true }
      return
    }
    if let issue = ConnectionIssue(failure, operation: operation) {
      if let current = connectionIssue, current.operation == issue.operation, current.offline == issue.offline { return }
      connectionIssue = issue
    }
  }
  func connectionRecovered(operation: String, issueID: UUID?) {
    guard let issueID, connectionIssue?.id == issueID, connectionIssue?.operation == operation else { return }
    connectionIssue = nil
    // The connection is back: label changes waiting offline go now rather than at their next retry.
    if !labelQueue.isEmpty { retryQueuedLabelChanges() }
  }
  /// A Gmail request just succeeded, so a connection tag that was already showing when it started
  /// (from any mail operation) is out of date. A newer tag, or Gmail's own failure, stays.
  func gmailReached(since issueID: UUID?) {
    guard let issue = connectionIssue, issue.id == issueID, !issue.gmailFailed else { return }
    connectionIssue = nil
    if !labelQueue.isEmpty { retryQueuedLabelChanges() }
  }
  /// Signs in to the open account again (after `googleSignInNeeded`); its mailbox and waiting changes stay.
  func signInAgain() async {
    await connect(includeCalendar: calendarConnected)
  }
}

struct ConnectionStatusTag: View {
  @Bindable var store: AppStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var details = false
  private var waitingNote: String? {
    let count = store.pendingLabelChanges
    guard count > 0 else { return nil }
    return count == 1 ? "1 change will reach Gmail when it can." : "\(count) changes will reach Gmail when they can."
  }
  var body: some View {
    Group {
      if store.googleSignInNeeded && !store.isSample {
        Button { details.toggle() } label: {
          Label("Sign in to Google again", systemImage: "person.crop.circle.badge.exclamationmark")
            .font(.coveControl).foregroundStyle(Palette.body)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Palette.sidebar, in: Capsule())
            .overlay(Capsule().stroke(Palette.line))
        }.buttonStyle(.plain).help("Google needs you to sign in again · click for details")
          .accessibilityLabel("Google needs you to sign in again. Show details")
          .popover(isPresented: $details, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
              Text("Sign in to Google again").font(.coveSubheading)
              Text("Google no longer accepts Cove’s sign-in for \(store.accountEmail). Your downloaded mail is still here; new mail and your changes wait until you sign in.")
                .fixedSize(horizontal: false, vertical: true)
              if let waitingNote { Text(waitingNote).foregroundStyle(Palette.body) }
              Button(store.busy ? "Working…" : "Sign in again") { details = false; Task { await store.signInAgain() } }
                .buttonStyle(SecondaryButton()).disabled(store.busy)
            }.font(.coveSecondary).foregroundStyle(Palette.ink).padding(18).frame(width: 300)
          }
          .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
      } else if let issue = store.connectionIssue {
        Button { details.toggle() } label: {
          Label(issue.title, systemImage: issue.gmailFailed ? "exclamationmark.icloud" : "wifi.slash")
            .font(.coveControl).foregroundStyle(Palette.body)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Palette.sidebar, in: Capsule())
            .overlay(Capsule().stroke(Palette.line))
        }.buttonStyle(.plain).help("Connection status · click for details")
          .accessibilityLabel(issue.title + ". Show connection details")
          .popover(isPresented: $details, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
              Text(issue.title).font(.coveSubheading)
              Text(issue.detail).fixedSize(horizontal: false, vertical: true)
              if !issue.gmailFailed {
                Text(issue.operation.replacingOccurrences(of: "…", with: "") + " didn’t finish.")
                  .foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
              }
              if let waitingNote { Text(waitingNote).foregroundStyle(Palette.body) }
              if issue.canRetryMailSync || issue.gmailFailed {
                Text(store.backgroundSyncEnabled ? "Cove will retry during its next mail check." : "Background sync is paused. Retry when you’re ready.").foregroundStyle(Palette.body)
                Button(store.syncing ? "Working…" : "Retry sync") { Task { await store.sync() } }
                  .buttonStyle(SecondaryButton()).disabled(store.syncing || !store.entered || !store.queuedTrashIDs.isEmpty)
              } else if QueuedLabelChange.isQueueOperation(issue.operation) {
                Text("Your changes are kept and Cove sends them as soon as the connection is back.").foregroundStyle(Palette.body)
              } else {
                Text("Try the action again when your connection is restored.").foregroundStyle(Palette.body)
              }
              Button("Dismiss") { if store.connectionIssue?.id == issue.id { store.connectionIssue = nil }; details = false }
                .buttonStyle(.plain).font(.coveControl)
            }.font(.coveSecondary).foregroundStyle(Palette.ink).padding(18).frame(width: 300)
          }
          .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
      }
    }.animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: store.connectionIssue != nil || store.googleSignInNeeded)
      .onChange(of: store.connectionIssue == nil && !store.googleSignInNeeded) { _, cleared in if cleared { details = false } }
  }
}
