import CSQLite
import XCTest

@testable import CoveCore

final class ParallelMailLoadTests: XCTestCase {
  private let key = Data(repeating: 0x42, count: 32)

  private func withStore(_ operation: (URL) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try operation(dir.appendingPathComponent("mail.sqlite"))
  }

  func testOrderSurvivesSeveralParallelChunks() throws {
    try withStore { url in
      let count = Database.decodeChunk * 5 + 7
      let mails = MailboxLoadBenchmarkTests.synthetic(count)
      let db = try Database(url: url, encryptionKey: key, namespace: "parallel")
      try db.saveMailSnapshot(mails)
      let loaded = try db.loadMail()
      XCTAssertEqual(loaded.map(\.id), mails.sorted { ($0.date, $0.id) > ($1.date, $1.id) }.map(\.id))
      XCTAssertEqual(loaded.first(where: { $0.id == "m10" }), mails[10])
      let thread = try db.loadThread(threadID: "t3")
      XCTAssertEqual(thread.map(\.id), ["m6", "m7"])
    }
  }

  func testACorruptRowStillThrowsWhenDecodingInParallel() throws {
    try withStore { url in
      let mails = MailboxLoadBenchmarkTests.synthetic(Database.decodeChunk * 3)
      do {
        let db = try Database(url: url, encryptionKey: key, namespace: "parallel")
        try db.saveMailSnapshot(mails)
      }
      var handle: OpaquePointer?
      XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
      // A row in a later chunk gets ciphertext that fails authentication.
      XCTAssertEqual(
        sqlite3_exec(handle, "UPDATE messages SET value = zeroblob(64) WHERE id='m150'", nil, nil, nil), SQLITE_OK)
      sqlite3_close(handle)
      let db = try Database(url: url, encryptionKey: key, namespace: "parallel")
      XCTAssertThrowsError(try db.loadMail())
    }
  }

  func testMailPreviewIsOneShortLine() {
    var mail = MailboxLoadBenchmarkTests.synthetic(1)[0]
    mail.body = "\n\n  Hello   there,\r\n\r\nthe\tplan  is ready.  \n"
    XCTAssertEqual(mail.preview, "Hello there, the plan is ready.")
    mail.body = String(repeating: "word ", count: 5_000)
    XCTAssertTrue((239...240).contains(mail.preview.count))
    XCTAssertFalse(mail.preview.hasSuffix(" "))
    mail.body = "   \n "
    XCTAssertEqual(mail.preview, "")
  }
}
