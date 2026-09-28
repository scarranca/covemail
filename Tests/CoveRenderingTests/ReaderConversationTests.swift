import AppKit
import CoveCore
import Quartz
import SwiftUI
import XCTest
@testable import Cove

@MainActor final class ReaderConversationTests: XCTestCase {
  var roots: [URL] = []
  override func tearDown() { roots.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown() }
  private func fixture(_ transport: ConversationHTTP? = nil) throws -> (AppStore, Database, Mail) {
    let http = transport ?? ConversationHTTP()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); roots.append(root)
    let db = try Database(url: root.appendingPathComponent("mail.sqlite"))
    let mail = Mail(id: "m1", threadID: "conversation", sender: "Maya Chen", senderEmail: "maya@example.com", to: "alex@example.com",
      subject: "Launch review", body: "Please review the attached launch checklist.", labels: ["INBOX"], draft: "Keep my reply")
    try db.saveMailSnapshot([mail], historyID: "123", nextPage: "older", updatesPagination: true)
    let store = try AppStore(database: db, accountEmail: "alex@example.com", gmail: GmailClient(transport: http), gmailTokenProvider: { "fixture" }, syncClock: Date.init)
    store.select(mail)
    return (store, db, mail)
  }
  func testConversationFetchPersistsMessagesPreservesDraftCursorAndSelection() async throws {
    let (store, db, mail) = try fixture()
    try await store.refreshReaderThread(mail)
    XCTAssertEqual(MailConversation.messages(in: store.mails, anchor: mail).map(\.id), ["m1", "m2"])
    XCTAssertEqual(store.mails.first { $0.id == "m1" }?.draft, "Keep my reply")
    XCTAssertEqual(try db.loadMail().count, 3)
    XCTAssertEqual(try db.load(String.self, key: "gmailHistoryID"), "123")
    XCTAssertEqual(try db.load(String.self, key: "gmailNextPage"), "older")
    XCTAssertEqual(store.selectedID, mail.id); XCTAssertFalse(store.busy)
  }
  func testEditsDuringFetchSurviveAndCancelledSelectionCannotPersist() async throws {
    let http = ConversationHTTP(); let started = expectation(description: "thread started"); http.started = started
    let (store, db, mail) = try fixture(http)
    let request = Task { try await store.refreshReaderThread(mail) }
    await fulfillment(of: [started], timeout: 2)
    store.saveReply(id: mail.id, text: "Edited during fetch")
    store.mails[0].labels = ["STARRED"]
    http.release()
    try await request.value
    XCTAssertEqual(store.mails.first { $0.id == mail.id }?.labels, ["STARRED"])
    XCTAssertEqual(try db.loadMail().first { $0.id == mail.id }?.draft, "Edited during fetch")
    let secondHTTP = ConversationHTTP(); let secondStarted = expectation(description: "second thread"); secondHTTP.started = secondStarted
    let (second, secondDB, secondMail) = try fixture(secondHTTP)
    let pending = Task { try await second.refreshReaderThread(secondMail) }
    await fulfillment(of: [secondStarted], timeout: 2)
    second.selectedID = nil
    secondHTTP.release()
    do { try await pending.value; XCTFail("Must reject stale reader request") } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(try secondDB.loadMail().count, 1)
  }
  func testOfflineAndSampleKeepCachedConversation() async throws {
    let http = ConversationHTTP(); http.status = 503
    let (store, db, mail) = try fixture(http)
    do { try await store.refreshReaderThread(mail); XCTFail("Expected network failure") } catch { }
    XCTAssertEqual(try db.loadMail(), [mail]); XCTAssertEqual(store.selectedID, mail.id)
    store.isSample = true
    try await store.refreshReaderThread(mail)
    XCTAssertEqual(http.requests, 1)
  }
  func testEmptyThreadIDsNeverGroupUnrelatedMailAndDraftsStayOutOfConversation() {
    var anchor = Mail(id: "one", sender: "One", senderEmail: "one@example.com", subject: "Same subject", body: "Body")
    var other = anchor; other.id = "two"
    XCTAssertEqual(MailConversation.messages(in: [anchor, other], anchor: anchor).map(\.id), ["one"])
    anchor.threadID = "thread"; other.threadID = "thread"; other.labels = ["DRAFT"]
    XCTAssertEqual(MailConversation.messages(in: [anchor, other], anchor: anchor).map(\.id), ["one"])
  }
  func testReplyToConversationMessageKeepsOtherDraftAndUsesOriginalRecipientsForSentMail() async throws {
    let (store, db, anchor) = try fixture()
    store.isSample = true
    var sent = anchor; sent.id = "sent"; sent.senderEmail = "alias@example.com"; sent.to = "friend@example.com"; sent.labels = ["SENT"]
    sent.draft = "One more detail"
    store.mails.append(sent)
    let recipient = MailConversation.replyRecipient(for: sent, accountEmail: store.accountEmail)
    XCTAssertEqual(recipient, "friend@example.com")
    var incoming = anchor; incoming.replyTo = "replies@example.com"
    XCTAssertEqual(MailConversation.replyRecipient(for: incoming, accountEmail: store.accountEmail), "replies@example.com")
    let success = await store.send(to: recipient, subject: "Re: Launch review", body: sent.draft, reply: sent)
    XCTAssertTrue(success)
    let saved = try db.loadMail()
    XCTAssertEqual(saved.first { $0.id == anchor.id }?.draft, "Keep my reply")
    XCTAssertEqual(saved.first { $0.id == sent.id }?.draft, "")
    XCTAssertTrue(saved.contains { $0.id.hasPrefix("local-sent-") && $0.to == "friend@example.com" && $0.threadID == anchor.threadID })
    XCTAssertEqual(store.selectedID, anchor.id)
  }
  func testAttachmentAuthenticationUsesRemoteIDWhenEmbeddedDataIsEmptyAndSampleNeverFetches() async throws {
    let http = ConversationHTTP()
    let (store, _, mail) = try fixture(http)
    let attachment = MailAttachment(id: "part", filename: "notes.txt", mimeType: "text/plain", byteCount: 5, attachmentID: "remote", data: "")
    store.mails[0].attachments = [attachment]
    let data = try await store.readerAttachmentData(attachment, from: mail)
    XCTAssertEqual(String(decoding: data, as: UTF8.self), "Notes")
    XCTAssertEqual(http.attachmentToken, "Bearer fixture")
    store.isSample = true
    do { _ = try await store.readerAttachmentData(attachment, from: mail); XCTFail("Must not fetch sample IDs") } catch { }
    XCTAssertEqual(http.requests, 1)
  }
  func testAttachmentResultIsDiscardedAfterDisconnect() async throws {
    let http = ConversationHTTP(); let started = expectation(description: "attachment started"); http.started = started
    let (store, _, mail) = try fixture(http)
    let attachment = MailAttachment(id: "part", filename: "notes.txt", mimeType: "text/plain", byteCount: 5, attachmentID: "remote")
    store.mails[0].attachments = [attachment]
    let pending = Task { try await store.readerAttachmentData(attachment, from: mail) }
    await fulfillment(of: [started], timeout: 2)
    store.entered = false
    http.release()
    do { _ = try await pending.value; XCTFail("Disconnected previews must be discarded") } catch { XCTAssertTrue(error is CancellationError) }
  }
  func testPreviewResourceLimitsCancellationAndPrivateFileCleanup() async throws {
    let state = AttachmentPreviewState()
    let attachment = MailAttachment(id: "text", filename: "../../private.html", mimeType: "text/html", byteCount: 15)
    await state.load(attachment) { Data("<h1>Hello</h1>".utf8) }
    let url = try XCTUnwrap(state.file?.url)
    XCTAssertEqual(url.pathExtension, "txt", "HTML attachments must never execute or load remote resources")
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
    state.close()
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    var large = attachment; large.byteCount = AttachmentPreviewFile.maximumBytes + 1
    await state.load(large) { XCTFail("Oversized files must not download"); return Data() }
    XCTAssertNotNil(state.error)
    var unsupported = attachment; unsupported.mimeType = "application/zip"
    await state.load(unsupported) { XCTFail("Unsupported files must not download"); return Data() }
    XCTAssertTrue(state.error?.contains("file type") == true)
    await state.load(attachment) { state.close(); return Data("Late result".utf8) }
    XCTAssertNil(state.file); XCTAssertNil(state.error); XCTAssertFalse(state.loading)
  }
  func testConversationAndInlinePreviewRenderWithoutShowingAWindow() async throws {
    _ = NSApplication.shared; DesignAssets.registerFonts()
    let (store, _, original) = try fixture()
    store.isSample = true
    var first = original; first.draft = ""; first.date = Date(timeIntervalSince1970: 1000)
    var response = first; response.id = "m2"; response.sender = "Alex Morgan"; response.senderEmail = "alex@example.com"; response.body = "Thanks, the timing works. I added a few notes to the launch checklist."; response.date = first.date.addingTimeInterval(3600)
    let content = Data("LAUNCH REVIEW\n\nConfirm the schedule and review the updated checklist.\n\nAll examples are synthetic.".utf8)
    let attachment = MailAttachment(id: "notes", filename: "Launch review notes.txt", mimeType: "text/plain", byteCount: content.count, data: content.base64URL)
    first.attachments = [attachment]
    store.mails = [response, first]
    for width in [420.0, 760.0] {
      try await render(ReaderView(store: store, mail: first), width: width, height: 1000, name: "conversation-\(Int(width))")
    }
    try await render(ReaderAttachment(store: store, mail: first, attachment: attachment, initiallyExpanded: true).padding(24), width: 640, height: 550, name: "attachment-preview", expectPreview: true)
  }
  func testPDFAndImagePreviewRenderInline() async throws {
    _ = NSApplication.shared
    let (store, _, mail) = try fixture(); store.isSample = true
    let picture = NSImage(size: NSSize(width: 300, height: 200), flipped: false) { rect in
      NSColor(calibratedRed: 0.88, green: 0.94, blue: 0.98, alpha: 1).setFill(); rect.fill()
      ("Synthetic attachment" as NSString).draw(at: NSPoint(x: 24, y: 100), withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black])
      return true
    }
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(picture.tiffRepresentation)))
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let pdf = PDFDocument()
    for index in 0..<2 { pdf.insert(try XCTUnwrap(PDFPage(image: picture)), at: index) }
    for (mime, ext, data) in [("image/png", "png", png), ("application/pdf", "pdf", try XCTUnwrap(pdf.dataRepresentation()))] {
      let attachment = MailAttachment(id: ext, filename: "Example.\(ext)", mimeType: mime, byteCount: data.count, data: data.base64URL)
      store.mails[0].attachments = [attachment]
      try await render(ReaderAttachment(store: store, mail: mail, attachment: attachment, initiallyExpanded: true).padding(24), width: 640, height: 550, name: "attachment-\(ext)", expectPreview: true)
    }
  }
  private func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String, expectPreview: Bool = false) async throws {
    let host = NSHostingView(rootView: view.background(Palette.canvas).foregroundStyle(Palette.ink))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    for _ in 0..<35 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(40)) }
    XCTAssertFalse(window.isVisible); XCTAssertEqual(host.bounds.width, width, accuracy: 1)
    if expectPreview {
      func descendant<T: NSView>(_ view: NSView, type: T.Type) -> T? { (view as? T) ?? view.subviews.compactMap { descendant($0, type: type) }.first }
      if name == "attachment-pdf" {
        let native = try XCTUnwrap(descendant(host, type: AttachmentPDFPages.self))
        XCTAssertEqual(native.document.pageCount, 2)
        XCTAssertGreaterThan(native.bounds.width, 100)
        XCTAssertGreaterThan(native.bounds.height, 420, "Every PDF page must remain scrollable")
      } else if name == "attachment-png" {
        let native = try XCTUnwrap(descendant(host, type: NSImageView.self))
        XCTAssertNotNil(native.image)
      } else {
        let native = try XCTUnwrap(descendant(host, type: QLPreviewView.self))
        XCTAssertNotNil(native.previewItem); XCTAssertFalse(native.autostarts)
      }
    }
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    if name == "attachment-pdf" || name == "attachment-png" {
      var coloredSamples = 0
      for y in stride(from: 0, to: bitmap.pixelsHigh, by: 32) {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 32) {
          if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
            color.blueComponent > color.redComponent + 0.02,
            color.greenComponent > color.redComponent + 0.02 { coloredSamples += 1 }
        }
      }
      XCTAssertGreaterThan(coloredSamples, 10, "The preview must paint actual file content, not only attach a native preview item")
    }
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-\(name).png"))
  }
}

@MainActor private final class ConversationHTTP: HTTPTransport {
  var requests = 0
  var status = 200
  var started: XCTestExpectation?
  var continuation: CheckedContinuation<Void, Never>?
  var attachmentToken: String?
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests += 1
    if let started { await withCheckedContinuation { continuation = $0; started.fulfill() } }
    let data: Data
    if request.url!.path.contains("/attachments/") {
      attachmentToken = request.value(forHTTPHeaderField: "Authorization")
      data = try JSONSerialization.data(withJSONObject: ["data": Data("Notes".utf8).base64URL, "size": 5])
    } else {
      XCTAssertEqual(request.url?.path, "/gmail/v1/users/me/threads/conversation")
      let messages = ["m1", "m2", "draft"].enumerated().map { index, id in
        ["id": id, "threadId": "conversation", "internalDate": String((index + 1) * 1000), "labelIds": id == "draft" ? ["DRAFT"] : ["INBOX"],
         "payload": ["mimeType": "text/plain", "headers": [["name": "From", "value": "sender@example.com"]], "body": ["data": Data("Thread \(id)".utf8).base64URL]]] as [String: Any]
      }
      data = try JSONSerialization.data(withJSONObject: ["id": "conversation", "messages": messages])
    }
    return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }
  func release() { continuation?.resume(); continuation = nil }
}
