import CSQLite
import CryptoKit
import XCTest

@testable import CoveCore

final class EncryptedStorageTests: XCTestCase {
  private let key = Data(repeating: 0x71, count: 32)
  private let namespace = "account-a"
  private let secret = "PRIVATE-MAIL-COVE-ONLY café 🌊 with an unsent draft"

  private func withStore(_ operation: (URL) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try operation(dir.appendingPathComponent("mail.sqlite"))
  }

  private func sql(_ url: URL, _ command: String) throws {
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, command, nil, nil, nil) == SQLITE_OK else {
      throw CoveError.message("Synthetic SQL failed")
    }
  }

  private func assertNoPlaintext(_ url: URL, file: StaticString = #filePath, line: UInt = #line)
    throws
  {
    for suffix in ["", "-wal", "-shm", "-journal"] {
      let path = URL(fileURLWithPath: url.path + suffix)
      guard FileManager.default.fileExists(atPath: path.path) else { continue }
      let bytes = try Data(contentsOf: path)
      XCTAssertNil(bytes.range(of: Data("PRIVATE-MAIL-COVE-ONLY".utf8)), file: file, line: line)
      let mode =
        try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int
      XCTAssertEqual((mode ?? 0) & 0o077, 0, file: file, line: line)
    }
  }

  func testMigratesSnapshotOverridesPreferencesAndDraftsWithoutPlaintextResidue() throws {
    try withStore { url in
      var mail = Samples.mail[0]
      mail.body = secret
      var edited = mail
      edited.draft = secret
      do {
        let db = try Database(url: url)
        try db.saveMailSnapshot([mail], historyID: "cursor-before", decodingVersion: 4)
        try db.saveMessage(edited)
        try db.save([secret], key: "preferences")
        // Leave deleted content in old pages to exercise migration compaction as well.
        try db.save(String(repeating: secret, count: 20_000), key: "old")
        try db.deleteRecords(prefix: "old")
      }
      // Older Cove databases and their reused WAL/SHM files may have broader modes.
      try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
      XCTAssertFalse(try Database.requiresEncryptionKey(at: url))
      do {
        let db = try Database(url: url, encryptionKey: key, namespace: namespace)
        XCTAssertEqual(try db.loadMail(), [edited])
        XCTAssertEqual(try db.load([String].self, key: "preferences"), [secret])
        XCTAssertEqual(try db.load(String.self, key: "gmailHistoryID"), "cursor-before")
        XCTAssertTrue(try Database.requiresEncryptionKey(at: url))
        try assertNoPlaintext(url)
        try db.saveMailSnapshot([edited], historyID: "cursor-after")
        try assertNoPlaintext(url)
      }
      let reopened = try Database(url: url, encryptionKey: key, namespace: namespace)
      XCTAssertEqual(try reopened.loadMail(), [edited])
      XCTAssertEqual(try reopened.load(String.self, key: "gmailHistoryID"), "cursor-after")
      try assertNoPlaintext(url)
    }
  }

  func testEncryptedSnapshotMigratesToEncryptedRows() throws {
    try withStore { url in
      var mail = Samples.mail[0]
      mail.body = secret
      var edited = mail
      edited.draft = secret
      do {
        // Recreate an encrypted version-2 store in the original single-snapshot format.
        let db = try Database(url: url, encryptionKey: key, namespace: namespace)
        try db.save([mail], key: "mail")
        try db.save(edited, key: "mailOverride:" + edited.id)
        try db.save("cursor", key: "gmailHistoryID")
      }
      try sql(url, "DELETE FROM messages; PRAGMA user_version=2")
      XCTAssertThrowsError(try Database(url: url, encryptionKey: Data(repeating: 2, count: 32), namespace: namespace))
      do {
        let db = try Database(url: url, encryptionKey: key, namespace: namespace)
        XCTAssertEqual(try db.loadMail(), [edited])
        XCTAssertNil(try db.load([Mail].self, key: "mail"))
        XCTAssertEqual(try db.load(String.self, key: "gmailHistoryID"), "cursor")
      }
      var handle: OpaquePointer?
      XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
      var statement: OpaquePointer?
      XCTAssertEqual(sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &statement, nil), SQLITE_OK)
      XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
      XCTAssertEqual(sqlite3_column_int(statement, 0), 3)
      sqlite3_finalize(statement)
      sqlite3_close(handle)
      // A row moved to another email's id fails authentication.
      try sql(url, "INSERT INTO messages SELECT 'other', thread_id, date, starred, has_draft, in_inbox, snoozed, value FROM messages")
      XCTAssertThrowsError(try Database(url: url, encryptionKey: key, namespace: namespace).loadMail())
      try assertNoPlaintext(url)
    }
  }

  func testMissingWrongKeyOrWrongAccountNeverResetEncryptedMailbox() throws {
    try withStore { url in
      do {
        let db = try Database(url: url, encryptionKey: key, namespace: namespace)
        try db.save(secret, key: "note")
      }
      XCTAssertThrowsError(try Database(url: url))
      XCTAssertThrowsError(
        try Database(url: url, encryptionKey: Data(repeating: 2, count: 32), namespace: namespace))
      XCTAssertThrowsError(try Database(url: url, encryptionKey: key, namespace: "account-b"))
      let recovered = try Database(url: url, encryptionKey: key, namespace: namespace)
      XCTAssertEqual(try recovered.load(String.self, key: "note"), secret)
    }
  }

  func testTamperingAndMovingCiphertextBetweenRecordsIsRejected() throws {
    try withStore { url in
      let db = try Database(url: url, encryptionKey: key, namespace: namespace)
      try db.save(secret, key: "one")
      try db.save("Other", key: "two")
      try sql(
        url, "UPDATE records SET value=(SELECT value FROM records WHERE key='one') WHERE key='two'")
      XCTAssertThrowsError(try db.load(String.self, key: "two"))
      XCTAssertEqual(try db.load(String.self, key: "one"), secret)
      try sql(url, "UPDATE records SET value=zeroblob(length(value)) WHERE key='one'")
      XCTAssertThrowsError(try db.load(String.self, key: "one"))
    }
  }

  func testCorruptLegacyRecordRollsBackTheWholeMigration() throws {
    try withStore { url in
      do {
        let db = try Database(url: url)
        try db.save(secret, key: "aaa")
      }
      try sql(url, "INSERT INTO records VALUES('zzz',x'fffe')")
      XCTAssertThrowsError(try Database(url: url, encryptionKey: key, namespace: namespace))
      XCTAssertFalse(try Database.requiresEncryptionKey(at: url))
      let original = try Database(url: url)
      XCTAssertEqual(try original.load(String.self, key: "aaa"), secret)
    }
  }

  func testInterruptedCleanupIsResumedAndNewWritesUseFreshNonces() throws {
    try withStore { url in
      do {
        let db = try Database(url: url, encryptionKey: key, namespace: namespace)
        try db.save(secret, key: "note")
      }
      try sql(url, "PRAGMA user_version=1")
      let db = try Database(url: url, encryptionKey: key, namespace: namespace)
      XCTAssertEqual(try db.load(String.self, key: "note"), secret)
      try assertNoPlaintext(url)
      let cipher = try RecordCipher(key: key, namespace: namespace)
      let a = try cipher.seal(Data(secret.utf8), record: "mail")
      let b = try cipher.seal(Data(secret.utf8), record: "mail")
      XCTAssertNotEqual(a, b)
      XCTAssertEqual(try cipher.open(a, record: "mail"), Data(secret.utf8))
      XCTAssertThrowsError(try cipher.open(a.dropLast(), record: "mail"))
    }
  }

  func testExplicitLocalErasureClearsRecordsAndPreservesUsableEncryption() throws {
    try withStore { url in
      do {
        let db = try Database(url: url, encryptionKey: key, namespace: namespace)
        try db.save(secret, key: "preferences")
        try db.saveMailSnapshot([Samples.mail[0]], historyID: "old-cursor")
        try db.saveMessage(Samples.mail[1])
        try db.eraseContents()
        XCTAssertEqual(try db.loadMail(), [])
        // The same email saved again after erasure is written, not skipped as unchanged.
        try db.saveMailSnapshot([Samples.mail[0]])
        XCTAssertEqual(try db.messageCount(), 1)
        try db.eraseContents()
        XCTAssertNil(try db.load(String.self, key: "preferences"))
        XCTAssertNil(try db.load(String.self, key: "gmailHistoryID"))
        try assertNoPlaintext(url)
      }
      let reopened = try Database(url: url, encryptionKey: key, namespace: namespace)
      XCTAssertEqual(try reopened.loadMail(), [])
      try reopened.save(secret, key: "new")
      XCTAssertEqual(try reopened.load(String.self, key: "new"), secret)
    }
  }

  func testEncryptedTransactionsRollbackAndRejectSymlinkStores() throws {
    try withStore { url in
      let db = try Database(url: url, encryptionKey: key, namespace: namespace)
      try db.save(secret, key: "note")
      XCTAssertThrowsError(
        try db.transaction {
          try db.save("Changed", key: "mail")
          throw CoveError.message("Synthetic interruption")
        })
      XCTAssertEqual(try db.load(String.self, key: "note"), secret)
      let link = url.deletingLastPathComponent().appendingPathComponent("link.sqlite")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
      XCTAssertThrowsError(try Database(url: link, encryptionKey: key, namespace: namespace))
      XCTAssertThrowsError(try RecordCipher(key: Data(), namespace: namespace))
    }
  }
}
