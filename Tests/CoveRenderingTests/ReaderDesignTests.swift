import AppKit
import CoveCore
import SwiftUI
import WebKit
import XCTest
@testable import Cove

@MainActor final class ReaderDesignTests: XCTestCase {
  private var roots: [URL] = []
  override func tearDown() {
    roots.forEach { try? FileManager.default.removeItem(at: $0) }
    super.tearDown()
  }
  private func fixture() throws -> AppStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    roots.append(root)
    let store = try AppStore(database: Database(url: root.appendingPathComponent("mail.sqlite")),
      accountEmail: "alex@example.com", gmail: GmailClient(),
      gmailTokenProvider: { XCTFail("Reader fixtures must not access Gmail"); return "fixture" }, syncClock: Date.init)
    store.isSample = true; store.entered = true; store.screen = "mail"; store.priorityOnly = false
    return store
  }
  private var message: Mail {
    Mail(id: "reader-fixture", sender: "Gigstack", senderEmail: "no-reply@example.com",
      subject: "Acción requerida: Completar configuración de WooCommerce",
      body: "Para asegurar que recibes todas tus transacciones de WooCommerce en gigstack, necesitamos que completes la configuración de tu integración.\n\nActualmente falta información de tu tienda. Sin estos datos no podremos sincronizar tus órdenes.",
      date: Date(timeIntervalSince1970: 1790463480), labels: ["INBOX"],
      decision: Decision(category: .work, confidence: 0.92, needsReply: 0.87, urgent: 0.2,
        excerpt: "Actualmente falta información de tu tienda.", model: "Synthetic fixture"),
      htmlBody: "<div style='background:#f7f9fc;padding:28px;border-radius:8px'><div style='background:white;padding:24px;color:#1c2853'><h2 style='color:#075445'>gigstack</h2><p>Para asegurar que recibes todas tus transacciones de WooCommerce en gigstack, necesitamos que completes la configuración de tu integración.</p><p>Actualmente falta información de tu tienda. Sin estos datos no podremos sincronizar tus órdenes.</p></div></div>")
  }
  func testReplyAddressNoticeUsesReplyToAndDoesNotGuessFromDisplayName() {
    var mail = message
    XCTAssertTrue(mail.replyAddressLooksUnmonitored)
    mail.replyTo = "Support <support@example.com>"
    XCTAssertFalse(mail.replyAddressLooksUnmonitored)
    mail.replyTo = "Service <NO-REPLY@example.com>"
    XCTAssertTrue(mail.replyAddressLooksUnmonitored)
    mail.replyTo = "No-reply team <help@example.com>"
    XCTAssertFalse(mail.replyAddressLooksUnmonitored)
    mail.replyTo = "no-reply-team@example.com"
    XCTAssertFalse(mail.replyAddressLooksUnmonitored)
  }
  func testTranslationPreparesSelectedEmailQuestionWithoutChangingDraftOrSending() throws {
    let store = try fixture()
    var mail = message; mail.draft = "Keep my existing reply."
    store.mails = [mail]
    let prompt = "Translate the selected email into Spanish."
    store.askAboutEmail(mail, question: prompt)
    XCTAssertTrue(store.showAssistant)
    XCTAssertEqual(store.selectedID, mail.id)
    XCTAssertEqual(store.assistantInitialQuery, prompt)
    XCTAssertEqual(store.mails, [mail])
    XCTAssertFalse(store.showComposer)
    store.askAboutEmail(mail)
    XCTAssertEqual(store.assistantInitialQuery, "")
  }
  func testReaderRendersFormattedPlainLongIdentityAndSavedReplyOffscreen() async throws {
    _ = NSApplication.shared; DesignAssets.registerFonts()
    let store = try fixture()
    let suite = "Cove.ReaderDesignTests." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    for width in [420.0, 620.0, 824.0] {
      store.mails = [message]; store.selectedID = message.id
      try await render(ReaderView(store: store, mail: message).defaultAppStorage(defaults), width: width, name: "formatted")
    }
    var long = message
    long.sender = "Customer support and integrations team with a long sender name"
    long.senderEmail = "customer-support-and-integrations@example.com"
    long.to = "Alex Morgan <alex@example.com>, Maya Chen <maya@example.com>"
    long.htmlBody = nil; long.decision = nil
    long.draft = "Gracias por el aviso. Revisaré la configuración y les confirmaré cuando esté lista."
    store.mails = [long]
    try await render(ReaderView(store: store, mail: long).defaultAppStorage(defaults), width: 420, name: "saved-reply")
    store.mails = [message]
    defaults.set(true, forKey: "reading.textOnly")
    try await render(ReaderView(store: store, mail: message).defaultAppStorage(defaults), width: 824, name: "plain")
    try await render(MailboxView(store: store).defaultAppStorage(defaults), width: 1050, name: "mailbox")
  }
  private func render<V: View>(_ view: V, width: CGFloat, name: String) async throws {
    let host = NSHostingView(rootView: view.font(.coveBody).foregroundStyle(Palette.ink).background(Palette.canvas))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 960), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    for _ in 0..<25 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    XCTAssertFalse(window.isVisible)
    XCTAssertEqual(host.bounds.width, width, accuracy: 1)
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      .write(to: URL(fileURLWithPath: "/tmp/cove-reader-\(name)-\(Int(width)).png"))
  }
}
