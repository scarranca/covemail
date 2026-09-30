import XCTest

@testable import CoveCore

/// Gmail updates for stored emails that aren't loaded must keep their local state.
final class ArchivedMailMergeTests: XCTestCase {
  private var directory: URL!
  override func setUp() {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }
  override func tearDown() { try? FileManager.default.removeItem(at: directory) }

  private func store() throws -> (Database, live: [Mail], archived: Mail) {
    let database = try Database(url: directory.appendingPathComponent("mail.sqlite"))
    var archived = Samples.mail[0]
    archived.id = "old"
    archived.labels = ["CATEGORY_UPDATES"]
    archived.date = Date().addingTimeInterval(-400 * 86_400)
    var live = Samples.mail[1]
    live.id = "new"
    live.labels = ["INBOX"]
    live.date = Date()
    try database.storeArchived([archived])
    try database.saveMailSnapshot([live])
    XCTAssertNotNil(archived.decision)
    return (database, [live], archived)
  }
  private let window: (Mail) -> Bool = { $0.labels.contains("INBOX") || $0.date > Date().addingTimeInterval(-90 * 86_400) }

  func testLabelChangeAndRefetchKeepTheDecisionAndStayArchived() throws {
    let (database, live, archived) = try store()
    let relabeled = try GmailSyncResult(labels: ["old": ["IMPORTANT"]], historyID: "2")
      .merging(into: live, store: database, keepsLoaded: window)
    XCTAssertEqual(relabeled.map(\.id), ["new"])
    var refetched = archived
    refetched.decision = nil
    refetched.labels = ["STARRED"]  // starred now, but this window rule leaves it archived
    refetched.body += "\nRe-decoded"
    let merged = try GmailSyncResult(messages: [refetched], historyID: "3")
      .merging(into: relabeled, store: database, keepsLoaded: window)
    XCTAssertEqual(merged.map(\.id), ["new"])
    try database.saveMailSnapshot(merged)
    let stored = try XCTUnwrap(database.loadMessages(ids: ["old"]).first)
    XCTAssertEqual(stored.decision, archived.decision)
    XCTAssertEqual(stored.labels, ["STARRED"])
    XCTAssertTrue(stored.body.hasSuffix("Re-decoded"))
  }

  func testArchivedEmailMovedToInboxJoinsTheLiveMailbox() throws {
    let (database, live, archived) = try store()
    let merged = try GmailSyncResult(labels: ["old": ["INBOX"]], historyID: "2")
      .merging(into: live, store: database, keepsLoaded: window)
    XCTAssertEqual(Set(merged.map(\.id)), ["new", "old"])
    XCTAssertEqual(merged.first { $0.id == "old" }?.decision, archived.decision)
    try database.saveMailSnapshot(merged)
    XCTAssertEqual(Set(try Database(url: directory.appendingPathComponent("mail.sqlite"))
      .loadMail(since: Date().addingTimeInterval(-90 * 86_400)).map(\.id)), ["new", "old"])
  }

  func testGmailDeletionPurgesTheArchivedCopy() throws {
    let (database, live, _) = try store()
    let merged = try GmailSyncResult(deletedIDs: ["old"], historyID: "2")
      .merging(into: live, store: database, keepsLoaded: window)
    XCTAssertEqual(merged.map(\.id), ["new"])
    XCTAssertEqual(try database.storedMessageIDs(), ["new"])
  }

  func testSearchResultsAdoptTheStoredCopy() throws {
    let (database, live, archived) = try store()
    var fromGmail = archived
    fromGmail.decision = nil
    var fresh = Samples.mail[2]
    fresh.id = "fresh"
    let adopted = try database.adopting([fromGmail, fresh, live[0], fresh], live: Set(live.map(\.id)))
    XCTAssertEqual(adopted.map(\.id), ["old", "fresh"])
    XCTAssertEqual(adopted[0].decision, archived.decision)
  }
}
