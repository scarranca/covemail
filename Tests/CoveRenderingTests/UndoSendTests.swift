import XCTest
@testable import Cove
@testable import CoveCore

/// Send waits 4 seconds with an Undo bar (no confirmation dialog), like Delete.
@MainActor final class UndoSendTests: XCTestCase {
  private func store() throws -> (AppStore, Mail) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let store = try AppStore(database: Database(url: directory.appendingPathComponent("mail.sqlite")),
      accountEmail: "me@example.com", gmail: GmailClient(), gmailTokenProvider: { "t" }, syncClock: Date.init)
    store.isSample = true
    let mail = Mail(id: "m1", sender: "Mariana", senderEmail: "mariana@example.com", subject: "Plan", body: "b", labels: ["INBOX"])
    store.mails = [mail]
    return (store, mail)
  }

  func testUndoKeepsItUnsentAndPutsTheTextBack() async throws {
    let (store, mail) = try store()
    store.queueSend(to: "Mariana <mariana@example.com>", subject: "Re: Plan", body: "Sounds good!", reply: mail)
    XCTAssertNotNil(store.pendingSend)
    XCTAssertEqual(SendUndoToast.firstRecipient(store.pendingSend!.to), "Mariana")
    store.undoSend()
    XCTAssertNil(store.pendingSend)
    XCTAssertEqual(store.mails.first { $0.id == "m1" }?.draft, "Sounds good!", "the reply is back in its box")
    try await Task.sleep(for: .seconds(AppStore.undoSendSeconds + 0.5))
    XCTAssertFalse(store.mails.contains { $0.labels.contains("SENT") }, "nothing was sent")
  }

  func testWithoutUndoItSendsAfterTheWindow() async throws {
    let (store, mail) = try store()
    store.queueSend(to: "mariana@example.com", subject: "Re: Plan", body: "Sounds good!", reply: mail)
    try await Task.sleep(for: .seconds(1))
    XCTAssertFalse(store.mails.contains { $0.labels.contains("SENT") }, "still waiting out the undo window")
    try await Task.sleep(for: .seconds(AppStore.undoSendSeconds))
    XCTAssertNil(store.pendingSend)
    XCTAssertTrue(store.mails.contains { $0.labels.contains("SENT") && $0.body == "Sounds good!" })
  }
}
