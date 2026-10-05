import CoveCore
import Foundation
import XCTest
@testable import Cove

/// About you sync on the Mac, against an in-memory `/v1/personal`.
@MainActor final class PersonalSyncTests: XCTestCase {
  private func store(_ db: Database, account: String = "fixture@example.com") throws -> AppStore {
    try AppStore(database: db, accountEmail: account, gmail: GmailClient(), gmailTokenProvider: { "fixture" }, syncClock: { Date() })
  }
  private func database() throws -> (Database, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return (try Database(url: root.appendingPathComponent("mail.sqlite"), encryptionKey: Data(repeating: 9, count: 32),
                         namespace: "personal-fixture"), root)
  }

  func testTakesTheServerCopyThenSendsALaterEditAndRemembersOnlyForThisAccount() async throws {
    let (db, root) = try database(); defer { try? FileManager.default.removeItem(at: root) }
    var on = PersonalSyncState(); on.enabled = true; on.account = "fixture@example.com"
    try db.save(on, key: "personalSync")
    let server = PersonalServer()
    await server.seed(role: "Founder", updatedAt: "2026-10-05T10:00:00Z")
    let client = try CloudMailClient(baseURL: URL(string: "https://sync.example.com")!, transport: server)
    let mac = try store(db)
    XCTAssertTrue(mac.personalSyncOn)

    // A Mac that never edited About you adopts the iPhone's copy, keeping the iPhone's date.
    await mac.syncPersonal(client: client, token: { "fixture" })
    XCTAssertEqual(mac.preferences.personal?.role, "Founder")
    XCTAssertEqual(mac.preferences.personal?.updatedAt, ISO8601DateFormatter().date(from: "2026-10-05T10:00:00Z"))
    XCTAssertEqual(mac.personalSync.revision, "1")
    let putsAfterApply = await server.puts.count
    XCTAssertEqual(putsAfterApply, 0, "an applied copy is not sent straight back")
    XCTAssertEqual(mac.personalSyncStatus, "Up to date with your other devices")

    // An edit here is newer: it goes up, with only About you fields.
    var edited = try XCTUnwrap(mac.preferences.personal)
    edited.role = "CEO"; edited.updatedAt = Date()
    mac.preferences.personal = edited
    await mac.syncPersonal(client: client, token: { "fixture" })
    let puts = await server.puts
    let body = try XCTUnwrap(puts.last)
    XCTAssertEqual((body["personal"] as? [String: Any])?["role"] as? String, "CEO")
    XCTAssertEqual(Set(body.keys), ["baseRevision", "personal", "updatedAt"])
    XCTAssertEqual(mac.personalSync.revision, "2")

    // Restart keeps sync on; another account on the same store starts with it off.
    XCTAssertEqual(try store(db).personalSync.revision, "2")
    XCTAssertFalse(try store(db, account: "other@example.com").personalSyncOn)
  }

  func testRemovingTheServerCopyTurnsSyncOffAndKeepsTheLocalCopy() async throws {
    let (db, root) = try database(); defer { try? FileManager.default.removeItem(at: root) }
    var on = PersonalSyncState(); on.enabled = true; on.account = "fixture@example.com"
    try db.save(on, key: "personalSync")
    let server = PersonalServer()
    await server.seed(role: "Founder", updatedAt: "2026-10-05T10:00:00Z")
    let client = try CloudMailClient(baseURL: URL(string: "https://sync.example.com")!, transport: server)
    let mac = try store(db)
    await mac.syncPersonal(client: client, token: { "fixture" })
    await mac.removePersonalCloudCopy(client: client, token: { "fixture" })
    let deleted = await server.deleted
    XCTAssertTrue(deleted)
    XCTAssertFalse(mac.personalSyncOn)
    XCTAssertEqual(mac.preferences.personal?.role, "Founder")
    XCTAssertFalse(try store(db).personalSyncOn)
  }
}

private actor PersonalServer: HTTPTransport {
  private var revision = 0
  private var personal: [String: Any]?
  private var updatedAt: String?
  private(set) var puts: [[String: Any]] = []
  private(set) var deleted = false

  func seed(role: String, updatedAt: String) {
    revision = 1
    personal = ["name": "Ana", "role": role, "company": "", "about": "", "projects": [], "notes": [], "signature": "", "enabled": true]
    self.updatedAt = updatedAt
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    func reply(_ object: Any, _ status: Int = 200) -> (Data, HTTPURLResponse) {
      (try! JSONSerialization.data(withJSONObject: object),
       HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    guard request.url?.path == "/v1/personal" else { return reply(["error": "not_found"], 404) }
    switch request.httpMethod {
    case "PUT":
      let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
      puts.append(body)
      guard body["baseRevision"] as? String == String(revision) else { return reply(["error": "personal_conflict"], 409) }
      revision += 1; personal = body["personal"] as? [String: Any]; updatedAt = body["updatedAt"] as? String
      return reply(["revision": String(revision)])
    case "DELETE":
      deleted = true; revision = 0; personal = nil; updatedAt = nil
      return reply(["deleted": true])
    default:
      let value: Any = personal ?? NSNull()
      let date: Any = updatedAt ?? NSNull()
      return reply(["revision": String(revision), "personal": value, "updatedAt": date])
    }
  }
}
