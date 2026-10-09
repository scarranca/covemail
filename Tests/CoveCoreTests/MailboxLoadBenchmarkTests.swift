import CryptoKit
import Foundation
import XCTest
@testable import CoveCore

/// Baseline numbers for opening a mailbox: how long loading and decrypting a realistic store takes, and
/// how long one autosave write takes. The bounds are loose (they guard against regressions by an order
/// of magnitude, not noise); the printed timings are what the speed audit quotes.
final class MailboxLoadBenchmarkTests: XCTestCase {
  static let count = 4_000

  static func synthetic(_ count: Int) -> [Mail] {
    let paragraph = String(repeating: "Thanks for the update. Let's review the figures on Thursday and confirm the plan. ", count: 60)
    let html = "<html><body>" + String(repeating: "<p style=\"margin:0 0 12px\">" + paragraph.prefix(400) + "</p>", count: 20) + "</body></html>"
    return (0..<count).map { index in
      var mail = Mail(id: "m\(index)", sender: "Sender \(index % 300)", senderEmail: "s\(index % 300)@example.com",
        subject: "Subject \(index) about the quarterly plan", body: paragraph,
        date: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 90),
        labels: index % 3 == 0 ? ["INBOX", "UNREAD"] : index % 3 == 1 ? ["INBOX"] : ["SENT"], isBulkOrAutomated: index % 5 == 0)
      mail.htmlBody = html
      mail.threadID = "t\(index / 2)"
      return mail
    }
  }

  func testLoadingAnEncryptedMailboxAndSavingOneDraft() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CoveBench-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("mail.sqlite")
    let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    let mails = Self.synthetic(Self.count)
    do {
      let db = try Database(url: url, encryptionKey: key, namespace: "bench")
      let started = Date()
      try db.saveMailSnapshot(mails, historyID: "h1", decodingVersion: GmailMessage.decodingVersion)
      print("BENCH save snapshot of \(Self.count): \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    }
    let db = try Database(url: url, encryptionKey: key, namespace: "bench")
    let started = Date()
    let loaded = try db.loadMail()
    let loadMS = Date().timeIntervalSince(started) * 1000
    print("BENCH load \(loaded.count) encrypted emails: \(Int(loadMS)) ms")
    XCTAssertEqual(loaded.count, Self.count)
    XCTAssertEqual(Set(loaded.map(\.id)), Set(mails.map(\.id)))
    XCTAssertEqual(loaded.first?.id, mails.last?.id, "newest first")
    XCTAssertLessThan(loadMS, 20_000)

    var draft = loaded[10]
    draft.draft = String(repeating: "A reply being typed. ", count: 40)
    let saveStarted = Date()
    for _ in 0..<20 { try db.saveMessage(draft) }
    let saveMS = Date().timeIntervalSince(saveStarted) * 1000 / 20
    print("BENCH one autosave write (encrypt + sqlite): \(String(format: "%.2f", saveMS)) ms")
    XCTAssertLessThan(saveMS, 500)
  }
}
