import CoveCore
import Foundation
import SwiftUI

struct ConnectionIssue: Identifiable {
  let id = UUID()
  let operation: String
  let offline: Bool
  var title: String { offline ? "You’re offline" : "Connection issue" }
  var detail: String {
    offline ? "Cove can’t connect to the internet. Your downloaded mail is still available."
      : "Cove couldn’t reach the server. Your downloaded mail is still available."
  }
  var canRetryMailSync: Bool { operation == "Syncing Gmail…" }

  init?(_ error: Error, operation: String) {
    var current = error as NSError
    for _ in 0..<5 {
      if current.domain == NSURLErrorDomain {
        let code = URLError.Code(rawValue: current.code)
        guard [.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
               .networkConnectionLost, .timedOut, .dataNotAllowed, .internationalRoamingOff].contains(code) else { return nil }
        self.operation = operation
        offline = code == .notConnectedToInternet
        return
      }
      guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { return nil }
      current = underlying
    }
    return nil
  }
}

extension AppStore {
  func reportFailure(_ failure: Error, operation: String, message: String? = nil) {
    if let issue = ConnectionIssue(failure, operation: operation) {
      connectionIssue = issue
    } else {
      error = message ?? failure.localizedDescription
    }
  }
  func connectionRecovered(operation: String, issueID: UUID?) {
    guard let issueID, connectionIssue?.id == issueID, connectionIssue?.operation == operation else { return }
    connectionIssue = nil
  }
}

struct ConnectionStatusTag: View {
  @Bindable var store: AppStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var details = false
  var body: some View {
    Group {
      if let issue = store.connectionIssue {
        Button { details.toggle() } label: {
          Label(issue.title, systemImage: "wifi.slash")
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
              Text(issue.operation.replacingOccurrences(of: "…", with: "") + " didn’t finish.")
                .foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
              if issue.canRetryMailSync {
                Text(store.backgroundSyncEnabled ? "Cove will retry during its next mail check." : "Background sync is paused. Retry when you’re ready.").foregroundStyle(Palette.body)
                Button(store.busy ? "Working…" : "Retry sync") { Task { await store.sync() } }
                  .buttonStyle(SecondaryButton()).disabled(store.busy || !store.entered || !store.queuedTrashIDs.isEmpty)
              } else {
                Text(issue.operation == "Marking email as read…" ? "Open the email again to retry when your connection is restored." : "Try the action again when your connection is restored.").foregroundStyle(Palette.body)
              }
              Button("Dismiss") { if store.connectionIssue?.id == issue.id { store.connectionIssue = nil }; details = false }
                .buttonStyle(.plain).font(.coveControl)
            }.font(.coveSecondary).foregroundStyle(Palette.ink).padding(18).frame(width: 300)
          }
          .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
      }
    }.animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: store.connectionIssue != nil)
      .onChange(of: store.connectionIssue == nil) { _, cleared in if cleared { details = false } }
  }
}
