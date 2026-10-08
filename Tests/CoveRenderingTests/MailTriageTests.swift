import AppKit
import CoveCore
import XCTest
@testable import Cove

/// Triage (0.1.69): one key acts on the open email or every chosen one, advances like E, and Z takes it back.
@MainActor final class MailTriageTests: XCTestCase {
  private var directories: [URL] = []
  override func tearDown() { directories.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown() }
  private func fixture(count: Int = 5) throws -> AppStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    directories.append(dir)
    let db = try Database(url: dir.appendingPathComponent("mail.sqlite"))
    let store = try AppStore(database: db, accountEmail: "me@example.com", gmail: GmailClient(), gmailTokenProvider: { "test" }, syncClock: Date.init)
    store.isSample = true; store.screen = "mail"; store.folder = "Inbox"; store.priorityOnly = false
    store.mails = (0..<count).map { index in
      Mail(id: "mail-\(index)", sender: "Maya Chen", senderEmail: "maya@example.com", subject: "Project update \(index)", body: "Everything is ready for Thursday.", date: Date().addingTimeInterval(Double(-index * 60)), labels: index % 2 == 0 ? ["INBOX", "UNREAD"] : ["INBOX"])
    }
    store.selectedID = nil
    return store
  }
  private func host(_ store: AppStore) -> (MailNavigationShortcut.ShortcutView, NSWindow) {
    let view = MailNavigationShortcut.ShortcutView(store: store)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = view
    return (view, window)
  }
  private func key(_ text: String, code: UInt16, window: NSWindow, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
  }
  private func wait(_ condition: () -> Bool) async throws {
    for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
  }
  private func inInbox(_ store: AppStore, _ id: String) -> Bool { store.mail(id: id)?.labels.contains("INBOX") == true }

  func testXOnThreeThenEArchivesAllWithOneUndoAndZRestoresAndReopens() async throws {
    _ = NSApplication.shared
    let store = try fixture()
    let (view, window) = host(store)
    defer { window.close() }
    let x = try key("x", code: 7, window: window), j = try key("j", code: 38, window: window)
    store.selectedID = "mail-1"
    XCTAssertNil(view.handle(x)); XCTAssertNil(view.handle(j))
    XCTAssertNil(view.handle(x)); XCTAssertNil(view.handle(j))
    XCTAssertNil(view.handle(x))
    XCTAssertEqual(store.selectedIDs, ["mail-1", "mail-2", "mail-3"]); XCTAssertEqual(store.selectedID, "mail-3")
    let computations = store.visibleComputations
    _ = store.visible
    XCTAssertEqual(store.visibleComputations, computations, "choosing emails never recomputes the list")

    XCTAssertNil(view.handle(try key("e", code: 14, window: window)))
    XCTAssertEqual(store.selectedID, "mail-4", "E advances past every archived email at once")
    XCTAssertTrue(store.selectedIDs.isEmpty)
    XCTAssertEqual(store.triageUndo?.message, "Archived · 3 emails")
    XCTAssertEqual(store.triageUndo?.reselect, "mail-3")
    try await wait { !["mail-1", "mail-2", "mail-3"].contains { inInbox(store, $0) } }
    for id in ["mail-1", "mail-2", "mail-3"] { XCTAssertFalse(inInbox(store, id), "\(id) archived") }
    XCTAssertTrue(inInbox(store, "mail-0")); XCTAssertTrue(inInbox(store, "mail-4"))
    XCTAssertEqual(store.visible.map(\.id), ["mail-0", "mail-4"])

    XCTAssertNil(view.handle(try key("z", code: 6, window: window)))
    try await wait { store.triageUndo == nil && store.selectedID == "mail-3" }
    for id in ["mail-1", "mail-2", "mail-3"] { XCTAssertTrue(inInbox(store, id), "Z brings \(id) back") }
    XCTAssertEqual(store.selectedID, "mail-3", "Z reopens the email that was open")
    XCTAssertNil(store.triageUndo)
    XCTAssertNotNil(view.handle(try key("z", code: 6, window: window)), "nothing left to undo: Z passes through")
  }

  func testEAtTheEndOpensTheEmailAboveAndShiftEMovesBack() async throws {
    _ = NSApplication.shared
    let store = try fixture(count: 3)
    let (view, window) = host(store)
    defer { window.close() }
    store.selectedID = "mail-2"
    XCTAssertNil(view.handle(try key("e", code: 14, window: window)))
    XCTAssertEqual(store.selectedID, "mail-1", "at the end, E opens the email above")
    try await wait { !inInbox(store, "mail-2") }
    store.folder = "Archive"
    XCTAssertNil(store.triageUndo, "a folder change drops the last Undo")
    store.selectedID = "mail-2"
    XCTAssertNil(view.handle(try key("E", code: 14, window: window, modifiers: .shift)))
    try await wait { inInbox(store, "mail-2") }
    XCTAssertTrue(inInbox(store, "mail-2"), "⇧E moves it back to the Inbox")
    XCTAssertEqual(store.triageUndo?.message, "Moved to Inbox")
    XCTAssertNotNil(view.handle(try key("E", code: 14, window: window, modifiers: .shift)), "already in the Inbox: nothing to do")
  }

  func testUndoReversesOnlyWhatChanged() async throws {
    let store = try fixture()
    // mail-0 is unread, mail-1 already read: marking both read changes only mail-0.
    await store.triage([store.mails[0], store.mails[1]], .markRead)
    XCTAssertFalse(store.mail(id: "mail-0")!.isUnread)
    XCTAssertEqual(store.triageUndo?.message, "Marked read")
    await store.undoLastTriage()
    XCTAssertTrue(store.mail(id: "mail-0")!.isUnread, "Undo marks the changed email unread again")
    XCTAssertFalse(store.mail(id: "mail-1")!.isUnread, "and leaves the one that was already read alone")
    await store.triage([store.mails[3]], .archive)
    let undo = store.triageUndo
    await store.triage([store.mails[0]], .flag)
    XCTAssertNotEqual(store.triageUndo?.id, undo?.id, "each action replaces the last Undo")
    await store.undoLastTriage()
    XCTAssertFalse(store.mail(id: "mail-0")!.isStarred)
    XCTAssertFalse(inInbox(store, "mail-3"), "only the latest action is undone")
  }

  func testSnoozeAdvancesAndUndoRestoresThePreviousTime() async throws {
    let store = try fixture()
    store.selectedID = "mail-0"
    let tomorrow = Date().addingTimeInterval(86_400), nextWeek = Date().addingTimeInterval(7 * 86_400)
    await store.triage([store.mails[0]], .snooze(tomorrow))
    XCTAssertEqual(store.mail(id: "mail-0")?.snoozedUntil, tomorrow)
    XCTAssertFalse(store.visible.contains { $0.id == "mail-0" })
    XCTAssertEqual(store.selectedID, "mail-1", "snoozing the open email opens the next one")
    await store.undoLastTriage()
    XCTAssertNil(store.mail(id: "mail-0")?.snoozedUntil)
    XCTAssertEqual(store.selectedID, "mail-0")
    // Re-snoozing a snoozed email: Undo puts back its earlier time, not "no snooze".
    store.snooze(store.mails[2], until: tomorrow)
    store.folder = "Snoozed"
    await store.triage([try XCTUnwrap(store.mail(id: "mail-2"))], .snooze(nextWeek))
    XCTAssertEqual(store.mail(id: "mail-2")?.snoozedUntil, nextWeek)
    await store.undoLastTriage()
    XCTAssertEqual(store.mail(id: "mail-2")?.snoozedUntil, tomorrow)
  }

  func testTrashAndArchiveCallersGoThroughTriage() async throws {
    let store = try fixture()
    store.selectedID = "mail-1"
    await store.archive(store.mails[1])
    XCTAssertEqual(store.selectedID, "mail-2", "the reader's Archive advances like E")
    XCTAssertEqual(store.triageUndo?.message, "Archived")
    await store.triage([store.mails[2]], .trash)
    XCTAssertTrue(store.queuedTrashIDs.contains("mail-2"))
    XCTAssertEqual(store.selectedID, "mail-3")
    await store.undoLastTriage()
    XCTAssertTrue(store.queuedTrashIDs.isEmpty, "Z cancels the pending move to Trash")
    XCTAssertTrue(store.visible.contains { $0.id == "mail-2" })
    XCTAssertEqual(store.selectedID, "mail-2")
  }

  func testLargeSetsGoAsOneBatchAndUndoTogether() async throws {
    let store = try fixture(count: 30)
    store.selectedIDs = Set(store.mails.map(\.id))
    await store.triage(store.triageTargets(for: nil), .archive)
    XCTAssertTrue(store.mails.allSatisfy { !$0.labels.contains("INBOX") })
    XCTAssertEqual(store.triageUndo?.message, "Archived · 30 emails")
    XCTAssertTrue(store.selectedIDs.isEmpty)
    XCTAssertFalse(store.busy)
    await store.undoLastTriage()
    XCTAssertTrue(store.mails.allSatisfy { $0.labels.contains("INBOX") })
  }
}
