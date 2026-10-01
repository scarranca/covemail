import AppKit
import CoveCore
import SwiftUI
import XCTest
@testable import Cove

@MainActor final class InboxSplitStoreTests: XCTestCase {
  private var directories: [URL] = []
  override func tearDown() { directories.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown() }

  private func store(_ mails: [Mail]) throws -> AppStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CoveSplit-" + UUID().uuidString)
    directories.append(dir)
    let store = try AppStore(database: Database(url: dir.appendingPathComponent("mail.sqlite")), accountEmail: "me@example.com",
      gmail: GmailClient(), gmailTokenProvider: { "x" }, syncClock: Date.init)
    store.isSample = true; store.screen = "mail"
    store.mails = mails
    store.chooseFolder("Inbox")
    return store
  }
  private static func fixture() -> [Mail] {
    let now = Date()
    return [
      Mail(id: "maya", sender: "Maya Chen", senderEmail: "maya@example.com", subject: "Final designs for Thursday",
        body: "Can you review the final designs before our call?", date: now, labels: ["INBOX", "UNREAD"], isBulkOrAutomated: false),
      Mail(id: "sam", sender: "Sam Ortiz", senderEmail: "sam@example.com", subject: "Budget notes",
        body: "Here are my notes on the budget.", date: now.addingTimeInterval(-600), labels: ["INBOX"], isBulkOrAutomated: false),
      Mail(id: "digest", sender: "Design Weekly", senderEmail: "digest@designweekly.com", subject: "This week in type",
        body: "Five new typefaces worth a look.", date: now.addingTimeInterval(-1200), labels: ["INBOX", "UNREAD"],
        decision: Decision(category: .newsletters, confidence: 0.9, needsReply: 0, urgent: 0, model: "t"), isBulkOrAutomated: true),
      Mail(id: "github", sender: "GitHub", senderEmail: "notifications@github.com", subject: "[cove] New comment on #412",
        body: "A new comment was posted.", date: now.addingTimeInterval(-1800), labels: ["INBOX", "UNREAD"]),
      Mail(id: "receipt", sender: "Shop", senderEmail: "orders@shop.com", subject: "Your receipt",
        body: "Thanks for your order.", date: now.addingTimeInterval(-2400), labels: ["INBOX"], isBulkOrAutomated: true),
    ]
  }

  func testTabsSplitTheInboxAndUnreadComposesWithEither() throws {
    let store = try store(Self.fixture())
    XCTAssertEqual(store.inboxTab, .important)
    XCTAssertEqual(store.visible.map(\.id), ["maya", "sam"])
    XCTAssertEqual(store.inboxUnreadCounts, [.important: 1, .other: 2])
    XCTAssertEqual(store.inboxBadgeCount, 1, "the sidebar counts unread Important mail, not every Inbox email")
    store.labelUnreadOnly = true
    XCTAssertEqual(store.visible.map(\.id), ["maya"])
    store.chooseInboxTab(.other)
    XCTAssertEqual(store.visible.map(\.id), ["digest", "github"])
    store.labelUnreadOnly = false
    XCTAssertEqual(store.visible.map(\.id), ["digest", "github", "receipt"])
    // Search looks through both tabs.
    store.search = "budget"
    XCTAssertEqual(store.visible.map(\.id), ["sam"])
    store.search = ""
    // Home's Needs attention filter spans both tabs.
    store.priorityOnly = true
    XCTAssertNil(store.effectiveInboxTab)
    store.chooseInboxTab(.important)
    XCTAssertFalse(store.priorityOnly)
    // Other folders are never split.
    store.chooseFolder("All mail")
    XCTAssertEqual(store.visible.count, 5)
  }

  func testTurningTheSplitOffShowsEverythingAndPersists() throws {
    let store = try store(Self.fixture())
    store.setSplitInbox(false)
    XCTAssertEqual(store.visible.map(\.id), ["maya", "sam", "digest", "github", "receipt"])
    XCTAssertEqual(store.inboxUnreadCount, 3)
    store.labelUnreadOnly = true
    XCTAssertEqual(store.visible.map(\.id), ["maya", "digest", "github"])
    XCTAssertFalse(store.preferences.splitsInbox)
    store.setSplitInbox(true)
    store.labelUnreadOnly = false
    XCTAssertEqual(store.visible.map(\.id), ["maya", "sam"])
  }

  func testVoteOverridesImmediatelyAndUndoRestores() throws {
    let store = try store(Self.fixture())
    let digest = try XCTUnwrap(store.mails.first { $0.id == "digest" })
    store.moveToInboxTab(digest, .important)
    XCTAssertEqual(store.visible.map(\.id), ["maya", "sam", "digest"])
    XCTAssertEqual(store.inboxUnreadCounts, [.important: 2, .other: 1])
    XCTAssertEqual(store.inboxMoveUndo?.message, "Moved to Important")
    store.undoInboxMove()
    XCTAssertNil(store.inboxMoveUndo)
    XCTAssertNil(store.mails.first { $0.id == "digest" }?.inboxVote)
    XCTAssertEqual(store.visible.map(\.id), ["maya", "sam"])
    // Moving the open email keeps it listed until selection moves on, like marking it read.
    let sam = try XCTUnwrap(store.mails.first { $0.id == "sam" })
    store.select(sam)
    store.moveToInboxTab(sam, .other)
    XCTAssertTrue(store.visible.contains { $0.id == "sam" })
    store.selectedID = nil
    XCTAssertEqual(store.visible.map(\.id), ["maya"])
    store.chooseInboxTab(.other)
    XCTAssertEqual(store.visible.first?.id, "sam")
  }

  func testSenderRuleAppliesToNewMailFromThatSenderAndUndoes() throws {
    let store = try store(Self.fixture())
    let github = try XCTUnwrap(store.mails.first { $0.id == "github" })
    // An earlier conflicting vote on one of the sender's emails yields to the newer sender choice.
    store.moveToInboxTab(github, .other)
    store.alwaysInboxTab(.important, forSenderOf: github)
    XCTAssertEqual(store.preferences.inboxSenderRules, ["notifications@github.com": .important])
    XCTAssertNil(store.mails.first { $0.id == "github" }?.inboxVote)
    XCTAssertTrue(store.visible.contains { $0.id == "github" })
    store.mails.insert(Mail(id: "github-2", sender: "GitHub", senderEmail: "Notifications@GitHub.com",
      subject: "[cove] Review requested", body: "Please review.", labels: ["INBOX", "UNREAD"], isBulkOrAutomated: true), at: 0)
    XCTAssertEqual(store.visible.first?.id, "github-2")
    XCTAssertEqual(store.inboxUnreadCounts[.important], 3)
    store.undoInboxMove()
    XCTAssertNil(store.preferences.inboxSenderRules)
    XCTAssertEqual(store.mails.first { $0.id == "github" }?.inboxVote, .other)
    XCTAssertEqual(store.visible.map(\.id), ["maya", "sam"])
  }

  func testTabSwitchIsMemoizedAndFastOnFiveThousandEmails() throws {
    let mails: [Mail] = (0..<5_000).map { (index: Int) -> Mail in
      let address: String = index % 3 == 0 ? "no-reply@s\(index % 300).com" : "s\(index % 300)@example.com"
      let labels: Set<String> = index % 2 == 0 ? ["INBOX", "UNREAD"] : ["INBOX"]
      return Mail(id: "m\(index)", sender: "Sender \(index % 300)", senderEmail: address,
        subject: "Subject number \(index)", body: String(repeating: "Lorem ipsum dolor sit amet. ", count: 40),
        date: Date(timeIntervalSince1970: Double(index)), labels: labels, isBulkOrAutomated: index % 5 == 0)
    }
    let store = try store(mails)
    store.preferences.inboxSenderRules = ["s7@example.com": InboxSplit.other]
    _ = store.visible; _ = store.inboxUnreadCounts
    var timings: [String] = []
    for tab in [InboxSplit.other, .important, .other] {
      let before = store.visibleComputations
      let start = CFAbsoluteTimeGetCurrent()
      store.chooseInboxTab(tab)
      let first = store.visible
      for _ in 0..<5 { XCTAssertEqual(store.visible.count, first.count); _ = store.inboxUnreadCounts }
      let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
      XCTAssertEqual(store.visibleComputations - before, 1, "one filter pass per tab switch")
      XCTAssertLessThan(ms, 250, "tab switch should feel instant")
      timings.append("\(tab.title) \(first.count) \(String(format: "%.1f", ms)) ms")
    }
    print("TAB SWITCH TIMINGS (6 reads each): " + timings.joined(separator: " · "))
    // Typing still narrows the cached list with a tab in the key.
    store.search = "subject"
    _ = store.visible
    let before = store.visibleComputations
    store.search = "subject number"
    _ = store.visible; _ = store.visible
    XCTAssertEqual(store.visibleComputations - before, 1)
  }

  func testInboxTabsRender() async throws {
    _ = NSApplication.shared; DesignAssets.registerFonts()
    let store = try store(Self.fixture())
    for (name, tab, unread) in [("important", InboxSplit.important, false), ("other-unread", .other, true)] {
      store.chooseInboxTab(tab); store.labelUnreadOnly = unread
      let host = NSHostingView(rootView: MailboxView(store: store).foregroundStyle(Palette.ink))
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; window.contentView = host
      for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-mail-tabs-\(name).png"))
      window.close()
    }
    store.labelUnreadOnly = false
    store.chooseInboxTab(.important)
    // Realistic three-digit counts must still fit the 300 pt list column.
    store.mails += (0..<150).map { Mail(id: "bulk-\($0)", sender: "Deals", senderEmail: "deals@shop.com", subject: "Offer \($0)",
      body: "Sale", date: Date().addingTimeInterval(Double(-4000 - $0)), labels: ["INBOX", "UNREAD"], isBulkOrAutomated: true) }
    store.mails += (0..<120).map { Mail(id: "person-\($0)", sender: "Colleague \($0)", senderEmail: "c\($0)@example.com", subject: "Note \($0)",
      body: "Hi", date: Date().addingTimeInterval(Double(-9000 - $0)), labels: ["INBOX", "UNREAD"], isBulkOrAutomated: false) }
    XCTAssertEqual(store.inboxUnreadCounts[.other], 152)
    store.moveToInboxTab(store.mails[1], .other)
    let host = NSHostingView(rootView: MailboxView(store: store).foregroundStyle(Palette.ink))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-mail-tabs-undo.png"))
    window.close()
    store.setSplitInbox(false)
    let off = NSHostingView(rootView: MailboxView(store: store).foregroundStyle(Palette.ink))
    let offWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
    offWindow.isReleasedWhenClosed = false; offWindow.contentView = off
    for _ in 0..<5 { off.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    let offBitmap = try XCTUnwrap(off.bitmapImageRepForCachingDisplay(in: off.bounds)); off.cacheDisplay(in: off.bounds, to: offBitmap)
    try XCTUnwrap(offBitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-mail-tabs-off.png"))
    offWindow.close()
  }
}
