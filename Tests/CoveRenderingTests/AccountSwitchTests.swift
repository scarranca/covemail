import AppKit
import SwiftUI
import XCTest

@testable import Cove
@testable import CoveCore

/// One account at a time: switching settles the current account's Gmail work, then opens the other
/// account's local mailbox. Synthetic stores, an in-memory roster and no network or Keychain.
@MainActor final class AccountSwitchTests: XCTestCase {
  private var directories: [URL] = []
  private var databases: [String: Database] = [:]
  private var activated: [String] = []
  private var roster = ["first@example.com", "second@example.com"]
  private var failActivation = false

  override func tearDown() {
    for directory in directories { try? FileManager.default.removeItem(at: directory) }
    directories = []
    databases = [:]
    activated = []
    super.tearDown()
  }

  private func database(_ name: String) throws -> Database {
    if let existing = databases[name] { return existing }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    directories.append(directory)
    let database = try Database(url: directory.appendingPathComponent("mail.sqlite"))
    databases[name] = database
    return database
  }

  private func fixture(_ http: SwitchHTTP = SwitchHTTP()) throws -> AppStore {
    let first = try database("first@example.com")
    try first.saveMailSnapshot([
      Mail(id: "first-1", sender: "Mariana", senderEmail: "mariana@example.com", subject: "Plan",
           body: "First account mail", date: Date(), labels: ["INBOX"]),
    ])
    let second = try database("second@example.com")
    try second.saveMailSnapshot([
      Mail(id: "second-1", sender: "Priya", senderEmail: "priya@example.com", subject: "Invoice",
           body: "Second account mail", date: Date(), labels: ["INBOX", "UNREAD"]),
    ])
    let store = try AppStore(
      database: first, accountEmail: "first@example.com", gmail: GmailClient(transport: http),
      gmailTokenProvider: { "fixture-token" }, syncClock: Date.init, jevKeyProvider: { "" })
    store.accountsProvider = { [unowned self] in self.roster }
    store.mailboxDatabase = { [unowned self] name in try self.database(name) }
    store.activateAccount = { [unowned self] email in
      if self.failActivation { throw CoveError.message("Sign in to \(email) again.") }
      self.activated.append(email)
      return (calendar: email.hasPrefix("second"), tasks: false)
    }
    store.reloadAccounts()
    return store
  }

  func testRefusesWhileBusyAndChangesNothing() async throws {
    let store = try fixture()
    store.search = "plan"
    store.busy = true
    await store.switchAccount(to: "second@example.com")
    XCTAssertEqual(store.accountEmail, "first@example.com")
    XCTAssertEqual(store.mails.map(\.id), ["first-1"])
    XCTAssertEqual(store.search, "plan")
    XCTAssertEqual(store.status, "Finish the current action first")
    XCTAssertTrue(activated.isEmpty, "the session was never touched")
    XCTAssertFalse(store.switchingAccount)
  }

  func testSwitchOpensTheOtherMailboxAndClearsAccountState() async throws {
    let store = try fixture()
    XCTAssertEqual(store.accounts, roster)
    store.sendingAliases = ["first@example.com", "alias@example.com"]
    store.googleTasks = [GoogleTask(id: "t1", title: "Call Mariana")]
    store.search = "plan"
    store.selectedID = "first-1"
    store.replyRequestID = "first-1"
    await store.switchAccount(to: "SECOND@example.com")
    XCTAssertEqual(activated, ["second@example.com"])
    XCTAssertEqual(store.accountEmail, "second@example.com", "roster casing, not the argument's")
    XCTAssertTrue(store.entered)
    XCTAssertFalse(store.isSample)
    XCTAssertEqual(store.mails.map(\.id), ["second-1"])
    XCTAssertTrue(store.calendarConnected)
    XCTAssertFalse(store.tasksConnected)
    XCTAssertEqual(store.sendingAliases, [])
    XCTAssertTrue(store.googleTasks.isEmpty)
    XCTAssertEqual(store.search, "")
    XCTAssertNil(store.selectedID)
    XCTAssertNil(store.replyRequestID)
    XCTAssertNil(store.error)
    XCTAssertFalse(store.switchingAccount)

    // Already active: nothing happens.
    await store.switchAccount(to: "second@example.com")
    XCTAssertEqual(activated, ["second@example.com"])
    // Not signed in on this Mac: nothing happens.
    await store.switchAccount(to: "stranger@example.com")
    XCTAssertEqual(store.accountEmail, "second@example.com")
  }

  func testWaitsForARunningSyncAndGivesUpWhenItNeverEnds() async throws {
    let store = try fixture()
    store.syncing = true
    Task { @MainActor in try? await Task.sleep(for: .milliseconds(300)); store.syncing = false }
    await store.switchAccount(to: "second@example.com")
    XCTAssertEqual(store.accountEmail, "second@example.com", "switched once the sync finished")

    store.syncing = true
    let settled = await store.settleBeforeLeavingMailbox(timeout: .milliseconds(300))
    XCTAssertFalse(settled, "a sync that never ends doesn't switch later by surprise")
    XCTAssertTrue(store.status.contains("try again"))
    XCTAssertEqual(activated, ["second@example.com"])
  }

  func testFailedActivationKeepsTheCurrentAccount() async throws {
    let store = try fixture()
    failActivation = true
    await store.switchAccount(to: "second@example.com")
    XCTAssertEqual(store.accountEmail, "first@example.com")
    XCTAssertEqual(store.mails.map(\.id), ["first-1"])
    XCTAssertTrue(store.entered)
    XCTAssertTrue(store.error?.contains("Sign in") == true)
    XCTAssertTrue(store.status.contains("sign in again"))
  }

  func testPendingSendIsDeliveredForTheOldAccountBeforeSwitching() async throws {
    let http = SwitchHTTP()
    let store = try fixture(http)
    let mail = try XCTUnwrap(store.mails.first)
    store.queueSend(to: "mariana@example.com", subject: "Re: Plan", body: "Sounds good!", reply: mail)
    XCTAssertNotNil(store.pendingSend)
    await store.switchAccount(to: "second@example.com")

    let requests = await http.requests
    let sendIndex = try XCTUnwrap(requests.firstIndex { $0.url?.lastPathComponent == "send" },
      "the waiting email was sent instead of dropped")
    XCTAssertEqual(requests.filter { $0.url?.lastPathComponent == "send" }.count, 1)
    XCTAssertEqual(sendIndex, 0, "it went out before anything for the next account")
    XCTAssertNil(store.pendingSend)
    let firstMail = try XCTUnwrap(databases["first@example.com"]).loadMail()
    XCTAssertTrue(firstMail.contains { $0.labels.contains("SENT") && $0.body == "Sounds good!" },
      "saved as sent in the account it was written in")
    let secondMail = try XCTUnwrap(databases["second@example.com"]).loadMail()
    XCTAssertFalse(secondMail.contains { $0.labels.contains("SENT") })
    XCTAssertEqual(store.accountEmail, "second@example.com")

    // The undo window passing later must not send it again.
    try await Task.sleep(for: .seconds(AppStore.undoSendSeconds + 0.5))
    let after = await http.requests
    XCTAssertEqual(after.filter { $0.url?.lastPathComponent == "send" }.count, 1)
  }

  func testSignOutWithAnotherAccountOpensIt() async throws {
    let store = try fixture()
    let defaults = UserDefaults(suiteName: "Cove.AccountSwitchTests." + UUID().uuidString)!
    var items: [String: String] = [:]
    store.auth = GoogleAuth(storage: .init(
      read: { items[$0] }, save: { value, name in items[name] = value },
      delete: { items[$0] = nil }, defaults: defaults))
    for email in roster {
      AccountRoster.add(email, defaults)
      items[AccountRoster.sessionKey(for: email)] = String(decoding: try JSONEncoder().encode(
        GoogleAccountSession(email: email, clientID: "client", clientSecret: "fake-secret",
                             refreshToken: "fake-refresh-\(email)", calendarConnected: false)), as: UTF8.self)
    }
    defaults.set("first@example.com", forKey: "accountEmail")
    store.accountsProvider = nil  // read the in-memory roster through GoogleAuth
    store.reloadAccounts()
    XCTAssertEqual(store.accounts, roster)

    store.disconnect()
    XCTAssertEqual(store.accounts, ["second@example.com"])
    XCTAssertEqual(store.accountEmail, "second@example.com")
    XCTAssertTrue(store.entered)
    XCTAssertEqual(store.mails.map(\.id), ["second-1"])
    XCTAssertNil(items[AccountRoster.sessionKey(for: "first@example.com")])
    XCTAssertNotNil(items[AccountRoster.sessionKey(for: "second@example.com")])
  }

  func testSidebarAccountMenuLabelRendersOffscreen() async throws {
    _ = NSApplication.shared; DesignAssets.registerFonts()
    let store = try fixture()
    let host = NSHostingView(rootView: Sidebar(store: store).frame(width: 224, height: 420, alignment: .top))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 224, height: 420), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    for _ in 0..<6 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
    XCTAssertFalse(window.isVisible)
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      .write(to: URL(fileURLWithPath: "/tmp/cove-ui-account-switcher.png"))
  }
}

/// Gmail send succeeds; every other request is offline (a quiet connection issue, never an alert).
private actor SwitchHTTP: HTTPTransport {
  private(set) var requests: [URLRequest] = []

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    guard request.url?.lastPathComponent == "send" else { throw URLError(.notConnectedToInternet) }
    return (Data(#"{"id":"gmail-sent"}"#.utf8),
            try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 200,
                                          httpVersion: nil, headerFields: nil)))
  }
}
