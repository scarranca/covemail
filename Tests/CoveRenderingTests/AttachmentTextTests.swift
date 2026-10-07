import AppKit
import CoveCore
import PDFKit
import XCTest
@testable import Cove

/// Ask Cove reads the selected email's PDFs with the same reader as agents.
@MainActor final class AttachmentTextTests: XCTestCase {
  private func pdf(_ text: String) -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
    context.beginPDFPage(nil)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    (text as NSString).draw(in: CGRect(x: 40, y: 40, width: 530, height: 700), withAttributes: [.font: NSFont.systemFont(ofSize: 12)])
    NSGraphicsContext.restoreGraphicsState()
    context.endPDFPage()
    context.closePDF()
    return data as Data
  }

  func testReadsPDFsEvenWhenGmailCallsThemGenericFilesAndRemembersThem() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try Database(url: root.appendingPathComponent("mail.sqlite"), encryptionKey: Data(repeating: 3, count: 32), namespace: "files-fixture")
    let store = try AppStore(database: db, accountEmail: "me@example.com", gmail: GmailClient(),
                             gmailTokenProvider: { "synthetic" }, syncClock: { Date() })
    let imss = pdf("Formato para pago de cuotas IMSS\nLinea de captura: 0123456789012345678901\nImporte total a pagar: $48,312.55")
    let photo = Data([0xFF, 0xD8, 0xFF])
    var mail = Mail(id: "m1", sender: "Despacho", senderEmail: "contador@example.com", subject: "Líneas de captura", body: "Adjuntos")
    mail.attachments = [
      MailAttachment(id: "a1", filename: "Formato para pago cuotas IMSS SEPTIEMBRE.pdf", mimeType: "application/octet-stream",
                     byteCount: imss.count, data: imss.base64URL),
      MailAttachment(id: "a2", filename: "logo.jpg", mimeType: "image/jpeg", byteCount: photo.count, data: photo.base64URL),
    ]
    XCTAssertTrue(AppStore.readableAttachment(mail.attachments![0]))
    XCTAssertFalse(AppStore.readableAttachment(mail.attachments![1]))
    let (texts, warnings) = try await store.attachmentTexts(mail)
    XCTAssertEqual(texts.map(\.name), ["Formato para pago cuotas IMSS SEPTIEMBRE.pdf"])
    XCTAssertTrue(texts[0].text.contains("$48,312.55"))
    XCTAssertTrue(texts[0].text.contains("0123456789012345678901"))
    XCTAssertTrue(warnings.contains { $0.contains("logo.jpg") }, "an image is reported, not guessed")
    // Cached for follow-up questions: a second call doesn't read again.
    mail.attachments = []
    let again = try await store.attachmentTexts(mail)
    XCTAssertEqual(again.0, texts)
  }
}
