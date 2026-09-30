import CSQLite
import XCTest

@testable import CoveCore

final class MailboxPersistenceTests: XCTestCase {
  private func withDatabase(_ operation: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try operation(directory.appendingPathComponent("mailbox.sqlite"))
  }

  func testLegacySnapshotAndOverridesMigrateToRowsOnce() throws {
    try withDatabase { url in
      var original = Samples.mail[0]
      original.id = "existing"
      var edited = original
      edited.draft = "A revised reply with café 🌊"
      edited.labels.remove("UNREAD")
      var newDraft = Mail(
        id: "local-new", sender: "Me", senderEmail: "me@example.com", subject: "New draft",
        body: "Persisted without rewriting the snapshot", labels: ["DRAFT"])
      newDraft.date = original.date.addingTimeInterval(60)
      do {
        // The original storage format: one snapshot record plus per-email overrides.
        let database = try Database(url: url)
        try database.save([original], key: "mail")
        try database.save(edited, key: "mailOverride:" + edited.id)
        try database.save(newDraft, key: "mailOverride:" + newDraft.id)
        try database.save("cursor", key: "gmailHistoryID")
      }
      let reopened = try Database(url: url)
      XCTAssertEqual(try reopened.loadMail(), [newDraft, edited])
      XCTAssertNil(try reopened.load([Mail].self, key: "mail"))
      XCTAssertEqual(try reopened.loadRecords(Mail.self, prefix: "mailOverride:"), [])
      XCTAssertEqual(try reopened.load(String.self, key: "gmailHistoryID"), "cursor")
      XCTAssertEqual(try reopened.messageCount(), 2)
      let again = try Database(url: url)
      XCTAssertEqual(try again.loadMail(), [newDraft, edited])
    }
  }

  func testSnapshotRewritesOnlyChangedEmailsAndNeverDropsUnloadedOnes() throws {
    try withDatabase { url in
      let now = Date()
      let mails = (0..<5).map { index -> Mail in
        var mail = Samples.mail[0]
        mail.id = "m\(index)"
        mail.date = now.addingTimeInterval(-Double(index) * 86_400 * 200)
        return mail
      }
      do {
        let database = try Database(url: url)
        try database.saveMailSnapshot(mails)
      }
      var handle: OpaquePointer?
      XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
      defer { sqlite3_close(handle) }
      XCTAssertEqual(
        sqlite3_exec(
          handle,
          "CREATE TABLE writes(id TEXT); CREATE TRIGGER count_writes AFTER INSERT ON messages BEGIN INSERT INTO writes VALUES(NEW.id); END;",
          nil, nil, nil), SQLITE_OK)
      let database = try Database(url: url)
      // Load only the last year; older emails stay on disk and must survive a snapshot without them.
      let recent = try database.loadMail(since: now.addingTimeInterval(-365 * 86_400))
      XCTAssertEqual(recent.map(\.id), ["m0", "m1"])
      var changed = recent
      changed[1].labels.remove("UNREAD")
      try database.saveMailSnapshot(changed)
      var statement: OpaquePointer?
      XCTAssertEqual(sqlite3_prepare_v2(handle, "SELECT group_concat(id) FROM writes", -1, &statement, nil), SQLITE_OK)
      XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
      XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "m1")
      sqlite3_finalize(statement)
      XCTAssertEqual(try database.messageCount(), 5)
      // Dropping a loaded email from the snapshot removes its row.
      try database.saveMailSnapshot([changed[1]])
      XCTAssertEqual(try Database(url: url).loadMail().map(\.id), ["m1", "m2", "m3", "m4"])
    }
  }

  func testStarredAndDraftEmailsLoadRegardlessOfAge() throws {
    try withDatabase { url in
      var old = Samples.mail[0]
      old.date = Date(timeIntervalSince1970: 1_000_000_000)
      var starred = old; starred.id = "starred"; starred.labels = ["STARRED"]
      var drafted = old; drafted.id = "drafted"; drafted.labels = []; drafted.draft = "Unsent"
      var plain = old; plain.id = "plain"; plain.labels = ["INBOX"]
      let database = try Database(url: url)
      try database.saveMailSnapshot([starred, drafted, plain])
      let loaded = try Database(url: url).loadMail(since: Date().addingTimeInterval(-86_400))
      XCTAssertEqual(Set(loaded.map(\.id)), ["starred", "drafted"])
    }
  }

  func testNewerStorageVersionIsRejectedWithoutChanges() throws {
    try withDatabase { url in
      _ = try Database(url: url)
      var handle: OpaquePointer?
      XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
      XCTAssertEqual(sqlite3_exec(handle, "PRAGMA user_version=4", nil, nil, nil), SQLITE_OK)
      sqlite3_close(handle)
      XCTAssertThrowsError(try Database(url: url))
    }
  }

  func testSnapshotRemovalDoesNotResurrectAnOldOverride() throws {
    try withDatabase { url in
      do {
        let database = try Database(url: url)
        try database.saveMailSnapshot([Samples.mail[0]], historyID: "100")
        var edited = Samples.mail[0]
        edited.draft = "An edit before this message was deleted"
        try database.saveMessage(edited)
        try database.save("preserved", key: "mailOverrideOther")
        try database.saveMailSnapshot([], historyID: "101")
      }
      let reopened = try Database(url: url)
      XCTAssertEqual(try reopened.loadMail(), [])
      XCTAssertEqual(try reopened.load(String.self, key: "gmailHistoryID"), "101")
      XCTAssertEqual(try reopened.load(String.self, key: "mailOverrideOther"), "preserved")
    }
  }

  func testSnapshotAndOverridesRollBackWhenCursorWriteFails() throws {
    try withDatabase { url in
      let original = Samples.mail[0]
      var edited = original
      edited.draft = "Must survive failed synchronization"
      do {
        let database = try Database(url: url)
        try database.saveMailSnapshot([original], historyID: "before", decodingVersion: 1)
        try database.saveMessage(edited)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        // Fail the cursor write, after the transaction has replaced mail and deleted overrides.
        XCTAssertEqual(
          sqlite3_exec(
            handle,
            "CREATE TRIGGER reject_cursor BEFORE INSERT ON records WHEN NEW.key='gmailHistoryID' BEGIN SELECT RAISE(ABORT,'simulated cursor failure'); END;",
            nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(
          try database.saveMailSnapshot([], historyID: "after", decodingVersion: 2))
        XCTAssertEqual(try database.loadMail(), [edited])
        // Change tracking was restored, so a retry still removes the email.
        XCTAssertEqual(sqlite3_exec(handle, "DROP TRIGGER reject_cursor", nil, nil, nil), SQLITE_OK)
        try database.saveMailSnapshot([], historyID: "retry")
        XCTAssertEqual(try database.loadMail(), [])
        try database.saveMailSnapshot([edited], historyID: "before", decodingVersion: 1)
        XCTAssertEqual(try database.load(String.self, key: "gmailHistoryID"), "before")
        XCTAssertEqual(try database.load(Int.self, key: "mailDecodingVersion"), 1)
      }
      let reopened = try Database(url: url)
      XCTAssertEqual(try reopened.loadMail(), [edited])
      XCTAssertEqual(try reopened.load(String.self, key: "gmailHistoryID"), "before")
      XCTAssertEqual(try reopened.load(Int.self, key: "mailDecodingVersion"), 1)
    }
  }

  func testSnapshotWithoutCursorPreservesExistingCursor() throws {
    try withDatabase { url in
      let database = try Database(url: url)
      let mail = Samples.mail[0]
      try database.saveMailSnapshot([], historyID: "existing-cursor")
      try database.saveMailSnapshot([mail])
      XCTAssertEqual(try database.load(String.self, key: "gmailHistoryID"), "existing-cursor")
      XCTAssertEqual(try database.loadMail(), [mail])
    }
  }

  func testPaginationSurvivesRestartAndIncrementalSync() throws {
    try withDatabase { url in
      do {
        let database = try Database(url: url)
        try database.saveMailSnapshot(
          [], historyID: "100", nextPage: "older-page", updatesPagination: true)
        try database.saveMailSnapshot([], historyID: "101")
      }
      let reopened = try Database(url: url)
      XCTAssertEqual(try reopened.load(String.self, key: "gmailNextPage"), "older-page")
      try reopened.saveMailSnapshot([], historyID: "102", updatesPagination: true)
      XCTAssertEqual(try reopened.load(String.self, key: "gmailNextPage"), "")
    }
  }

  func testDecodingVersionCommitsWithSnapshotAndNilPreservesItAcrossRestart() throws {
    try withDatabase { url in
      let mail = Samples.mail[0]
      do {
        let database = try Database(url: url)
        try database.saveMailSnapshot([], historyID: "before", decodingVersion: 1)
        try database.saveMailSnapshot(
          [mail], historyID: "after", decodingVersion: GmailMessage.decodingVersion)
        XCTAssertEqual(
          try database.load(Int.self, key: "mailDecodingVersion"), GmailMessage.decodingVersion)
        try database.saveMailSnapshot([mail])
      }
      let reopened = try Database(url: url)
      XCTAssertEqual(try reopened.loadMail(), [mail])
      XCTAssertEqual(try reopened.load(String.self, key: "gmailHistoryID"), "after")
      XCTAssertEqual(
        try reopened.load(Int.self, key: "mailDecodingVersion"), GmailMessage.decodingVersion)
    }
  }
}
