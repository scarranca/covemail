import AppKit
import CoveCore
import SwiftUI
import XCTest
@testable import Cove

/// Files on Mac drafts: read on add, kept encrypted with the draft, sent through Gmail's upload, and
/// removed from the draft only once Gmail accepts the email.
@MainActor final class DraftAttachmentTests: XCTestCase {
  private func fixture(_ http: HTTPTransport) throws -> (AppStore, Database, URL) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let db = try Database(url: root.appendingPathComponent("mail.sqlite"), encryptionKey: Data(repeating: 5, count: 32), namespace: "attach-fixture")
    let store = try AppStore(database: db, accountEmail: "alex@example.com", gmail: GmailClient(transport: http),
                             gmailTokenProvider: { "synthetic" }, syncClock: { Date() })
    return (store, db, root)
  }

  func testFilesAreKeptWithTheDraftAcrossRestartAndLeaveOnlyAfterGmailAccepts() async throws {
    let http = AttachmentGmail()
    let (store, db, root) = try fixture(http); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("Propuesta año.pdf")
    try Data(repeating: 7, count: 2_000).write(to: file)
    store.newDraft(present: false)
    let target = AttachmentTarget.draft(try XCTUnwrap(store.composeID))
    store.addAttachments([file, root], to: target)
    XCTAssertEqual(store.attachments(for: target).map(\.filename), ["Propuesta año.pdf"])
    XCTAssertTrue(store.attachmentNotice?.contains("is a folder") == true, "a folder is refused with a reason")
    try FileManager.default.removeItem(at: file)

    // The bytes were read on add: a restart still has them, though the original is gone.
    let restarted = try AppStore(database: db, accountEmail: "alex@example.com", gmail: GmailClient(transport: http),
                                 gmailTokenProvider: { "synthetic" }, syncClock: { Date() })
    restarted.loadAttachments(target)
    let files = restarted.attachments(for: target)
    XCTAssertEqual(files.first?.data.count, 2_000)
    XCTAssertEqual(files.first?.mimeType, "application/pdf")

    // A failed send keeps them; a sent one takes exactly those files out of the draft.
    let sent = await restarted.send(to: "maya@example.com", subject: "Propuesta", body: "Adjunta", attachments: files)
    XCTAssertTrue(sent, "\(restarted.error ?? "") \(restarted.status)")
    let requests = await http.requests
    XCTAssertEqual(requests.last?.url?.path, "/upload/gmail/v1/users/me/messages/send")
    let body = String(decoding: requests.last?.httpBody ?? Data(), as: UTF8.self)
    XCTAssertTrue(body.contains("filename*=UTF-8''Propuesta%20a%C3%B1o.pdf"))
    restarted.clearAttachments(target, keeping: files)
    XCTAssertTrue(restarted.attachments(for: target).isEmpty)
    XCTAssertNil(try db.load([OutgoingAttachment].self, key: "attachments.\(target)"), "the encrypted record is removed")
  }

  func testDroppingOnTheWindowJoinsTheReplyOrStartsANewEmail() throws {
    let (store, _, root) = try fixture(AttachmentGmail()); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("notes.txt")
    try Data("hola".utf8).write(to: file)
    store.replyDraftTarget = "mail-1"
    store.attachDropped([file])
    XCTAssertEqual(store.attachments(for: AttachmentTarget.reply("mail-1")).count, 1)
    XCTAssertNil(store.composeID)
    store.replyDraftTarget = nil
    store.attachDropped([file])
    let id = try XCTUnwrap(store.composeID)
    XCTAssertTrue(store.showComposer)
    XCTAssertEqual(store.attachments(for: AttachmentTarget.draft(id)).map(\.filename), ["notes.txt"])
  }

  func testComposerShowsAttachedFilesBesideSend() async throws {
    let (store, _, root) = try fixture(AttachmentGmail()); defer { try? FileManager.default.removeItem(at: root) }
    store.newDraft(present: false)
    let id = try XCTUnwrap(store.composeID)
    store.saveComposition(id: id, to: "maya@example.com", subject: "Launch review", body: "Hi Maya,\n\nThe deck and the budget are attached.\n\nAlex")
    store.addAttachments([OutgoingAttachment(filename: "Launch deck — final.pdf", data: Data(count: 2_400_000)),
                          OutgoingAttachment(filename: "Budget Q4.xlsx", data: Data(count: 86_000)),
                          OutgoingAttachment(filename: "storefront.png", data: Data(count: 640_000))], to: AttachmentTarget.draft(id))
    let host = NSHostingView(rootView: ComposerView(store: store, availableSize: CGSize(width: 1100, height: 820)))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1036, height: 756), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-compose-attachments.png"))
  }
}

private actor AttachmentGmail: HTTPTransport {
  var requests: [URLRequest] = []
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    let body = request.url?.lastPathComponent == "sendAs"
      ? #"{"sendAs":[{"sendAsEmail":"alex@example.com","isPrimary":true}]}"# : #"{"id":"sent-1"}"#
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
