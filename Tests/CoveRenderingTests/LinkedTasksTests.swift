import AppKit
import CoveCore
import SwiftUI
import XCTest
@testable import Cove

@MainActor final class LinkedTasksTests: XCTestCase {
  private func store() throws -> AppStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CoveLinkedTasks-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return try AppStore(database: Database(url: root.appendingPathComponent("mail.sqlite")), accountEmail: "me@example.com",
      gmail: GmailClient(transport: OfflineHTTP()), gmailTokenProvider: { "fixture" }, syncClock: Date.init)
  }

  func testAnEmailFindsTasksMadeFromItOrItsConversation() throws {
    let store = try store()
    var first = Mail(id: "m1", sender: "Siegrist", senderEmail: "pagos@example.com", subject: "Solicitud de pago", body: "Paga", labels: ["INBOX"])
    first.threadID = "thread9"
    var check = MailTaskCheck(found: true, confidence: 0.9); check.createdTaskIDs = ["fromSheet"]
    first.taskCheck = check
    var reply = Mail(id: "m2", sender: "Me", senderEmail: "me@example.com", subject: "Re: Solicitud de pago", body: "Listo", labels: ["SENT"])
    reply.threadID = "thread9"
    store.mails = [first, reply]
    store.googleTasks = [
      GoogleTask(id: "fromSheet", title: "Pay Siegrist $4,800"),
      GoogleTask(id: "fromTasks", title: "Send receipt", notes: "From: Siegrist\nhttps://mail.google.com/mail/u/0/#all/thread9"),
      GoogleTask(id: "other", title: "Unrelated", notes: "https://mail.google.com/mail/u/0/#all/elsewhere"),
    ]
    XCTAssertEqual(Set(store.tasks(for: reply).map(\.id)), ["fromSheet", "fromTasks"], "any message in the conversation shows its tasks")

    let host = NSHostingView(rootView: LinkedTasksStrip(store: store, mail: first).padding(24).frame(width: 620).background(Color.white))
    host.frame = NSRect(x: 0, y: 0, width: 620, height: host.fittingSize.height)
    host.layoutSubtreeIfNeeded()
    let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-linked-tasks.png"))
  }
}

private struct OfflineHTTP: HTTPTransport {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    XCTFail("No network in linked task tests: \(request.url!)")
    return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
  }
}
